import Foundation

// MARK: - move-account (Handeln, Socket)

/// `whisperm8 chats move-account <ref> [<ref>…] --to <profil>` — CLI-
/// Entsprechung von „Zu Account verschieben". Die Entscheidung trifft die App
/// (derselbe Planer, dieselben Skip-Regeln, dasselbe Journal wie die
/// Oberflaeche); die CLI loest nur die Refs auf und formatiert das Ergebnis.
struct ChatsMoveAccountOptions: Equatable {
    var refs: [String] = []
    var toProfile = ""
    /// Nur die Vorschau: was wuerde umziehen, was nicht und warum.
    var dryRun = false
    /// Laufende, nicht arbeitende Chats anhalten, umziehen und im Zielkonto
    /// neu starten. Ohne dieses Flag werden laufende Chats uebersprungen.
    var stopAndResume = false
    /// Nur mit `--stop-and-resume`: auch arbeitende Chats bzw. Chats mit
    /// vermutlich ungesendetem Entwurf anhalten.
    var force = false
    var json = false

    static let usage = "Usage: whisperm8 chats move-account <ref> [<ref>…] --to <profil> "
        + "[--dry-run] [--stop-and-resume [--force]] [--json]"
}

extension ChatsCLIParser {
    static func parseMoveAccount(_ arguments: [String]) throws -> ChatsMoveAccountOptions {
        var options = ChatsMoveAccountOptions()
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--to":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else {
                    throw ParseError.missingValue(arg)
                }
                options.toProfile = arguments[index]
            case "--dry-run": options.dryRun = true
            case "--stop-and-resume": options.stopAndResume = true
            case "--force": options.force = true
            case "--json": options.json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                options.refs.append(arg)
            }
            index += 1
        }
        guard !options.refs.isEmpty else { throw ParseError.missingShortID }
        guard !options.toProfile.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ParseError.missingValue("--to")
        }
        // Wie bei `close --stop`: `--force` ohne das Flag, das es erst
        // gefaehrlich macht, ist ein Tippfehler oder eine Fehlannahme.
        guard !options.force || options.stopAndResume else {
            throw ParseError.invalidValue(flag: "--force", value: "ohne --stop-and-resume",
                                          allowed: "--force nur zusammen mit --stop-and-resume")
        }
        return options
    }
}

/// Ergebnis je Chat, aus der Server-Response geparst — pur und Equatable,
/// damit Exit-Code und Zeilenformat testbar sind.
struct ChatsMoveAccountResultItem: Equatable {
    var id: String
    var title: String?
    var project: String?
    var fromProfile: String
    /// moved | wouldMove | skipped | failed | notFound
    var outcome: String
    var reason: String?
    var reasonLabel: String?
    var stopAndResume = false
    var stopAndResumePossible = false
    var stopBlocked: String?
    var resumeScheduled = false
}

enum ChatsMoveAccountSupport {
    static func items(from result: ChatsControlJSON?) -> [ChatsMoveAccountResultItem] {
        guard let results = result?["results"]?.arrayValue else { return [] }
        return results.map { entry in
            ChatsMoveAccountResultItem(
                id: entry["id"]?.stringValue ?? "?",
                title: entry["title"]?.stringValue,
                project: entry["project"]?.stringValue,
                fromProfile: entry["fromProfile"]?.stringValue ?? ClaudeAccountProfiles.mainProfileName,
                outcome: entry["outcome"]?.stringValue ?? "notFound",
                reason: entry["reason"]?.stringValue,
                reasonLabel: entry["reasonLabel"]?.stringValue,
                stopAndResume: entry["stopAndResume"]?.boolValue ?? false,
                stopAndResumePossible: entry["stopAndResumePossible"]?.boolValue ?? false,
                stopBlocked: entry["stopBlocked"]?.stringValue,
                resumeScheduled: entry["resumeScheduled"]?.boolValue ?? false)
        }
    }

    /// Exit-Vertrag: 3, wenn ein Ziel nicht (mehr) existiert. Die Vorschau
    /// ist sonst immer 0 — sie aendert nichts. Beim echten Umzug heisst 0:
    /// jeder Chat ist jetzt im Zielkonto (umgezogen oder war schon dort).
    /// Alles andere — uebersprungen oder gescheitert — ist 4, damit ein
    /// Supervisor „nicht alles erledigt" nicht aus dem Text raten muss.
    static func exitCode(for items: [ChatsMoveAccountResultItem], dryRun: Bool) -> Int32 {
        if items.contains(where: { $0.outcome == "notFound" }) { return ChatsCLIExit.notFound }
        if dryRun { return ChatsCLIExit.ok }
        let complete = items.allSatisfy { item in
            item.outcome == "moved"
                || (item.outcome == "skipped" && item.reason == AccountMovePlanner.SkipReason.alreadyInTarget.rawValue)
        }
        return complete ? ChatsCLIExit.ok : ChatsCLIExit.conflict
    }

    static func humanLine(
        for item: ChatsMoveAccountResultItem,
        toProfile: String,
        fallbackLabel: String?
    ) -> String {
        let label = [item.project, item.title].compactMap { $0 }.joined(separator: "/")
        let name = label.isEmpty ? (fallbackLabel ?? item.id) : label
        let route = "\(item.fromProfile) → \(toProfile)"
        let why = item.reasonLabel.map { " — \($0)" } ?? ""
        switch item.outcome {
        case "wouldMove" where item.stopAndResume:
            return "↻ würde anhalten, umziehen und neu starten: \(name) (\(route))"
        case "wouldMove":
            return "→ würde umziehen: \(name) (\(route))"
        case "moved" where item.resumeScheduled:
            return "✓ umgezogen, Neustart vorgemerkt: \(name) (\(route))"
        case "moved":
            return "✓ umgezogen: \(name) (\(route))"
        case "skipped":
            var line = "– übersprungen: \(name)\(why)"
            if item.stopAndResumePossible {
                line += " (mit --stop-and-resume umziehbar)"
            }
            if item.resumeScheduled {
                line += " · Neustart im bisherigen Konto vorgemerkt"
            }
            return line
        case "failed":
            var line = "✗ fehlgeschlagen: \(name)\(why)"
            if item.resumeScheduled {
                line += " · Neustart im bisherigen Konto vorgemerkt"
            }
            return line
        default:
            return "✗ nicht gefunden: \(name)\(why)"
        }
    }

    static func summaryLine(for items: [ChatsMoveAccountResultItem], dryRun: Bool) -> String {
        func count(_ outcome: String) -> Int { items.filter { $0.outcome == outcome }.count }
        var parts: [String] = []
        if dryRun {
            parts.append("\(count("wouldMove")) würden umziehen")
        } else {
            parts.append("\(count("moved")) umgezogen")
        }
        let skipped = count("skipped")
        if skipped > 0 { parts.append("\(skipped) übersprungen") }
        let failed = count("failed")
        if failed > 0 { parts.append("\(failed) fehlgeschlagen") }
        let notFound = count("notFound")
        if notFound > 0 { parts.append("\(notFound) nicht gefunden") }
        return parts.joined(separator: " · ")
    }
}

enum ChatsMoveAccountCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let options: ChatsMoveAccountOptions
        do {
            options = try ChatsCLIParser.parseMoveAccount(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            CLIIO.err(ChatsMoveAccountOptions.usage)
            return ChatsCLIExit.usage
        }

        // Alles-oder-nichts bei der Aufloesung (wie close/pin): eine
        // mehrdeutige Ref bricht ab, BEVOR irgendein Chat umzieht.
        var targetIDs: [UUID] = []
        var labelByID: [UUID: String] = [:]
        for ref in options.refs {
            switch ChatsLiveSupport.resolveTarget(ref: ref) {
            case .resolved(let id, let label):
                if !targetIDs.contains(id) { targetIDs.append(id) }
                labelByID[id] = label
            case .failed(let code):
                return code
            }
        }

        let params: [String: Any] = [
            "targetSessionIDs": targetIDs.map(\.uuidString),
            "toProfile": options.toProfile,
            "dryRun": options.dryRun,
            "stopAndResume": options.stopAndResume,
            "force": options.force,
        ]
        switch ChatsLiveSupport.perform(method: "session.moveAccount", params: params) {
        case .failed(let code):
            return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            let items = ChatsMoveAccountSupport.items(from: response.result)
            if options.json {
                CLIIO.out(ChatsOutput.encodeJSON(ChatsLiveSupport.jsonObject(from: response)))
            } else {
                let toProfile = response.result?["toProfile"]?.stringValue ?? options.toProfile
                CLIIO.out(options.dryRun
                    ? "Konto-Umzug nach „\(toProfile)“ — Vorschau, nichts geändert:"
                    : "Konto-Umzug nach „\(toProfile)“:")
                for item in items {
                    let fallback = UUID(uuidString: item.id).flatMap { labelByID[$0] }
                    CLIIO.out("  " + ChatsMoveAccountSupport.humanLine(
                        for: item, toProfile: toProfile, fallbackLabel: fallback))
                }
                CLIIO.out(ChatsMoveAccountSupport.summaryLine(for: items, dryRun: options.dryRun))
                if !options.dryRun, items.contains(where: { $0.outcome == "moved" }) {
                    CLIIO.out("Rückgängig: in der App im Kontextmenü „Zu Account verschieben → "
                        + "Letzten Kontowechsel rückgängig machen“.")
                }
                if items.contains(where: { $0.resumeScheduled }) {
                    CLIIO.out("Neu gestartet wird beim Anzeigen des Tabs; sofort mit Fokus: "
                        + "whisperm8 chats resume <ref>.")
                }
            }
            return ChatsMoveAccountSupport.exitCode(for: items, dryRun: options.dryRun)
        }
    }
}
