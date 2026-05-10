import Foundation

/// Baut aus einem Stück Transcript-JSONL einen kompakten User+Assistant-Excerpt
/// für die Title-Generierung. Pure Funktion, testbar.
enum AgentTranscriptExcerpt {
    static let maxCharacters: Int = 2000
    static let maxMessages: Int = 6
    static let snippetCharLimit: Int = 280

    static func build(fromText text: String, provider: AgentProvider) -> String {
        let lines = text.split(omittingEmptySubsequences: true) { $0.isNewline }
        var entries: [String] = []
        var totalChars = 0

        for line in lines {
            let lineString = String(line)
            guard let event = AgentTranscriptParser.parseLine(lineString, provider: provider) else {
                continue
            }
            let role: String
            switch event {
            case .userMessage: role = "User"
            case .assistantMessageStopped: role = "Assistant"
            default: continue
            }
            guard let body = extractMessageText(line: lineString, provider: provider) else {
                continue
            }
            let cleaned = body
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let snippet = String(cleaned.prefix(snippetCharLimit))
            let formatted = "\(role): \(snippet)"
            entries.append(formatted)
            totalChars += formatted.count
            if entries.count >= maxMessages || totalChars >= maxCharacters {
                break
            }
        }
        return entries.joined(separator: "\n")
    }

    static func build(from url: URL, provider: AgentProvider) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        return build(fromText: text, provider: provider)
    }

    private static func extractMessageText(line: String, provider: AgentProvider) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch provider {
        case .claude:
            return extractClaudeMessageText(obj)
        case .codex:
            return extractCodexMessageText(obj)
        }
    }

    private static func extractClaudeMessageText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let str = message["content"] as? String {
            return str
        }
        if let array = message["content"] as? [[String: Any]] {
            let texts = array.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: " ")
        }
        return nil
    }

    private static func extractCodexMessageText(_ obj: [String: Any]) -> String? {
        if let array = obj["content"] as? [[String: Any]] {
            let texts = array.compactMap { dict -> String? in
                (dict["text"] as? String) ?? (dict["content"] as? String)
            }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        if let str = obj["text"] as? String { return str }
        if let str = obj["content"] as? String { return str }
        return nil
    }
}

enum AgentTitleGeneratorError: Error, LocalizedError {
    case executableNotFound(AgentProvider)
    case emptyOutput
    case nonZeroExit(Int32)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let provider):
            return "Konnte das CLI für \(provider.displayName) nicht finden."
        case .emptyOutput:
            return "Headless-Call lieferte keinen Title."
        case .nonZeroExit(let code):
            return "Headless-Call beendet mit Exit-Code \(code)."
        }
    }
}

/// Ruft Claude/Codex headless auf, um einen kurzen Title zu generieren.
/// Trennt CLI-Resolver + Process-Runner als Closures, damit der Generator in
/// Tests ohne echte Subprocesses verwendbar ist.
struct AgentTitleGenerator {
    var executableResolver: (AgentProvider) -> String?
    var runner: (URL, [String], [String: String]) async throws -> String

    static let live = AgentTitleGenerator(
        executableResolver: { provider in
            switch provider {
            case .claude: return AgentCommandBuilder.commandPath("claude")
            case .codex: return AgentCommandBuilder.commandPath("codex")
            }
        },
        runner: AgentTitleGenerator.defaultRunner
    )

    func generate(provider: AgentProvider, excerpt: String) async throws -> String {
        guard let path = executableResolver(provider) else {
            throw AgentTitleGeneratorError.executableNotFound(provider)
        }
        let prompt = Self.titlePrompt(for: excerpt)
        let executable = URL(fileURLWithPath: path)
        let args: [String]
        switch provider {
        case .claude:
            args = ["-p", prompt, "--output-format", "text"]
        case .codex:
            args = ["exec", "--skip-git-repo-check", prompt]
        }
        let env = LoginShellEnvironment.shared.processEnvironment()
        let stdout = try await runner(executable, args, env)
        let cleaned = Self.cleanTitle(stdout)
        guard !cleaned.isEmpty else {
            throw AgentTitleGeneratorError.emptyOutput
        }
        return cleaned
    }

    static func titlePrompt(for excerpt: String) -> String {
        """
        Below is a short excerpt of an agent coding session.
        Reply with a single concise title of 3 to 6 words that describes what the user is working on.
        Title only — no quotes, no trailing punctuation, no preamble.

        \(excerpt)
        """
    }

    static func cleanTitle(_ raw: String) -> String {
        let firstLine = raw.split(omittingEmptySubsequences: true) { $0.isNewline }
            .first
            .map(String.init) ?? raw
        var trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        // Strip leading bullet-style prefixes like "Title: ".
        for prefix in ["Title:", "TITLE:", "title:"] {
            if trimmed.hasPrefix(prefix) {
                trimmed = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Drop trailing punctuation.
        while let last = trimmed.last, ".!?,;:".contains(last) {
            trimmed = String(trimmed.dropLast())
        }
        if trimmed.count > 60 {
            trimmed = String(trimmed.prefix(60))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// Default-Process-Runner: spawned das CLI mit den gegebenen Args + ENV,
    /// wartet auf Exit, liefert stdout. Stderr wird in den Logs notiert.
    static func defaultRunner(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    Logger.agentPerformance.warning(
                        "auto_namer_subprocess_exit code=\(proc.terminationStatus) stderr=\(stderr.prefix(200), privacy: .public)"
                    )
                    continuation.resume(throwing: AgentTitleGeneratorError.nonZeroExit(proc.terminationStatus))
                    return
                }
                continuation.resume(returning: stdout)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Triggert beim ersten Turn-End einer Session den Headless-Title-Generator.
/// Respektiert `AgentChatSession.canAutoRenameTitle` und blockt sich gegen
/// parallele Re-Entries für dieselbe Session.
@MainActor
final class AgentSessionAutoNamer {
    private let store: AgentSessionStore
    private let titleGenerator: AgentTitleGenerator
    private var inFlight: Set<UUID> = []
    /// IDs, die in dieser App-Session schon einmal (erfolgreich oder erfolglos)
    /// ausgewertet wurden. Verhindert Endlosschleifen, falls die Title-
    /// Generierung permanent fehlschlägt.
    private var alreadyAttempted: Set<UUID> = []

    init(store: AgentSessionStore, titleGenerator: AgentTitleGenerator = .live) {
        self.store = store
        self.titleGenerator = titleGenerator
    }

    /// Wird vom `AgentSessionRuntimeWatcher` via `onTurnFinished` aufgerufen.
    /// Führt nur dann zum Headless-Call, wenn:
    /// - die Session laut `canAutoRenameTitle` Auto-Rename erlaubt,
    /// - sie eine `externalSessionID` hat (sonst kein Transcript lokalisierbar),
    /// - sie noch keinen `lastTurnAt`-Stempel trägt (= erstes Turn-End),
    /// - in dieser App-Session noch kein Auto-Naming-Versuch lief.
    func handleTurnFinished(
        session: AgentChatSession,
        cwd: String,
        onCompletion: ((Result<String, Error>) -> Void)? = nil
    ) {
        guard session.canAutoRenameTitle else { return }
        guard session.lastTurnAt == nil else { return }
        guard !alreadyAttempted.contains(session.id) else { return }
        guard !inFlight.contains(session.id) else { return }
        guard let externalSessionID = session.externalSessionID, !externalSessionID.isEmpty else {
            return
        }

        runTitleGeneration(
            sessionID: session.id,
            provider: session.provider,
            externalSessionID: externalSessionID,
            cwd: cwd,
            onCompletion: onCompletion
        )
    }

    /// Wie `handleTurnFinished`, aber ohne `lastTurnAt`-Check und mit
    /// Reset des `alreadyAttempted`-Markers für die jeweilige Session.
    /// Aufgerufen vom „Sessions scannen"-Trigger, damit alte/gescannte Sessions
    /// und Sessions mit zuvor fehlgeschlagenem Auto-Naming explizit
    /// nachträglich benannt werden können.
    ///
    /// `canAutoRenameTitle == false` (= User hat manuell umbenannt) wird
    /// weiterhin respektiert — wir überschreiben niemals einen User-Namen.
    /// `inFlight`-Schutz bleibt aktiv.
    func forceGenerateTitle(
        session: AgentChatSession,
        cwd: String,
        onCompletion: ((Result<String, Error>) -> Void)? = nil
    ) {
        guard session.canAutoRenameTitle else { return }
        guard !inFlight.contains(session.id) else { return }
        guard let externalSessionID = session.externalSessionID, !externalSessionID.isEmpty else {
            return
        }

        alreadyAttempted.remove(session.id)
        runTitleGeneration(
            sessionID: session.id,
            provider: session.provider,
            externalSessionID: externalSessionID,
            cwd: cwd,
            onCompletion: onCompletion
        )
    }

    /// Reset für Tests + manuelle „erneut versuchen"-Trigger.
    func resetAttemptTracking() {
        inFlight.removeAll()
        alreadyAttempted.removeAll()
    }

    /// Backwards-compatible alias (Tests rufen das vor der Umbenennung auf).
    func resetTrackingForTesting() {
        resetAttemptTracking()
    }

    // MARK: - Shared title-generation pipeline

    private func runTitleGeneration(
        sessionID: UUID,
        provider: AgentProvider,
        externalSessionID: String,
        cwd: String,
        onCompletion: ((Result<String, Error>) -> Void)?
    ) {
        inFlight.insert(sessionID)
        alreadyAttempted.insert(sessionID)
        let store = store
        let generator = titleGenerator

        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.inFlight.remove(sessionID)
                }
            }
            do {
                guard let url = AgentTranscriptLocator.locate(
                    provider: provider,
                    externalSessionID: externalSessionID,
                    cwd: cwd
                ) else {
                    onCompletion?(.failure(AgentTitleGeneratorError.emptyOutput))
                    return
                }
                let excerpt = try AgentTranscriptExcerpt.build(from: url, provider: provider)
                guard !excerpt.isEmpty else {
                    onCompletion?(.failure(AgentTitleGeneratorError.emptyOutput))
                    return
                }
                let title = try await generator.generate(provider: provider, excerpt: excerpt)
                try store.applyAutoGeneratedTitle(id: sessionID, title: title)
                Logger.agentPerformance.info(
                    "auto_named session=\(sessionID.uuidString, privacy: .public) provider=\(provider.rawValue, privacy: .public) title=\"\(title, privacy: .public)\""
                )
                onCompletion?(.success(title))
            } catch {
                Logger.agentPerformance.warning(
                    "auto_naming_failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                onCompletion?(.failure(error))
            }
        }
    }
}
