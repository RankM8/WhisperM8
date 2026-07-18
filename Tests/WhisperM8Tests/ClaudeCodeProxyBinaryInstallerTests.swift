import CryptoKit
import XCTest

@testable import WhisperM8

/// Tests für den Managed Download des Proxy-Binarys: Checksummen-Pflicht
/// (Pin bzw. Release-Sidecar), atomare Installation mit Versions-Stempel
/// und Update-Check über die GitHub-API — alles ohne Netz (Fake-Downloader),
/// aber mit echtem /usr/bin/tar.
final class ClaudeCodeProxyBinaryInstallerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Baut ein echtes tar.gz mit einem Fake-Binary und liefert (Tarball, SHA-256).
    private func makeTarball(binaryContent: String = "#!/bin/sh\necho fake-proxy\n") throws -> (Data, String) {
        let stage = tempDir.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let binary = stage.appendingPathComponent("claude-code-proxy")
        try binaryContent.write(to: binary, atomically: true, encoding: .utf8)

        let tarball = stage.appendingPathComponent("asset.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", tarball.path, "-C", stage.path, "claude-code-proxy"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let data = try Data(contentsOf: tarball)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, digest)
    }

    private func makeInstaller(
        responses: @escaping (URL) async throws -> Data
    ) -> ClaudeCodeProxyBinaryInstaller {
        ClaudeCodeProxyBinaryInstaller(
            directory: tempDir.appendingPathComponent("bin", isDirectory: true),
            architecture: "arm64",
            downloader: responses
        )
    }

    // MARK: Installation

    func testInstallVerifiesSidecarChecksumAndStampsVersion() async throws {
        let (tarball, digest) = try makeTarball()
        let installer = makeInstaller { url in
            if url.absoluteString.hasSuffix(".sha256") {
                return Data("\(digest)  claude-code-proxy-darwin-arm64.tar.gz\n".utf8)
            }
            return tarball
        }

        // 9.9.9 hat keinen Pin → Sidecar-Verifikation muss greifen.
        let installed = try await installer.install(version: "9.9.9")

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        XCTAssertEqual(installer.installedManagedVersion(), "9.9.9")
        let content = try String(contentsOf: installed, encoding: .utf8)
        XCTAssertTrue(content.contains("fake-proxy"))
    }

    func testInstallRejectsChecksumMismatch() async throws {
        let (tarball, _) = try makeTarball()
        let wrong = String(repeating: "ab", count: 32)
        let installer = makeInstaller { url in
            if url.absoluteString.hasSuffix(".sha256") {
                return Data("\(wrong)  claude-code-proxy-darwin-arm64.tar.gz\n".utf8)
            }
            return tarball
        }

        do {
            _ = try await installer.install(version: "9.9.9")
            XCTFail("Checksummen-Mismatch muss die Installation abbrechen")
        } catch let error as ClaudeCodeProxyBinaryInstaller.InstallerError {
            guard case .checksumMismatch = error else {
                return XCTFail("Falscher Fehler: \(error)")
            }
        }
        XCTAssertNil(installer.installedManagedVersion())
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.binaryURL.path))
    }

    func testKnownGoodVersionUsesPinnedChecksumNotSidecar() async throws {
        let (tarball, digest) = try makeTarball()
        // Pin der known-good-Version passt absichtlich NICHT auf unser
        // Fake-Tarball — der Sidecar (mit korrekter Checksumme) darf den
        // Pin nicht übersteuern können.
        var sidecarRequested = false
        let installer = makeInstaller { url in
            if url.absoluteString.hasSuffix(".sha256") {
                sidecarRequested = true
                return Data("\(digest)  claude-code-proxy-darwin-arm64.tar.gz\n".utf8)
            }
            return tarball
        }

        do {
            _ = try await installer.install(version: ClaudeCodeProxyBinaryInstaller.knownGoodVersion)
            XCTFail("Gepinnte Version darf nur mit exakt gepinnter Checksumme installieren")
        } catch let error as ClaudeCodeProxyBinaryInstaller.InstallerError {
            guard case .checksumMismatch = error else {
                return XCTFail("Falscher Fehler: \(error)")
            }
        }
        XCTAssertFalse(sidecarRequested, "Pin vorhanden → Sidecar darf nicht gefragt werden")
    }

    func testInstallOverwritesPreviousManagedVersionAtomically() async throws {
        let (first, firstDigest) = try makeTarball(binaryContent: "#!/bin/sh\necho v1\n")
        let (second, secondDigest) = try makeTarball(binaryContent: "#!/bin/sh\necho v2\n")
        var current = (first, firstDigest)
        let installer = makeInstaller { url in
            if url.absoluteString.hasSuffix(".sha256") {
                return Data("\(current.1)  x.tar.gz\n".utf8)
            }
            return current.0
        }

        _ = try await installer.install(version: "9.9.8")
        current = (second, secondDigest)
        _ = try await installer.install(version: "9.9.9")

        XCTAssertEqual(installer.installedManagedVersion(), "9.9.9")
        let content = try String(contentsOf: installer.binaryURL, encoding: .utf8)
        XCTAssertTrue(content.contains("echo v2"))
    }

    func testInstallRepairsBrokenPermissionsOnExistingTarget() async throws {
        // replaceItemAt uebernimmt auf Darwin die POSIX-Rechte des ZIELS —
        // ohne chmod NACH dem Replace bliebe ein 0600-Ziel unausfuehrbar.
        let (tarball, digest) = try makeTarball()
        let installer = makeInstaller { url in
            if url.absoluteString.hasSuffix(".sha256") {
                return Data("\(digest)  x.tar.gz\n".utf8)
            }
            return tarball
        }
        try FileManager.default.createDirectory(
            at: installer.binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("kaputt".utf8).write(to: installer.binaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: installer.binaryURL.path
        )

        _ = try await installer.install(version: "9.9.9")

        let permissions = try FileManager.default
            .attributesOfItem(atPath: installer.binaryURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.binaryURL.path))
    }

    // MARK: Versionsvergleich

    func testVersionComparisonIsNumericNotLexicographic() {
        XCTAssertTrue(ClaudeCodeProxyBinaryInstaller.isVersion("0.1.22", newerThan: "0.1.21"))
        XCTAssertTrue(ClaudeCodeProxyBinaryInstaller.isVersion("0.2.0", newerThan: "0.1.99"))
        XCTAssertTrue(ClaudeCodeProxyBinaryInstaller.isVersion("0.1.100", newerThan: "0.1.21"))
        XCTAssertFalse(ClaudeCodeProxyBinaryInstaller.isVersion("0.1.20", newerThan: "0.1.21"))
        XCTAssertFalse(ClaudeCodeProxyBinaryInstaller.isVersion("0.1.21", newerThan: "0.1.21"))
        // Fehlende Komponenten zaehlen als 0.
        XCTAssertTrue(ClaudeCodeProxyBinaryInstaller.isVersion("0.2", newerThan: "0.1.21"))
        XCTAssertFalse(ClaudeCodeProxyBinaryInstaller.isVersion("0.1", newerThan: "0.1.0"))
    }

    // MARK: Update-Check

    func testLatestVersionStripsTagPrefix() async throws {
        let installer = makeInstaller { _ in
            Data(#"{"tag_name":"v0.1.22"}"#.utf8)
        }
        let latest = try await installer.latestVersion()
        XCTAssertEqual(latest, "0.1.22")
    }

    func testLatestVersionFailsOnMalformedResponse() async {
        let installer = makeInstaller { _ in Data("not-json".utf8) }
        do {
            _ = try await installer.latestVersion()
            XCTFail("Kaputte API-Antwort muss ein Fehler sein")
        } catch let error as ClaudeCodeProxyBinaryInstaller.InstallerError {
            XCTAssertEqual(error, .latestVersionUnavailable)
        } catch {
            XCTFail("Falscher Fehlertyp: \(error)")
        }
    }

    // MARK: Release-URLs

    func testAssetURLsFollowReleaseNamingScheme() {
        let installer = makeInstaller { _ in Data() }
        XCTAssertEqual(
            installer.assetURL(version: "0.1.21").absoluteString,
            "https://github.com/raine/claude-code-proxy/releases/download/v0.1.21/claude-code-proxy-darwin-arm64.tar.gz"
        )
        XCTAssertEqual(
            installer.checksumSidecarURL(version: "0.1.21").absoluteString,
            "https://github.com/raine/claude-code-proxy/releases/download/v0.1.21/claude-code-proxy-darwin-arm64.sha256"
        )
    }
}
