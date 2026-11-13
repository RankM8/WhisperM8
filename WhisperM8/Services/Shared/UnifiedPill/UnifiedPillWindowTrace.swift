import CoreGraphics
import Foundation
import QuartzCore

/// Mitschnitt des Übergangs Status-Pille ↔ Diktat aus Sicht der
/// Fensterverwaltung (`whisperm8 debug pill`): Welche Fenster der App wann auf
/// dem Bildschirm stehen und wo. Prüft ohne Bildschirmaufnahme, dass nie
/// keine Pille steht und beide Fenster dieselbe Mitte haben.
///
/// Grenze: Die Fensterliste weiß nicht, ob ein Fenster schon ein Bild
/// gezeichnet hat. Was der Bildschirm wirklich zeigt, klärt nur eine
/// Aufnahme (Doku: docs/features/ui-testing.md, Stufe 3).
struct UnifiedPillWindowSample: Equatable {
    struct Window: Equatable {
        var number: Int
        /// Quartz-Koordinaten (oben links), Punkte.
        var bounds: CGRect
        var alpha: Double
    }

    /// Millisekunden seit Beginn des Mitschnitts.
    var time: Double
    var windows: [Window]
}

struct UnifiedPillTraceEvent: Equatable {
    var time: Double
    var name: String
}

/// Auswertung, rein und testbar.
struct UnifiedPillTraceVerdict: Equatable {
    /// Längste Zeit, in der weder Status- noch Diktat-Fenster stand (ms),
    /// zwischen dem ersten Auftauchen des Diktats und dem Ende des Mitschnitts.
    var longestGapMs: Double
    /// Größter senkrechter Abstand der Fenstermitten von Status- und
    /// Diktat-Fenster bzw. des Diktats zur Status-Pille vom Start (pt).
    var maxCenterOffset: Double
    /// Zeit, in der beide Fenster zugleich standen (ms), je Übergabe summiert.
    var overlapMs: Double
    var dictationAppearedMs: Double?
    var statusHiddenMs: Double?
    var statusBackMs: Double?
    var dictationGoneMs: Double?

    var isSeamless: Bool { longestGapMs == 0 && maxCenterOffset <= 0.5 }

    static func evaluate(
        samples: [UnifiedPillWindowSample], dictationWindow: Int?, statusWindows: Set<Int>
    ) -> UnifiedPillTraceVerdict {
        var verdict = UnifiedPillTraceVerdict(longestGapMs: 0, maxCenterOffset: 0, overlapMs: 0)
        guard let dictationWindow else { return verdict }
        var gapStart: Double?
        var overlapStart: Double?
        var statusCenterAtStart: Double?
        var sawDictation = false
        var statusWasShown = false
        for (index, sample) in samples.enumerated() {
            let dictation = sample.windows.first { $0.number == dictationWindow && $0.alpha > 0 }
            let status = sample.windows.first { statusWindows.contains($0.number) && $0.alpha > 0 }
            if statusCenterAtStart == nil, let status { statusCenterAtStart = Double(status.bounds.midY) }
            if let dictation {
                if !sawDictation { verdict.dictationAppearedMs = sample.time }
                sawDictation = true
                if let reference = status.map({ Double($0.bounds.midY) }) ?? statusCenterAtStart {
                    verdict.maxCenterOffset = max(verdict.maxCenterOffset, abs(Double(dictation.bounds.midY) - reference))
                }
            } else if sawDictation, verdict.dictationGoneMs == nil {
                verdict.dictationGoneMs = sample.time
            }
            if sawDictation {
                if status == nil, statusWasShown, verdict.statusHiddenMs == nil { verdict.statusHiddenMs = sample.time }
                if status != nil, verdict.statusHiddenMs != nil, verdict.statusBackMs == nil { verdict.statusBackMs = sample.time }
            }
            statusWasShown = status != nil || statusWasShown
            let end = index + 1 < samples.count ? samples[index + 1].time : sample.time
            if sawDictation, dictation == nil, status == nil {
                gapStart = gapStart ?? sample.time
                verdict.longestGapMs = max(verdict.longestGapMs, end - gapStart!)
            } else {
                gapStart = nil
            }
            if dictation != nil, status != nil {
                overlapStart = overlapStart ?? sample.time
            } else if let start = overlapStart {
                verdict.overlapMs += sample.time - start
                overlapStart = nil
            }
        }
        return verdict
    }
}

/// Liest die Fensterliste abseits des Main Threads in dichter Folge (etwa
/// jede Millisekunde) und merkt sich nur Änderungen. Ein hängender Main
/// Thread hält den Mitschnitt also nicht auf.
final class UnifiedPillWindowTracer: @unchecked Sendable {
    private let pid: pid_t
    private let start = CACurrentMediaTime()
    private let lock = NSLock()
    private var samples: [UnifiedPillWindowSample] = []
    private var events: [UnifiedPillTraceEvent] = []
    private var running = true
    private let finished = DispatchSemaphore(value: 0)

    init(pid: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.pid = pid
        let thread = Thread { [self] in sampleLoop() }
        thread.qualityOfService = .userInteractive
        thread.name = "whisperm8.pill-trace"
        thread.start()
    }

    var now: Double { (CACurrentMediaTime() - start) * 1000 }

    func mark(_ name: String) {
        let time = now
        lock.lock()
        events.append(UnifiedPillTraceEvent(time: time, name: name))
        lock.unlock()
    }

    /// Hält den Mitschnitt an und liefert alles.
    func stop() -> (samples: [UnifiedPillWindowSample], events: [UnifiedPillTraceEvent]) {
        lock.lock()
        running = false
        lock.unlock()
        finished.wait()
        lock.lock()
        defer { lock.unlock() }
        return (samples, events)
    }

    private func sampleLoop() {
        var last: [UnifiedPillWindowSample.Window]?
        while true {
            lock.lock()
            let keepGoing = running
            lock.unlock()
            guard keepGoing else { break }
            let windows = Self.ownWindows(pid: pid)
            if windows != last {
                last = windows
                let sample = UnifiedPillWindowSample(time: now, windows: windows)
                lock.lock()
                samples.append(sample)
                lock.unlock()
            }
            usleep(500)
        }
        finished.signal()
    }

    private static func ownWindows(pid: pid_t) -> [UnifiedPillWindowSample.Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return .init(number: number, bounds: bounds, alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1)
        }
    }
}
