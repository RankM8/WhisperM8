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
                    if let test = parseTestRun(command: tool.subject, result: tool.result, isError: tool.isError) {
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

    /// Erkennt Test-Kommandos am Anfang eines Kommando-Segments (nach `&&`, `;`,
    /// `||`, Zeilenumbruch, optionalem Env-Präfix) — ein bloß zitierter Befehl
    /// (`echo 'npm test'`) zählt nicht. Ohne zugeordnetes Ergebnis (`result == nil`:
    /// Chat vor dem Ende beendet, Befehl läuft noch) gibt es keinen Beleg —
    /// weder „bestanden" noch „fehlgeschlagen" (LR-AK-014).
    static func parseTestRun(command: String, result: String?, isError: Bool) -> AgentSessionSummary.Evidence.TestRun? {
        guard result != nil else { return nil }
        let markers = ["swift test", "npm test", "npm run test", "pnpm test", "yarn test",
                       "pytest", "go test", "cargo test", "php artisan test", "phpunit", "vitest", "jest"]
        let segments = command
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: "||", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .split(separator: "\n")
        let isTestCommand = segments.contains { segment in
            var words = segment.trimmingCharacters(in: .whitespaces).lowercased()
                .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Env-Präfix (`CI=1 npm test`) und `time` überspringen.
            while let first = words.first, first == "time" || (first.contains("=") && !first.hasPrefix("-")) {
                words.removeFirst()
            }
            let head = words.joined(separator: " ")
            return markers.contains { head == $0 || head.hasPrefix($0 + " ") }
        }
        guard isTestCommand else { return nil }
        return .init(command: String(command.prefix(90)), passed: !isError)
    }
}
