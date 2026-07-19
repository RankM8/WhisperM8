import Foundation
import XCTest
@testable import WhisperM8

/// Tests fuer das Git-Status-Parsing ueber den Runner-Seam (kein echter
/// Git-Spawn) — Regressionsschutz fuer den C13-Umbau (off-main Load).
final class GitProjectStatusTests: XCTestCase {
    /// Existierender Pfad, damit der FileManager-Guard passiert.
    private let existingPath = FileManager.default.temporaryDirectory.path

    private static func runner(
        branch: String? = "main",
        porcelain: String? = "",
        numstat: String? = ""
    ) -> GitProjectStatus.Runner {
        { arguments in
            switch arguments.dropFirst(2).first {
            case "branch": return branch
            case "status": return porcelain
            case "diff": return numstat
            default: return nil
            }
        }
    }

    func testParsesBranchChangedFilesAndDiffTotals() {
        let status = GitProjectStatus(
            path: existingPath,
            runner: Self.runner(
                branch: "feature/x",
                porcelain: " M a.swift\n?? b.swift\nD  c.swift",
                numstat: "10\t2\ta.swift\n3\t4\tc.swift"
            )
        )
        XCTAssertEqual(status?.branch, "feature/x")
        XCTAssertEqual(status?.changedFiles, 3)
        XCTAssertEqual(status?.added, 13)
        XCTAssertEqual(status?.deleted, 6)
        XCTAssertEqual(status?.summary, "3 Dateien geändert")
    }

    func testMissingPathReturnsNil() {
        XCTAssertNil(GitProjectStatus(
            path: "/nonexistent/\(UUID().uuidString)",
            runner: Self.runner()
        ))
    }

    func testFailedGitCallsDegradeGracefully() {
        let status = GitProjectStatus(
            path: existingPath,
            runner: Self.runner(branch: nil, porcelain: nil, numstat: nil)
        )
        XCTAssertNil(status?.branch)
        XCTAssertEqual(status?.changedFiles, 0)
        XCTAssertEqual(status?.added, 0)
        XCTAssertEqual(status?.deleted, 0)
        XCTAssertEqual(status?.summary, "Clean")
    }

    func testBinaryNumstatLinesCountZero() {
        // Binaerdateien liefern "-\t-\t<file>" — darf nicht crashen und
        // zaehlt 0/0.
        let status = GitProjectStatus(
            path: existingPath,
            runner: Self.runner(numstat: "-\t-\timage.png\n5\t1\ta.swift")
        )
        XCTAssertEqual(status?.added, 5)
        XCTAssertEqual(status?.deleted, 1)
    }

    func testEmptyBranchBecomesNil() {
        // Detached HEAD: `branch --show-current` liefert Leerstring.
        let status = GitProjectStatus(
            path: existingPath,
            runner: Self.runner(branch: "")
        )
        XCTAssertNil(status?.branch)
    }

    func testAsyncLoadMatchesSyncInit() async {
        let runner = Self.runner(branch: "main", porcelain: " M a", numstat: "1\t1\ta")
        let loaded = await GitProjectStatus.load(path: existingPath, runner: runner)
        let direct = GitProjectStatus(path: existingPath, runner: runner)
        XCTAssertEqual(loaded?.branch, direct?.branch)
        XCTAssertEqual(loaded?.changedFiles, direct?.changedFiles)
        XCTAssertEqual(loaded?.added, direct?.added)
        XCTAssertEqual(loaded?.deleted, direct?.deleted)
    }
}
