import CoreServices
import Foundation
import XCTest
@testable import WhisperM8

/// FSEvents-Rückrufe dürfen nie ein freigegebenes Objekt erreichen (Absturz in
/// Oles Suite am 13.11.2026: SIGSEGV in `ClaudeRegistryStatusSource`).
///
/// Was die Tests beweisen:
/// - `…DroppedWithoutStop…`: Vor dem Fix stürzt der Testprozess hier
///   zuverlässig ab (Besitzer weg, Stream läuft weiter, nächstes Ereignis trifft
///   toten Speicher — gemessen: erste Runde). Danach läuft er durch.
/// - `…StoppedUnderLoad…`: Belastungstest für das seltene Rennen zwischen
///   `Invalidate` auf dem Main Thread und einem schon eingereihten Rückruf. Er
///   schlägt ohne Fix nicht zuverlässig an; er zeigt nur, dass der Weg unter
///   Last hält.
/// - Die `FSEventsSubscription`-Tests prüfen die Zusage selbst: Nach `cancel()`
///   oder dem Ende der Subscription erreicht kein Rückruf mehr den Handler.
@MainActor
final class FSEventsLifetimeTests: XCTestCase {
    private var tempDir: URL!
    private var writer: Thread?
    nonisolated(unsafe) private var writing = false

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsevents-lifetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        stopWriting()
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Schreibt ständig Dateien in `directory`, damit FSEvents Ereignisse hat.
    private func startWriting(into directory: URL) {
        writing = true
        let thread = Thread { [unowned self] in
            var index = 0
            while self.writing {
                try? Data("{\"pid\": \(4000 + index % 40)}".utf8)
                    .write(to: directory.appendingPathComponent("\(4000 + index % 40).json"))
                index += 1
                usleep(300)
            }
        }
        thread.start()
        writer = thread
    }

    private func stopWriting() {
        writing = false
        writer = nil
        Thread.sleep(forTimeInterval: 0.05)
    }

    private func sessionsRoot(_ name: String) throws -> ClaudeSessionRegistry.Root {
        let url = tempDir.appendingPathComponent("\(name)/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return .init(profileName: name, url: url)
    }

    func testRegistrySourceDroppedWithoutStopNeverCrashes() async throws {
        let root = try sessionsRoot("drop")
        startWriting(into: root.url)
        for _ in 0..<40 {
            let source = ClaudeRegistryStatusSource(rootsProvider: { [root] }, isAlive: { _, _ in true })
            await source.rescan()
            XCTAssertEqual(source.watchedPaths, [root.url.path])
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...20)))
            // kein stop(): der Besitzer verschwindet mit laufendem Stream
        }
        // Ereignisse weiterlaufen lassen — hier stürzte der alte Code ab.
        try await Task.sleep(for: .milliseconds(800))
    }

    // MARK: FSEventsSubscription

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
        func increment() { lock.lock(); storage += 1; lock.unlock() }
    }

    private func makeSubscription(_ counter: Counter, queue: DispatchQueue) throws -> FSEventsSubscription {
        try XCTUnwrap(FSEventsSubscription(
            paths: [tempDir.path], latency: 0.01,
            flags: FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents),
            queue: queue,
            handler: { _, _ in counter.increment() }
        ))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }

    func testSubscriptionDeliversEventsWithFlags() throws {
        let queue = DispatchQueue(label: "fsevents-test")
        let counter = Counter()
        var flagsSeen = false
        let subscription = try XCTUnwrap(FSEventsSubscription(
            paths: [tempDir.path], latency: 0.01,
            flags: FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents),
            queue: queue,
            handler: { paths, flags in
                if !paths.isEmpty, paths.count == flags.count { flagsSeen = true }
                counter.increment()
            }
        ))
        defer { subscription.cancel() }
        startWriting(into: tempDir)
        waitUntil(5) { counter.value > 0 }
        XCTAssertGreaterThan(counter.value, 0)
        queue.sync {}
        XCTAssertTrue(flagsSeen, "Pfade und Flags passen nicht zusammen")
    }

    func testNoCallbackReachesHandlerAfterCancel() throws {
        let queue = DispatchQueue(label: "fsevents-test")
        let counter = Counter()
        let subscription = try makeSubscription(counter, queue: queue)
        startWriting(into: tempDir)
        waitUntil(5) { counter.value > 0 }
        subscription.cancel()
        XCTAssertFalse(subscription.isActive)
        queue.sync {} // alles, was schon eingereiht war
        let afterCancel = counter.value
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(counter.value, afterCancel, "Rückruf nach cancel()")
        subscription.cancel() // idempotent
    }

    func testDroppingSubscriptionStopsStream() throws {
        let queue = DispatchQueue(label: "fsevents-test")
        let counter = Counter()
        var subscription: FSEventsSubscription? = try makeSubscription(counter, queue: queue)
        startWriting(into: tempDir)
        waitUntil(5) { counter.value > 0 }
        XCTAssertNotNil(subscription)
        subscription = nil // deinit → cancel
        queue.sync {}
        let afterDrop = counter.value
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(counter.value, afterDrop, "Stream läuft nach dem Ende der Subscription weiter")
    }

    func testNoPathsMeansNoSubscription() {
        XCTAssertNil(FSEventsSubscription(paths: [], latency: 1, flags: 0, queue: .main, handler: { _, _ in }))
    }

    func testRegistrySourceStoppedUnderLoadNeverCrashes() async throws {
        let root = try sessionsRoot("stop")
        startWriting(into: root.url)
        for _ in 0..<150 {
            let source = ClaudeRegistryStatusSource(rootsProvider: { [root] }, isAlive: { _, _ in true })
            await source.rescan()
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...8)))
            source.stop()
        }
        try await Task.sleep(for: .milliseconds(300))
    }
}
