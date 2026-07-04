import Foundation

// MARK: - Sink (die Slice-Naht)

/// Beobachter eines Turns. Der Executor kennt bewusst KEIN Job-Verzeichnis —
/// Slice 1 (synchroner CLI-Run) hängt einen In-Memory-Sink an, Slice 2 einen
/// JobDirectory-Sink, der Events nach `events.jsonl` appended und
/// State-Übergänge in `state.json` schreibt. So bleibt der Turn-Code für
/// beide Welten identisch.
///
/// Achtung: Die Callbacks feuern auf einer Hintergrund-Queue (Reihenfolge
/// pro Turn ist garantiert, Thread nicht).
protocol AgentTurnSink {
    func turnWillStart(prompt: String)
    func received(event: CodexExecEvent, rawLine: String)
    /// Feuert beim ersten `thread.started` — Slice 2 persistiert die ID
    /// SOFORT (Crash-Sicherheit: ohne ID ist kein `send`/Resume möglich).
    func threadStarted(threadID: String)
    func turnDidFinish(outcome: CodexTurnOutcome)
}

// MARK: - Outcome

enum CodexTurnOutcome: Equatable {
    case done(report: AgentReport?, rawLastMessage: String?, threadID: String?, duration: TimeInterval)
    case failed(reason: String, threadID: String?, rawLastMessage: String?, duration: TimeInterval)

    var threadID: String? {
        switch self {
        case .done(_, _, let id, _), .failed(_, let id, _, _):
            return id
        }
    }

    var duration: TimeInterval {
        switch self {
        case .done(_, _, _, let d), .failed(_, _, _, let d):
            return d
        }
    }
}

// MARK: - Executor

/// Führt einen Turn über den `CodexExecRunner` aus und übersetzt das
/// Prozess-Ergebnis in ein `CodexTurnOutcome`. Misst die Turn-Dauer selbst —
/// Metriken kommen vom Supervisor, nie vom Modell (beschlossene Politik).
struct CodexTurnExecutor {
    var runner: CodexExecRunner = CodexExecRunner()
    /// Test-Seam für die Zeitmessung.
    var now: () -> Date = Date.init

    func execute(request: CodexTurnRequest, sink: AgentTurnSink) async -> CodexTurnOutcome {
        sink.turnWillStart(prompt: request.prompt)
        let started = now()

        let result: CodexTurnResult
        do {
            result = try await runner.run(request: request) { event, rawLine in
                if case .threadStarted(let threadID) = event {
                    sink.threadStarted(threadID: threadID)
                }
                sink.received(event: event, rawLine: rawLine)
            }
        } catch {
            let outcome = CodexTurnOutcome.failed(
                reason: error.localizedDescription,
                threadID: nil,
                rawLastMessage: nil,
                duration: now().timeIntervalSince(started)
            )
            sink.turnDidFinish(outcome: outcome)
            return outcome
        }

        let duration = now().timeIntervalSince(started)
        let outcome = Self.mapOutcome(result: result, duration: duration)
        sink.turnDidFinish(outcome: outcome)
        return outcome
    }

    /// Pure Abbildung Prozess-Ergebnis → Outcome (separat testbar).
    static func mapOutcome(result: CodexTurnResult, duration: TimeInterval) -> CodexTurnOutcome {
        if result.stalled {
            return .failed(
                reason: "stalled: keine Events mehr vom codex-Prozess (Idle-Watchdog)",
                threadID: result.threadID,
                rawLastMessage: result.lastMessage,
                duration: duration
            )
        }
        if let message = result.turnFailedMessage {
            return .failed(
                reason: "turn.failed: \(message)",
                threadID: result.threadID,
                rawLastMessage: result.lastMessage,
                duration: duration
            )
        }
        guard result.exitCode == 0 else {
            let stderr = result.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = stderr.isEmpty ? "" : ": \(stderr.suffix(500))"
            return .failed(
                reason: "codex exec endete mit Exit \(result.exitCode)\(suffix)",
                threadID: result.threadID,
                rawLastMessage: result.lastMessage,
                duration: duration
            )
        }
        // Report tolerant parsen — nicht parsebar heißt NICHT failed: der
        // Turn war erfolgreich, nur der Report-Vertrag wurde verletzt. Der
        // Aufrufer entscheidet (CLI reicht den Rohtext durch).
        let report = result.lastMessage.flatMap(AgentReport.parse(lastMessage:))
        return .done(
            report: report,
            rawLastMessage: result.lastMessage,
            threadID: result.threadID,
            duration: duration
        )
    }
}

// MARK: - In-Memory-Sink (Slice 1)

/// Sammelt Events im Speicher — reicht für den synchronen CLI-Run, der am
/// Ende nur das Outcome braucht. Optional mit Progress-Callback für
/// menschenlesbare Live-Ausgabe auf stderr.
final class InMemoryTurnSink: AgentTurnSink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [CodexExecEvent] = []
    private(set) var threadID: String?
    private let onProgress: ((CodexExecEvent) -> Void)?

    init(onProgress: ((CodexExecEvent) -> Void)? = nil) {
        self.onProgress = onProgress
    }

    func turnWillStart(prompt: String) {}

    func received(event: CodexExecEvent, rawLine: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
        onProgress?(event)
    }

    func threadStarted(threadID: String) {
        lock.lock()
        self.threadID = threadID
        lock.unlock()
    }

    func turnDidFinish(outcome: CodexTurnOutcome) {}
}
