import Foundation

// MARK: - Nichts Geheimes ins Log

/// Befund 13.11.2026 (Dex, Fehler-Szenarien): Eine Logzeile gab den Plan der
/// Übernahme per `String(describing:)` aus; beim Fall `take` stand damit der
/// Anfang des Einmal-Geheimnisses öffentlich und dauerhaft im System-Log.
///
/// Regel für das ganze Modul: Logs nennen nur Fälle und Zahlen, nie
/// zugeordnete Werte. Zusätzlich beschreiben sich alle Typen, die Geheimnis,
/// Control-Token oder Manifest tragen, geschwärzt — ein versehentliches
/// `\(wert)` oder `String(describing:)` verrät dann nichts.
/// `HandoverRedactionTests` prüft beides.
enum HandoverLog {
    static let redacted = "<geschwärzt>"

    /// Fehler fürs Log: Art und Fall, ohne freie Texte.
    static func label(_ error: Error) -> String {
        switch error {
        case let error as HandoverWireError:
            switch error {
            case .timedOut: return "wire.timedOut"
            case .closed: return "wire.closed"
            case .io(let code): return "wire.io(\(code))"
            case .frameTooLarge: return "wire.frameTooLarge"
            case .payloadTooLarge: return "wire.payloadTooLarge"
            case .decode: return "wire.decode"
            case .missingDescriptor: return "wire.missingDescriptor"
            case .unexpected: return "wire.unexpected"
            }
        case let error as HandoverClient.ClientError:
            switch error {
            case .refused: return "client.refused"
            case .rejected(let reason): return reason == "secret" || reason == "peer" ? "client.rejected.\(reason)" : "client.rejected"
            case .incompatible: return "client.incompatible"
            case .unexpected: return "client.unexpected"
            }
        case let error as HandoverClient.VerificationError:
            switch error {
            case .wrongRunID: return "verify.wrongRunID"
            case .wrongPID: return "verify.wrongPID"
            case .untrustedServer: return "verify.untrustedServer"
            }
        default:
            return "error.\(type(of: error))"
        }
    }
}

extension HandoverLaunchPlan: CustomStringConvertible, CustomDebugStringConvertible {
    /// Nur der Fall, nie das Geheimnis oder eine PID.
    var logLabel: String {
        switch self {
        case .nothing: return "nothing"
        case .take: return "take"
        case .release: return "release"
        case .terminateKeeper: return "terminateKeeper"
        case .keeperGone: return "keeperGone"
        }
    }

    var description: String { logLabel }
    var debugDescription: String { logLabel }
}

extension HandoverSecretLookup: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .found: return "found(\(HandoverLog.redacted))"
        case .missing: return "missing"
        case .denied(let status): return "denied(\(status))"
        case .timedOut: return "timedOut"
        }
    }

    var debugDescription: String { description }
}

extension HandoverMessage: CustomStringConvertible, CustomDebugStringConvertible {
    /// Art und Chat, ohne Geheimnis, Manifest (Token) und Nutzlast.
    var description: String {
        var parts = ["type: \(type.rawValue)"]
        if let chatID { parts.append("chatID: \(chatID)") }
        if secret != nil { parts.append("secret: \(HandoverLog.redacted)") }
        if manifest != nil { parts.append("manifest: \(HandoverLog.redacted)") }
        return "HandoverMessage(\(parts.joined(separator: ", ")))"
    }

    var debugDescription: String { description }
}

extension HandoverManifest: CustomStringConvertible, CustomDebugStringConvertible {
    /// Kennung, Art und PID; Control-Token und Startkommando (Umgebung) nie.
    var description: String {
        "HandoverManifest(chatID: \(chatID), kind: \(kind), pid: \(pid)"
            + (controlToken != nil ? ", controlToken: \(HandoverLog.redacted)" : "") + ")"
    }

    var debugDescription: String { description }
}

extension HandoverChatSummary: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "HandoverChatSummary(\(manifest.description), exited: \(exited), gapBytes: \(gapBytes))"
    }

    var debugDescription: String { description }
}

extension HandoverClient.TakenChat: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "TakenChat(\(manifest.description), exited: \(exited), image: \(image.count) Byte)"
    }

    var debugDescription: String { description }
}

extension HandoverKeeper.Configuration: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "HandoverKeeper.Configuration(runID: \(runID), directory: \(paths.directory.path), secret: "
            + (secret == nil ? "nil" : HandoverLog.redacted) + ")"
    }

    var debugDescription: String { description }
}

// MARK: - Nacharbeit (Vic, 13.11.2026)

extension HandoverLaunchCommandSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
    /// Programm und Ordner; Argumente und Umgebung (Konto-Pfade, Header,
    /// Control-Token) nie.
    var description: String {
        "HandoverLaunchCommandSnapshot(executable: \((executablePath as NSString).lastPathComponent), "
            + "arguments: \(arguments.count), environment: \(HandoverLog.redacted))"
    }

    var debugDescription: String { description }
}

extension HandoverJSONValue: CustomStringConvertible, CustomDebugStringConvertible {
    /// Nur die Form, nie Werte: Das Startkommando im Manifest trägt die Umgebung.
    var description: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "string(\(HandoverLog.redacted))"
        case .array(let values): return "array(\(values.count))"
        case .object(let values): return "object(\(values.count) keys)"
        }
    }

    var debugDescription: String { description }
}

// `dump` und `Mirror` gehen an `description` vorbei und listen alle Felder.
// Für die Träger von Geheimnis und Token gibt es deshalb keine Kinder.
extension HandoverLaunchPlan: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}

extension HandoverSecretLookup: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}

extension HandoverMessage: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: ["type": type.rawValue], displayStyle: .struct) }
}

extension HandoverManifest: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: ["chatID": chatID, "kind": kind, "pid": pid], displayStyle: .struct) }
}

extension HandoverChatSummary: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension HandoverClient.TakenChat: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension HandoverKeeper.Configuration: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: ["runID": runID], displayStyle: .struct) }
}

extension HandoverLaunchCommandSnapshot: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension HandoverJSONValue: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}
