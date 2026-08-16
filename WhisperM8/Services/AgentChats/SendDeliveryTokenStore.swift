import CryptoKit
import Foundation

/// Zustell-Tokens für die Send-Pipeline — die eine Hälfte des
/// Wiedervorlage-Schutzes (die andere ist der `UserPromptSubmit`-Hook
/// `whisperm8 chats _prompt-guard`).
///
/// **Problem (Vorfall 2026-08-17):** Bricht der User einen per `chats send`
/// zugestellten Turn mit ESC ab, legt die Claude-CLI den Prompt des
/// abgebrochenen Turns selbst zurück in den Composer (Interrupt-Restore;
/// Doppel-ESC-Rewind tut dasselbe). Ein versehentliches Enter würde einen
/// inzwischen zurückgezogenen Auftrag erneut absenden. Die App kann den
/// Composer weder lesen noch gefahrlos leeren — also wird nicht das
/// Restaurieren verhindert, sondern das erneute ABSENDEN abgefangen.
///
/// **Mechanik:** `session.send` und die Queue-Zustellung legen unmittelbar
/// vor dem Paste ein Token ab (SHA-256 des gepasteten Texts + Zeitstempel).
/// Der Hook konsumiert es beim ersten Submit. Jede weitere Submission eines
/// `[via whisperm8 chats …]`-Prompts ohne passendes frisches Token wird
/// geblockt — egal, WIE der Text in den Composer kam (Interrupt-Restore,
/// Rewind, Copy-Paste). Die Markerzeile stellt ausschließlich die App voran.
///
/// Der Lookup läuft über den HASH (Verzeichnis-Scan), nicht über eine
/// Session-ID: der Hook braucht so kein Environment und funktioniert auch
/// für Background-Sessions. Gleicher Prompt an zwei Ziele = zwei Tokens mit
/// gleichem Hash — jede Submission konsumiert genau eines.
struct SendDeliveryTokenStore {
    struct Token: Codable, Equatable {
        /// SHA-256 (hex) des normalisierten Prompt-Texts.
        var promptHash: String
        var createdAt: Date
    }

    /// Tokens, die älter sind, gelten nicht mehr und werden beim nächsten
    /// Schreiben weggeräumt. Großzügig gewählt: ein `--force`-Send an ein
    /// arbeitendes Ziel wird von der TUI als queued message erst am
    /// Turn-Ende submittet, und ein `--no-submit`-Stage schickt der User
    /// irgendwann selbst ab. Der Kernschutz hängt NICHT an der Frist —
    /// das Token wird beim Erst-Submit konsumiert; die Frist begrenzt nur
    /// Karteileichen, deren Hook nie lief.
    static let timeToLive: TimeInterval = 30 * 60

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    /// App und CLI sind dasselbe Binary — beide leiten identisch ab.
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("send-tokens", isDirectory: true)
    }

    /// Normalisierung vor dem Hashen: Die TUI kann Rand-Whitespace des
    /// gepasteten Texts trimmen, bevor der Hook den Prompt sieht — ohne
    /// dieselbe Normalisierung auf beiden Seiten blockte ein
    /// Hash-Mismatch legitime Zustellungen.
    static func promptHash(_ prompt: String) -> String {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Legt ein Token ab (eine Datei pro Zustellung, UUID-Name) und räumt
    /// dabei abgelaufene weg. Fehler sind bewusst still: ein fehlendes
    /// Token darf nie eine Zustellung verhindern — der Guard failt dann
    /// eben in Richtung Block der SPÄTEREN Wiedervorlage.
    func stage(promptText: String, now: Date = Date()) {
        let token = Token(promptHash: Self.promptHash(promptText), createdAt: now)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            purgeExpired(now: now)
            let url = directory.appendingPathComponent("\(UUID().uuidString).json")
            let data = try JSONEncoder.tokenEncoder.encode(token)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            Logger.agentStore.warning(
                "send_token_stage_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sucht ein frisches Token mit passendem Hash und KONSUMIERT es
    /// (löscht die Datei). `true` = gefunden → die Submission ist eine
    /// autorisierte Erst-Zustellung.
    func consume(promptText: String, now: Date = Date()) -> Bool {
        let hash = Self.promptHash(promptText)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return false }
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let token = try? JSONDecoder.tokenDecoder.decode(Token.self, from: data),
                  token.promptHash == hash,
                  now.timeIntervalSince(token.createdAt) <= Self.timeToLive,
                  token.createdAt.timeIntervalSince(now) < 60 // Uhr-Drift-Kappe
            else { continue }
            try? FileManager.default.removeItem(at: url)
            return true
        }
        return false
    }

    private func purgeExpired(now: Date) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let token = try? JSONDecoder.tokenDecoder.decode(Token.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if now.timeIntervalSince(token.createdAt) > Self.timeToLive {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

private extension JSONEncoder {
    static let tokenEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let tokenDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Pure Entscheidungslogik des `UserPromptSubmit`-Guards — getrennt vom
/// CLI-Subcommand, damit die Fallunterscheidung ohne Dateisystem testbar
/// bleibt. Der Marker ist der einzige Trigger: normale, von Menschen
/// getippte Prompts passieren ohne jeden Lookup.
enum ChatsPromptGuard {
    /// Präfix der Markerzeile aus `AgentControlRequestHandler.markedPrompt`
    /// — die einzige Quelle dieser Zeile ist die App selbst.
    static let markerPrefix = "[via whisperm8 chats"

    enum Verdict: Equatable {
        /// Kein Marker-Prompt bzw. autorisierte Erst-Zustellung.
        case allow
        /// Marker-Prompt ohne frisches Token → blocken (Exit 2 im Hook).
        case block(reason: String)
    }

    /// `consumeToken` kapselt den Store-Zugriff (Hash-Match + Konsum) —
    /// im Test ein Closure, im Hook der `SendDeliveryTokenStore`.
    static func decide(
        prompt: String,
        consumeToken: (String) -> Bool
    ) -> Verdict {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(markerPrefix) else { return .allow }
        guard consumeToken(prompt) else {
            return .block(reason:
                "WhisperM8-Send-Guard: Dieser [via whisperm8 chats]-Prompt wurde bereits "
                + "zugestellt oder zurückgezogen — vermutlich hat die CLI ihn nach einem "
                + "Abbruch (ESC) ins Eingabefeld zurückgelegt. Nicht erneut ausgeführt. "
                + "Falls die Zustellung doch gewollt ist: per `whisperm8 chats send` neu senden.")
        }
        return .allow
    }
}
