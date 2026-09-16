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

    /// P3 S3: Bounded Head-Read statt Voll-Load — der Excerpt bricht ohnehin
    /// nach `maxMessages` ab, Transcripts können aber >50 MB groß sein. Die
    /// ggf. abgeschnittene letzte Zeile ist nicht parsebar und wird vom
    /// Parser übersprungen (gleiches Absorb-Muster wie beim Tail-Read).
    static let headReadBytes: Int = 512 * 1024

    static func build(from url: URL, provider: AgentProvider) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: headReadBytes)
        return build(fromText: String(decoding: data, as: UTF8.self), provider: provider)
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
    case missingTranscript
    case emptyExcerpt
    case unavailableBackendModel
    case nonZeroExit(Int32, stderr: String = "", stdout: String = "")
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let provider):
            return "Konnte das CLI für \(provider.displayName) nicht finden."
        case .emptyOutput:
            return "Headless-Call lieferte keinen Title."
        case .missingTranscript:
            return "Transcript für die Titelgenerierung noch nicht gefunden."
        case .emptyExcerpt:
            return "Transcript enthält noch keine verwendbaren Nachrichten."
        case .unavailableBackendModel:
            return "Das Backend-Modell der Session ist derzeit nicht verfügbar."
        case .nonZeroExit(let code, _, _):
            return "Headless-Call beendet mit Exit-Code \(code)."
        case .timedOut(let timeout):
            return "Headless-Call nach \(Int(timeout)) Sekunden abgebrochen."
        }
    }
}

/// Ruft Claude/Codex headless auf, um einen kurzen Title zu generieren.
/// Trennt CLI-Resolver + Process-Runner als Closures, damit der Generator in
/// Tests ohne echte Subprocesses verwendbar ist.
struct AgentTitleGenerator {
    var executableResolver: (AgentProvider) -> String?
    var runner: (URL, [String], [String: String]) async throws -> String
    var commandBuilder = AgentCommandBuilder()
    var environmentProvider: () -> [String: String] = {
        LoginShellEnvironment.shared.processEnvironment()
    }

    static let live = AgentTitleGenerator(
        executableResolver: { provider in
            switch provider {
            case .claude: return AgentCommandBuilder.commandPath("claude")
            case .codex: return AgentCommandBuilder.commandPath("codex")
            }
        },
        runner: AgentTitleGenerator.defaultRunner
    )

    func generate(session: AgentChatSession, excerpt: String) async throws -> String {
        let provider = session.provider
        guard let path = executableResolver(provider) else {
            throw AgentTitleGeneratorError.executableNotFound(provider)
        }
        let prompt = Self.titlePrompt(for: excerpt)
        let executable = URL(fileURLWithPath: path)
        var args: [String]
        // Die Bereinigung bleibt VOR den expliziten Launch-Overrides: ein
        // geerbtes CLAUDE_CONFIG_DIR darf nie das Session-Profil ersetzen.
        var env = environmentProvider()
        switch provider {
        case .claude:
            args = ["-p", prompt, "--output-format", "text", "--no-session-persistence"]
            env.merge(commandBuilder.claudeProfileEnvironmentResolver(session.claudeProfileName)) { _, explicit in explicit }
            if let router = commandBuilder.gptRouterCoreEnvironment() {
                env.merge(router) { _, explicit in explicit }
            }
            if let model = session.claudeBackendModel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !model.isEmpty {
                guard let effectiveModel = commandBuilder.effectiveClaudeBackendModel(model) else {
                    // Kein stiller Wechsel auf das native Profil-Modell bei
                    // deaktiviertem Router oder ungültigem GPT-Stempel.
                    throw AgentTitleGeneratorError.unavailableBackendModel
                }
                args.append(contentsOf: ["--model", effectiveModel])
            }
        case .codex:
            args = ["exec", "--skip-git-repo-check", "--ephemeral", "--model", session.model, prompt]
        }
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
        Reply with a single concise German title, ALWAYS starting with exactly two clearly understandable topic words.
        Optionally add a colon followed by a short concrete task, ideally 3 to 5 words (never more than 5).
        Examples: Apify Review: Fehler prüfen und beheben
        Chat Benennung: Automatik reparieren
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

    /// Persistenz-Opt-outs der Hilfsläufe (P0.4a): interne Printläufe dürfen
    /// keine importierbaren Provider-Sessions hinterlassen.
    static let sessionPersistenceOptOutFlags = ["--no-session-persistence", "--ephemeral"]

    /// Kompatibilitäts-Gate: Lehnt eine ältere CLI eines der Opt-out-Flags als
    /// unbekannte Option ab, liefert dies die argv für genau einen Retry ohne
    /// das Flag (Ergebnis geht vor Junk-Schutz; sichtbar geloggt). Sonst `nil`.
    static func retryArgumentsAfterUnknownOption(arguments: [String], stderr: String) -> [String]? {
        let diagnostic = stderr.lowercased()
        guard diagnostic.contains("unknown option") || diagnostic.contains("unexpected argument")
                || diagnostic.contains("unrecognized option") else { return nil }
        guard let flag = sessionPersistenceOptOutFlags.first(where: {
            arguments.contains($0) && stderr.contains($0)
        }) else { return nil }
        return arguments.filter { $0 != flag }
    }

    /// Default-Process-Runner: spawned das CLI mit den gegebenen Args + ENV,
    /// wartet auf Exit, liefert stdout. Fehlerausgaben bleiben begrenzt im
    /// Fehlerobjekt; Logs enthalten nur Exit-Code und Ausgabelängen.
    /// Läuft mit Scratch-cwd (P0.4a) — ohne explizites cwd erben Hilfsläufe
    /// das App-cwd ("/") und tauchen als Junk-Sessions im Root-Projekt auf.
    static func defaultRunner(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperm8-headless-scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            return try await AgentHeadlessCLI().run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: scratch
            )
        } catch AgentHeadlessCLIError.nonZeroExit(let code, let stderr, let stdout) {
            if let retryArgs = retryArgumentsAfterUnknownOption(arguments: arguments, stderr: stderr + "\n" + stdout) {
                Logger.agentPerformance.warning(
                    "headless_persistence_flag_unsupported — retry ohne Opt-out-Flag (ältere CLI)"
                )
                return try await defaultRunner(
                    executable: executable, arguments: retryArgs, environment: environment
                )
            }
            Logger.agentPerformance.warning(
                "auto_namer_subprocess_exit code=\(code) stdoutBytes=\(stdout.utf8.count) stderrBytes=\(stderr.utf8.count)"
            )
            throw AgentTitleGeneratorError.nonZeroExit(code, stderr: stderr, stdout: stdout)
        } catch AgentHeadlessCLIError.timedOut(let timeout) {
            Logger.agentPerformance.warning(
                "auto_namer_subprocess_timeout timeout=\(timeout)"
            )
            throw AgentTitleGeneratorError.timedOut(timeout)
        }
    }
}

/// Triggert beim ersten Turn-End einer Session den Headless-Title-Generator.
/// Respektiert `AgentChatSession.canAutoRenameTitle` und blockt sich gegen
/// parallele Re-Entries für dieselbe Session.
///
/// Exponiert den aktuellen `inFlight`-Set publik fuer UI-Feedback. State-
/// Aenderungen werden via NotificationCenter (`inFlightDidChangeNotification`)
/// gepublisht — die Sidebar haengt sich daran fuer einen Spinner-Indikator.
@MainActor
final class AgentSessionAutoNamer {
    private let store: AgentSessionStore
    private let titleGenerator: AgentTitleGenerator
    /// Sessions mit laufendem oder bereits eingereihtem Auto-Naming-Auftrag.
    private(set) var inFlight: Set<UUID> = [] {
        didSet {
            guard oldValue != inFlight else { return }
            NotificationCenter.default.post(
                name: Self.inFlightDidChangeNotification,
                object: nil
            )
        }
    }
    private struct Request {
        var session: AgentChatSession
        var cwd: String
        var onCompletion: ((Result<String, Error>) -> Void)?
    }

    private struct Failure {
        var count: Int
        var retryAfter: Date
    }

    private var completed: Set<UUID> = []
    private var failures: [UUID: Failure] = [:]
    private var pending: [Request] = []
    private var activeCount = 0
    private let maxParallel: Int
    private let now: () -> Date
    private let isEnabled: () -> Bool
    private let excerptLoader: (AgentChatSession, String) async throws -> String

    static let inFlightDidChangeNotification = Notification.Name("AgentSessionAutoNamer.inFlightDidChange")

    init(
        store: AgentSessionStore,
        titleGenerator: AgentTitleGenerator = .live,
        maxParallel: Int = 2,
        now: @escaping () -> Date = Date.init,
        isEnabled: @escaping () -> Bool = { AppPreferences.shared.isAutoChatRenameEnabled },
        excerptLoader: @escaping (AgentChatSession, String) async throws -> String = AgentSessionAutoNamer.loadExcerpt
    ) {
        self.store = store
        self.titleGenerator = titleGenerator
        self.maxParallel = max(1, maxParallel)
        self.now = now
        self.isEnabled = isEnabled
        self.excerptLoader = excerptLoader
    }

    func isInFlight(_ sessionID: UUID) -> Bool {
        inFlight.contains(sessionID)
    }

    /// Erster Turn-End und Scan teilen sich Backoff + Duplikatschutz.
    func handleTurnFinished(
        session: AgentChatSession,
        cwd: String,
        onCompletion: ((Result<String, Error>) -> Void)? = nil
    ) {
        guard session.lastTurnAt == nil else { return }
        generateTitleIfNeeded(session: session, cwd: cwd, onCompletion: onCompletion)
    }

    /// Automatischer Scan: alte Sessions sind erlaubt, Fehler umgehen aber
    /// NICHT die Wartezeit. Weitere Scans nehmen fällige Versuche wieder auf.
    func generateTitleIfNeeded(
        session: AgentChatSession,
        cwd: String,
        onCompletion: ((Result<String, Error>) -> Void)? = nil
    ) {
        guard !completed.contains(session.id) else { return }
        if let failure = failures[session.id], now() < failure.retryAfter { return }
        enqueue(session: session, cwd: cwd, onCompletion: onCompletion)
    }

    /// Nur die ausdrückliche Einzelaktion darf Backoff/Erfolg umgehen.
    /// Queue-Limit, Duplikatschutz und manuelle Namen bleiben geschützt.
    func forceGenerateTitle(
        session: AgentChatSession,
        cwd: String,
        onCompletion: ((Result<String, Error>) -> Void)? = nil
    ) {
        enqueue(session: session, cwd: cwd, onCompletion: onCompletion)
    }

    func resetAttemptTracking() {
        completed.removeAll()
        failures.removeAll()
        // Laufende/queued Aufträge niemals entmarkieren: sonst könnte ein
        // Reset einen zweiten Subprozess für dieselbe Session zulassen.
    }

    func resetTrackingForTesting() {
        resetAttemptTracking()
    }

    private func enqueue(
        session: AgentChatSession,
        cwd: String,
        onCompletion: ((Result<String, Error>) -> Void)?
    ) {
        guard isEnabled(), session.canAutoRenameTitle,
              !inFlight.contains(session.id),
              let externalID = session.externalSessionID, !externalID.isEmpty else { return }
        inFlight.insert(session.id)
        pending.append(Request(session: session, cwd: cwd, onCompletion: onCompletion))
        startPendingRequests()
    }

    private func startPendingRequests() {
        while activeCount < maxParallel, !pending.isEmpty {
            let request = pending.removeFirst()
            // Während des Wartens kann der User umbenannt/archiviert oder
            // Auto-Naming abgeschaltet haben. Keine unnötigen Modellaufrufe.
            guard isEnabled(),
                  let session = store.loadWorkspace().sessions.first(where: { $0.id == request.session.id }),
                  session.canAutoRenameTitle, session.status != .archived else {
                inFlight.remove(request.session.id)
                continue
            }
            activeCount += 1
            runTitleGeneration(request: request, session: session)
        }
    }

    nonisolated static func loadExcerpt(session: AgentChatSession, cwd: String) async throws -> String {
        // Locate + File-I/O bleiben off-main (Codex-Lookup kann rekursiv sein).
        try await Task.detached(priority: .utility) {
            guard let externalID = session.externalSessionID,
                  let url = AgentTranscriptLocator.locate(
                    provider: session.provider, externalSessionID: externalID, cwd: cwd
                  ) else {
                throw AgentTitleGeneratorError.missingTranscript
            }
            do {
                let excerpt = try AgentTranscriptExcerpt.build(from: url, provider: session.provider)
                guard !excerpt.isEmpty else { throw AgentTitleGeneratorError.emptyExcerpt }
                return excerpt
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                throw AgentTitleGeneratorError.missingTranscript
            }
        }.value
    }

    private func runTitleGeneration(request: Request, session: AgentChatSession) {
        let sessionID = session.id
        Task {
            let result: Result<String, Error>
            do {
                let excerpt = try await excerptLoader(session, request.cwd)
                guard !excerpt.isEmpty else { throw AgentTitleGeneratorError.emptyExcerpt }
                let title = try await titleGenerator.generate(session: session, excerpt: excerpt)
                try store.applyAutoGeneratedTitle(id: sessionID, title: title)
                failures.removeValue(forKey: sessionID)
                completed.insert(sessionID)
                Logger.agentPerformance.info(
                    "auto_named session=\(sessionID.uuidString, privacy: .public) provider=\(session.provider.rawValue, privacy: .public)"
                )
                result = .success(title)
            } catch {
                completed.remove(sessionID)
                let count = min((failures[sessionID]?.count ?? 0) + 1, 16)
                let awaitingTranscript: Bool
                switch error {
                case AgentTitleGeneratorError.missingTranscript, AgentTitleGeneratorError.emptyExcerpt:
                    awaitingTranscript = true
                default:
                    awaitingTranscript = false
                }
                let delay = min(awaitingTranscript ? 300.0 : 3600.0,
                                (awaitingTranscript ? 15.0 : 60.0) * pow(2, Double(count - 1)))
                failures[sessionID] = Failure(count: count, retryAfter: now().addingTimeInterval(delay))
                // Keine beliebigen localizedDescription-Texte loggen: CLI-
                // Ausgaben können Secrets oder Inhalte des Prompts enthalten.
                Logger.agentPerformance.warning(
                    "auto_naming_failed session=\(sessionID.uuidString, privacy: .public) awaitingTranscript=\(awaitingTranscript) attempt=\(count) retrySeconds=\(delay)"
                )
                result = .failure(error)
            }
            activeCount -= 1
            inFlight.remove(sessionID)
            request.onCompletion?(result)
            startPendingRequests()
        }
    }
}
