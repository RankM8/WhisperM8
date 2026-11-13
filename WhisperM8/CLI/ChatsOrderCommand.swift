import Foundation

// MARK: - whisperm8 chats order

/// `whisperm8 chats order <ref>… [--last <ref>]… [--dry-run] [--json]`:
/// setzt die Reihenfolge der Chats eines Projekts in der Seitenleiste; die
/// Projekt-Ansicht (Raster) folgt. Genannte Chats kommen in dieser Folge nach
/// vorn, `--last` ans Ende, alle übrigen behalten ihre relative Folge
/// dazwischen. Die App schreibt, die CLI handelt über den Socket.
enum ChatsOrderCommand {
    static let usage = "Usage: whisperm8 chats order [--tabs] <ref> [<ref>…] [--last <ref>]… [--dry-run] [--json]"

    struct Options: Equatable {
        var first: [String] = []
        var last: [String] = []
        var dryRun = false
        var json = false
        /// Tab-Folge im Fenster statt Folge in der Seitenleiste.
        var tabs = false
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--last":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ChatsOrderParseError("--last braucht einen Chat")
                }
                options.last.append(arguments[index])
            case "--dry-run": options.dryRun = true
            case "--tabs": options.tabs = true
            case "--json": options.json = true
            default:
                if argument.hasPrefix("--") { throw ChatsOrderParseError("Unbekannte Option: \(argument)") }
                options.first.append(argument)
            }
            index += 1
        }
        guard !(options.first.isEmpty && options.last.isEmpty) else {
            throw ChatsOrderParseError("Mindestens einen Chat nennen")
        }
        return options
    }

    static func run(_ arguments: [String]) -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            CLIIO.err(usage)
            return ChatsCLIExit.usage
        }
        let context = ChatsCommandContext.load()
        func resolve(_ refs: [String]) -> Result<[UUID], ChatsOrderFailure> {
            var ids: [UUID] = []
            for ref in refs {
                switch ChatsLiveSupport.resolveTarget(ref: ref, context: context) {
                case .resolved(let id, _): ids.append(id)
                case .failed(let code): return .failure(ChatsOrderFailure(code: code))
                }
            }
            return .success(ids)
        }
        let first: [UUID]
        let last: [UUID]
        switch (resolve(options.first), resolve(options.last)) {
        case (.success(let f), .success(let l)): (first, last) = (f, l)
        case (.failure(let error), _), (_, .failure(let error)): return error.code
        }

        let params: [String: Any] = [
            "firstSessionIDs": first.map(\.uuidString),
            "lastSessionIDs": last.map(\.uuidString),
            "dryRun": options.dryRun,
        ]
        switch ChatsLiveSupport.perform(method: options.tabs ? "tab.order" : "session.order", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            if options.json {
                CLIIO.out(ChatsOutput.encodeJSON(ChatsLiveSupport.jsonObject(from: response)))
            } else {
                CLIIO.out(textReport(response.result, tabs: options.tabs))
            }
            return ChatsCLIExit.ok
        }
    }

    /// Lesbare Ausgabe: neue Folge mit Nummer, bei Änderung die alte Position.
    static func textReport(_ result: ChatsControlJSON?, tabs: Bool = false) -> String {
        let project = result?["project"]?.stringValue ?? "?"
        let dryRun = result?["dryRun"]?.boolValue ?? false
        let changed = result?["changed"]?.boolValue ?? false
        let before = (result?["before"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        let place = tabs
            ? "Tabs im Fenster \(ChatsWindowCommand.shortWindowID(result?["windowID"]?.stringValue)) (Projekt \(project))"
            : project
        var lines = [dryRun ? "Vorschau für \(place) (nichts geändert):" : "Reihenfolge in \(place):"]
        for entry in result?["after"]?.arrayValue ?? [] {
            let position = entry["position"]?.intValue ?? 0
            let title = entry["title"]?.stringValue ?? ""
            let id = entry["id"]?.stringValue ?? ""
            let old = (before.firstIndex(of: id)).map { $0 + 1 }
            let note = old.map { $0 == position ? "" : "  (vorher \($0))" } ?? ""
            lines.append("  \(position). \(title)\(note)")
        }
        let views = result?["projectViews"]?.arrayValue ?? []
        let moved = views.filter { view in
            (view["before"]?.arrayValue ?? []) != (view["after"]?.arrayValue ?? [])
        }
        if !views.isEmpty {
            lines.append(moved.isEmpty
                ? "Projekt-Ansicht: schon in dieser Folge."
                : "Projekt-Ansicht folgt: \(moved.compactMap { $0["name"]?.stringValue }.joined(separator: ", "))")
        }
        if !changed { lines.append("Unverändert: Die Folge stimmte schon.") }
        if result?["persisted"]?.boolValue == false {
            lines.append("Achtung: In der App gesetzt, aber noch nicht gespeichert; chats list kann kurz die alte Folge zeigen.")
        }
        return lines.joined(separator: "\n")
    }
}

struct ChatsOrderFailure: Error {
    var code: Int32
}

struct ChatsOrderParseError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
