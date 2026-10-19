import Foundation

// MARK: - `whisperm8 chats address <ref>`

/// Adressbuch für Claudes natives `SendMessage` über Konten hinweg:
/// `ListAgents` sieht nur das eigene Profil, die Sockets aller Konten liegen
/// aber gemeinsam in `/tmp/cc-socks` — eine `uds:`-Adresse erreicht jeden
/// laufenden Claude-Chat (Plan `claude-status-aus-registry.md`, S1).
/// Liest nur Claudes Registry, braucht keine laufende App.
struct ChatsAddressOptions: Equatable {
    var ref = ""
    var json = false
}

/// Warum ein Chat keine Adresse hat — Klartext für stderr/JSON.
enum ChatsAddressUnavailable: String, Equatable {
    case notClaude
    case notBound
    case notRunning
    case noInbox

    var message: String {
        switch self {
        case .notClaude: return "kein Claude-Chat (Codex & Co. haben kein natives SendMessage)"
        case .notBound: return "Chat hat noch keine Claude-Session-ID"
        case .notRunning: return "Chat läuft gerade nicht"
        case .noInbox: return "Claude-Prozess läuft, hat aber kein Postfach (Socket)"
        }
    }
}

enum ChatsAddressLogic {
    enum Outcome: Equatable {
        case address(ClaudeSessionRecord)
        case unavailable(ChatsAddressUnavailable)
    }

    /// Pur: Chat-Fakten + Registry-Index → Adresse oder Grund.
    static func resolve(
        provider: AgentProvider,
        externalSessionID: String?,
        registry: [String: ClaudeSessionRecord]
    ) -> Outcome {
        guard provider == .claude else { return .unavailable(.notClaude) }
        guard let ext = externalSessionID, !ext.isEmpty else { return .unavailable(.notBound) }
        guard let record = registry[ext] else { return .unavailable(.notRunning) }
        guard record.messagingAddress != nil else { return .unavailable(.noInbox) }
        return .address(record)
    }

    static func json(entry: ChatsSessionEntry, outcome: Outcome) -> [String: Any] {
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "id": entry.session.id.uuidString,
            "shortID": ChatsOutput.shortID(entry.session.id),
            "title": entry.session.title,
        ]
        switch outcome {
        case .address(let record):
            payload["reachable"] = true
            payload["address"] = record.messagingAddress ?? NSNull()
            payload["nativeName"] = record.name ?? NSNull()
            payload["account"] = record.profileName
            payload["status"] = record.rawStatus ?? NSNull()
            payload["waitingFor"] = record.waitingFor ?? NSNull()
            payload["pid"] = Int(record.pid)
            payload["externalSessionID"] = record.sessionID
        case .unavailable(let reason):
            payload["reachable"] = false
            payload["reason"] = reason.rawValue
            payload["explanation"] = reason.message
        }
        return payload
    }
}

enum ChatsAddressCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let options: ChatsAddressOptions
        do {
            options = try parse(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return ChatsCLIExit.usage
        }

        let context = ChatsCommandContext.load()
        let entry: ChatsSessionEntry
        switch context.resolve(ref: options.ref, includeArchived: true) {
        case .success(let resolved): entry = resolved
        case .failure(let code): return code
        }

        let registry = ClaudeSessionRegistry.indexBySessionID(
            ClaudeSessionRegistry.scan(roots: ClaudeSessionRegistry.roots()))
        let outcome = ChatsAddressLogic.resolve(
            provider: entry.session.provider,
            externalSessionID: entry.session.externalSessionID,
            registry: registry)

        if case .address = outcome {
            // Audit-Spur + Selbstschutz, bevor die Adresse ausgegeben wird
            // (LR-CLI-007). Ist die App nicht erreichbar, bleibt der reine
            // Registry-Lesebefehl wie bisher nutzbar (fail-open, keine Spur).
            if let response = try? ChatsControlClient.send(
                method: "audit.note", params: ["targetSessionID": entry.session.id.uuidString]),
               !response.ok {
                CLIIO.err("\(entry.session.title): \(response.error?.message ?? "abgelehnt")")
                return ChatsCLIExit.conflict
            }
        }
        if options.json {
            CLIIO.out(ChatsOutput.encodeJSON(ChatsAddressLogic.json(entry: entry, outcome: outcome)))
        }
        switch outcome {
        case .address(let record):
            if !options.json { CLIIO.out(record.messagingAddress ?? "") }
            return ChatsCLIExit.ok
        case .unavailable(let reason):
            if !options.json {
                CLIIO.err("\(entry.session.title): nicht nativ erreichbar — \(reason.message). Nimm `whisperm8 chats send`/`enqueue`.")
            }
            return ChatsCLIExit.conflict
        }
    }

    static func parse(_ arguments: [String]) throws -> ChatsAddressOptions {
        var options = ChatsAddressOptions()
        var positionals: [String] = []
        for arg in arguments {
            switch arg {
            case "--json": options.json = true
            default:
                if arg.hasPrefix("-") { throw AgentCLIParser.ParseError.unknownFlag(arg) }
                positionals.append(arg)
            }
        }
        guard positionals.count == 1 else {
            throw positionals.isEmpty
                ? AgentCLIParser.ParseError.missingShortID
                : AgentCLIParser.ParseError.tooManyPositionals
        }
        options.ref = positionals[0]
        return options
    }
}
