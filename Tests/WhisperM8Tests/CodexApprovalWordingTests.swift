import Foundation
import XCTest
@testable import WhisperM8

/// WM8-107: Die Erkennung der Codex-Freigabe hängt am Wortlaut von Codex CLI
/// 0.169.0. Ändert ein Update die Texte, griffe sie still nicht mehr. Dieser
/// Test sucht die Texte im installierten Codex-Programm und schlägt an, wenn
/// einer fehlt. Ohne installiertes Codex überspringt er sich.
final class CodexApprovalWordingTests: XCTestCase {
    /// Wörtlich im Programm (Codex setzt „(y)“ und die Tastennamen der
    /// Hinweiszeile erst zur Laufzeit ein; die stehen deshalb nicht hier).
    private let wording = [
        "Would you like to run the following command?",
        "Yes, proceed",
        "No, and tell Codex what to do differently",
        " to confirm or ",
    ]

    func testInstalledCodexStillUsesTheMeasuredWording() throws {
        guard let binary = Self.codexBinary() else {
            throw XCTSkip("Kein installiertes Codex gefunden")
        }
        let data = try Data(contentsOf: binary, options: .alwaysMapped)
        for text in wording {
            XCTAssertTrue(Self.contains(data, text),
                          "Codex sagt „\(text)“ nicht mehr (\(binary.path)). Freigabe-Dialog neu messen und "
                          + "ControllerScreenReading.isCodexApproval anpassen (gemessen an 0.169.0, WM8-67).")
        }
        // Und die Erkennung selbst nutzt nur Texte, die es dort gibt.
        for option in ControllerScreenReading.codexApprovalOptions {
            XCTAssertTrue(wording.contains { $0.lowercased() == option }, option)
        }
    }

    private static func contains(_ data: Data, _ text: String) -> Bool {
        let needle = Array(text.utf8)
        return data.withUnsafeBytes { raw in
            needle.withUnsafeBytes { pattern in
                memmem(raw.baseAddress, raw.count, pattern.baseAddress, pattern.count) != nil
            }
        }
    }

    /// Das native Programm hinter `codex` im PATH: direkt (Homebrew-Cask) oder
    /// über das npm-Paket, dessen `codex.js` das Programm aus `vendor/` startet.
    static func codexBinary() -> URL? {
        let fileManager = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let launcher = dirs.lazy.map({ URL(fileURLWithPath: $0).appendingPathComponent("codex") })
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else { return nil }
        let resolved = launcher.resolvingSymlinksInPath()
        if isMachO(resolved) { return resolved }
        // npm: <paket>/bin/codex.js → <paket>/node_modules/@openai/codex-darwin-<arch>/vendor/<triple>/bin/codex
        let package = resolved.deletingLastPathComponent().deletingLastPathComponent()
        for (arch, triple) in [("arm64", "aarch64-apple-darwin"), ("x64", "x86_64-apple-darwin")] {
            let candidate = package.appendingPathComponent(
                "node_modules/@openai/codex-darwin-\(arch)/vendor/\(triple)/bin/codex")
            if isMachO(candidate) { return candidate }
        }
        return nil
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return [Data([0xCF, 0xFA, 0xED, 0xFE]), Data([0xCA, 0xFE, 0xBA, 0xBE])].contains(magic)
    }
}
