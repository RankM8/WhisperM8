import Foundation

/// Begrenzte, fail-open SSE-Probe fuer den bekannten Codex-Proxy-Synthetic-
/// Overflow. Sie erkennt ausschliesslich einen semantisch leeren Start gefolgt
/// von `event:error` mit exakt `api_error` / `Prompt is too long`.
struct CodexSyntheticOverflowProbe {
    enum Decision: Equatable {
        case pending
        case passThrough
        case overflow
    }

    static let maximumPrefixBytes = 32 * 1_024
    static let deadlineSeconds: TimeInterval = 1

    private let startedAt: TimeInterval
    private(set) var bufferedData = Data()
    private(set) var lastAcceptedByteCount = 0
    private var lineBuffer = Data()
    private var eventLines: [String] = []
    private var pendingCarriageReturn = false
    private var decision: Decision = .pending

    init(startedAt: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        self.startedAt = startedAt
    }

    func hasExpired(at now: TimeInterval) -> Bool {
        now - startedAt >= Self.deadlineSeconds
    }

    mutating func ingest(
        _ data: Data,
        at now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> Decision {
        lastAcceptedByteCount = 0
        guard decision == .pending else { return decision }
        guard !hasExpired(at: now) else {
            decision = .passThrough
            return decision
        }

        let capacity = max(0, Self.maximumPrefixBytes - bufferedData.count)
        let accepted = min(capacity, data.count)
        lastAcceptedByteCount = accepted
        let prefix = data.prefix(accepted)
        bufferedData.append(prefix)

        for byte in prefix {
            if pendingCarriageReturn {
                pendingCarriageReturn = false
                processNewline()
                if decision != .pending { return decision }
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0D:
                pendingCarriageReturn = true
            case 0x0A:
                processNewline()
            default:
                lineBuffer.append(byte)
            }
            if decision != .pending { return decision }
        }

        if accepted < data.count {
            decision = .passThrough
        }
        return decision
    }

    mutating func finish() -> Decision {
        guard decision == .pending else { return decision }
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            processNewline()
        }
        // Unvollstaendige Zeile/Event am EOF ist kein sicherer Treffer.
        if decision == .pending, !lineBuffer.isEmpty || !eventLines.isEmpty {
            decision = .passThrough
        }
        return decision == .pending ? .passThrough : decision
    }

    private mutating func processNewline() {
        if lineBuffer.isEmpty {
            if !eventLines.isEmpty {
                decision = classifyEvent(eventLines)
                eventLines.removeAll(keepingCapacity: true)
            }
        } else {
            eventLines.append(String(decoding: lineBuffer, as: UTF8.self))
            lineBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func classifyEvent(_ lines: [String]) -> Decision {
        var eventName: String?
        var dataLines: [String] = []
        var sawField = false

        for line in lines {
            if line.hasPrefix(":") { continue }
            sawField = true
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .passThrough }
            let field = String(parts[0])
            var value = String(parts[1])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "event":
                // Mehrere event-Felder sind fuer diese sicherheitskritische
                // Erkennung nicht eindeutig genug, obwohl SSE last-one-wins kennt.
                guard eventName == nil else { return .passThrough }
                eventName = value
            case "data":
                dataLines.append(value)
            default:
                return .passThrough
            }
        }

        // Kommentar-/Heartbeat-Events enthalten keine semantischen Bytes.
        if !sawField { return .pending }
        if eventName == "ping", dataLines.isEmpty { return .pending }
        guard !dataLines.isEmpty,
              let data = dataLines.joined(separator: "\n").data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return .passThrough
        }

        if eventName == "error", isExactSyntheticOverflow(object, type: type) {
            return .overflow
        }

        switch type {
        case "message_start":
            return isEmptyMessageStart(object, eventName: eventName) ? .pending : .passThrough
        case "content_block_start":
            return isEmptyTextBlockStart(object, eventName: eventName) ? .pending : .passThrough
        case "content_block_stop":
            return isEmptyBlockStop(object, eventName: eventName) ? .pending : .passThrough
        case "ping":
            return isEmptyJSONPing(object, eventName: eventName) ? .pending : .passThrough
        default:
            // Delta, Thinking, Signatur, Tool-Use und unbekannte Events sind
            // semantisch. Ab hier darf ein spaeterer gleichlautender Fehlertext
            // nie mehr in eine lokale 400 umgeschrieben werden.
            return .passThrough
        }
    }

    private func isExactSyntheticOverflow(_ object: [String: Any], type: String) -> Bool {
        guard type == "error",
              Set(object.keys) == ["type", "error"],
              let error = object["error"] as? [String: Any],
              Set(error.keys) == ["type", "message"] else {
            return false
        }
        return error["type"] as? String == "api_error"
            && error["message"] as? String == "Prompt is too long"
    }

    private func isEmptyMessageStart(_ object: [String: Any], eventName: String?) -> Bool {
        guard eventName == nil || eventName == "message_start",
              Set(object.keys) == ["type", "message"],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any],
              content.isEmpty else {
            return false
        }
        if let role = message["role"] as? String, role != "assistant" { return false }
        if let stopReason = message["stop_reason"], !(stopReason is NSNull) { return false }
        if let stopSequence = message["stop_sequence"], !(stopSequence is NSNull) { return false }
        return true
    }

    private func isEmptyTextBlockStart(_ object: [String: Any], eventName: String?) -> Bool {
        guard eventName == nil || eventName == "content_block_start",
              Set(object.keys).isSubset(of: ["type", "index", "content_block"]),
              let block = object["content_block"] as? [String: Any],
              block["type"] as? String == "text",
              block["text"] as? String == "" else {
            return false
        }
        // Nur ein leerer Textblock ist Struktur. Thinking-/Tool-/Signaturfelder
        // oder bereits vorhandene Zitate machen das Event semantisch.
        let permittedBlockKeys: Set<String> = ["type", "text", "citations"]
        guard Set(block.keys).isSubset(of: permittedBlockKeys) else { return false }
        if let citations = block["citations"], !(citations is NSNull) {
            guard let values = citations as? [Any], values.isEmpty else { return false }
        }
        return true
    }

    private func isEmptyBlockStop(_ object: [String: Any], eventName: String?) -> Bool {
        (eventName == nil || eventName == "content_block_stop")
            && Set(object.keys).isSubset(of: ["type", "index"])
    }

    private func isEmptyJSONPing(_ object: [String: Any], eventName: String?) -> Bool {
        (eventName == nil || eventName == "ping") && Set(object.keys) == ["type"]
    }
}
