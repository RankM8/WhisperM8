import Foundation

// MARK: - Control-Socket-Protokoll (geteilt CLI ↔ App)

/// Ein Binary, zwei Rollen: dieselben Typen serialisieren die CLI-Seite
/// (Client) und die App-Seite (Server). NDJSON über einen BSD-Unix-Domain-
/// Socket — eine Zeile = ein JSON-Objekt, eine Response pro Request.
enum ChatsControlProtocol {
    /// Bei inkompatiblem Handshake bricht die CLI mit klarer Meldung ab, statt
    /// still Unsinn zu tun (Update-Fall: alter Prozess trifft neuen Server).
    static let version = 1

    /// Ordner (0700) + Socket (0600) unter Application Support. Der restriktive
    /// Elternordner schließt das bind→chmod-Fenster.
    static func controlDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("control", isDirectory: true)
    }

    /// Discovery-Datei: enthält genau eine Zeile — den absoluten Socket-Pfad.
    /// Die CLI liest zuerst hier, statt Pfade zu raten.
    static func discoveryFileURL() -> URL {
        controlDirectory().appendingPathComponent("socket-path")
    }

    static func lockFileURL() -> URL {
        controlDirectory().appendingPathComponent("control.lock")
    }

    /// Standard-Socket-Pfad. `sun_path` fasst auf macOS nur 104 Bytes inkl.
    /// NUL — ist der App-Support-Pfad zu lang, weicht der Server auf
    /// `/private/tmp/whisperm8-<uid>/control.sock` aus und publiziert den
    /// realen Pfad in der Discovery-Datei.
    static func defaultSocketURL() -> URL {
        controlDirectory().appendingPathComponent("control.sock")
    }

    static func fallbackSocketURL() -> URL {
        URL(fileURLWithPath: "/private/tmp/whisperm8-\(getuid())/control.sock")
    }

    /// `sun_path`-Limit inkl. abschließendem NUL.
    static let maxSocketPathBytes = 104

    static func socketPathFits(_ url: URL) -> Bool {
        url.path.utf8.count < maxSocketPathBytes
    }
}

// MARK: - Request

/// Eine Actor-Identität begleitet jeden mutierenden Request. `token` beweist,
/// dass der Aufruf aus genau der PTY dieser Session stammt — die nackte
/// `sessionID` wäre spoofbar.
struct ChatsControlActor: Codable, Equatable {
    var sessionID: String?
    var token: String?

    init(sessionID: String? = nil, token: String? = nil) {
        self.sessionID = sessionID
        self.token = token
    }

    init(identity: ChatsCallerIdentity) {
        self.sessionID = identity.sessionID?.uuidString
        self.token = identity.token
    }
}

struct ChatsControlRequest: Codable, Equatable {
    var protocolVersion: Int
    var requestID: String
    var actor: ChatsControlActor
    var method: String
    /// Methoden-spezifische Parameter, dynamisch getypt.
    var params: ChatsControlJSON

    init(
        protocolVersion: Int = ChatsControlProtocol.version,
        requestID: String = UUID().uuidString,
        actor: ChatsControlActor,
        method: String,
        params: ChatsControlJSON = .object([:])
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.actor = actor
        self.method = method
        self.params = params
    }
}

// MARK: - Response

/// Fehlercodes mappen 1:1 auf die CLI-Exit-Codes.
enum ChatsControlErrorCode: String, Codable {
    case notFound          // → Exit 3
    case conflict          // → Exit 4 (working-Ziel, Drift, Status-Guard)
    case selfSend          // → Exit 4 (Endlosschleife verhindert)
    case noPty             // → Exit 4 (keine laufende PTY)
    case invalid           // → Exit 1 (kaputte Parameter)
    case unsupported       // → Exit 1
    case internalError     // → Exit 4

    var exitCode: Int32 {
        switch self {
        case .notFound: return ChatsCLIExit.notFound
        case .conflict, .selfSend, .noPty, .internalError: return ChatsCLIExit.conflict
        case .invalid, .unsupported: return ChatsCLIExit.usage
        }
    }
}

struct ChatsControlError: Codable, Equatable {
    var code: String
    var message: String
    var detail: ChatsControlJSON?
}

struct ChatsControlResponse: Codable, Equatable {
    var protocolVersion: Int
    var requestID: String
    var ok: Bool
    var result: ChatsControlJSON?
    var error: ChatsControlError?

    static func success(requestID: String, result: ChatsControlJSON) -> ChatsControlResponse {
        ChatsControlResponse(protocolVersion: ChatsControlProtocol.version, requestID: requestID,
                             ok: true, result: result, error: nil)
    }

    static func failure(requestID: String, code: ChatsControlErrorCode, message: String,
                        detail: ChatsControlJSON? = nil) -> ChatsControlResponse {
        ChatsControlResponse(
            protocolVersion: ChatsControlProtocol.version, requestID: requestID, ok: false,
            result: nil, error: ChatsControlError(code: code.rawValue, message: message, detail: detail))
    }
}

// MARK: - NDJSON-Codec

enum ChatsControlCodec {
    /// Maximale Zeilenlänge (1 MiB) — schützt den Server vor Speicher-DoS.
    static let maxLineBytes = 1_048_576

    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        // JSON escaped Newlines in Strings — eine echte \n gibt es nur als
        // Zeilentrenner. Grenze sicher.
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

// MARK: - Dynamischer JSON-Wert

/// Minimaler dynamischer JSON-Typ für Params/Result/Detail — vermeidet ein
/// Typ-Zoo pro Methode, bleibt aber Codable-serialisierbar über den Socket.
indirect enum ChatsControlJSON: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ChatsControlJSON])
    case array([ChatsControlJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ChatsControlJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([ChatsControlJSON].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unbekannter JSON-Wert")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    // MARK: Bequeme Accessoren

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [ChatsControlJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> ChatsControlJSON? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    /// Baut einen `.object` aus einem `[String: Any]`-Literal (nur die
    /// unterstützten Typen; Unbekanntes wird zu `.null`).
    static func object(_ dict: [String: Any]) -> ChatsControlJSON {
        .object(dict.mapValues(ChatsControlJSON.init(any:)))
    }

    init(any value: Any) {
        switch value {
        case let string as String: self = .string(string)
        case let bool as Bool: self = .bool(bool)
        case let int as Int: self = .number(Double(int))
        case let double as Double: self = .number(double)
        case let dict as [String: Any]: self = .object(dict.mapValues(ChatsControlJSON.init(any:)))
        case let array as [Any]: self = .array(array.map(ChatsControlJSON.init(any:)))
        default: self = .null
        }
    }
}
