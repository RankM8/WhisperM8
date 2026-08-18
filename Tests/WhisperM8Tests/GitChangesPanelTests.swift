import XCTest
@testable import WhisperM8

/// Pure Logik des Changes-Panels: porcelain-v2-Parser, Baum-Builder
/// (Einzelkind-Flattening, Sortierung, Counts), flaches Zeilenmodell und
/// Breiten-Clamping des rechten Panels.
final class GitChangesPanelTests: XCTestCase {
    // MARK: - Parser

    private func porcelain(_ records: [String]) -> String {
        records.joined(separator: "\u{0}") + "\u{0}"
    }

    func testParsesBranchModifiedStagedAndUntracked() {
        let output = porcelain([
            "# branch.oid abc123",
            "# branch.head feat/sammel-kw34-2",
            "1 .M N... 100644 100644 100644 h1 h2 src/Model/Chat/Skill.php",
            "1 M. N... 100644 100644 100644 h1 h2 api/staged-only.php",
            "1 MM N... 100644 100644 100644 h1 h2 both/areas.php",
            "? neu/unversioniert.md",
        ])
        let parsed = GitChangesSnapshot.parse(porcelainV2: output)

        XCTAssertEqual(parsed.branch, "feat/sammel-kw34-2")
        XCTAssertFalse(parsed.truncated)
        XCTAssertEqual(parsed.entries, [
            GitChangeEntry(path: "src/Model/Chat/Skill.php", kind: .modified, area: .unstaged),
            GitChangeEntry(path: "api/staged-only.php", kind: .modified, area: .staged),
            GitChangeEntry(path: "both/areas.php", kind: .modified, area: .staged),
            GitChangeEntry(path: "both/areas.php", kind: .modified, area: .unstaged),
            GitChangeEntry(path: "neu/unversioniert.md", kind: .untracked, area: .unstaged),
        ])
    }

    func testParsesRenameAndConsumesSecondNulField() {
        // Rename-Records tragen den ALTEN Pfad als eigenes NUL-Feld — der
        // Parser muss es konsumieren, sonst würde es als kaputter Record
        // gelesen (oder schlimmer: als Datei "alt/name.php" auftauchen).
        let output = porcelain([
            "# branch.head main",
            "2 R. N... 100644 100644 100644 h1 h2 R100 neu/name.php",
            "alt/name.php",
            "1 .D N... 100644 100644 000000 h1 h2 geloescht.txt",
        ])
        let parsed = GitChangesSnapshot.parse(porcelainV2: output)

        XCTAssertEqual(parsed.entries, [
            GitChangeEntry(path: "neu/name.php", kind: .renamed, area: .staged),
            GitChangeEntry(path: "geloescht.txt", kind: .deleted, area: .unstaged),
        ])
    }

    func testParserCapsHugeStatusAndFlagsTruncation() {
        var records = ["# branch.head main"]
        for index in 0..<(GitChangesSnapshot.entryCap + 50) {
            records.append("? datei-\(index).txt")
        }
        let parsed = GitChangesSnapshot.parse(porcelainV2: porcelain(records))

        XCTAssertTrue(parsed.truncated)
        XCTAssertEqual(parsed.entries.count, GitChangesSnapshot.entryCap)
    }

    func testDetachedHeadIsLabelled() {
        let output = porcelain(["# branch.head (detached)"])
        XCTAssertEqual(GitChangesSnapshot.parse(porcelainV2: output).branch, "detached")
    }

    // MARK: - Baum

    func testTreeFlattensSingleChildDirectoryChains() {
        let entries = [
            GitChangeEntry(path: "data/chat/skills/cold-mailing/marketing-offer.md", kind: .modified, area: .unstaged),
            GitChangeEntry(path: "src/Model/Chat/Skill.php", kind: .modified, area: .unstaged),
            GitChangeEntry(path: "src/Service/A.php", kind: .modified, area: .unstaged),
            GitChangeEntry(path: "src/Service/B.php", kind: .added, area: .unstaged),
        ]
        let tree = GitChangesTreeBuilder.build(entries: entries, area: .unstaged)

        // Kette data/chat/skills/cold-mailing verschmilzt zu EINEM Knoten.
        XCTAssertEqual(tree.map(\.name), ["data/chat/skills/cold-mailing", "src"])
        XCTAssertEqual(tree[0].fileCount, 1)
        XCTAssertEqual(tree[0].relativePath, "data/chat/skills/cold-mailing")
        XCTAssertEqual(tree[0].children.map(\.name), ["marketing-offer.md"])

        // src hat ZWEI Kinder → kein Flattening; Model/Chat (Einzelkind-Kette
        // unterhalb) verschmilzt wieder. Ordner vor Dateien, alphabetisch.
        XCTAssertEqual(tree[1].fileCount, 3)
        XCTAssertEqual(tree[1].children.map(\.name), ["Model/Chat", "Service"])
        XCTAssertEqual(tree[1].children[1].children.map(\.name), ["A.php", "B.php"])
    }

    func testTreeSeparatesAreasAndSortsDirectoriesFirst() {
        let entries = [
            GitChangeEntry(path: "zz-datei.txt", kind: .modified, area: .unstaged),
            GitChangeEntry(path: "ordner/inhalt.txt", kind: .modified, area: .unstaged),
            GitChangeEntry(path: "nur-staged.txt", kind: .added, area: .staged),
        ]
        let unstaged = GitChangesTreeBuilder.build(entries: entries, area: .unstaged)
        let staged = GitChangesTreeBuilder.build(entries: entries, area: .staged)

        XCTAssertEqual(unstaged.map(\.name), ["ordner", "zz-datei.txt"])
        XCTAssertEqual(staged.map(\.name), ["nur-staged.txt"])
        // IDs sind bereichspräfixiert — Staged/Unstaged derselben Datei
        // kollidieren nie im Expand-State.
        XCTAssertEqual(staged[0].id, "staged|nur-staged.txt")
    }

    func testVisibleRowsRespectCollapsedNodes() {
        let entries = [
            GitChangeEntry(path: "a/eins.txt", kind: .modified, area: .unstaged),
            GitChangeEntry(path: "b/zwei.txt", kind: .modified, area: .unstaged),
        ]
        let tree = GitChangesTreeBuilder.build(entries: entries, area: .unstaged)

        let expanded = GitChangesTreeBuilder.visibleRows(nodes: tree, collapsedIDs: [])
        XCTAssertEqual(expanded.map(\.name), ["a", "eins.txt", "b", "zwei.txt"])
        XCTAssertEqual(expanded.map(\.depth), [0, 1, 0, 1])

        let collapsed = GitChangesTreeBuilder.visibleRows(nodes: tree, collapsedIDs: ["unstaged|a"])
        XCTAssertEqual(collapsed.map(\.name), ["a", "b", "zwei.txt"])
        XCTAssertFalse(collapsed[0].isExpanded)
    }

    func testDirectoryIDsCollectsOnlyDirectories() {
        let entries = [
            GitChangeEntry(path: "a/b/datei.txt", kind: .modified, area: .unstaged),
        ]
        let tree = GitChangesTreeBuilder.build(entries: entries, area: .unstaged)
        XCTAssertEqual(GitChangesTreeBuilder.directoryIDs(in: tree), ["unstaged|a/b"])
    }

    // MARK: - Inspector-Breite

    func testInspectorWidthClampsAndNegatesDragTranslation() {
        // Handle sitzt links: Drag nach LINKS (negative Translation) = breiter.
        let wider = InspectorWidthResolver.widthDuringDrag(
            startWidth: 292, translation: -100, windowWidth: 1600, sidebarWidth: 276
        )
        XCTAssertEqual(wider, 392)

        let narrower = InspectorWidthResolver.widthDuringDrag(
            startWidth: 292, translation: 200, windowWidth: 1600, sidebarWidth: 276
        )
        XCTAssertEqual(narrower, InspectorWidthResolver.minWidth)

        // Obergrenze: Content-Mindestbreite gewinnt gegen den Wunschwert.
        let capped = InspectorWidthResolver.effectiveWidth(
            stored: 900, windowWidth: 1200, sidebarWidth: 276
        )
        XCTAssertEqual(capped, 1200 - 480 - 276)

        // Kleines Fenster: nie unter minWidth, auch wenn rechnerisch weniger
        // Platz wäre (gleiches Quetsch-Verhalten wie die Sidebar).
        let tiny = InspectorWidthResolver.effectiveWidth(
            stored: 400, windowWidth: 700, sidebarWidth: 276
        )
        XCTAssertEqual(tiny, InspectorWidthResolver.minWidth)
    }
}

// MARK: - PhpStorm-Launch-Argumente

extension GitChangesPanelTests {
    func testLaunchArgumentsPrependProjectRootForFiles() {
        // Hint gültig (enthält Datei, ist Git-Root) → [projekt, datei].
        XCTAssertEqual(
            PhpStormLauncher.launchArguments(
                filePath: "/repos/whisperm8/docs/a.md",
                projectPathHint: "/repos/whisperm8",
                hasGitDirectory: { $0 == "/repos/whisperm8" }
            ),
            ["/repos/whisperm8", "/repos/whisperm8/docs/a.md"]
        )

        // Projekt selbst öffnen → ein Argument (kein Doppel).
        XCTAssertEqual(
            PhpStormLauncher.launchArguments(
                filePath: "/repos/whisperm8",
                projectPathHint: "/repos/whisperm8",
                hasGitDirectory: { _ in true }
            ),
            ["/repos/whisperm8"]
        )

        // Hint ist Unterordner ohne .git (Terminal-cwd) → Aufwärtssuche ab
        // der Datei findet das echte Repo-Root.
        XCTAssertEqual(
            PhpStormLauncher.launchArguments(
                filePath: "/repos/whisperm8/docs/plans/x/plan.md",
                projectPathHint: "/repos/whisperm8/docs",
                hasGitDirectory: { $0 == "/repos/whisperm8" }
            ),
            ["/repos/whisperm8", "/repos/whisperm8/docs/plans/x/plan.md"]
        )

        // Datei liegt AUSSERHALB des Hints → Hint verwerfen, Root der Datei.
        XCTAssertEqual(
            PhpStormLauncher.launchArguments(
                filePath: "/repos/andere/lib.php",
                projectPathHint: "/repos/whisperm8",
                hasGitDirectory: { $0 == "/repos/andere" }
            ),
            ["/repos/andere", "/repos/andere/lib.php"]
        )

        // Nirgendwo ein .git → bisheriges Verhalten (nur Datei).
        XCTAssertEqual(
            PhpStormLauncher.launchArguments(
                filePath: "/Users/x/Downloads/notiz.md",
                projectPathHint: nil,
                hasGitDirectory: { _ in false }
            ),
            ["/Users/x/Downloads/notiz.md"]
        )

        // Prefix-Falle: /repos/whisperm8-fork liegt NICHT in /repos/whisperm8.
        XCTAssertEqual(
            PhpStormLauncher.launchArguments(
                filePath: "/repos/whisperm8-fork/a.md",
                projectPathHint: "/repos/whisperm8",
                hasGitDirectory: { $0 == "/repos/whisperm8-fork" }
            ),
            ["/repos/whisperm8-fork", "/repos/whisperm8-fork/a.md"]
        )
    }
}
