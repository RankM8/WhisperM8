import Foundation
import XCTest
@testable import WhisperM8

/// Routing-Logik für Terminal-Link-Klicks. Rein, ohne Dateisystem/AppKit —
/// die Existenz-Probe wird als Closure injiziert.
final class TerminalLinkResolverTests: XCTestCase {
    private typealias Action = TerminalLinkResolver.Action
    private typealias FileStatus = TerminalLinkResolver.FileStatus

    /// Baut eine `fileStatus`-Closure aus bekannten Dateien + Ordnern. Alles
    /// andere gilt als nicht existent.
    private func probe(files: Set<String> = [], dirs: Set<String> = []) -> (String) -> FileStatus {
        { path in
            if dirs.contains(path) { return FileStatus(exists: true, isDirectory: true) }
            if files.contains(path) { return FileStatus(exists: true, isDirectory: false) }
            return .missing
        }
    }

    private func resolve(
        _ link: String,
        wd: String? = "/work",
        reveal: Bool = false,
        files: Set<String> = [],
        dirs: Set<String> = []
    ) -> Action {
        TerminalLinkResolver.resolve(
            link: link,
            workingDirectory: wd,
            revealInFinder: reveal,
            fileStatus: probe(files: files, dirs: dirs)
        )
    }

    // MARK: - Web/Remote-Schemes (dürfen NICHT regressieren)

    func testHttpsStaysWeb() {
        XCTAssertEqual(resolve("https://example.com/path?q=1"),
                       .openWeb(URL(string: "https://example.com/path?q=1")!))
    }

    func testHttpStaysWeb() {
        XCTAssertEqual(resolve("http://localhost:8080"), .openWeb(URL(string: "http://localhost:8080")!))
    }

    func testMailtoStaysWeb() {
        XCTAssertEqual(resolve("mailto:a@b.com"), .openWeb(URL(string: "mailto:a@b.com")!))
    }

    func testSshSchemeStaysWeb() {
        XCTAssertEqual(resolve("ssh://host/repo"), .openWeb(URL(string: "ssh://host/repo")!))
    }

    // MARK: - Code/Markdown → Editor (PhpStorm)

    func testCodeFileOpensInEditor() {
        XCTAssertEqual(resolve("/Users/gc/repos/main.swift", files: ["/Users/gc/repos/main.swift"]),
                       .openInEditor(URL(fileURLWithPath: "/Users/gc/repos/main.swift")))
    }

    func testMarkdownFileOpensInEditor() {
        let p = "/work/docs/lead-pipeline/export-fresh/MANIFEST.md"
        XCTAssertEqual(resolve("docs/lead-pipeline/export-fresh/MANIFEST.md", wd: "/work", files: [p]),
                       .openInEditor(URL(fileURLWithPath: p)))
    }

    func testExtensionlessFileOpensInEditor() {
        // Makefile/Dockerfile/LICENSE etc. → im Coding-Kontext Text ⇒ Editor.
        XCTAssertEqual(resolve("/work/Makefile", files: ["/work/Makefile"]),
                       .openInEditor(URL(fileURLWithPath: "/work/Makefile")))
    }

    func testDotfileOpensInEditor() {
        XCTAssertEqual(resolve("/work/.gitignore", files: ["/work/.gitignore"]),
                       .openInEditor(URL(fileURLWithPath: "/work/.gitignore")))
    }

    // MARK: - Medien/Binaries → Standard-App

    func testImageOpensWithDefaultApp() {
        XCTAssertEqual(resolve("/work/assets/logo.png", files: ["/work/assets/logo.png"]),
                       .openFile(URL(fileURLWithPath: "/work/assets/logo.png")))
    }

    func testPdfOpensWithDefaultApp() {
        XCTAssertEqual(resolve("/work/report.PDF", files: ["/work/report.PDF"]),
                       .openFile(URL(fileURLWithPath: "/work/report.PDF")))  // Endung case-insensitiv
    }

    func testArchiveOpensWithDefaultApp() {
        XCTAssertEqual(resolve("/work/bundle.zip", files: ["/work/bundle.zip"]),
                       .openFile(URL(fileURLWithPath: "/work/bundle.zip")))
    }

    // MARK: - Ordner

    func testExistingFolderOpensInFinder() {
        XCTAssertEqual(resolve("/Users/gc/repos/customer-sites", dirs: ["/Users/gc/repos/customer-sites"]),
                       .openFolder(URL(fileURLWithPath: "/Users/gc/repos/customer-sites")))
    }

    // MARK: - Fehlend (Screenshot-Fall: vorher -50)

    func testAbsoluteMissingPathIsNotFound() {
        XCTAssertEqual(resolve("/Users/gc/repos/customer-sites"),
                       .notFound(path: "/Users/gc/repos/customer-sites"))
    }

    // MARK: - Reveal (Cmd+Alt) — schlägt vor Editor/App-Routing zu

    func testRevealCodeFileInFinder() {
        XCTAssertEqual(resolve("/x/file.swift", reveal: true, files: ["/x/file.swift"]),
                       .revealInFinder(URL(fileURLWithPath: "/x/file.swift")))
    }

    func testRevealFolderInFinder() {
        XCTAssertEqual(resolve("/x/dir", reveal: true, dirs: ["/x/dir"]),
                       .revealInFinder(URL(fileURLWithPath: "/x/dir")))
    }

    func testRevealMissingStaysNotFound() {
        XCTAssertEqual(resolve("/x/gone", reveal: true), .notFound(path: "/x/gone"))
    }

    // MARK: - Relative Pfade

    func testRelativeResolvesAgainstWorkingDirectory() {
        XCTAssertEqual(resolve("src/App.swift", wd: "/work", files: ["/work/src/App.swift"]),
                       .openInEditor(URL(fileURLWithPath: "/work/src/App.swift")))
    }

    func testRelativeWithoutWorkingDirectoryIsRejected() {
        if case .reject = resolve("src/App.swift", wd: nil) { } else {
            XCTFail("relativer Pfad ohne Arbeitsverzeichnis muss abgelehnt werden")
        }
    }

    func testDotDotIsNormalized() {
        // /work + ../shared/x.swift → /shared/x.swift (»..« aufgelöst)
        XCTAssertEqual(resolve("../shared/x.swift", wd: "/work", files: ["/shared/x.swift"]),
                       .openInEditor(URL(fileURLWithPath: "/shared/x.swift")))
    }

    // MARK: - Tilde

    func testTildeExpandsToHome() {
        let home = ("~/proj/notes.md" as NSString).expandingTildeInPath
        XCTAssertEqual(resolve("~/proj/notes.md", files: [home]),
                       .openInEditor(URL(fileURLWithPath: home)))
    }

    // MARK: - Sonderzeichen (Leerzeichen, Umlaute)

    func testPathWithSpacesIsHandled() {
        let p = "/Users/gc/My Repo/Datei mit Leerzeichen.md"
        guard case .openInEditor(let url) = resolve(p, files: [p]) else {
            return XCTFail("Pfad mit Leerzeichen sollte im Editor öffnen")
        }
        XCTAssertEqual(url.path, p, "Pfad bleibt unverändert, kein %20")
    }

    func testPathWithUmlautsIsHandled() {
        let p = "/Users/gc/Büro/Lösung.md"
        guard case .openInEditor(let url) = resolve(p, files: [p]) else {
            return XCTFail("Pfad mit Umlauten sollte im Editor öffnen")
        }
        XCTAssertEqual(url.path, p)
    }

    // MARK: - file:-URLs

    func testFileURLTripleSlash() {
        XCTAssertEqual(resolve("file:///work/main.swift", files: ["/work/main.swift"]),
                       .openInEditor(URL(fileURLWithPath: "/work/main.swift")))
    }

    func testFileURLPercentEncodedSpace() {
        let p = "/work/My Repo/x.md"
        XCTAssertEqual(resolve("file:///work/My%20Repo/x.md", files: [p]),
                       .openInEditor(URL(fileURLWithPath: p)))
    }

    func testFileURLUnescapedSpaceFallback() {
        // `URL(string:)` liefert hier nil → manueller Fallback muss greifen.
        let p = "/work/My Repo/x.md"
        XCTAssertEqual(resolve("file:///work/My Repo/x.md", files: [p]),
                       .openInEditor(URL(fileURLWithPath: p)))
    }

    func testFileURLWithLocalhostHost() {
        XCTAssertEqual(resolve("file://localhost/work/a.swift", files: ["/work/a.swift"]),
                       .openInEditor(URL(fileURLWithPath: "/work/a.swift")))
    }

    // MARK: - path:line (Editor-/Grep-Stil)

    func testPathWithLineNumberSuffixStripsAndOpens() {
        XCTAssertEqual(resolve("/work/src/App.swift:42", files: ["/work/src/App.swift"]),
                       .openInEditor(URL(fileURLWithPath: "/work/src/App.swift")))
    }

    func testPathWithLineAndColumnSuffixStripsAndOpens() {
        XCTAssertEqual(resolve("/work/src/App.swift:42:7", files: ["/work/src/App.swift"]),
                       .openInEditor(URL(fileURLWithPath: "/work/src/App.swift")))
    }

    func testLineSuffixOnTrulyMissingFileStaysNotFound() {
        XCTAssertEqual(resolve("/work/gone.swift:42"), .notFound(path: "/work/gone.swift:42"))
    }

    // MARK: - Degenerierte Eingaben

    func testEmptyLinkRejected() {
        if case .reject = resolve("   ") { } else { XCTFail("leerer Link muss abgelehnt werden") }
    }

    // MARK: - Editor-Heuristik direkt

    func testIsEditorFileHeuristic() {
        for code in ["a.swift", "b.ts", "c.py", "d.md", "e.json", "f.yaml", "g.txt", "Makefile", ".gitignore", "x.unknownext"] {
            XCTAssertTrue(TerminalLinkResolver.isEditorFile(URL(fileURLWithPath: "/w/\(code)")), "\(code) → Editor")
        }
        for media in ["a.png", "b.jpg", "c.pdf", "d.zip", "e.mp4", "f.docx", "g.dmg", "h.ttf"] {
            XCTAssertFalse(TerminalLinkResolver.isEditorFile(URL(fileURLWithPath: "/w/\(media)")), "\(media) → Standard-App")
        }
    }
}
