@testable import WhisperM8
import XCTest

/// Doku-Lint (Launch-Readiness W7): Die Nutzer-Doku beschreibt nur den
/// Brew-Weg, nennt Einstellungsseiten so wie die App und keine gelöschten
/// Typen. Prüft Text, keine Formatierung — bewusst grob, damit er nicht bei
/// jeder Umformulierung bricht.
final class DocsLintTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Befehle, die für Endnutzer kein Weg sind (Entwickler-Doku: DEVELOPMENT.md).
    private static let developerOnly = [
        "make install", "make clean-install", "make kill", "make dev", "make run",
        "xattr -dr com.apple.quarantine", "git clone", "git pull",
    ]

    /// LR-DOK-001
    func testReadmeOffersOnlyHomebrew() throws {
        let readme = try read("README.md")
        XCTAssertTrue(readme.contains("brew install --cask rankm8/tap/whisperm8"))
        XCTAssertTrue(readme.contains("Claude Code") && readme.contains("Codex"),
                      "README braucht den Einrichtungsweg für Claude Code und Codex")
        for command in Self.developerOnly {
            XCTAssertFalse(readme.contains(command), "README nennt Entwicklerbefehl „\(command)“")
        }
    }

    /// LR-DOK-004, LR-DOK-005, LR-DOK-009
    func testUserGuideIsForEndUsers() throws {
        let guide = try read("docs/USER_GUIDE.md")
        XCTAssertTrue(guide.contains("brew install --cask rankm8/tap/whisperm8"))
        XCTAssertTrue(guide.contains("## Agent Chats"), "Kapitel Agent Chats fehlt")
        for command in Self.developerOnly {
            XCTAssertFalse(guide.contains(command), "USER_GUIDE nennt Entwicklerbefehl „\(command)“")
        }
    }

    /// LR-DOK-004: Auch die technische Einstiegsseite schickt Nutzer nicht
    /// in den destruktiven Reset.
    func testDocsReadmeHasNoDestructiveTroubleshooting() throws {
        let docs = try read("docs/README.md")
        for command in ["make install", "make clean-install", "make kill", "git clone"] {
            XCTAssertFalse(docs.contains(command), "docs/README.md nennt „\(command)“")
        }
    }

    /// LR-DOK-005: Jede Seite der Einstellungs-Tabelle gibt es in der App.
    func testUserGuideSettingsPagesExist() throws {
        let guide = try read("docs/USER_GUIDE.md")
        let section = try XCTUnwrap(guide.components(separatedBy: "\n## Settings\n").dropFirst().first)
            .components(separatedBy: "\n## ").first ?? ""
        let names = section.components(separatedBy: "\n")
            .filter { $0.hasPrefix("| **") }
            .compactMap { line -> String? in
                guard let start = line.range(of: "| **"),
                      let end = line.range(of: "** |", range: start.upperBound..<line.endIndex)
                else { return nil }
                return String(line[start.upperBound..<end.lowerBound])
            }
        XCTAssertGreaterThan(names.count, 5, "Einstellungs-Tabelle nicht gefunden")
        let pages = Set(SettingsPage.allCases.map(\.title))
        for name in names {
            XCTAssertTrue(pages.contains(name), "USER_GUIDE nennt unbekannte Einstellungsseite „\(name)“")
        }
    }

    /// LR-DOK-007: Lokale Rettungskopien und Reports samt Grenzen genannt.
    func testUserGuidePrivacyNamesLocalCopies() throws {
        let guide = try read("docs/USER_GUIDE.md")
        for needle in ["FailedRecordings", "Reports", "10 recordings", "7 days", "500 reports", "180 days", "2 GB"] {
            XCTAssertTrue(guide.contains(needle), "Datenschutz-Abschnitt nennt „\(needle)“ nicht")
        }
    }

    /// LR-DOK-006: Aktive Feature-Doku nennt keine gelöschten Typen.
    func testActiveFeatureDocsNameNoDeletedTypes() throws {
        let deleted = [
            "AgentTimelineView", "TimelineRoundView", "TimelineActivityRow", "TimelineReportView",
            "TerminalSnapshotView", "AgentChatTranscriptView", "TranscriptWindow", "TerminalSnapshotStore",
        ]
        let features = Self.root.appendingPathComponent("docs/features")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: features, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "md" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("\nstatus: aktiv") else { continue }
            for name in deleted where text.contains("`\(name)`") {
                XCTFail("\(url.lastPathComponent) nennt den gelöschten Typ \(name)")
            }
        }
    }
}
