import Foundation
import Security

/// Lokales Zugangs-Token des GPT-Routers (LR-GPT-001).
///
/// Der Router lauscht auf Loopback ohne Benutzerpruefung; ohne Token koennte
/// jeder lokale Prozess GPT-Konten ueber ihn benutzen. Das Token liegt als Datei
/// (0600) unter Application Support — NICHT im Keychain (kein Passwortdialog bei
/// Neustart/Signaturwechsel) und ueberlebt App-Neustarts, damit Hintergrund-
/// Agents und Resume-Chats ihr beim Spawn eingefrorenes Token behalten.
/// Der Wert wird nie geloggt und nie als Argument uebergeben, nur ueber das
/// Env `ANTHROPIC_CUSTOM_HEADERS` der Claude-Prozesse.
final class ClaudeGPTRouterToken {
    static let shared = ClaudeGPTRouterToken()

    /// Header, mit dem Claude Code das Token an den Router schickt.
    static let headerName = "X-WhisperM8-Router-Token"

    private let fileURL: URL
    private let lock = NSLock()
    private var cached: String?

    init(fileURL: URL = ClaudeGPTRouterToken.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("gpt-router-token", isDirectory: false)
    }

    /// Vorhandenes Token oder ein frisch erzeugtes. `nil` nur, wenn weder
    /// lesen noch schreiben gelingt (dann wird nicht erzwungen, siehe Router).
    func current() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           Self.isWellFormed(text) {
            cached = text
            return text
        }
        guard let fresh = Self.generate() else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Datei mit 0600 anlegen, bevor der Wert drinsteht.
            let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            let bytes = Array(fresh.utf8)
            guard write(fd, bytes, bytes.count) == bytes.count else { return nil }
        } catch {
            return nil
        }
        cached = fresh
        return fresh
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.count >= 32 && token.allSatisfy { $0.isHexDigit }
    }

    private static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Konstantzeit-Vergleich des Header-Werts mit dem erwarteten Token.
    static func matches(_ presented: String?, expected: String) -> Bool {
        guard let presented else { return false }
        let a = Array(presented.trimmingCharacters(in: .whitespaces).utf8)
        let b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
