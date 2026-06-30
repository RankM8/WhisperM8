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

    // MARK: - Absolute Pfade

    func testAbsoluteExistingFileOpensWithApp() {
        XCTAssertEqual(resolve("/Users/gc/repos/main.swift", files: ["/Users/gc/repos/main.swift"]),
                       .openFile(URL(fileURLWithPath: "/Users/gc/repos/main.swift")))
    }

    func testAbsoluteExistingFolderOpensInFinder() {
        XCTAssertEqual(resolve("/Users/gc/repos/customer-sites", dirs: ["/Users/gc/repos/customer-sites"]),
                       .openFolder(URL(fileURLWithPath: "/Users/gc/repos/customer-sites")))
    }

    func testAbsoluteMissingPathIsNotFound() {
        // Genau der Screenshot-Fall: vorher -50, jetzt klare Meldung.
        XCTAssertEqual(resolve("/Users/gc/repos/customer-sites"),
                       .notFound(path: "/Users/gc/repos/customer-sites"))
    }

    // MARK: - Reveal (Cmd+Alt)

    func testRevealFileInFinder() {
        XCTAssertEqual(resolve("/x/file.txt", reveal: true, files: ["/x/file.txt"]),
                       .revealInFinder(URL(fileURLWithPath: "/x/file.txt")))
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
                       .openFile(URL(fileURLWithPath: "/work/src/App.swift")))
    }

    func testRelativeWithoutWorkingDirectoryIsRejected() {
        if case .reject = resolve("src/App.swift", wd: nil) { } else {
            XCTFail("relativer Pfad ohne Arbeitsverzeichnis muss abgelehnt werden")
        }
    }

    func testDotDotIsNormalized() {
        // /work + ../shared/x → /shared/x (»..« aufgelöst)
        XCTAssertEqual(resolve("../shared/x.txt", wd: "/work", files: ["/shared/x.txt"]),
                       .openFile(URL(fileURLWithPath: "/shared/x.txt")))
    }

    // MARK: - Tilde

    func testTildeExpandsToHome() {
        let home = ("~/proj/notes.md" as NSString).expandingTildeInPath
        XCTAssertEqual(resolve("~/proj/notes.md", files: [home]),
                       .openFile(URL(fileURLWithPath: home)))
    }

    // MARK: - Sonderzeichen (Leerzeichen, Umlaute) — der zweite Kernbug

    func testPathWithSpacesIsHandled() {
        let p = "/Users/gc/My Repo/Datei mit Leerzeichen.txt"
        guard case .openFile(let url) = resolve(p, files: [p]) else {
            return XCTFail("Pfad mit Leerzeichen sollte als Datei öffnen")
        }
        XCTAssertEqual(url.path, p, "Pfad bleibt unverändert, kein %20")
    }

    func testPathWithUmlautsIsHandled() {
        let p = "/Users/gc/Büro/Lösung.md"
        guard case .openFile(let url) = resolve(p, files: [p]) else {
            return XCTFail("Pfad mit Umlauten sollte als Datei öffnen")
        }
        XCTAssertEqual(url.path, p)
    }

    // MARK: - file:-URLs

    func testFileURLTripleSlash() {
        XCTAssertEqual(resolve("file:///work/main.swift", files: ["/work/main.swift"]),
                       .openFile(URL(fileURLWithPath: "/work/main.swift")))
    }

    func testFileURLPercentEncodedSpace() {
        let p = "/work/My Repo/x.txt"
        XCTAssertEqual(resolve("file:///work/My%20Repo/x.txt", files: [p]),
                       .openFile(URL(fileURLWithPath: p)))
    }

    func testFileURLUnescapedSpaceFallback() {
        // `URL(string:)` liefert hier nil → manueller Fallback muss greifen.
        let p = "/work/My Repo/x.txt"
        XCTAssertEqual(resolve("file:///work/My Repo/x.txt", files: [p]),
                       .openFile(URL(fileURLWithPath: p)))
    }

    func testFileURLWithLocalhostHost() {
        XCTAssertEqual(resolve("file://localhost/work/a.txt", files: ["/work/a.txt"]),
                       .openFile(URL(fileURLWithPath: "/work/a.txt")))
    }

    // MARK: - path:line (Editor-/Grep-Stil)

    func testPathWithLineNumberSuffixStripsAndOpens() {
        XCTAssertEqual(resolve("/work/src/App.swift:42", files: ["/work/src/App.swift"]),
                       .openFile(URL(fileURLWithPath: "/work/src/App.swift")))
    }

    func testPathWithLineAndColumnSuffixStripsAndOpens() {
        XCTAssertEqual(resolve("/work/src/App.swift:42:7", files: ["/work/src/App.swift"]),
                       .openFile(URL(fileURLWithPath: "/work/src/App.swift")))
    }

    func testLineSuffixOnTrulyMissingFileStaysNotFound() {
        XCTAssertEqual(resolve("/work/gone.swift:42"), .notFound(path: "/work/gone.swift:42"))
    }

    // MARK: - Degenerierte Eingaben

    func testEmptyLinkRejected() {
        if case .reject = resolve("   ") { } else { XCTFail("leerer Link muss abgelehnt werden") }
    }
}
