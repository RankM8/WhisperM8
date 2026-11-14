import Foundation

// MARK: - send

enum ChatsSendCommand {
    /// Frist für `--wait-started` ohne Zahl.
    static let defaultWaitSeconds: TimeInterval = 20

    static func run(_ arguments: [String]) -> Int32 {
        var positionals: [String] = []
        var ifStatus: [String]?
        var noSubmit = false
        var force = false
        var json = false
        // WM8-85: Standard ist Vormerken statt Absage; `--no-queue` gibt das
        // alte Verhalten. `--queue-if-busy` bleibt als ausdrückliche Form.
        var queueIfBusy = false
        var noQueue = false
        var answer = false
        var waitSeconds: TimeInterval?
        var promptsOnly = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if promptsOnly { positionals.append(arg); index += 1; continue }
            switch arg {
            case "--": promptsOnly = true
            case "--if-status":
                index += 1
                guard index < arguments.count else { CLIIO.err("--if-status erwartet einen Wert."); return ChatsCLIExit.usage }
                ifStatus = arguments[index].split(separator: ",").map(String.init)
            case "--no-submit": noSubmit = true
            case "--force": force = true
            case "--json": json = true
            case "--queue-if-busy": queueIfBusy = true
            case "--no-queue": noQueue = true
            case "--answer": answer = true
            case "--wait-started":
                waitSeconds = defaultWaitSeconds
            case let flag where flag.hasPrefix("--wait-started="):
                // Nur `=N`: eine freie Zahl dahinter wäre von einer Ref oder
                // einer Antwort wie „2“ nicht zu unterscheiden (Review).
                guard let value = TimeInterval(flag.dropFirst("--wait-started=".count)), value > 0 else {
                    CLIIO.err("--wait-started=N erwartet Sekunden > 0."); return ChatsCLIExit.usage
                }
                waitSeconds = min(value, 600)
            default:
                if arg.hasPrefix("-"), !promptsOnly { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count >= 2 else {
            CLIIO.err("Usage: whisperm8 chats send <ref> [--] \"<prompt>\" [--answer] [--no-queue] [--if-status S,S] [--no-submit] [--force]"
                      + " [--queue-if-busy] [--wait-started[=Sekunden]]")
            return ChatsCLIExit.usage
        }
        if answer, ifStatus != nil {
            CLIIO.err("--answer passt nicht zu --if-status (--answer heißt: auch in eine offene Rückfrage).")
            return ChatsCLIExit.usage
        }
        if noQueue, queueIfBusy {
            CLIIO.err("--no-queue und --queue-if-busy widersprechen sich.")
            return ChatsCLIExit.usage
        }
        // Eine offene Rückfrage beantwortet send nur noch auf ausdrücklichen
        // Wunsch (WM8-71/85): sonst landete der Text als Antwort des Users im Dialog.
        if answer { ifStatus = ["awaitingInput", "idle"] }
        // Ohne Enter nie vormerken: die Warteschlange schickt immer ab.
        let autoQueue = !noQueue && !answer && !noSubmit
        if noSubmit, waitSeconds != nil {
            CLIIO.err("--wait-started passt nicht zu --no-submit (ohne Enter startet der Chat nicht).")
            return ChatsCLIExit.usage
        }
        let ref = positionals[0]
        let prompt = positionals[1...].joined(separator: " ")

        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }

        var params: [String: Any] = [
            "targetSessionID": targetID.uuidString,
            "prompt": prompt,
            "submit": !noSubmit,
            "force": force,
        ]
        if let ifStatus { params["ifStatus"] = ifStatus }

        switch ChatsLiveSupport.perform(method: "session.send", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            let title = response.result?["target"]?["title"]?.stringValue ?? ref
            guard response.ok else {
                // Beschäftigt (oder Entwurf im Eingabefeld): auf Wunsch vormerken
                // statt mit einem Fehler zu enden, der einen zweiten Befehl verlangt.
                // Nicht bei einem bewusst gesetzten --if-status: dessen Konflikt
                // soll nicht über die Warteschlange umgangen werden (Review).
                let code = response.error.flatMap { ChatsControlErrorCode(rawValue: $0.code) }
                // Zurückgehaltenes Enter (WM8-75): Der Text steht schon im
                // Eingabefeld — nie vormerken, sonst käme er doppelt.
                let withheld = response.error?.detail?["resend"]?.boolValue == false
                if queueIfBusy || autoQueue, !withheld, let error = response.error, let code, code.alternative == "enqueue",
                   code == .notReady || code == .approvalPending || ifStatus == nil {
                    return enqueue(targetID: targetID, ref: ref, prompt: prompt, json: json,
                                   waitSeconds: waitSeconds, busyReason: error.message)
                }
                if code == .approvalPending, queueIfBusy || waitSeconds != nil {
                    return finish(.notStarted(withheld ? .enterWithheld : .approvalPending),
                                  title: title, prompt: prompt, json: json, server: response)
                }
                return ChatsLiveSupport.mapError(response)
            }
            if !json, let warning = response.result?["warning"]?.stringValue { CLIIO.err("⚠︎ \(warning)") }
            guard let waitSeconds else {
                if queueIfBusy { return finish(.delivered, title: title, prompt: prompt, json: json, server: response) }
                ChatsLiveSupport.printResult(response, json: json) { result in
                    let ack = result["ack"]?.stringValue ?? "delivered"
                    return "✓ \(ack) an \(title) (\(prompt.count) Zeichen)"
                }
                return ChatsCLIExit.ok
            }
            let outcome = ChatsSendStartWaiter.wait(targetID: targetID, seconds: waitSeconds)
            return finish(outcome, title: title, prompt: prompt, json: json, server: response)
        }
    }

    private static func enqueue(targetID: UUID, ref: String, prompt: String, json: Bool,
                                waitSeconds: TimeInterval?, busyReason: String) -> Int32 {
        switch ChatsLiveSupport.perform(method: "queue.enqueue", params: [
            "targetSessionID": targetID.uuidString, "prompt": prompt,
        ]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok, let result = response.result else { return ChatsLiveSupport.mapError(response) }
            let title = result["target"]?["title"]?.stringValue ?? ref
            if result["deliveredImmediately"]?.boolValue == true {
                // Inzwischen frei geworden: direkt zugestellt.
                guard let waitSeconds else {
                    return finish(.delivered, title: title, prompt: prompt, json: json, server: response)
                }
                let outcome = ChatsSendStartWaiter.wait(targetID: targetID, seconds: waitSeconds)
                return finish(outcome, title: title, prompt: prompt, json: json, server: response)
            }
            let position = result["position"]?.intValue ?? result["queued"]?.intValue ?? 0
            let status = result["runtimeStatus"]?.stringValue ?? "beschäftigt"
            if !json { CLIIO.err("Hinweis: \(busyReason)") }
            return finish(.queued(position: position, status: status), title: title, prompt: prompt,
                          json: json, server: response)
        }
    }

    private static func finish(_ outcome: ChatsSendOutcome, title: String, prompt: String, json: Bool,
                               server: ChatsControlResponse) -> Int32 {
        if json {
            var payload = ChatsLiveSupport.jsonObject(from: server)
            payload["ok"] = outcome.exitCode == ChatsCLIExit.ok
            payload["outcome"] = outcome.keyword
            if let reason = outcome.reasonCode { payload["reason"] = reason }
            switch outcome {
            case .started(let waited): payload["waitedSeconds"] = Int(waited.rounded())
            case .queued(let position, _): payload["position"] = position
            case .notStarted(.usageLimit(let until)):
                payload["usageLimitResetsAt"] = until.map(ChatsOutput.iso) ?? NSNull()
            default: break
            }
            payload["message"] = outcome.line(title: title, characters: prompt.count)
            CLIIO.out(ChatsOutput.encodeJSON(payload))
        } else {
            CLIIO.out(outcome.line(title: title, characters: prompt.count))
        }
        return outcome.exitCode
    }
}
