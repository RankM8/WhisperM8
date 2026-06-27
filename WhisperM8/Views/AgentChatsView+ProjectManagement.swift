import SwiftUI
import AppKit

/// Projekt-Verwaltung der AgentChatsView: Auswahl/Toggle, Hinzufuegen,
/// Loeschen, Umbenennen/Faerben und Projekt-Icon-Handling (waehlen, auto-
/// erkennen, entfernen, Migration). Aus AgentChatsView.swift ausgelagert
/// (Phase-2-Split).
extension AgentChatsView {
    /// Projekt-Klick setzt den Kontext (Ziel für „Neuer Chat", Inspector) und
    /// klappt das Projekt auf bzw. zu (Standard-Disclosure-Verhalten — Klick auf
    /// die ganze Header-Zeile öffnet/schließt). Die globale Tab-Bar und die
    /// Session-Selektion bleiben unangetastet.
    func selectProject(_ projectID: UUID) {
        selectedProjectID = projectID
        if let project = workspace.projects.first(where: { $0.id == projectID }) {
            AppPreferences.shared.agentDefaultProjectPath = project.path
        }
        toggleProject(projectID)
    }

    func toggleProject(_ projectID: UUID) {
        if expandedProjectIDs.contains(projectID) {
            expandedProjectIDs.remove(projectID)
        } else {
            expandedProjectIDs.insert(projectID)
        }
    }

    @discardableResult
    func addProject() -> AgentProject? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let project = try store.upsertProject(path: url.path, createdManually: true)
            selectedProjectID = project.id
            expandedProjectIDs.insert(project.id)
            AppPreferences.shared.agentDefaultProjectPath = project.path
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Project metadata actions

    /// Löscht ein Projekt (nach Bestätigung): beendet laufende Terminals
    /// seiner Sessions, entfernt Projekt + Sessions aus dem Workspace und
    /// räumt den UI-State (offene Tabs, Pins, Selektion) auf. Repo und
    /// externe Transcripts auf der Platte bleiben unangetastet.
    func deleteProject(_ project: AgentProject) {
        let sessionIDs = Set(
            workspace.sessions.filter { $0.projectID == project.id }.map(\.id)
        )
        for id in sessionIDs where terminalRegistry.controller(for: id)?.isRunning == true {
            terminalRegistry.terminate(sessionID: id)
        }
        do {
            try store.deleteProject(id: project.id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        openTabIDs.removeAll { sessionIDs.contains($0) }
        pinnedSessionIDs.removeAll { sessionIDs.contains($0) }
        expandedProjectIDs.remove(project.id)
        iconLookupAttempted.remove(project.id)
        if let selected = selectedSessionID, sessionIDs.contains(selected) {
            selectedSessionID = openTabIDs.first
        }
        if selectedProjectID == project.id {
            selectedProjectID = workspace.projects.first?.id
        }
        projectPendingDeletion = nil
    }

    func beginRenameProject(_ project: AgentProject) {
        renameProjectTargetID = project.id
        renameProjectDraft = project.name
    }

    func renameProject(id: UUID, name: String) {
        do {
            try store.renameProject(id: id, name: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setProjectColor(id: UUID, color: String) {
        do {
            try store.setProjectColor(id: id, color: color)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Öffnet einen NSOpenPanel und speichert den absoluten Pfad als
    /// `customIconAbsolutePath` (Vorrang vor Auto-Detect-Pfad). Akzeptiert die
    /// üblichen Bildformate, die NSImage zuverlässig darstellt.
    func chooseProjectIcon(_ project: AgentProject) {
        let panel = NSOpenPanel()
        panel.title = "Projekt-Icon wählen"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .svg, .icns, .ico, .image]
        panel.directoryURL = URL(fileURLWithPath: project.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.setProjectCustomIcon(id: project.id, absolutePath: url.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Setzt den Auto-Lookup-Status zurück und triggert sofort einen neuen
    /// Resolver-Lauf — User-getriggert via Context-Menü.
    func reAutoDetectProjectIcon(_ project: AgentProject) {
        do {
            try store.clearProjectIcon(id: project.id)
            iconLookupAttempted.remove(project.id)
            attemptAutoDetectProjectIcons()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearProjectIcon(_ id: UUID) {
        do {
            try store.clearProjectIcon(id: id)
            iconLookupAttempted.insert(id)  // nicht direkt re-resolven
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Einmalige Migration nach Resolver-Verbesserungen: setzt den
    /// Auto-Lookup für alle Projekte OHNE manuell gewähltes Icon zurück,
    /// damit der verbesserte Resolver (`AgentProjectIconResolver.version`)
    /// beim folgenden `attemptAutoDetectProjectIcons()` erneut greift.
    /// Ohne das blieben Projekte, die der alte Resolver schon einmal (oft
    /// erfolglos) gescannt hat, dauerhaft ohne Icon. User-gewählte Icons
    /// (`customIconAbsolutePath`) bleiben unangetastet.
    func migrateIconDetectionIfNeeded() {
        let key = "agentIconResolverVersion"
        let applied = UserDefaults.standard.integer(forKey: key)
        guard applied < AgentProjectIconResolver.version else { return }
        for project in workspace.projects {
            guard project.customIconAbsolutePath?.isEmpty ?? true else { continue }
            try? store.updateProject(id: project.id) { project in
                project.iconRelativePath = nil
                project.iconAutoLookupAttempted = nil
            }
        }
        iconLookupAttempted.removeAll()
        UserDefaults.standard.set(AgentProjectIconResolver.version, forKey: key)
    }

    /// Iteriert über alle Projekte und scannt deren Repos asynchron nach Icons,
    /// sofern noch kein Lookup gemacht wurde. Bewusst lazy: nur Projekte, deren
    /// `iconAutoLookupAttempted != true` und die in dieser App-Session noch
    /// nicht gescannt wurden.
    func attemptAutoDetectProjectIcons() {
        let candidates = workspace.projects.filter { project in
            // Nur manuell hinzugefügte Projekte werden in der Sidebar gezeigt —
            // auto-importierte Pseudo-Projekte (versehentliche cwds wie Home/
            // Downloads) gar nicht erst scannen.
            project.isManuallyAdded
                && !iconLookupAttempted.contains(project.id)
                && project.iconAutoLookupAttempted != true
                && (project.customIconAbsolutePath?.isEmpty ?? true)
                && (project.iconRelativePath?.isEmpty ?? true)
        }
        guard !candidates.isEmpty else { return }

        for project in candidates {
            iconLookupAttempted.insert(project.id)
        }

        Task.detached(priority: .utility) { [store] in
            for project in candidates {
                let path = project.path
                let id = project.id
                let resolved = AgentProjectIconResolver.findIconRelativePath(in: path)
                do {
                    try store.applyAutoResolvedProjectIcon(id: id, relativePath: resolved)
                } catch {
                    Logger.debug("project_icon_auto_resolve_failed project=\(id.uuidString) error=\(error.localizedDescription)")
                }
            }
            await MainActor.run {
            }
        }
    }
}
