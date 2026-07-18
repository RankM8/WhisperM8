import Foundation

/// Verwaltet die von WhisperM8 gepflegte Claude-Code-Agent-Definition
/// `~/.claude/agents/gpt.md`. Ueber sie kann das Hauptmodell einer Session
/// nativ PRO AUFGABE einen GPT-Subagenten waehlen (Frontmatter `model:` hat
/// in Claude Codes Aufloesungskette Vorrang vor dem Hauptmodell), ohne dass
/// `CLAUDE_CODE_SUBAGENT_MODEL` saemtliche Subagents auf GPT zwingt.
///
/// Lifecycle folgt dem GPT-Backend: aktiv → Datei anlegen/aktualisieren,
/// deaktiviert → entfernen (sonst scheitern `gpt`-Spawns ohne Router).
/// Fremde Dateien (ohne WhisperM8-Marker) werden niemals angetastet.
struct ClaudeGPTAgentDefinitionInstaller {
    enum SyncOutcome: Equatable {
        case installed
        case updated
        case upToDate
        case removed
        case nothingToDo
        case leftForeignFileAlone
    }

    /// Kennzeichnet die Datei als WhisperM8-verwaltet; nur markierte Dateien
    /// werden ueberschrieben oder entfernt.
    static let managedMarker = "managed-by: whisperm8-gpt-backend"

    /// Ziel-Dateien: `<config-dir>/agents/gpt.md` fuer `main` UND jedes
    /// Zusatzprofil. Claude Code liest User-Level-Agents aus dem
    /// `CLAUDE_CONFIG_DIR` der jeweiligen Session — Profil-Sessions sehen
    /// `~/.claude/agents/` NICHT (QA-Befund 2026-07-18: der gpt-Typ fehlte
    /// in allen Sessions mit Account-Profil).
    var fileURLs: [URL] = ClaudeAccountProfiles().profiles().map { profile in
        profile.configDir
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("gpt.md", isDirectory: false)
    }

    static func definitionContent(model: String) -> String {
        """
        ---
        name: gpt
        description: GPT-Subagent über das WhisperM8 GPT-Backend (\(model), high thinking). Nutzen, wenn der User explizit GPT verlangt, eine zweite Meinung eines Nicht-Claude-Modells sinnvoll ist oder Teilaufgaben parallel auf GPT ausgelagert werden sollen.
        model: \(model)
        ---
        <!-- \(managedMarker) — automatisch verwaltet; manuelle Änderungen werden überschrieben. -->

        Du bist ein GPT-Subagent (\(model)) innerhalb einer Claude-Code-Session. Erledige die übergebene Aufgabe eigenständig und liefere ein kompaktes, direkt weiterverwendbares Ergebnis. Melde dein Resultat IMMER aktiv in deiner finalen Antwort an den Hauptagenten — beende dich nie ohne inhaltliches Ergebnis.
        """
    }

    /// Idempotenter Abgleich von Soll (Backend-Zustand + Modell) und Platte —
    /// fuer alle Config-Roots. Rueckgabe je Root, in fileURLs-Reihenfolge.
    @discardableResult
    func sync(backendEnabled: Bool, model rawModel: String) -> [SyncOutcome] {
        fileURLs.map { sync(backendEnabled: backendEnabled, model: rawModel, at: $0) }
    }

    /// Abgleich einer einzelnen Ziel-Datei. Leeres Modell faellt auf das
    /// kanonische GPT-Modell zurueck, damit der Agent-Typ auch ohne
    /// konfiguriertes Standard-Modell funktioniert.
    private func sync(backendEnabled: Bool, model rawModel: String, at fileURL: URL) -> SyncOutcome {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = trimmed.isEmpty ? AppPreferences.claudeGPTCanonicalModel : trimmed
        let fileManager = FileManager.default
        let existing = try? String(contentsOf: fileURL, encoding: .utf8)

        if let existing, !existing.contains(Self.managedMarker) {
            Logger.agentStore.warning(
                "gpt_agent_definition_foreign_file path=\(fileURL.path, privacy: .public) — Datei stammt nicht von WhisperM8 und bleibt unangetastet"
            )
            return .leftForeignFileAlone
        }

        guard backendEnabled else {
            guard existing != nil else { return .nothingToDo }
            try? fileManager.removeItem(at: fileURL)
            return .removed
        }

        let content = Self.definitionContent(model: model)
        if existing == content { return .upToDate }

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Logger.agentStore.error(
                "gpt_agent_definition_write_failed path=\(fileURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return .nothingToDo
        }
        return existing == nil ? .installed : .updated
    }

    /// Bequemer Abgleich aus den aktuellen Preferences.
    func syncFromPreferences() {
        sync(
            backendEnabled: AppPreferences.shared.claudeGPTBackendEnabled,
            model: AppPreferences.shared.claudeGPTBackendDefaultModel
        )
    }
}
