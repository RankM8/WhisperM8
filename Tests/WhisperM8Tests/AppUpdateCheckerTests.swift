import XCTest
@testable import WhisperM8

// MARK: - SemanticVersion

final class SemanticVersionTests: XCTestCase {
    func testParsesPlainAndPrefixedVersions() {
        XCTAssertEqual(SemanticVersion("2.5.0"), SemanticVersion(major: 2, minor: 5, patch: 0))
        XCTAssertEqual(SemanticVersion("v2.5.0"), SemanticVersion(major: 2, minor: 5, patch: 0))
        XCTAssertEqual(SemanticVersion("V2.5.0"), SemanticVersion(major: 2, minor: 5, patch: 0))
        XCTAssertEqual(SemanticVersion(" 2.5.0 "), SemanticVersion(major: 2, minor: 5, patch: 0))
    }

    func testMissingComponentsDefaultToZero() {
        XCTAssertEqual(SemanticVersion("2.6"), SemanticVersion(major: 2, minor: 6, patch: 0))
        XCTAssertEqual(SemanticVersion("3"), SemanticVersion(major: 3, minor: 0, patch: 0))
    }

    func testGarbageParsesToNil() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("2.5.0-beta"), "Prerelease-Suffixe werden bewusst nicht unterstützt")
        XCTAssertNil(SemanticVersion("2..0"))
        XCTAssertNil(SemanticVersion("2.5.0.1"))
        XCTAssertNil(SemanticVersion("abc"))
        XCTAssertNil(SemanticVersion("2.-1.0"))
    }

    func testComparisonIsNumericNotLexicographic() {
        XCTAssertLessThan(SemanticVersion("2.5.0")!, SemanticVersion("2.6.0")!)
        XCTAssertLessThan(SemanticVersion("2.9.9")!, SemanticVersion("2.10.0")!)
        XCTAssertLessThan(SemanticVersion("2.5.9")!, SemanticVersion("3.0.0")!)
        XCTAssertGreaterThan(SemanticVersion("2.5.1")!, SemanticVersion("2.5.0")!)
        XCTAssertEqual(SemanticVersion("v2.5.0")!, SemanticVersion("2.5")!)
        XCTAssertFalse(SemanticVersion("2.5.0")! < SemanticVersion("2.5.0")!)
    }
}

// MARK: - AppUpdateChecker

@MainActor
final class AppUpdateCheckerTests: XCTestCase {
    private func releaseJSON(tag: String, url: String = "https://github.com/RankM8/WhisperM8/releases/tag/vX") -> Data {
        Data("""
        {"tag_name": "\(tag)", "html_url": "\(url)", "name": "Release \(tag)"}
        """.utf8)
    }

    private func makeChecker(
        currentVersion: String? = "2.5.0",
        response: Result<Data, Error>,
        brewInstalled: Bool = true
    ) -> AppUpdateChecker {
        AppUpdateChecker(
            currentVersionProvider: { currentVersion },
            fetchLatestRelease: { try response.get() },
            brewReceiptExists: { brewInstalled },
            isAutomaticCheckEnabled: { true }
        )
    }

    func testNewerRemoteVersionYieldsAvailableWithBrewFlag() async {
        let checker = makeChecker(
            response: .success(releaseJSON(tag: "v2.6.0", url: "https://github.com/RankM8/WhisperM8/releases/tag/v2.6.0")),
            brewInstalled: true
        )

        await checker.checkNow()

        guard case .available(let info) = checker.state else {
            return XCTFail("Erwartet .available, war \(checker.state)")
        }
        XCTAssertEqual(info.latestVersion.description, "2.6.0")
        XCTAssertEqual(info.currentVersion.description, "2.5.0")
        XCTAssertTrue(info.isBrewInstall)
        XCTAssertEqual(info.releaseURL.absoluteString, "https://github.com/RankM8/WhisperM8/releases/tag/v2.6.0")
        XCTAssertNotNil(checker.lastCheckedAt)
    }

    func testNonBrewInstallIsReflectedInInfo() async {
        let checker = makeChecker(response: .success(releaseJSON(tag: "v9.0.0")), brewInstalled: false)
        await checker.checkNow()
        guard case .available(let info) = checker.state else {
            return XCTFail("Erwartet .available, war \(checker.state)")
        }
        XCTAssertFalse(info.isBrewInstall)
    }

    func testEqualVersionIsUpToDate() async {
        let checker = makeChecker(response: .success(releaseJSON(tag: "v2.5.0")))
        await checker.checkNow()
        XCTAssertEqual(checker.state, .upToDate(current: SemanticVersion("2.5.0")!))
    }

    func testOlderRemoteNeverOffersDowngrade() async {
        // Dev-Build ist dem Release voraus → kein Badge.
        let checker = makeChecker(currentVersion: "2.7.0", response: .success(releaseJSON(tag: "v2.6.0")))
        await checker.checkNow()
        XCTAssertEqual(checker.state, .upToDate(current: SemanticVersion("2.7.0")!))
    }

    func testNetworkErrorYieldsFailed() async {
        let checker = makeChecker(response: .failure(URLError(.notConnectedToInternet)))
        await checker.checkNow()
        guard case .failed = checker.state else {
            return XCTFail("Erwartet .failed, war \(checker.state)")
        }
    }

    func testMalformedResponseYieldsFailed() async {
        let checker = makeChecker(response: .success(Data("not json".utf8)))
        await checker.checkNow()
        guard case .failed = checker.state else {
            return XCTFail("Erwartet .failed, war \(checker.state)")
        }
    }

    func testUnparsableTagYieldsFailed() async {
        let checker = makeChecker(response: .success(releaseJSON(tag: "nightly-build")))
        await checker.checkNow()
        guard case .failed = checker.state else {
            return XCTFail("Erwartet .failed, war \(checker.state)")
        }
    }

    func testMissingBundleVersionYieldsFailed() async {
        let checker = makeChecker(currentVersion: nil, response: .success(releaseJSON(tag: "v2.6.0")))
        await checker.checkNow()
        guard case .failed = checker.state else {
            return XCTFail("Erwartet .failed, war \(checker.state)")
        }
    }

    func testMissingHTMLURLFallsBackToReleasesPage() async {
        let checker = makeChecker(response: .success(Data(#"{"tag_name": "v9.9.9", "html_url": ""}"#.utf8)))
        await checker.checkNow()
        guard case .available(let info) = checker.state else {
            return XCTFail("Erwartet .available, war \(checker.state)")
        }
        XCTAssertEqual(info.releaseURL, AppUpdateChecker.fallbackReleasesPageURL)
    }
}
