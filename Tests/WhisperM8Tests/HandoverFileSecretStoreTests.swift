import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Option A (Vics Auflagen 13.11.2026): Das Einmal-Geheimnis liegt als Datei
/// 0600 im 0700-Ordner des Aufbewahrers, nie im Schlüsselbund.
final class HandoverFileSecretStoreTests: XCTestCase {
    private var directory: URL!
    private var paths: HandoverPaths { HandoverPaths(directory: directory) }
    private var store: HandoverFileSecretStore { HandoverFileSecretStore(paths: paths) }

    override func setUpWithError() throws {
        directory = try HandoverTestSupport.makeDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mode(_ url: URL) -> mode_t {
        var st = stat()
        lstat(url.path, &st)
        return st.st_mode & 0o777
    }

    func testStoreLoadRemove() {
        XCTAssertEqual(store.load(), .missing)
        let secret = HandoverSecret.make()
        XCTAssertTrue(store.store(secret))
        XCTAssertEqual(mode(paths.secretFileURL), 0o600)
        XCTAssertEqual(mode(paths.directory), 0o700)
        XCTAssertEqual(store.load(), .found(secret))
        store.remove()
        XCTAssertEqual(store.load(), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.secretFileURL.path))
    }

    func testNewStoreReplacesAStaleOwnFile() {
        XCTAssertTrue(store.store(HandoverSecret.make()))
        let second = HandoverSecret.make()
        XCTAssertTrue(store.store(second))
        XCTAssertEqual(store.load(), .found(second))
    }

    func testRejectsMalformedSecret() {
        XCTAssertFalse(store.store("kurz"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.secretFileURL.path))
    }

    func testNeverFollowsASymlink() throws {
        let target = directory.appendingPathComponent("anderswo")
        try HandoverSecret.make().write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: paths.secretFileURL, withDestinationURL: target)
        if case .found = store.load() { XCTFail("Symlink gelesen") }
        XCTAssertFalse(store.store(HandoverSecret.make()), "Symlink wird nicht ersetzt")
        store.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "Ziel des Symlinks unberührt")
    }

    func testRefusesAFileOthersCouldRead() {
        XCTAssertTrue(store.store(HandoverSecret.make()))
        chmod(paths.secretFileURL.path, 0o644)
        if case .found = store.load() { XCTFail("für andere lesbare Datei akzeptiert") }
    }

    /// Der Aufbewahrer löscht das Geheimnis bei seinem Ende.
    func testKeeperRemovesTheSecretWhenItFinishes() throws {
        XCTAssertTrue(store.store(HandoverSecret.make()))
        let keeper = HandoverKeeper(configuration: .init(
            paths: paths, runID: "r", holdSeconds: 30, depositSeconds: 10, ioTimeout: 5, ackTimeout: 5,
            peerPolicy: HandoverPeerPolicy(allowedExecutablePaths: []), logToFile: false))
        try keeper.start(onFinish: { _ in })
        keeper.queue.sync { keeper.finish(.terminated) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.secretFileURL.path))
    }

    /// Vic zu 565433f7: Starb der Aufbewahrer (SIGKILL, Neustart des Macs),
    /// räumt das Aufräumen der Reste auch das Geheimnis weg.
    func testLeftoversOfADeadKeeperIncludeTheSecret() {
        XCTAssertTrue(store.store(HandoverSecret.make()))
        XCTAssertFalse(HandoverKeeperLock.isHeld(paths: paths), "kein lebender Aufbewahrer")
        HandoverKeeperLock.removeLeftovers(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.secretFileURL.path))
    }

    /// Auflage 1: kein Schlüsselbund-Aufruf mehr im Übergabe-Weg.
    func testHandoverPathUsesTheFileStoreAndNoKeychain() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent("WhisperM8/Services/AgentChats/Handover")
        for file in ["HandoverTakeService+Live.swift", "HandoverRestartService.swift"] {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("HandoverSecretStores.live("), file)
            XCTAssertFalse(text.contains("HandoverSecretStore.live("), "\(file) nimmt den Schlüsselbund")
        }
        XCTAssertTrue(HandoverSecretStores.live(paths: paths) is HandoverFileSecretStore)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        for file in files where file != "HandoverSecretStore.swift" {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("SecItem"), "\(file) ruft den Schlüsselbund")
        }
    }
}
