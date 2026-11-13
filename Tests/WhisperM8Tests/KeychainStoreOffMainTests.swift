import XCTest
import Security
@testable import WhisperM8

/// Schlüsselbund abseits des Main Threads (Hänger 13.11.2026): Nach einem neuen
/// Build blockiert der erste Lesevorgang, bis der macOS-Dialog beantwortet ist.
final class KeychainStoreOffMainTests: XCTestCase {
    /// Backend, dessen Lesevorgang wartet, bis der Test ihn freigibt — wie ein
    /// offener Schlüsselbund-Dialog.
    final class GatedBackend: KeychainBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        private var _readOnMainThread = false
        let readStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var value = "secret"

        var reads: Int { lock.withLock { _reads } }
        var readOnMainThread: Bool { lock.withLock { _readOnMainThread } }

        func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
            lock.withLock {
                _reads += 1
                if Thread.isMainThread { _readOnMainThread = true }
            }
            readStarted.signal()
            // Timeout statt ewig: ein Rückfall soll rot werden, nicht hängen.
            guard release.wait(timeout: .now() + 5) == .success else {
                return (errSecInteractionNotAllowed, nil)
            }
            return (errSecSuccess, value.data(using: .utf8))
        }

        func update(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
        func add(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
        func probe(service: String, account: String) -> OSStatus { errSecSuccess }
        func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    }

    /// Wartet abseits des Main Threads, bis der Lesevorgang angelaufen ist.
    private func awaitReadStarted(_ backend: GatedBackend, file: StaticString = #filePath, line: UInt = #line) async {
        let started = await Task.detached { backend.readStarted.wait(timeout: .now() + 5) == .success }.value
        if !started { XCTFail("Lesevorgang ist nicht angelaufen", file: file, line: line) }
    }

    private var defaults: UserDefaults!
    private let suite = "KeychainStoreOffMainTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Während der Lesevorgang hängt, bleibt der Main Thread frei.
    @MainActor
    func testReadRunsOffTheMainThreadAndKeepsItFree() async {
        let backend = GatedBackend()
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)

        let reading = Task { @MainActor in await store.loadOffMain(key: "k") }
        // Der Lesevorgang hängt, während dieser Test selbst auf dem Main Actor
        // weiterläuft. Läse `loadOffMain` auf dem Main Thread, käme er nie an.
        await awaitReadStarted(backend)
        backend.release.signal()

        let value = await reading.value
        XCTAssertEqual(value, "secret")
        XCTAssertFalse(backend.readOnMainThread)
    }

    func testValueStaysInMemoryForTheAppRun() async {
        let backend = GatedBackend()
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)
        backend.release.signal()

        let first = await store.loadOffMain(key: "k")
        let second = await store.loadOffMain(key: "k")
        XCTAssertEqual(first, "secret")
        XCTAssertEqual(second, "secret")
        XCTAssertEqual(backend.reads, 1, "zweites Diktat liest aus dem Speicher, kein zweiter Dialog")
    }

    /// Zwei Diktate, während der Dialog noch offen ist: ein Zugriff, nicht zwei.
    func testConcurrentReadsShareOneKeychainAccess() async {
        let backend = GatedBackend()
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)

        async let a = store.loadOffMain(key: "k")
        await awaitReadStarted(backend)
        async let b = store.loadOffMain(key: "k")
        // Erst freigeben, wenn beide am selben Lesevorgang hängen.
        let deadline = Date().addingTimeInterval(5)
        while store.waitingReaders(for: "k") < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(store.waitingReaders(for: "k"), 2)
        backend.release.signal()

        let values = await [a, b]
        XCTAssertEqual(values, ["secret", "secret"])
        XCTAssertEqual(backend.reads, 1)
    }

    /// ESC bei offenem Dialog: der Wartende kehrt sofort zurück, der
    /// Lesevorgang läuft weiter und füllt den Cache fürs nächste Diktat.
    func testCancelledWaiterReturnsAtOnceAndReadStillFillsCache() async {
        let backend = GatedBackend()
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)

        let waiting = Task { await store.loadOffMain(key: "k") }
        await awaitReadStarted(backend)
        waiting.cancel()
        let cancelledValue = await waiting.value
        XCTAssertNil(cancelledValue, "kehrt zurück, obwohl der Dialog noch offen ist")

        backend.release.signal()
        // Hängt sich an den noch laufenden Lesevorgang oder liest aus dem Cache.
        let next = await store.loadOffMain(key: "k")
        XCTAssertEqual(next, "secret")
        XCTAssertEqual(backend.reads, 1)
    }

    func testForgetCachedReadsAgain() async {
        let backend = GatedBackend()
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)
        backend.release.signal()
        _ = await store.loadOffMain(key: "k")

        store.forgetCached(key: "k")
        backend.value = "new"
        backend.release.signal()
        let value = await store.loadOffMain(key: "k")
        XCTAssertEqual(value, "new")
        XCTAssertEqual(backend.reads, 2)
    }

    /// Ändert der User den Schlüssel in den Einstellungen, während ein alter
    /// Lesevorgang noch hängt, gewinnt der neue Schlüssel.
    func testSaveDuringPendingReadWins() async {
        let backend = GatedBackend()
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)

        async let pending = store.loadOffMain(key: "k")
        await awaitReadStarted(backend)
        XCTAssertEqual(store.save(key: "k", value: "fresh"), .saved)
        backend.release.signal()
        _ = await pending

        XCTAssertEqual(store.load(key: "k"), "fresh")
    }

    func testDeleteDuringPendingReadLeavesNoStaleCopy() async {
        let backend = GatedBackend()
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)

        async let pending = store.loadOffMain(key: "k")
        await awaitReadStarted(backend)
        store.delete(key: "k")
        backend.release.signal()
        _ = await pending

        backend.value = "after-delete"
        backend.release.signal()
        XCTAssertEqual(store.load(key: "k"), "after-delete", "nach dem Löschen wird neu gelesen, nicht der alte Wert aus dem Speicher")
    }

    /// Dialog abgelehnt: nichts im Cache, und eine alte UserDefaults-Kopie wird
    /// weder zurückgegeben noch über den echten Eintrag geschrieben.
    func testDeniedReadCachesNothingAndSkipsLegacyMigration() {
        final class DeniedBackend: KeychainBackend {
            var reads = 0
            var writes = 0
            func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
                reads += 1
                return (errSecUserCanceled, nil)
            }
            func update(service: String, account: String, data: Data) -> OSStatus { writes += 1; return errSecSuccess }
            func add(service: String, account: String, data: Data) -> OSStatus { writes += 1; return errSecSuccess }
            func probe(service: String, account: String) -> OSStatus { errSecSuccess }
            func delete(service: String, account: String) -> OSStatus { errSecSuccess }
        }
        defaults.set("legacy", forKey: "k")
        let backend = DeniedBackend()
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)

        XCTAssertNil(store.load(key: "k"))
        XCTAssertNil(store.load(key: "k"))
        XCTAssertEqual(backend.reads, 2, "kein Cache nach Ablehnung: nächster Versuch fragt erneut")
        XCTAssertEqual(backend.writes, 0)
        XCTAssertEqual(defaults.string(forKey: "k"), "legacy")
    }
}
