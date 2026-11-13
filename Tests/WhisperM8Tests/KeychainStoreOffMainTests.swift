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
            release.wait()
            return (errSecSuccess, value.data(using: .utf8))
        }

        func update(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
        func add(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
        func probe(service: String, account: String) -> OSStatus { errSecSuccess }
        func delete(service: String, account: String) -> OSStatus { errSecSuccess }
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
        // Warten, ohne den Main Thread zu blockieren: Der Lesevorgang muss
        // anlaufen, während dieser Test selbst auf dem Main Actor läuft.
        await Task.detached { backend.readStarted.wait() }.value
        XCTAssertTrue(Thread.isMainThread, "der Main Actor läuft weiter, während der Dialog offen ist")
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
        await Task.detached { backend.readStarted.wait() }.value
        async let b = store.loadOffMain(key: "k")
        // Dem zweiten Aufruf Zeit geben, sich an den laufenden Lesevorgang zu hängen.
        try? await Task.sleep(nanoseconds: 50_000_000)
        backend.release.signal()

        let values = await [a, b]
        XCTAssertEqual(values, ["secret", "secret"])
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
        await Task.detached { backend.readStarted.wait() }.value
        XCTAssertEqual(store.save(key: "k", value: "fresh"), .saved)
        backend.release.signal()
        _ = await pending

        XCTAssertEqual(store.load(key: "k"), "fresh")
    }

    func testDeleteDuringPendingReadLeavesNoStaleCopy() async {
        let backend = GatedBackend()
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)

        async let pending = store.loadOffMain(key: "k")
        await Task.detached { backend.readStarted.wait() }.value
        store.delete(key: "k")
        backend.release.signal()
        _ = await pending

        backend.value = "after-delete"
        backend.release.signal()
        XCTAssertEqual(store.load(key: "k"), "after-delete", "nach dem Löschen wird neu gelesen, nicht der alte Wert aus dem Speicher")
    }
}
