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

    /// Normalisierung vor dem Hashen: ALLE Whitespace-Läufe werden zu einem
    /// Space kollabiert. Die TUI verändert Whitespace nachweislich — beim
    /// Zurücklegen eines Prompts in den Composer materialisiert sie
    /// Soft-Wrap-Umbrüche als `\n  ` mitten im Text (Vorfall 2026-08-17,
    /// Review-Agents: 640 vs. 665 Zeichen für denselben Prompt). Ein
    /// byte-exakter Hash blockte solche Texte fälschlich; der Marker-Inhalt
    /// bleibt auch kollabiert eindeutig identifizierend.
    static func promptHash(_ prompt: String) -> String {
        let collapsed = normalizedForMatching(prompt)
        let digest = SHA256.hash(data: Data(collapsed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whitespace-tolerante Vergleichsform (geteilt mit der
    /// Retry-Probe, damit Token-Match und Transcript-Match dieselbe
    /// Toleranz haben).
    static func normalizedForMatching(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

    /// `consumeToken` kapselt den Store-Zugriff (Hash-Match + Konsum),
    /// `failedTurnEvidence` die Transcript-Tail-Probe: Liefert sie `true`,
    /// ist die ERSTE Ausführung dieses Prompts nachweislich mit einem
    /// Modell-/API-Fehler gescheitert („Prompt is too long", Vorfall
    /// 2026-08-17 #2) — dann ist die Wiedervorlage ein legitimer Retry und
    /// passiert ohne Token. Läuft der Retry durch, ist der letzte Outcome
    /// wieder „ausgeführt" und die Sperre greift erneut.
    static func decide(
        prompt: String,
        consumeToken: (String) -> Bool,
        failedTurnEvidence: (String) -> Bool = { _ in false }
    ) -> Verdict {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(markerPrefix) else { return .allow }
        if consumeToken(prompt) { return .allow }
        if failedTurnEvidence(prompt) { return .allow }
        return .block(reason:
            "WhisperM8-Send-Guard: Dieser [via whisperm8 chats]-Prompt wurde bereits "
            + "zugestellt oder zurückgezogen — vermutlich hat die CLI ihn nach einem "
            + "Abbruch (ESC) ins Eingabefeld zurückgelegt. Nicht erneut ausgeführt; "
            + "das Eingabefeld wird geleert. "
            + "Falls die Zustellung doch gewollt ist: per `whisperm8 chats send` neu senden.")
    }
}

/// Transcript-Tail-Probe des Guards: War die letzte Ausführung GENAU dieses
/// Prompts ein Modell-/API-Fehler? Dann ist ein Composer-Retry legitim
/// („einmal zugestellt" ≠ „einmal erfolgreich ausgeführt" — Vorfall
/// 2026-08-17 #2: „Prompt is too long" nach `chats send`, die Wiedervorlage
/// war der einzige Weg und wurde fälschlich geblockt).
///
/// Bewusst ENG: Nur ein expliziter Fehlertext des Assistant zählt als
/// Beleg. Ein per ESC abgebrochener Turn hinterlässt KEINEN solchen Eintrag
/// (Teil-Output oder nichts) — das Abbruch-Szenario bleibt gesperrt.
enum PromptGuardRetryProbe {
    /// Fehlertexte, mit denen die Claude-CLI einen gescheiterten Turn als
    /// Assistant-Eintrag materialisiert. Präfix-Match, eng halten.
    static let assistantErrorPrefixes = [
        "Prompt is too long",
        "API Error",
        "Credit balance is too low",
    ]

    /// `transcriptTail` = die letzten JSONL-Zeilen des Session-Transcripts
    /// (Reihenfolge wie in der Datei). Liefert `true`, wenn der letzte
    /// user-Eintrag mit diesem Prompt-Text existiert und danach als einzige
    /// inhaltliche Antwort ein Fehlertext kam.
    static func failedTurnEvidence(prompt: String, transcriptTail: String) -> Bool {
        let wanted = SendDeliveryTokenStore.normalizedForMatching(prompt)
        guard !wanted.isEmpty else { return false }

        var lastMatchIndex: Int?
        var entries: [(type: String, text: String)] = []
        for line in transcriptTail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = (object["type"] as? String) ?? ""
            entries.append((type: type, text: Self.messageText(object)))
            if type == "user",
               SendDeliveryTokenStore.normalizedForMatching(entries.last!.text) == wanted {
                lastMatchIndex = entries.count - 1
            }
        }
        guard let lastMatchIndex else { return false }

        // Nach dem Prompt: erster inhaltlicher Assistant-Eintrag entscheidet.
        // Fehlertext → Retry erlaubt; normaler Text → ausgeführt → gesperrt.
        // Gar kein Assistant-Text (ESC vor erstem Output) → gesperrt.
        for entry in entries[(lastMatchIndex + 1)...] where entry.type == "assistant" {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return assistantErrorPrefixes.contains { text.hasPrefix($0) }
        }
        return false
    }

    private static func messageText(_ object: [String: Any]) -> String {
        guard let message = object["message"] as? [String: Any] else { return "" }
        if let text = message["content"] as? String { return text }
        guard let parts = message["content"] as? [[String: Any]] else { return "" }
        return parts.compactMap { part in
            (part["type"] as? String) == "text" ? part["text"] as? String : nil
        }.joined()
    }
}
