import CoreServices
import Foundation
import os

/// Ein FSEvents-Stream auf einer Dispatch-Queue, dessen Rückruf nie ein
/// freigegebenes Objekt erreicht.
///
/// Vorher gaben alle Beobachter `self` per `passUnretained` in den
/// Stream-Kontext. Zwei Wege führten dann zu einem Rückruf auf ein totes Objekt
/// (Absturz in Oles Suite am 13.11.2026, `ClaudeRegistryStatusSource`,
/// SIGSEGV in `OSAllocatedUnfairLock.withLock`):
/// - Der Besitzer verschwindet, ohne den Stream zu stoppen — der Stream läuft
///   weiter, das nächste Ereignis trifft Speicher, der niemandem mehr gehört
///   (im Nachbau sofort reproduzierbar).
/// - `Stop`/`Invalidate`/`Release` laufen auf dem Main Thread, der Rückruf auf
///   der Stream-Queue; ein schon empfangenes Ereignis kann danach noch
///   zugestellt werden (selten, unter Last).
///
/// Hier hält FSEvents eine kleine Box (retain/release im Kontext), nicht den
/// Besitzer. `cancel()` schaltet die Box unscharf (kein Handler mehr) und baut
/// den Stream ab; die letzte eigene Referenz auf die Box geht erst per
/// `queue.async` — die Queue ist seriell, also nach jedem Rückruf, der schon
/// läuft oder eingereiht ist. `deinit` ruft `cancel()`: Ein Besitzer, der ohne
/// Stopp verschwindet, nimmt seinen Stream mit.
///
/// Der Handler läuft auf `queue`. Er sollte seinen Besitzer nur schwach fangen.
final class FSEventsSubscription: @unchecked Sendable {
    /// Pfade und Flags eines Rückrufs.
    typealias Handler = (_ paths: [String], _ flags: [FSEventStreamEventFlags]) -> Void

    /// Vom Stream gehalten; trägt den Handler, solange die Subscription scharf ist.
    final class Box: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<Handler?>(initialState: nil)

        init(handler: @escaping Handler) {
            lock.withLock { $0 = handler }
        }

        var handler: Handler? { lock.withLock { $0 } }

        func disarm() { lock.withLock { $0 = nil } }
    }

    let queue: DispatchQueue
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var box: Box?

    /// `nil`, wenn FSEvents den Stream nicht anlegen kann (z. B. keine Pfade).
    init?(
        paths: [String],
        latency: CFTimeInterval,
        flags: FSEventStreamCreateFlags,
        queue: DispatchQueue,
        handler: @escaping Handler
    ) {
        guard !paths.isEmpty else { return nil }
        let box = Box(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Box>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            // Starke Referenz für die Dauer des Rückrufs.
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            guard let handler = box.handler,
                  let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else {
                return
            }
            let flags = (0..<min(count, paths.count)).map { eventFlags[$0] }
            handler(paths, flags)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags | FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }
        self.queue = queue
        self.stream = stream
        self.box = box
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        cancel()
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    /// Idempotent. Danach erreicht kein Rückruf mehr den Handler.
    func cancel() {
        lock.lock()
        let stream = self.stream
        let box = self.box
        self.stream = nil
        self.box = nil
        lock.unlock()
        box?.disarm()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // Die Box überlebt jeden Rückruf, der schon läuft oder eingereiht ist.
        if let box {
            queue.async { withExtendedLifetime(box) {} }
        }
    }
}
