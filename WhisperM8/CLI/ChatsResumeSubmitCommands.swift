import Foundation

// MARK: - resume

/// `chats resume <ref> [--prompt "…" | -- "…"]`. Mit Auftrag wird er nach
/// dem Start vorgemerkt; die Warteschlange stellt erst zu, wenn Claudes
/// Eingabefeld steht (WM8-100). Direkt nach `resume` zu senden landete
/// früher im Eingabefeld, ohne abgeschickt zu werden.
enum ChatsResumeCommand {
    struct Arguments: Equatable {
        var ref: String
        var prompt: String?
        var json: Bool
    }

    static let usage = "Usage: whisperm8 chats resume <ref> [--prompt \"…\" | -- \"…\"] [--json]"

    struct UsageError: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// Pur, damit der Vertrag ohne Socket testbar bleibt.
    static func parse(_ arguments: [String]) -> Result<Arguments, UsageError> {
        var ref: String?
        var prompt: String?
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--json": json = true
            case "--prompt":
                index += 1
                guard index < arguments.count else { return .failure(UsageError("--prompt erwartet einen Text.")) }
                prompt = arguments[index]
            case "--":
                let rest = arguments[(index + 1)...].joined(separator: " ")
                guard !rest.isEmpty else { return .failure(UsageError("Nach -- fehlt der Auftrag.")) }
                prompt = rest
                index = arguments.count
                continue
            default:
                if arg.hasPrefix("-") { return .failure(UsageError("Unbekannte Option: \(arg)")) }
                if ref == nil { ref = arg } else { return .failure(UsageError("Zu viele Argumente.")) }
            }
            index += 1
        }
        guard let ref else { return .failure(UsageError(usage)) }
        if let prompt, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(UsageError("Der Auftrag ist leer."))
        }
        return .success(Arguments(ref: ref, prompt: prompt, json: json))
    }

    static func run(_ arguments: [String]) -> Int32 {
        let parsed: Arguments
        switch parse(arguments) {
        case .success(let value): parsed = value
        case .failure(let error): CLIIO.err(error.message); return ChatsCLIExit.usage
        }
        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: parsed.ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }
        let resumed: ChatsControlResponse
        switch ChatsLiveSupport.perform(method: "session.resume", params: ["targetSessionID": targetID.uuidString]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            resumed = response
        }
        let title = resumed.result?["target"]?["title"]?.stringValue ?? parsed.ref
        guard let prompt = parsed.prompt else {
            ChatsLiveSupport.printResult(resumed, json: parsed.json) { _ in "✓ \(title) wird wiederaufgenommen (Resume)" }
            return ChatsCLIExit.ok
        }
        // Erst nach dem Start vormerken: Der Chat steht dann auf „startet“,
        // die Warteschlange hält bis zum Eingabefeld an.
        switch ChatsLiveSupport.perform(method: "queue.enqueue", params: [
            "targetSessionID": targetID.uuidString, "prompt": prompt,
        ]) {
        case .failed(let code):
            CLIIO.err("Chat wurde gestartet, der Auftrag ist aber NICHT vorgemerkt.")
            return code
        case .ok(let response):
            guard response.ok else {
                CLIIO.err("Chat wurde gestartet, der Auftrag ist aber NICHT vorgemerkt.")
                return ChatsLiveSupport.mapError(response)
            }
            ChatsLiveSupport.printResult(response, json: parsed.json) { _ in
                "✓ \(title) wird wiederaufgenommen; der Auftrag (\(prompt.count) Zeichen) geht raus, "
                    + "sobald das Eingabefeld steht"
            }
            return ChatsCLIExit.ok
        }
    }
}

// MARK: - submit

/// `chats submit <ref>`: schickt den Text ab, der im Eingabefeld eines
/// Claude-Chats steht, ohne neuen Text (WM8-100).
enum ChatsSubmitCommand {
    static let usage = "Usage: whisperm8 chats submit <ref> [--json]"

    static func run(_ arguments: [String]) -> Int32 {
        var ref: String?
        var json = false
        for arg in arguments {
            switch arg {
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                if ref == nil { ref = arg } else { CLIIO.err("Zu viele Argumente."); return ChatsCLIExit.usage }
            }
        }
        guard let ref else { CLIIO.err(usage); return ChatsCLIExit.usage }
        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }
        switch ChatsLiveSupport.perform(method: "session.submit", params: ["targetSessionID": targetID.uuidString]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let title = result["target"]?["title"]?.stringValue ?? ref
                return result["submitCheck"]?.stringValue == PromptSubmitCheck.Verdict.unknown.rawValue
                    ? "✓ Enter an \(title) gesendet (ob der Text raus ist, war nicht abzulesen)"
                    : "✓ abgeschickt: \(title)"
            }
            return ChatsCLIExit.ok
        }
    }
}
