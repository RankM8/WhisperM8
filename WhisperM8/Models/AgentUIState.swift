import Foundation

/// Persistenter UI-State des Agent-Chats-Fensters — offene Tabs, gepinnte
/// Chats, Selektion und aufgeklappte Sidebar-Projekte.
///
/// Wird als JSON-Sidecar-Datei `agent-ui-state.json` neben dem Workspace
/// in Application Support gespeichert. Bewusst NICHT in UserDefaults:
/// - Reihenfolge der Tabs (Array statt Set) bleibt erhalten
/// - Future-Proof: bei einem Workspace-Export wandert der UI-State mit
///
/// Schema v3 (Multi-Window Juni 2026): Tabs leben in Fenstergruppen. v2-Dateien
/// mit globaler `openTabIDs`-Liste werden in ein Primaerfenster migriert.
struct AgentChatWindowState: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var openTabIDs: [UUID]
    var selectedSessionID: UUID?
    var selectedProjectID: UUID?
    var isPrimary: Bool
    /// Grid-Ansicht des Fensters: `true` = der aktive Workspace als bündige
    /// Panes, `false` = der selektierte Tab füllt den Content (Default).
    /// Umgeschaltet über Maximize (Pane) / „Zurück zum Workspace".
    var showsGrid: Bool
    /// Der Workspace, den dieses Fenster gerade referenziert (Grid ODER
    /// Rücksprungziel der Einzelansicht — die Referenz bleibt auch bei
    /// `showsGrid == false` erhalten). Invarianten (`normalizedWindows`):
    /// zeigt auf eine existierende Entity, sonst `nil`; global höchstens
    /// EINEM Fenster zugeordnet (Single-Owner — eine Terminal-View lebt nur
    /// in einer Hierarchie).
    var activeWorkspaceID: UUID?
    /// Gemerkter Pane-Fokus des referenzierten Workspace — überlebt die
    /// Einzelansicht („Zurück zum Workspace" stellt EXAKT diese Pane wieder
    /// her, nicht den ersten belegten Slot). Nur beim sichtbaren Grid wird
    /// er in `selectedSessionID` gespiegelt.
    var gridFocusSessionID: UUID?
    /// v3-Altbestand (fensterlokale Grid-Mitgliedschaft) — wird nur noch
    /// dekodiert als Input der v4-Migration (→ globale Workspace-Entities),
    /// nie mehr encodiert. Nach `migrateIfNeeded` immer leer.
    var legacyGridSessionIDs: [UUID]

    init(
        id: UUID = UUID(),
        openTabIDs: [UUID] = [],
        selectedSessionID: UUID? = nil,
        selectedProjectID: UUID? = nil,
        isPrimary: Bool = false,
        showsGrid: Bool = false,
        activeWorkspaceID: UUID? = nil,
        gridFocusSessionID: UUID? = nil,
        legacyGridSessionIDs: [UUID] = []
    ) {
        self.id = id
        self.openTabIDs = openTabIDs
        self.selectedSessionID = selectedSessionID
        self.selectedProjectID = selectedProjectID
        self.isPrimary = isPrimary
        self.showsGrid = showsGrid
        self.activeWorkspaceID = activeWorkspaceID
        self.gridFocusSessionID = gridFocusSessionID
        self.legacyGridSessionIDs = legacyGridSessionIDs
    }

    enum CodingKeys: String, CodingKey {
        case id, openTabIDs, selectedSessionID, selectedProjectID, isPrimary
        case showsGrid
        case activeWorkspaceID
        case gridFocusSessionID
        // v3-Ära (fensterlokale Mitgliedschaft) — nur noch fürs Decoding.
        case legacyGridSessionIDs = "gridSessionIDs"
        // Preset-Ära (kurzlebiges V1, 2026-07-12) — nur noch fürs Decoding.
        case legacyGridPreset = "gridPreset"
    }

    /// Manueller Decoder statt Synthese: synthetisiertes Codable nutzt KEINE
    /// Property-Defaults — ein fehlender `showsGrid`-Key in Bestandsdateien
    /// wuerde `keyNotFound` werfen, und der `loadUIState`-Fallback verwirft
    /// dann still den kompletten Fenster-/Tab-State des Users.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        openTabIDs = try c.decodeIfPresent([UUID].self, forKey: .openTabIDs) ?? []
        selectedSessionID = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        selectedProjectID = try c.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        if let shows = try c.decodeIfPresent(Bool.self, forKey: .showsGrid) {
            showsGrid = shows
        } else {
            // Migration der Preset-Ära: "single" → Einzelansicht, jedes
            // andere Raster → Grid. Fehlt beides: Default Einzelansicht.
            let legacy = try c.decodeIfPresent(String.self, forKey: .legacyGridPreset)
            showsGrid = legacy.map { $0 != "single" } ?? false
        }
        activeWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
        gridFocusSessionID = try c.decodeIfPresent(UUID.self, forKey: .gridFocusSessionID)
        legacyGridSessionIDs = try c.decodeIfPresent([UUID].self, forKey: .legacyGridSessionIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(openTabIDs, forKey: .openTabIDs)
        try c.encodeIfPresent(selectedSessionID, forKey: .selectedSessionID)
        try c.encodeIfPresent(selectedProjectID, forKey: .selectedProjectID)
        try c.encode(isPrimary, forKey: .isPrimary)
        try c.encode(showsGrid, forKey: .showsGrid)
        try c.encodeIfPresent(activeWorkspaceID, forKey: .activeWorkspaceID)
        try c.encodeIfPresent(gridFocusSessionID, forKey: .gridFocusSessionID)
        // legacyGridSessionIDs/legacyGridPreset werden bewusst nicht mehr
        // geschrieben — v4 persistiert die Mitgliedschaft in den globalen
        // Workspace-Entities.
    }
}

struct AgentUIState: Codable, Equatable {
    var schemaVersion: Int
    /// v2-Altbestand: globale Tab-Liste. Wird fuer die v3-Migration gelesen
    /// und als Kompatibilitaets-Spiegel geschrieben.
    var openTabIDs: [UUID]
    /// In der Sidebar angepinnte Chats (Reihenfolge = Pin-Reihenfolge).
    /// Gepinnte Sessions erscheinen exklusiv in der Gepinnt-Sektion,
    /// nicht mehr in ihrer Projektgruppe.
    var pinnedSessionIDs: [UUID]
    /// Global selektierter Tab.
    var selectedSessionID: UUID?
    /// Kontext-Projekt (Ziel für „Neuer Chat", Inspector). Folgt der
    /// Session-Selektion, bestimmt aber keine Tab-Sichtbarkeit mehr.
    var selectedProjectID: UUID?
    /// Welche Sidebar-Projekte sind aktuell auf-geklappt (Disclosure).
    var expandedProjectIDs: [UUID]
    /// Subagent-Jobs mit ungelesenem Ergebnis (running→done/failed, noch
    /// nicht geöffnet). Global — gelesen ist gelesen, egal in welchem
    /// Fenster. `decodeIfPresent` mit Default `[]`, KEIN schemaVersion-Bump:
    /// ältere Builds ignorieren das Feld einfach.
    var unreadSubagentSessionIDs: [UUID]
    /// Persistierte Agent-Chat-Fenster mit eigener Tab-Reihenfolge.
    var windows: [AgentChatWindowState]
    /// Primaerfenster fuer Dock-/Menubar-Reopen und alte Single-Window-Flows.
    var primaryWindowID: UUID
    /// Globale Grid-Workspaces (Schema v4). Die Array-Reihenfolge IST die
    /// Sidebar-Reihenfolge — bewusst keine zweite Order-Liste.
    var gridWorkspaces: [AgentGridWorkspace]

    /// v1-Altbestand — wird nur noch dekodiert (Input für die Migration),
    /// nie mehr encodiert. Nach `migrateToV2IfNeeded` immer leer.
    var legacyOpenTabIDsByProject: [UUID: [UUID]]
    var legacySelectedSessionIDByProject: [UUID: UUID]

    /// Persistenz-Cap der globalen Tab-Liste. Greift nur in `prune` /
    /// bei der Migration — zur Laufzeit darf die Bar mehr Tabs zeigen
    /// (sie scrollt), beim nächsten Load wird gekappt.
    static let maxOpenTabs = 12
    static let currentSchemaVersion = 4

    static let empty = AgentUIState()

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case openTabIDs
        case pinnedSessionIDs
        case selectedSessionID
        case selectedProjectID
        case expandedProjectIDs
        case unreadSubagentSessionIDs
        case windows
        case primaryWindowID
        case gridWorkspaces
        // v1-Keys, nur fürs Decoding
        case openTabIDsByProject
        case selectedSessionIDByProject
    }

    init(
        schemaVersion: Int = AgentUIState.currentSchemaVersion,
        openTabIDs: [UUID] = [],
        pinnedSessionIDs: [UUID] = [],
        selectedSessionID: UUID? = nil,
        selectedProjectID: UUID? = nil,
        expandedProjectIDs: [UUID] = [],
        unreadSubagentSessionIDs: [UUID] = [],
        windows: [AgentChatWindowState] = [],
        primaryWindowID: UUID? = nil,
        gridWorkspaces: [AgentGridWorkspace] = [],
        legacyOpenTabIDsByProject: [UUID: [UUID]] = [:],
        legacySelectedSessionIDByProject: [UUID: UUID] = [:]
    ) {
        let resolvedPrimaryWindowID = primaryWindowID ?? windows.first(where: \.isPrimary)?.id ?? UUID()
        self.schemaVersion = schemaVersion
        self.openTabIDs = openTabIDs
        self.pinnedSessionIDs = pinnedSessionIDs
        self.selectedSessionID = selectedSessionID
        self.selectedProjectID = selectedProjectID
        self.expandedProjectIDs = expandedProjectIDs
        self.unreadSubagentSessionIDs = unreadSubagentSessionIDs
        self.primaryWindowID = resolvedPrimaryWindowID
        self.gridWorkspaces = Self.normalizedGridWorkspaces(gridWorkspaces)
        if windows.isEmpty {
            self.windows = [
                AgentChatWindowState(
                    id: resolvedPrimaryWindowID,
                    openTabIDs: openTabIDs,
                    selectedSessionID: selectedSessionID,
                    selectedProjectID: selectedProjectID,
                    isPrimary: true
                )
            ]
        } else {
            self.windows = Self.normalizedWindows(
                windows,
                primaryWindowID: resolvedPrimaryWindowID,
                gridWorkspaces: self.gridWorkspaces
            )
        }
        self.legacyOpenTabIDsByProject = legacyOpenTabIDsByProject
        self.legacySelectedSessionIDByProject = legacySelectedSessionIDByProject
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        openTabIDs = try c.decodeIfPresent([UUID].self, forKey: .openTabIDs) ?? []
        pinnedSessionIDs = try c.decodeIfPresent([UUID].self, forKey: .pinnedSessionIDs) ?? []
        selectedSessionID = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        selectedProjectID = try c.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        expandedProjectIDs = try c.decodeIfPresent([UUID].self, forKey: .expandedProjectIDs) ?? []
        unreadSubagentSessionIDs = try c.decodeIfPresent([UUID].self, forKey: .unreadSubagentSessionIDs) ?? []
        windows = try c.decodeIfPresent([AgentChatWindowState].self, forKey: .windows) ?? []
        primaryWindowID = try c.decodeIfPresent(UUID.self, forKey: .primaryWindowID)
            ?? windows.first(where: \.isPrimary)?.id
            ?? UUID()
        gridWorkspaces = try c.decodeIfPresent([AgentGridWorkspace].self, forKey: .gridWorkspaces) ?? []
        legacyOpenTabIDsByProject = try c.decodeIfPresent([UUID: [UUID]].self, forKey: .openTabIDsByProject) ?? [:]
        legacySelectedSessionIDByProject = try c.decodeIfPresent([UUID: UUID].self, forKey: .selectedSessionIDByProject) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(openTabIDs, forKey: .openTabIDs)
        try c.encode(pinnedSessionIDs, forKey: .pinnedSessionIDs)
        try c.encodeIfPresent(selectedSessionID, forKey: .selectedSessionID)
        try c.encodeIfPresent(selectedProjectID, forKey: .selectedProjectID)
        try c.encode(expandedProjectIDs, forKey: .expandedProjectIDs)
        try c.encode(unreadSubagentSessionIDs, forKey: .unreadSubagentSessionIDs)
        try c.encode(windows, forKey: .windows)
        try c.encode(primaryWindowID, forKey: .primaryWindowID)
        try c.encode(gridWorkspaces, forKey: .gridWorkspaces)
        // v1-Felder werden bewusst nicht mehr geschrieben.
    }

    /// Sequenzielle Migration auf das aktuelle Schema.
    ///
    /// v1 → v2: flacht die Pro-Projekt-Tab-Maps in die globale, geordnete
    /// Tab-Liste (Projekt-Reihenfolge = Sidebar-Reihenfolge).
    /// v2 → v3: globale Tab-Liste wird ein Primaerfenster.
    /// v3 → v4: fensterlokale Grid-Mitgliedschaft (`gridSessionIDs`) wird zu
    /// globalen Workspace-Entities — verlustfrei je Legacy-Fenster eine
    /// eigene Entity („Grid", „Grid 2", …). Die bisherigen globalen
    /// `@AppStorage`-Split-Verhältnisse übernimmt `legacySplits`. Idempotent.
    mutating func migrateIfNeeded(
        workspace: AgentWorkspace,
        legacySplits: (column: Double, row: Double)? = nil
    ) {
        guard schemaVersion < Self.currentSchemaVersion else {
            gridWorkspaces = Self.normalizedGridWorkspaces(gridWorkspaces)
            windows = Self.normalizedWindows(
                windows, primaryWindowID: primaryWindowID, gridWorkspaces: gridWorkspaces
            )
            // Nachbedingung „immer leer" gilt auch für v4-Dateien, die den
            // Legacy-Key (hand-editiert/fremd) noch tragen.
            for index in windows.indices {
                windows[index].legacyGridSessionIDs = []
            }
            syncLegacyWindowMirror()
            legacyOpenTabIDsByProject = [:]
            legacySelectedSessionIDByProject = [:]
            return
        }

        if schemaVersion < 2 {
            var flattened: [UUID] = []
            let knownProjectIDs = Set(workspace.projects.map(\.id))
            for project in AgentSessionStore.sortedProjects(workspace.projects) {
                flattened.append(contentsOf: legacyOpenTabIDsByProject[project.id] ?? [])
            }
            // Tabs von Projekten, die der Workspace nicht (mehr) kennt,
            // deterministisch hinten anhängen — prune() räumt tote IDs weg.
            for (projectID, ids) in legacyOpenTabIDsByProject
                .sorted(by: { $0.key.uuidString < $1.key.uuidString })
                where !knownProjectIDs.contains(projectID) {
                flattened.append(contentsOf: ids)
            }
            openTabIDs = Self.deduplicated(flattened)

            if selectedSessionID == nil {
                if let pid = selectedProjectID, let sid = legacySelectedSessionIDByProject[pid] {
                    selectedSessionID = sid
                } else {
                    selectedSessionID = openTabIDs.first
                }
            }
        }

        if schemaVersion < 3 || windows.isEmpty {
            primaryWindowID = windows.first(where: \.isPrimary)?.id ?? primaryWindowID
            windows = [
                AgentChatWindowState(
                    id: primaryWindowID,
                    openTabIDs: openTabIDs,
                    selectedSessionID: selectedSessionID,
                    selectedProjectID: selectedProjectID,
                    isPrimary: true
                )
            ]
        }
        // ROH-Snapshot der v3-Fenster VOR der globalen Tab-Normalisierung —
        // die dedupliziert Tabs fensterübergreifend und würde bei (korrupten)
        // Mehrfach-Fenster-Dateien Legacy-Mitglieder verlieren, BEVOR die
        // Migration sie in Entities überführen kann (Review-Finding 5).
        let rawV3Windows = schemaVersion < 4 ? windows : []
        gridWorkspaces = Self.normalizedGridWorkspaces(gridWorkspaces)
        windows = Self.normalizedWindows(
            windows, primaryWindowID: primaryWindowID, gridWorkspaces: gridWorkspaces,
            // Vor der v4-Migration darf `showsGrid` ohne Workspace-Referenz
            // noch nicht repariert werden — die Migration braucht das Flag.
            enforceGridReference: schemaVersion >= 4
        )

        if schemaVersion < 4 {
            migrateGridWorkspacesFromV3(
                rawWindows: rawV3Windows, workspace: workspace, legacySplits: legacySplits
            )
            windows = Self.normalizedWindows(
                windows, primaryWindowID: primaryWindowID, gridWorkspaces: gridWorkspaces
            )
        }

        syncLegacyWindowMirror()
        schemaVersion = Self.currentSchemaVersion
        legacyOpenTabIDsByProject = [:]
        legacySelectedSessionIDByProject = [:]
    }

    /// v3 → v4: pro Legacy-Fenster mit Grid-Zustand entsteht ein eigener
    /// Workspace — zwei Fenster mit unterschiedlichen `gridSessionIDs` können
    /// nicht verlustfrei in EINE Entity migriert werden. Arbeitet auf den
    /// ROHEN v3-Fensterdaten (vor der globalen Tab-Deduplizierung), in
    /// deterministischer Reihenfolge (Primaerfenster zuerst, dann UUID).
    /// Fenster, die die Normalisierung entfernt hat, hinterlassen ihre
    /// Entity ohne Besitzer (verlustfrei; per Sidebar wieder öffenbar).
    private mutating func migrateGridWorkspacesFromV3(
        rawWindows: [AgentChatWindowState],
        workspace: AgentWorkspace,
        legacySplits: (column: Double, row: Double)?
    ) {
        let liveSessionIDs = Set(
            workspace.sessions.filter { $0.status != .archived }.map(\.id)
        )
        var usedNames = Set(gridWorkspaces.map(\.name))
        // STABILE Sortierung (primaryRank, UUID, Eingabe-Index) — der frühere
        // Comparator war bei doppelten Fenster-IDs in beiden Richtungen
        // `true` und damit undeterministisch (Review-Finding).
        let ordered = rawWindows.enumerated().sorted { lhs, rhs in
            let lhsPrimary = lhs.element.id == primaryWindowID
            let rhsPrimary = rhs.element.id == primaryWindowID
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            if lhs.element.id != rhs.element.id {
                return lhs.element.id.uuidString < rhs.element.id.uuidString
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        // Nur die ERSTE Roh-Occurrence einer Fenster-ID bindet ihre Entity —
        // weitere Entities derselben (korrupten) ID bleiben bewusst
        // besitzerlos statt sich gegenseitig zu überschreiben.
        var boundWindowIDs = Set<UUID>()

        for raw in ordered {
            let hadLegacyMembers = !raw.legacyGridSessionIDs.isEmpty
            // Entity nur für Fenster mit Grid-Zustand — sichtbar ODER
            // konfigurierte Mitgliedschaft (verborgenes Grid bleibt als
            // Rücksprungziel erhalten). Fenster ohne Grid-Zustand erhalten
            // keinen künstlichen Workspace.
            guard raw.showsGrid || hadLegacyMembers else { continue }

            // Live-Tabs aus den ROHEN Fensterdaten: fensterlokal dedupliziert,
            // existent, nicht archiviert. Mitglieder in TAB-Reihenfolge —
            // die sichtbare Reihenfolge folgte den Tabs, nicht der
            // Membership-Liste.
            let liveTabs = Self.deduplicated(raw.openTabIDs)
                .filter { liveSessionIDs.contains($0) }
            let legacySet = Set(raw.legacyGridSessionIDs)
            let explicit = liveTabs.filter { legacySet.contains($0) }
            // Degenerierte Mitgliedschaft (≤1 gültiges Mitglied) hieß im
            // alten Modell „Default: erste 4 Tabs" — exakt so materialisieren.
            let members = explicit.count >= 2 ? explicit : Array(liveTabs.prefix(4))

            let capacity = AgentGridWorkspace.smallestCapacity(fitting: members.count)
            let name = Self.nextFreeGridName(used: &usedNames)
            let entity = AgentGridWorkspace(
                name: name,
                slots: members.prefix(9).map { $0 },
                capacity: capacity,
                columnFractions: Self.migratedAxisFractions(
                    firstFraction: legacySplits?.column,
                    count: AgentGridWorkspace.columns(forCapacity: capacity)
                ),
                rowFractions: Self.migratedAxisFractions(
                    firstFraction: legacySplits?.row,
                    count: AgentGridWorkspace.rows(forCapacity: capacity)
                )
            )
            gridWorkspaces.append(entity)
            if boundWindowIDs.insert(raw.id).inserted,
               let index = windows.firstIndex(where: { $0.id == raw.id }) {
                windows[index].activeWorkspaceID = entity.id
                // showsGrid bleibt unverändert — auch ein verborgenes Grid
                // behält seine Referenz („Zurück zum Workspace").
                windows[index].legacyGridSessionIDs = []
            }
        }
        for index in windows.indices {
            windows[index].legacyGridSessionIDs = []
        }
    }

    /// Deterministische Migrations-Namen: „Grid", dann „Grid 2", „Grid 3", …
    /// (nächster freier Suffix bei Kollisionen).
    private static func nextFreeGridName(used: inout Set<String>) -> String {
        if used.insert("Grid").inserted { return "Grid" }
        var suffix = 2
        while !used.insert("Grid \(suffix)").inserted { suffix += 1 }
        return "Grid \(suffix)"
    }

    /// Übernimmt das alte Ein-Wert-Split-Verhältnis (Anteil der ERSTEN
    /// Spalte/Zeile) als Gewichts-Paar; nur für 2er-Achsen sinnvoll, sonst
    /// (und bei degenerierten Werten) Gleichverteilung.
    private static func migratedAxisFractions(firstFraction: Double?, count: Int) -> [Double] {
        guard count == 2, let f = firstFraction, f.isFinite, f > 0.01, f < 0.99 else {
            return AgentGridWorkspace.equalFractions(count: count)
        }
        return [f, 1 - f]
    }

    /// Garbage-Collection: entfernt Eintraege fuer Projekte / Sessions, die
    /// nicht mehr im uebergebenen Workspace existieren. Wichtig damit
    /// stale UUIDs (z. B. nach manuellem Workspace-Delete) keine Geister-
    /// Tabs in der UI hinterlassen. Kappt außerdem die globale Tab-Liste
    /// auf `maxOpenTabs` (selektierter Tab überlebt die Kappung).
    /// `capTabs: false` fuer den Laufzeit-Aufruf (AgentWindowStore.prune) —
    /// zur Laufzeit darf die Bar mehr Tabs zeigen (sie scrollt), gekappt
    /// wird nur beim Load.
    mutating func prune(workspace: AgentWorkspace, capTabs: Bool = true) {
        let liveProjectIDs = Set(workspace.projects.map(\.id))
        // ALLE UI-Referenzen (Tabs, Pins, Unread, Selektionen, Slots) zeigen
        // nur auf existierende, NICHT-archivierte Sessions — `.closed` ist
        // eine normale, resumierbare Session und bleibt überall erhalten
        // (Spez 14d92786; Archivieren räumt damit auch Tabs/Pins zentral,
        // nicht nur über die View-Kaskade).
        let liveSessionIDs = Set(
            workspace.sessions.filter { $0.status != .archived }.map(\.id)
        )
        // Fokus-Anker VOR der Slot-Bereinigung sichern: Verliert ein Fenster
        // seinen fokussierten Slot (Archiv/Delete), gilt der deterministische
        // Fallback „nächster belegter Slot, sonst vorheriger" — dafür braucht
        // es den URSPRÜNGLICHEN Index (Review-Finding: pauschal „erster
        // belegter" war falsch).
        var focusAnchors: [UUID: (workspaceID: UUID, index: Int)] = [:]
        for window in windows {
            guard let workspaceID = window.activeWorkspaceID,
                  let entity = gridWorkspaces.first(where: { $0.id == workspaceID }),
                  let focus = window.gridFocusSessionID ?? window.selectedSessionID,
                  let index = entity.slotIndex(of: focus) else { continue }
            focusAnchors[window.id] = (workspaceID, index)
        }

        gridWorkspaces = Self.normalizedGridWorkspaces(gridWorkspaces).map { entity in
            var copy = entity
            // Indexstabil: toter Verweis wird am eigenen Index nil — nie
            // kompaktieren, nie schrumpfen.
            copy.slots = copy.slots.map { slot in
                guard let slot, liveSessionIDs.contains(slot) else { return nil }
                return slot
            }
            return copy
        }

        // Anker anwenden: Ist der verankerte Fokus kein Slot mehr, vom alten
        // Index aus vorwärts, dann rückwärts suchen — bevorzugt unter den
        // Slots, die diesem Fenster als TAB gehören (fremd-gehostete/
        // tablose Slots sind nur Platzhalter; die Selektions-Invariante
        // würde einen solchen Fallback sofort verwerfen und pauschal beim
        // ersten Slot landen — Re-Verifikations-Finding). Gibt es keinen
        // eigenen Kandidaten, zählt die reine Belegung (Erinnerung).
        // `gridFocusSessionID` trägt das Ergebnis; die Normalisierung
        // spiegelt es bei sichtbarem Grid in die Selektion.
        for index in windows.indices {
            guard let anchor = focusAnchors[windows[index].id],
                  let entity = gridWorkspaces.first(where: { $0.id == anchor.workspaceID })
            else { continue }
            if let focus = windows[index].gridFocusSessionID ?? windows[index].selectedSessionID,
               entity.slotIndex(of: focus) != nil {
                continue
            }
            let ownTabs = Set(windows[index].openTabIDs)
            let after = entity.slots[anchor.index...].compactMap { $0 }
            let before = entity.slots[..<anchor.index].compactMap { $0 }
            let fallback = after.first { ownTabs.contains($0) }
                ?? before.last { ownTabs.contains($0) }
                ?? after.first
                ?? before.last
            windows[index].gridFocusSessionID = fallback
            if windows[index].showsGrid {
                windows[index].selectedSessionID = fallback
            }
        }

        let cleanedGlobal = Self.deduplicated(openTabIDs.filter { liveSessionIDs.contains($0) })
        openTabIDs = capTabs
            ? Self.cappedOpenTabIDs(cleanedGlobal, selectedID: selectedSessionID)
            : cleanedGlobal
        windows = Self.normalizedWindows(
            windows, primaryWindowID: primaryWindowID, gridWorkspaces: gridWorkspaces
        ).map { window in
            var copy = window
            let cleaned = Self.deduplicated(copy.openTabIDs.filter { liveSessionIDs.contains($0) })
            copy.openTabIDs = capTabs
                ? Self.cappedOpenTabIDs(cleaned, selectedID: copy.selectedSessionID)
                : cleaned
            if let sid = copy.selectedSessionID, !liveSessionIDs.contains(sid) {
                copy.selectedSessionID = copy.openTabIDs.first
            }
            if let pid = copy.selectedProjectID, !liveProjectIDs.contains(pid) {
                copy.selectedProjectID = nil
            }
            return copy
        }.filter { $0.isPrimary || !$0.openTabIDs.isEmpty }
        if windows.first(where: { $0.id == primaryWindowID }) == nil {
            windows.insert(
                AgentChatWindowState(
                    id: primaryWindowID,
                    openTabIDs: openTabIDs,
                    selectedSessionID: selectedSessionID,
                    selectedProjectID: selectedProjectID,
                    isPrimary: true
                ),
                at: 0
            )
        }
        windows = Self.normalizedWindows(
            windows, primaryWindowID: primaryWindowID, gridWorkspaces: gridWorkspaces
        )
        pinnedSessionIDs = Self.deduplicated(
            pinnedSessionIDs.filter { liveSessionIDs.contains($0) }
        )
        unreadSubagentSessionIDs = Self.deduplicated(
            unreadSubagentSessionIDs.filter { liveSessionIDs.contains($0) }
        )

        if let sid = selectedSessionID, !liveSessionIDs.contains(sid) {
            selectedSessionID = nil
        }
        if let pid = selectedProjectID, !liveProjectIDs.contains(pid) {
            selectedProjectID = nil
        }
        expandedProjectIDs = expandedProjectIDs.filter { liveProjectIDs.contains($0) }
        syncLegacyWindowMirror()
    }

    /// First-Load-Migration: wenn der Sidecar fehlt und wir aus einem
    /// existierenden Workspace kommen, mit den neuesten manuell-erstellten
    /// nicht-archivierten Sessions pre-populieren (bis zu 3 pro Projekt,
    /// global gekappt) — damit die Tab-Bar nach Deployment des Features
    /// nicht ploetzlich leer ist.
    static func initialMigration(from workspace: AgentWorkspace) -> AgentUIState {
        var state = AgentUIState.empty
        for project in AgentSessionStore.sortedProjects(workspace.projects) {
            let sessions = workspace.sessions
                .filter { $0.projectID == project.id
                    && $0.isManuallyCreated
                    && $0.status != .archived
                }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            state.openTabIDs.append(contentsOf: sessions.prefix(3).map(\.id))
        }
        state.openTabIDs = Array(state.openTabIDs.prefix(maxOpenTabs))
        state.windows = [
            AgentChatWindowState(
                id: state.primaryWindowID,
                openTabIDs: state.openTabIDs,
                selectedSessionID: state.openTabIDs.first,
                selectedProjectID: nil,
                isPrimary: true
            )
        ]
        state.selectedSessionID = state.openTabIDs.first
        return state
    }

    func windowState(for id: UUID) -> AgentChatWindowState {
        windows.first { $0.id == id }
            ?? AgentChatWindowState(id: id, isPrimary: id == primaryWindowID)
    }

    mutating func upsertWindow(_ window: AgentChatWindowState) {
        if let index = windows.firstIndex(where: { $0.id == window.id }) {
            windows[index] = window
        } else {
            windows.append(window)
        }
        windows = Self.normalizedWindows(
            windows, primaryWindowID: primaryWindowID, gridWorkspaces: gridWorkspaces
        )
        syncLegacyWindowMirror()
    }

    mutating func removeWindowIfEmpty(_ id: UUID) {
        guard id != primaryWindowID,
              let window = windows.first(where: { $0.id == id }),
              window.openTabIDs.isEmpty else { return }
        windows.removeAll { $0.id == id }
    }

    /// Entfernt ein Sekundaerfenster MITSAMT seiner Tabs — Chrome-Semantik
    /// fuer „User schliesst das Fenster". Die Sessions bleiben im Workspace
    /// (Sidebar) erhalten. Das Primaerfenster ist geschuetzt: dessen Tabs
    /// muessen den Dock-Reopen ueberleben.
    mutating func removeWindow(_ id: UUID) {
        guard id != primaryWindowID else { return }
        windows.removeAll { $0.id == id }
    }

    mutating func moveTabToNewWindow(sessionID: UUID, sourceWindowID: UUID, newWindowID: UUID) {
        moveTab(sessionID: sessionID, from: sourceWindowID, to: newWindowID, before: nil)
    }

    mutating func moveTab(sessionID: UUID, from sourceWindowID: UUID, to targetWindowID: UUID, before targetID: UUID?) {
        for index in windows.indices {
            windows[index].openTabIDs.removeAll { $0 == sessionID }
            if windows[index].selectedSessionID == sessionID {
                windows[index].selectedSessionID = windows[index].openTabIDs.first
            }
        }
        var target = windowState(for: targetWindowID)
        target.openTabIDs.removeAll { $0 == sessionID }
        let insertAt = targetID.flatMap { target.openTabIDs.firstIndex(of: $0) } ?? target.openTabIDs.endIndex
        target.openTabIDs.insert(sessionID, at: insertAt)
        target.selectedSessionID = sessionID
        upsertWindow(target)
        removeWindowIfEmpty(sourceWindowID)
        syncLegacyWindowMirror()
    }

    /// Reihenfolge-erhaltendes Dedupe — doppelte Tab-IDs würden die
    /// SwiftUI-ForEach-Identity brechen.
    private static func deduplicated(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func cappedOpenTabIDs(_ ids: [UUID], selectedID: UUID?) -> [UUID] {
        guard ids.count > maxOpenTabs else { return ids }
        var capped = Array(ids.prefix(maxOpenTabs))
        if let selectedID, ids.contains(selectedID), !capped.contains(selectedID) {
            capped[maxOpenTabs - 1] = selectedID
        }
        return capped
    }

    private mutating func syncLegacyWindowMirror() {
        let primary = windowState(for: primaryWindowID)
        openTabIDs = primary.openTabIDs
        selectedSessionID = primary.selectedSessionID
        selectedProjectID = primary.selectedProjectID
    }

    /// Dedupliziert Workspace-Entities nach ID (erster Array-Eintrag gewinnt)
    /// und normalisiert jede intrinsisch.
    static func normalizedGridWorkspaces(
        _ workspaces: [AgentGridWorkspace]
    ) -> [AgentGridWorkspace] {
        var seen = Set<UUID>()
        return workspaces
            .filter { seen.insert($0.id).inserted }
            .map { $0.normalized() }
    }

    private static func normalizedWindows(
        _ windows: [AgentChatWindowState],
        primaryWindowID: UUID,
        gridWorkspaces: [AgentGridWorkspace] = [],
        enforceGridReference: Bool = true
    ) -> [AgentChatWindowState] {
        // 1. Doppelte Fenster-IDs entfernen, Primaerfenster garantieren.
        var seenWindowIDs = Set<UUID>()
        var normalized = windows.filter { seenWindowIDs.insert($0.id).inserted }
        if normalized.first(where: { $0.id == primaryWindowID }) == nil {
            normalized.insert(AgentChatWindowState(id: primaryWindowID, isPrimary: true), at: 0)
        }
        // 2. Primaerfenster zuerst — diese Reihenfolge bestimmt die
        //    Dedup-Prioritaet in Schritt 3.
        normalized.sort { lhs, rhs in
            if lhs.id == primaryWindowID { return true }
            if rhs.id == primaryWindowID { return false }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // 3. isPrimary setzen, Tabs INNERHALB jedes Fensters deduplizieren und
        //    dann GLOBAL: jede Session lebt in genau EINEM Fenster (das in der
        //    Reihenfolge fruehere gewinnt → Primaer hat Vorrang). Verhindert,
        //    dass derselbe Chat gleichzeitig in zwei Fenstern auftaucht.
        var claimedTabs = Set<UUID>()
        // Single-Owner: ein Workspace ist hoechstens EINEM Fenster zugeordnet
        // (eine Terminal-View lebt nur in einer Hierarchie). Bei beschaedigtem
        // Disk-State gewinnt das in der Reihenfolge fruehere Fenster
        // (Primaer vor UUID-sortierten Sekundaeren).
        let knownWorkspaceIDs = Set(gridWorkspaces.map(\.id))
        var claimedWorkspaces = Set<UUID>()
        for index in normalized.indices {
            normalized[index].isPrimary = normalized[index].id == primaryWindowID
            normalized[index].openTabIDs = deduplicated(normalized[index].openTabIDs)
                .filter { claimedTabs.insert($0).inserted }
            if let selected = normalized[index].selectedSessionID,
               !normalized[index].openTabIDs.contains(selected) {
                normalized[index].selectedSessionID = normalized[index].openTabIDs.first
            }
            // Legacy-Mitglieder (v3, nur bis zur Migration im Speicher)
            // folgen weiterhin den Tabs des Fensters.
            let tabSet = Set(normalized[index].openTabIDs)
            normalized[index].legacyGridSessionIDs = deduplicated(normalized[index].legacyGridSessionIDs)
                .filter { tabSet.contains($0) }
            // Workspace-Referenz: existierende Entity, exklusiv pro Fenster.
            if let workspaceID = normalized[index].activeWorkspaceID {
                if !knownWorkspaceIDs.contains(workspaceID)
                    || !claimedWorkspaces.insert(workspaceID).inserted {
                    normalized[index].activeWorkspaceID = nil
                    normalized[index].showsGrid = false
                }
            }
            // showsGrid ohne (gültige) Referenz ist ein illegaler Zustand —
            // ein Grid entsteht ausschließlich über activateGridWorkspace.
            // Nur die Pre-Migration-Normalisierung lässt das durch (die
            // v3→v4-Migration braucht das rohe Flag).
            if enforceGridReference,
               normalized[index].showsGrid,
               normalized[index].activeWorkspaceID == nil {
                normalized[index].showsGrid = false
            }
            // Gemerkter Pane-Fokus: nur gültig mit Referenz und solange die
            // Session ein belegter Slot des referenzierten Workspace ist.
            if let workspaceID = normalized[index].activeWorkspaceID {
                if let focus = normalized[index].gridFocusSessionID,
                   let entity = gridWorkspaces.first(where: { $0.id == workspaceID }),
                   entity.slotIndex(of: focus) == nil {
                    normalized[index].gridFocusSessionID = nil
                }
            } else {
                normalized[index].gridFocusSessionID = nil
            }
            // Fokus-Invariante im SICHTBAREN Grid: Selektion muss ein
            // belegter Slot sein — bevorzugt der gemerkte Pane-Fokus, sonst
            // erster belegter Slot, bei leerem Workspace nil (Spez 14d92786).
            // Kandidaten sind nur Slots, die auch Tabs DIESES Fensters sind
            // (Render-Ownership) — sonst bräche die Reparatur die
            // Tab-Invariante der Selektion.
            if normalized[index].showsGrid,
               let workspaceID = normalized[index].activeWorkspaceID,
               let entity = gridWorkspaces.first(where: { $0.id == workspaceID }) {
                let ownedSlots = entity.occupiedSessionIDs.filter { tabSet.contains($0) }
                let remembered = normalized[index].gridFocusSessionID
                if let selected = normalized[index].selectedSessionID,
                   ownedSlots.contains(selected) {
                    normalized[index].gridFocusSessionID = selected
                } else if let remembered, ownedSlots.contains(remembered) {
                    normalized[index].selectedSessionID = remembered
                } else {
                    normalized[index].selectedSessionID = ownedSlots.first
                    normalized[index].gridFocusSessionID = ownedSlots.first
                }
            }
        }
        return normalized
    }
}
