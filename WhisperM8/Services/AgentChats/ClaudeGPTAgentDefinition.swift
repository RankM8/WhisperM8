import Foundation

/// Verwaltet die von WhisperM8 gepflegte Claude-Code-Agent-Definition
/// `~/.claude/agents/gpt.md`. Ueber sie kann das Hauptmodell einer Session
/// nativ PRO AUFGABE einen GPT-Subagenten waehlen (Frontmatter `model:` hat
/// in Claude Codes Aufloesungskette Vorrang vor dem Hauptmodell), ohne dass
/// `CLAUDE_CODE_SUBAGENT_MODEL` saemtliche Subagents auf GPT zwingt. Die
/// verbindliche Subagent-Policy erlaubt nur GPT-5.6 Sol oder Terra; jede andere
/// nichtleere Konfiguration faellt sicher auf das kanonische Sol zurueck.
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

    /// Serialisiert alle Sync-Laeufe prozessweit. Ohne Lock kann ein
    /// detachter Start-Sync (ensureRunning) mit veraltetem Preference-
    /// Snapshot NACH einem frischeren Settings-Sync schreiben und z. B.
    /// einen gerade deaktivierten Fast-Toggle wieder zurueckrollen.
    private static let syncLock = NSLock()

    /// Idempotenter Abgleich von Soll (Backend-Zustand + Modell) und Platte —
    /// fuer alle Config-Roots. Rueckgabe je Root, in fileURLs-Reihenfolge.
    @discardableResult
    func sync(backendEnabled: Bool, model rawModel: String, fastEnabled: Bool) -> [SyncOutcome] {
        Self.syncLock.lock()
        defer { Self.syncLock.unlock() }
        return performSync(
            backendEnabled: backendEnabled,
            model: rawModel,
            fastEnabled: fastEnabled
        )
    }

    @discardableResult
    private func performSync(
        backendEnabled: Bool,
        model rawModel: String,
        fastEnabled: Bool
    ) -> [SyncOutcome] {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmed.isEmpty ? AppPreferences.claudeGPTCanonicalModel : trimmed
        let effectiveModel = ClaudeGPTModelAlias.supportedSubagentModel(
            resolvedModel,
            fastEnabled: fastEnabled
        ) ?? ClaudeGPTModelAlias.supportedSubagentModel(
            AppPreferences.claudeGPTCanonicalModel,
            fastEnabled: fastEnabled
        )!
        return fileURLs.map {
            sync(backendEnabled: backendEnabled, model: effectiveModel, at: $0)
        }
    }

    /// Abgleich einer einzelnen Ziel-Datei.
    private func sync(backendEnabled: Bool, model: String, at fileURL: URL) -> SyncOutcome {
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

    /// Bequemer Abgleich aus den aktuellen Preferences. Liest die Werte
    /// bewusst ERST unter dem Lock — der letzte Schreiber arbeitet damit
    /// garantiert mit dem frischesten Stand statt einem Alt-Snapshot.
    func syncFromPreferences() {
        Self.syncLock.lock()
        defer { Self.syncLock.unlock() }
        performSync(
            backendEnabled: AppPreferences.shared.claudeGPTBackendEnabled,
            model: AppPreferences.shared.claudeGPTBackendDefaultModel,
            fastEnabled: AppPreferences.shared.claudeGPTFastModeEnabled
        )
    }
}
