import Foundation

/// Extrahiert deterministische Fakten aus einer `TranscriptTimeline`:
/// Commits (SHA + Message aus `git commit`-Outputs), Testläufe (Kommando +
/// bestanden) und geänderte Dateien (Edit/Write-Steps). Pur — das LLM des
/// Summarizers bekommt diese Fakten fertig geliefert und kann keine SHAs
/// halluzinieren.
enum TranscriptEvidenceExtractor {

    static func extract(from timeline: TranscriptTimeline) -> AgentSessionSummary.Evidence {
        var evidence = AgentSessionSummary.Evidence()
        var files: [String] = []
        var seenFiles: Set<String> = []
        var seenCommits: Set<String> = []

        for round in timeline.rounds {
            for step in round.steps {
                guard case .tool(let tool) = step.kind else { continue }
                switch tool.op {
                case .edit, .write:
                    let file = tool.detail.map { "\($0)/\(tool.subject)" } ?? tool.subject
                    if !tool.subject.isEmpty, seenFiles.insert(file).inserted {
                        files.append(file)
                    }
                case .bash:
                    if let commit = parseCommit(command: tool.subject, output: tool.result) {
                        if seenCommits.insert(commit.sha).inserted {
                            evidence.commits.append(commit)
                        }
                    }
                    if let test = parseTestRun(command: tool.subject, isError: tool.isError) {
                        evidence.tests.append(test)
                    }
                case .read, .search, .web, .task, .mcp, .other:
                    break
                }
            }
        }

        // Deckel gegen ausufernde Karten; Reihenfolge = Auftrittsreihenfolge.
        evidence.filesChanged = Array(files.prefix(12))
        if evidence.tests.count > 6 {
            evidence.tests = Array(evidence.tests.suffix(6))
        }
        return evidence
    }

    // MARK: - Intern

    /// `git commit`-Output: "[main 4797eba] fix(agent-cli): …".
    static func parseCommit(command: String, output: String?) -> AgentSessionSummary.Evidence.Commit? {
        guard command.contains("git commit"), let output else { return nil }
        guard let match = output.range(
            of: #"\[[^\]\s]+ ([0-9a-f]{7,40})\] ?([^\n]*)"#,
            options: .regularExpression
        ) else { return nil }
        let line = String(output[match])
        guard let shaRange = line.range(of: #"[0-9a-f]{7,40}"#, options: .regularExpression) else { return nil }
        let sha = String(line[shaRange])
        let message = line
            .components(separatedBy: "] ")
            .dropFirst()
            .joined(separator: "] ")
            .trimmingCharacters(in: .whitespaces)
        return .init(sha: sha, message: message)
    }

    /// Erkennt Test-Kommandos konservativ am Anfang des Kommandos (nach
    /// optionalem `cd …&&`/Env-Präfix wäre zu viel Raterei — bewusst simpel).
    static func parseTestRun(command: String, isError: Bool) -> AgentSessionSummary.Evidence.TestRun? {
        let lowered = command.lowercased()
        let markers = ["swift test", "npm test", "npm run test", "pnpm test", "yarn test",
                       "pytest", "go test", "cargo test", "php artisan test", "phpunit", "vitest", "jest"]
        guard markers.contains(where: { lowered.contains($0) }) else { return nil }
        return .init(command: String(command.prefix(90)), passed: !isError)
    }
}
