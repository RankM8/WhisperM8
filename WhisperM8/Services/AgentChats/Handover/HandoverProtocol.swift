import Foundation
import Security

// MARK: - Übergabeprotokoll (Aufbewahrer ↔ App ↔ CLI)

/// Protokoll zwischen alter App, Aufbewahrer, neuer App und CLI beim
/// „Neustart ohne Chatverlust“ (docs/plans/neustart-ohne-chatverlust.md).
///
/// **Grundvertrag, versionsunabhängig:** Rahmung (4 Byte Länge big-endian +
/// JSON), das Feld `type` sowie `HELLO`, `INCOMPATIBLE`, `RELEASE` und
/// `STATUS`. Damit kann eine neue App einem alten Aufbewahrer immer noch
/// sagen „gib frei“, auch wenn sie sein Protokoll sonst nicht spricht.
///
/// **Harte Regel:** Wer einen Deskriptor verschickt, schließt ihn erst, wenn
/// der Empfänger ihn mit `ACK` bestätigt hat. Ohne diese Regel kann der Kernel
/// einen Deskriptor, der noch im Socket steckt, beim Aufräumen für verwaist
/// halten — bei einer PTY-Leitung hieße das: Leitung zu, Chat tot
/// (Fehlersuche 12.11.2026, 120 von 120 Übergaben fehlerfrei nur mit ACK).
enum HandoverProtocol {
    /// Versionen, die dieser Build spricht. Die neue App spricht das eigene
    /// Protokoll und das vorige; passt nichts, gilt `RELEASE`.
    static let supported: ClosedRange<Int> = 1...1
    static var current: Int { supported.upperBound }

    /// Obergrenze für ein JSON-Telegramm.
    static let maxFrameBytes = 1_048_576
    /// Obergrenze für die Nutzlast hinter einem Telegramm (Terminal-Bild).
    static let maxPayloadBytes = 64 * 1_048_576

    /// Aushandeln: höchste Version, die beide sprechen. `nil` = unverträglich.
    static func negotiate(
        keeper: ClosedRange<Int> = supported,
        client: ClosedRange<Int>
    ) -> Int? {
        let low = max(keeper.lowerBound, client.lowerBound)
        let high = min(keeper.upperBound, client.upperBound)
        return low <= high ? high : nil
    }

    /// Kennung des laufenden Builds, nur zur Anzeige und fürs Log.
    static var buildIdentifier: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "dev"
        }
    }
}

/// Nachrichtenarten. Werden nur ergänzt, nie umbenannt.
enum HandoverMessageType: String, Codable, Equatable {
    case hello = "HELLO"
    case ok = "OK"
    case incompatible = "INCOMPATIBLE"
    case deposit = "DEPOSIT"
    case ack = "ACK"
    case commit = "COMMIT"
    case abort = "ABORT"
    case list = "LIST"
    case chats = "CHATS"
    case take = "TAKE"
    case chat = "CHAT"
    case done = "DONE"
    case release = "RELEASE"
    case status = "STATUS"
    case statusResult = "STATUS_RESULT"
    case error = "ERROR"
}

/// Rolle, mit der sich eine Gegenseite bei `HELLO` meldet.
enum HandoverRole: String, Codable, Equatable {
    /// Alte App gibt ihre Chats ab.
    case deposit
    /// Neue App holt die Chats zurück.
    case take
}

/// Ein Telegramm. Bewusst eine flache Struktur mit optionalen Feldern statt
/// eines Enums mit Nutzlasten: neue Felder kommen einfach dazu, ein älterer
/// Leser ignoriert sie.
struct HandoverMessage: Codable, Equatable {
    var type: HandoverMessageType

    // HELLO / OK
    var role: HandoverRole?
    /// Abgabe: genau die Version der alten App.
    var protocolVersion: Int?
    /// Übernahme: Bereich, den die neue App spricht, `[min, max]`.
    var protocolRange: [Int]?
    var build: String?
    var appPid: Int32?
    /// Kennung des Aufbewahrer-Laufs (`--run`), in `OK` und `STATUS_RESULT`.
    var runID: String?
    /// HELLO der Abgabe: das Einmal-Geheimnis, das die alte App dem
    /// Aufbewahrer beim Start über stdin gegeben hat.
    var secret: String?

    // DEPOSIT / CHAT / ACK / TAKE
    var chatID: String?
    var manifest: HandoverManifest?
    /// Hängt an diesem Telegramm ein Deskriptor (`SCM_RIGHTS`)?
    var hasDescriptor: Bool?
    /// Länge der Nutzlast, die direkt hinter dem Telegramm im Strom folgt.
    var payloadBytes: Int?
    /// CHAT: Prozess ist in der Lücke beendet worden.
    var exited: Bool?
    /// CHAT: Exit-Status im Format von `waitpid` (nur wenn bekannt).
    var exitStatus: Int32?
    /// CHAT: Bytes, die der Aufbewahrer in der Lücke gelesen hat.
    var gapBytes: Int?

    // CHATS
    var chats: [HandoverChatSummary]?

    // STATUS_RESULT
    var status: HandoverKeeperStatus?

    // ERROR
    var message: String?
    /// Nur bei echter Ablehnung des Anfragenden (falsches Geheimnis, fremder
    /// Absender): `secret` oder `peer`. Fehlt bei „belegt“ und Ähnlichem.
    var rejection: String?

    init(type: HandoverMessageType) {
        self.type = type
    }

    static func error(_ text: String) -> HandoverMessage {
        var msg = HandoverMessage(type: .error)
        msg.message = text
        return msg
    }

    static func rejected(_ text: String, reason: String) -> HandoverMessage {
        var msg = error(text)
        msg.rejection = reason
        return msg
    }

    var protocolRangeValue: ClosedRange<Int>? {
        guard let range = protocolRange, range.count == 2, range[0] <= range[1] else { return nil }
        return range[0]...range[1]
    }
}

/// Eintrag der Liste `CHATS` (Antwort auf `LIST`). Enthält das Manifest und
/// damit das Control-Token — geht nur an eine geprüfte App, nie an `STATUS`.
struct HandoverChatSummary: Codable, Equatable {
    var manifest: HandoverManifest
    var exited: Bool
    var exitStatus: Int32?
    var gapBytes: Int
}

// MARK: - Einmal-Geheimnis

/// Nachweis der alten App gegenüber „ihrem“ Aufbewahrer. Geht nie über
/// Argumente (sichtbar in `ps`) und nie auf die Platte, nur über stdin.
enum HandoverSecret {
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isWellFormed(_ text: String) -> Bool {
        text.count >= 32 && text.allSatisfy(\.isHexDigit)
    }

    /// Vergleich ohne frühen Ausstieg.
    static func matches(_ given: String?, expected: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<a.count { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}

// MARK: - Manifest

/// Begleitdaten je Chat. Felder werden nur ergänzt, nie umbenannt (siehe Plan,
/// Abschnitt „Manifest je Chat“). Der Aufbewahrer selbst braucht nur Kennung,
/// Art, PID, Größe, Farben und `sendsInterruptOnStop`; alles andere reicht er
/// unverändert an die neue App weiter.
///
/// Enthält das Control-Token: nie auf die Platte, nie ins Log.
struct HandoverManifest: Codable, Equatable {
    /// Sitzungs-ID in WhisperM8.
    var chatID: String
    /// `claude`, `codex`, `terminal` oder `attach`.
    var kind: String
    var pid: Int32
    /// Startzeit des Prozesses (Sekunden seit 1970), gegen wiederverwendete PIDs.
    var pidStartTime: Double?
    var cols: Int
    var rows: Int
    /// Scrollback des Terminals in Zeilen (`nil` = SwiftTerm-Standard).
    var scrollback: Int?
    /// Beim geordneten Beenden zweimal Ctrl+C senden (wie `AgentLaunchCommand`).
    var sendsInterruptOnStop: Bool
    /// Das vollständige `AgentLaunchCommand`, für den Aufbewahrer undurchsichtig.
    var launchCommand: HandoverJSONValue?
    var controlToken: String?
    var title: String?
    /// Byte-Position in der Hook-Event-Datei.
    var hookCursor: UInt64?
    /// „Arbeitet seit“ (Sekunden seit 1970) für Statistik und Wach-Knopf.
    var workingSince: Double?
    /// Entwurf im Eingabefeld; `nil` = unbekannt, gilt dann als „Entwurf vorhanden“.
    var hasComposerDraft: Bool?
    /// Vorgemerkter Kontowechsel nach dem Turn (Entscheidung 9), undurchsichtig.
    var pendingAccountSwitch: HandoverJSONValue?
    var accountProfile: String?
    var gptProfile: String?
    /// Externe Sitzungs-ID von Claude oder Codex.
    var externalSessionID: String?
    /// Farben, die die App auf OSC 10/11 meldet. Ergänzung von Paket 2: Ohne
    /// sie nennt der Aufbewahrer den TUIs in der Lücke andere Farben als die App.
    var terminalColors: HandoverTerminalColors?
    /// Zurückgestellte SessionStart-ID (`/clear`, frische Sitzung nach
    /// `/background`), die erst mit dem ersten echten Turn gebunden wird. Liegt
    /// in der App nur im Speicher; ohne Manifest hinge der Chat nach der
    /// Übergabe an der alten ID (Bindungs-Befund, Punkt c).
    var pendingExternalSessionID: String?
    /// IDs der Background-Forks dieses Chats, die nie gebunden werden.
    var forkExternalSessionIDs: [String]?

    init(
        chatID: String,
        kind: String,
        pid: Int32,
        pidStartTime: Double? = nil,
        cols: Int,
        rows: Int,
        sendsInterruptOnStop: Bool
    ) {
        self.chatID = chatID
        self.kind = kind
        self.pid = pid
        self.pidStartTime = pidStartTime
        self.cols = cols
        self.rows = rows
        self.sendsInterruptOnStop = sendsInterruptOnStop
    }
}

struct HandoverTerminalColors: Codable, Equatable {
    /// `#rrggbb`
    var foreground: String
    var background: String
}

/// Undurchsichtiger JSON-Wert für Manifest-Teile, die nur die App versteht.
indirect enum HandoverJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HandoverJSONValue])
    case object([String: HandoverJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([HandoverJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: HandoverJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Status (für `whisperm8 app handover-status`)

/// Lagebild des Aufbewahrers. Ohne Tokens und ohne Terminal-Inhalte — geht an
/// jeden Prozess desselben Nutzers.
struct HandoverKeeperStatus: Codable, Equatable {
    var runID: String
    var pid: Int32
    var phase: String
    var protocolRange: [Int]
    var build: String
    var startedAt: Double
    /// Frist, nach der der Aufbewahrer geordnet beendet (Sekunden seit 1970).
    var deadline: Double?
    var chats: [Chat]

    struct Chat: Codable, Equatable {
        var chatID: String
        var kind: String
        var pid: Int32
        var exited: Bool
        var exitStatus: Int32?
        var gapBytes: Int
        /// Gerade an eine App unterwegs (TAKE gesendet, ACK fehlt noch).
        var inTransfer: Bool
    }
}

// MARK: - Pfade

/// Ordner des Aufbewahrers einer Instanz: Lock, Socket, Log, Discovery.
/// Standard: `Application Support/WhisperM8/handover/` (Test-Instanz: unter
/// ihrer eigenen Wurzel, über `AppInstance`).
struct HandoverPaths: Equatable {
    let directory: URL

    static func defaultDirectory() -> URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("handover", isDirectory: true)
    }

    static var `default`: HandoverPaths { HandoverPaths(directory: defaultDirectory()) }

    var lockFileURL: URL { directory.appendingPathComponent("keeper.lock") }
    /// Hält die App, solange sie beim Start übernimmt (Befund 4, Dex).
    var takeLockFileURL: URL { directory.appendingPathComponent("take.lock") }
    var logFileURL: URL { directory.appendingPathComponent("keeper.log") }
    /// Enthält genau eine Zeile: den realen Socket-Pfad.
    var discoveryFileURL: URL { directory.appendingPathComponent("socket-path") }

    var preferredSocketURL: URL { directory.appendingPathComponent("keeper.sock") }

    /// Ausweichpfad, wenn der bevorzugte zu lang für `sun_path` ist.
    var fallbackSocketURL: URL {
        let tag = String(UInt32(truncatingIfNeeded: AppInstance.stableHash(directory.standardizedFileURL.path)), radix: 36)
        return URL(fileURLWithPath: "/private/tmp/whisperm8-\(getuid())-h\(tag)/keeper.sock")
    }

    /// Socket-Pfad, den der Aufbewahrer bindet.
    var socketURL: URL {
        ChatsControlProtocol.socketPathFits(preferredSocketURL) ? preferredSocketURL : fallbackSocketURL
    }

    /// Socket-Pfad für Clients: erst die Discovery-Datei, sonst die Regel oben.
    func resolvedSocketURL() -> URL {
        if let raw = try? String(contentsOf: discoveryFileURL, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        }
        return socketURL
    }
}
