import XCTest
import Security
@testable import WhisperM8

/// LR-SH-003 / LR-ONB-007: Der Keychain-Speicher meldet Write-Fehler und löscht
/// bei gescheiterter Migration keine Key-Kopie.
final class KeychainStoreTests: XCTestCase {
    final class FakeBackend: KeychainBackend {
        var updateStatus: OSStatus = errSecItemNotFound
        var addStatus: OSStatus = errSecSuccess
        var readStatus: OSStatus = errSecItemNotFound
        var readData: Data?
        var probeStatus: OSStatus = errSecItemNotFound

        func update(service: String, account: String, data: Data) -> OSStatus { updateStatus }
        func add(service: String, account: String, data: Data) -> OSStatus { addStatus }
        func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) { (readStatus, readData) }
        func probe(service: String, account: String) -> OSStatus { probeStatus }
        func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    }

    private var defaults: UserDefaults!
    private let suite = "KeychainStoreTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testSaveReportsFailureInsteadOfSilentlySucceeding() {
        let backend = FakeBackend()
        backend.addStatus = errSecAuthFailed
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)

        XCTAssertEqual(store.save(key: "k", value: "v"), .failed(status: errSecAuthFailed))
        XCTAssertNil(store.load(key: "k"), "ein gescheiterter Write darf nicht im Cache landen")
    }

    func testSaveSucceedsAndCaches() {
        let store = KeychainStore(service: "t", backend: FakeBackend(), defaults: defaults)
        XCTAssertEqual(store.save(key: "k", value: "v"), .saved)
        XCTAssertEqual(store.load(key: "k"), "v")
    }

    func testFailedMigrationKeepsLegacyUserDefaultsCopy() {
        defaults.set("legacy-key", forKey: "groqAPIKey")
        let backend = FakeBackend()
        backend.addStatus = errSecInteractionNotAllowed
        let store = KeychainStore(service: "t", backend: backend, defaults: defaults)

        XCTAssertEqual(store.load(key: "groqAPIKey"), "legacy-key")
        XCTAssertEqual(defaults.string(forKey: "groqAPIKey"), "legacy-key",
                       "einzige persistierte Kopie darf bei Keychain-Fehler nicht gelöscht werden")
    }

    func testSuccessfulMigrationRemovesLegacyCopy() {
        defaults.set("legacy-key", forKey: "groqAPIKey")
        let store = KeychainStore(service: "t", backend: FakeBackend(), defaults: defaults)

        XCTAssertEqual(store.load(key: "groqAPIKey"), "legacy-key")
        XCTAssertNil(defaults.string(forKey: "groqAPIKey"))
    }
}
