import Foundation

enum AgentSessionSummarizerError: Error, LocalizedError {
    case missingExternalSessionID
    case transcriptNotFound
    case emptyTranscript
    case generatorFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingExternalSessionID:
            return "Diese Session hat noch keine zuordenbare CLI-Session-ID — ggf. einmal Sessions scannen."
        case .transcriptNotFound:
            return "Transcript-Datei konnte nicht gefunden werden."
        case .emptyTranscript:
            return "Transcript enthält keine User-/Assistant-Nachrichten."
        case .generatorFailed(let error):
            return error.localizedDescription
        }
    }
}

/// Erzeugt aus einer Claude-/Codex-JSONL-Session eine inhaltliche
/// Zusammenfassung (Headline + Details), damit der Detail-View für geschlossene
/// Sessions nicht nur die Resume-Hinweise zeigt, sondern was inhaltlich
/// passiert ist und wo der letzte Stand war.
@MainActor
final class AgentSessionSummarizer {
    private let store: AgentSessionStore
    private let titleGenerator: AgentTitleGenerator
    private var inFlight: Set<UUID> = []

    init(store: AgentSessionStore, titleGenerator: AgentTitleGenerator = .live) {
        self.store = store
        self.titleGenerator = titleGenerator
    }

    /// `true` solange für `sessionID` ein Headless-Call läuft — die UI kann das
    /// für einen Spinner-State binden.
    func isGenerating(sessionID: UUID) -> Bool {
        inFlight.contains(sessionID)
    }

    /// Triggert eine Summary-Generierung. Idempotent: parallele Aufrufe für die
    /// gleiche Session werden via `inFlight`-Set gesperrt.
    /// - Parameter force: wenn `true`, wird der `summary != nil`-Check übersprungen.
    @discardableResult
    func generateSummary(
        for session: AgentChatSession,
        cwd: String,
        force: Bool = false,
        onCompletion: ((Result<AgentSessionSummary, Error>) -> Void)? = nil
    ) -> Bool {
        if !force, session.summary != nil {
            onCompletion?(.success(session.summary!))
            return false
        }
        guard !inFlight.contains(session.id) else { return false }
        guard let externalSessionID = session.externalSessionID, !externalSessionID.isEmpty else {
            onCompletion?(.failure(AgentSessionSummarizerError.missingExternalSessionID))
            return false
        }

        inFlight.insert(session.id)
        let sessionID = session.id
        let provider = session.provider
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
                    onCompletion?(.failure(AgentSessionSummarizerError.transcriptNotFound))
                    return
                }

                let excerpt = try AgentTranscriptExcerpt.buildExtended(from: url, provider: provider)
                guard !excerpt.isEmpty else {
                    onCompletion?(.failure(AgentSessionSummarizerError.emptyTranscript))
                    return
                }

                let prompt = Self.summaryPrompt(for: excerpt)
                let raw = try await generator.runHeadless(provider: provider, prompt: prompt)
                let parsed = Self.parseSummary(raw)
                guard !parsed.headline.isEmpty || !parsed.details.isEmpty else {
                    onCompletion?(.failure(AgentSessionSummarizerError.emptyTranscript))
                    return
                }

                let digest = await Self.digest(for: url)
                let summary = AgentSessionSummary(
                    headline: parsed.headline.isEmpty ? "Session ohne erkennbare Headline" : parsed.headline,
                    details: parsed.details.isEmpty ? "Keine ausführliche Beschreibung verfügbar." : parsed.details,
                    generatedAt: Date(),
                    transcriptDigest: digest
                )
                try store.setSessionSummary(id: sessionID, summary: summary)
                Logger.agentPerformance.info(
                    "session_summary_generated session=\(sessionID.uuidString, privacy: .public) provider=\(provider.rawValue, privacy: .public) chars=\(parsed.details.count)"
                )
                onCompletion?(.success(summary))
            } catch {
                Logger.agentPerformance.warning(
                    "session_summary_failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                onCompletion?(.failure(error))
            }
        }
        return true
    }

    /// Generiert Summaries für alle nicht-archivierten Sessions, die noch
    /// keinen `summary` tragen — Backround-Pass nach „Sessions scannen".
    func generateMissingSummaries(in workspace: AgentWorkspace, force: Bool = false) {
        for session in workspace.sessions {
            guard session.status != .archived else { continue }
            if !force, session.summary != nil { continue }
            guard let project = workspace.projects.first(where: { $0.id == session.projectID }) else { continue }
            generateSummary(for: session, cwd: project.path, force: force)
        }
    }

    // MARK: - Prompt + parsing

    nonisolated static func summaryPrompt(for excerpt: String) -> String {
        """
        You will receive an excerpt of an AI coding-agent session (user prompts and assistant replies).
        Produce a concise summary of what happened in this session. Reply in this exact format and no other text:

        HEADLINE: <one or two sentences in German, scannable, no quotes, no trailing period overload>
        DETAILS:
        <several short bullet-style lines or sentences in German covering, in order:
         - Aufgabe / Problem
         - durchgeführte Änderungen oder Untersuchungen
         - letzter bekannter Stand
         - offene Punkte oder Worauf-beim-Resume-Achten (nur wenn klar erkennbar)>

        Do not invent facts. If the transcript does not provide enough information for one of the bullets, omit that bullet rather than guessing.

        TRANSCRIPT:
        \(excerpt)
        """
    }

    nonisolated static func parseSummary(_ raw: String) -> (headline: String, details: String) {
        // Tolerant gegenüber CLIs, die noch Vor- oder Nachtext schreiben.
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var headline = ""
        var detailsLines: [String] = []
        var inDetails = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("HEADLINE:") {
                headline = String(trimmed.dropFirst("HEADLINE:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if trimmed.uppercased().hasPrefix("DETAILS:") {
                inDetails = true
                let after = String(trimmed.dropFirst("DETAILS:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { detailsLines.append(after) }
                continue
            }
            if inDetails {
                detailsLines.append(line)
            }
        }

        // Trimming + Cleanup der einzelnen Zeilen.
        headline = AgentTitleGenerator.cleanTitle(headline)
        if headline.count > 200 {
            headline = String(headline.prefix(200))
        }
        let details = detailsLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (headline: headline, details: details)
    }

    private static func digest(for url: URL) async -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date
        let mtimeStamp = mtime.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "0"
        return "size=\(size);mtime=\(mtimeStamp)"
    }
}

// MARK: - Re-use of AgentTitleGenerator's runner for summaries

extension AgentTitleGenerator {
    /// Wiederverwendung der Process-Pipeline (executableResolver + runner) für
    /// beliebige Prompts — ohne den Title-Cleanup hinten dran.
    func runHeadless(provider: AgentProvider, prompt: String) async throws -> String {
        guard let path = executableResolver(provider) else {
            throw AgentTitleGeneratorError.executableNotFound(provider)
        }
        let executable = URL(fileURLWithPath: path)
        let args: [String]
        switch provider {
        case .claude:
            args = ["-p", prompt, "--output-format", "text"]
        case .codex:
            args = ["exec", "--skip-git-repo-check", prompt]
        }
        let env = LoginShellEnvironment.shared.processEnvironment()
        return try await runner(executable, args, env)
    }
}
