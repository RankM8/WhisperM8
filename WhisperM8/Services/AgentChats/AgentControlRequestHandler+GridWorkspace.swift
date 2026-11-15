import AppKit
import Foundation

// `gridWorkspace.*`: Grid-Workspaces der Sidebar (Mitglieder, Anlegen und
// Löschen, Öffnen, Liste, Umbenennen). Aus `AgentControlRequestHandler.swift`
// ausgelagert (WM8-98), damit die Hauptdatei Luft unter der Zeilengrenze hat.
extension AgentControlRequestHandler {
    // MARK: gridWorkspace.add / .remove

    /// Kompakte Erfolgs-Beschreibung einer Mitgliedschafts-Mutation —
    /// Sendable-tauglich über die MainActor-Grenze (kein `[String: Any]`).
    private struct MembershipDetail: Sendable {
        var outcome: String
        /// 1-basiert (CLI-Sicht) — hier schon konvertiert, damit CLI und
        /// Payload dieselbe Zahl zeigen.
        var slot: Int?
        var fromSlot: Int?
        /// Neue Kapazität, falls der Add das Grid erweitert hat.
        var grewTo: Int?
        var displaced: UUID?
        var keptSlot: Bool?
    }

    /// Grid-Workspace-Mitgliedschaft (Slots). `add` nutzt die Slot-Semantik
    /// von `WorkspaceSlotOps.add` (nächster freier Slot bzw. `--slot`,
    /// inkl. Auto-Wachsen auf höhere Slots); `remove` leert den Slot —
    /// Tab und Prozess bleiben (identisch zur Sidebar-Aktion in der App),
    /// standardmäßig kompaktierend, mit `keepSlot` positionsstabil.
    /// Ablehnungen kommen benannt zurück (Session unbekannt ≠ archiviert
    /// ≠ Slot außerhalb) — Agenten entscheiden am Exit-Code.
    func gridWorkspaceMembership(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let workspaceRef = request.params["workspaceRef"]?.stringValue, !workspaceRef.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "workspaceRef fehlt")
        }
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let slot = request.params["slot"].flatMap { json -> Int? in
            if case .number(let value) = json { return Int(value) }
            return nil
        }
        let keepSlot = request.params["keepSlot"]?.boolValue ?? false
        let isAdd = request.method == "gridWorkspace.add"

        enum MembershipOutcome {
            case ok(MembershipDetail, AgentGridWorkspace)
            case fail(ChatsControlErrorCode, String)
        }
        let outcome: MembershipOutcome = await MainActor.run {
            let store = AgentWindowStore.shared
            let workspaceEntity: AgentGridWorkspace
            switch Self.resolveGridWorkspaceRef(
                workspaceRef, all: store.gridWorkspaces.filter { $0.sourceProjectID == nil }
            ) {
            case .success(let entity): workspaceEntity = entity
            case .failure(let message): return .fail(.notFound, message)
            }
            if isAdd {
                let capacityBefore = workspaceEntity.capacity
                switch store.addSession(targetID, toGridWorkspace: workspaceEntity.id, at: slot) {
                case .added(let slotIndex, let grewTo):
                    return .ok(MembershipDetail(
                        outcome: "added", slot: slotIndex + 1, grewTo: grewTo
                    ), workspaceEntity)
                case .replaced(let slotIndex, let displaced):
                    return .ok(MembershipDetail(
                        outcome: "replaced", slot: slotIndex + 1, displaced: displaced
                    ), workspaceEntity)
                case .swapped(let from, let to):
                    // Move/Swap kennt kein `grewTo` — Kapazitätsvergleich
                    // vorher/nachher liefert dieselbe Information.
                    let capacityAfter = store.gridWorkspace(id: workspaceEntity.id)?
                        .capacity ?? capacityBefore
                    return .ok(MembershipDetail(
                        outcome: "moved", slot: to + 1, fromSlot: from + 1,
                        grewTo: capacityAfter > capacityBefore ? capacityAfter : nil
                    ), workspaceEntity)
                case .alreadyMember(let slotIndex):
                    return .ok(MembershipDetail(
                        outcome: "alreadyMember", slot: slotIndex + 1
                    ), workspaceEntity)
                case .full:
                    return .fail(.conflict, "Workspace „\(workspaceEntity.name)\" ist voll (Endstufe 3×3, Kapazität 9) — gezielt mit --slot N ersetzen")
                case .rejected(let reason):
                    switch reason {
                    case .workspaceUnknown:
                        return .fail(.notFound, "Workspace nicht gefunden")
                    case .sessionUnknown:
                        return .fail(.notFound, "Session nicht gefunden")
                    case .sessionArchived:
                        return .fail(.conflict, "Session ist archiviert — erst `chats unarchive`, dann erneut aufnehmen")
                    case .slotOutOfRange(let maxSlots):
                        return .fail(.invalid, "Slot \((slot ?? 0) + 1) liegt außerhalb — Maximum \(maxSlots) (Endstufe 3×3)")
                    case .projectViewForeignSession, .projectViewDisplacement:
                        return .fail(.conflict, "Projekt-Views verwalten ihre Mitglieder selbst (aktiv = Mitglied)")
                    }
                }
            } else {
                // `keptSlot` meldet den tatsächlichen Effekt (--keep-slot ODER „Close gaps…“ aus).
                let compacting = WorkspaceSlotOps.removalCompacts(keepSlot: keepSlot, closeGapsEnabled: store.isGridAutoCompactEnabled())
                let removed = store.removeSession(targetID, fromGridWorkspace: workspaceEntity.id, compacting: compacting)
                return .ok(MembershipDetail(
                    outcome: removed ? "removed" : "notMember",
                    keptSlot: (removed && !compacting) ? true : nil
                ), workspaceEntity)
            }
        }
        switch outcome {
        case .fail(let code, let message):
            return .failure(requestID: request.requestID, code: code, message: message)
        case .ok(let detail, let entity):
            if detail.outcome != "alreadyMember" && detail.outcome != "notMember" {
                let label = await sessionLabel(targetID)
                await audit(request.actor, method: isAdd ? "workspace-add" : "workspace-remove",
                            target: "\(entity.name) ← \(label)", outcome: "ok", prompt: nil)
            }
            var payload: [String: Any] = [
                "ok": true, "outcome": detail.outcome,
                "workspace": ["id": entity.id.uuidString, "name": entity.name],
                "target": ["id": targetID.uuidString],
            ]
            if let slot = detail.slot { payload["slot"] = slot }
            if let fromSlot = detail.fromSlot { payload["fromSlot"] = fromSlot }
            if let grewTo = detail.grewTo { payload["grewTo"] = grewTo }
            if let displaced = detail.displaced {
                payload["displacedSessionID"] = displaced.uuidString
            }
            if let keptSlot = detail.keptSlot { payload["keptSlot"] = keptSlot }
            return .success(requestID: request.requestID, result: .object(payload))
        }
    }

    // MARK: gridWorkspace.create / .delete

    /// Legt einen Grid-Workspace an — optional mit Initial-Mitgliedern
    /// (Slots in übergebener Reihenfolge, Kapazität wächst passend mit).
    /// Mitglieder werden VOR dem Anlegen hart validiert: eine unbekannte
    /// oder archivierte Session ist ein Fehler, kein stilles Loch
    /// (deterministisch für Agenten — `createGridWorkspace` würde sonst
    /// kommentarlos `nil` einsetzen).
    func gridWorkspaceCreate(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let rawName = request.params["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawName.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "name fehlt")
        }
        var colorHex = AgentGridWorkspace.defaultColorHex
        if let raw = request.params["colorHex"]?.stringValue {
            guard let canonical = AgentGridWorkspace.canonicalColorHex(raw) else {
                return .failure(requestID: request.requestID, code: .invalid,
                                message: "Ungültige Farbe „\(raw)\" — erwartet #RRGGBB")
            }
            colorHex = canonical
        }
        var memberIDs: [UUID] = []
        if let rawMembers = request.params["memberSessionIDs"]?.arrayValue {
            var seen = Set<UUID>()
            for value in rawMembers {
                guard let string = value.stringValue, let id = UUID(uuidString: string) else {
                    return .failure(requestID: request.requestID, code: .invalid,
                                    message: "memberSessionIDs enthält eine ungültige UUID")
                }
                // Duplikate in Reihenfolge deduplizieren (normalize() würde
                // sie sonst zu stillen Löchern machen).
                if seen.insert(id).inserted { memberIDs.append(id) }
            }
        }
        let maxSlots = AgentGridWorkspace.allowedCapacities.last!
        guard memberIDs.count <= maxSlots else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "Höchstens \(maxSlots) Mitglieder (Endstufe 3×3)")
        }

        enum CreateOutcome {
            case ok(id: UUID, name: String, capacity: Int, members: Int)
            case fail(ChatsControlErrorCode, String)
        }
        let name = rawName
        let color = colorHex
        let members = memberIDs
        let outcome: CreateOutcome = await MainActor.run {
            // Mitglieder gegen den Domain-Workspace validieren (In-Memory-
            // Read, kein Subprozess) — gleiche Quelle wie `addSession`.
            let sessions = AgentSessionStore().loadWorkspace().sessions
            for id in members {
                guard let session = sessions.first(where: { $0.id == id }) else {
                    return .fail(.notFound, "Session \(id.uuidString) nicht gefunden")
                }
                guard session.status != .archived else {
                    return .fail(.conflict, "Session „\(session.title)\" ist archiviert — erst `chats unarchive`")
                }
            }
            let store = AgentWindowStore.shared
            let workspaceID = store.createGridWorkspace(
                name: name, colorHex: color, capacity: AgentGridWorkspace.fittingCapacity(occupied: members.count),
                slots: members.map { Optional($0) })
            let entity = store.gridWorkspace(id: workspaceID)
            return .ok(id: workspaceID, name: entity?.name ?? name,
                       capacity: entity?.capacity ?? 2,
                       members: entity?.occupiedSessionIDs.count ?? members.count)
        }
        switch outcome {
        case .fail(let code, let message):
            return .failure(requestID: request.requestID, code: code, message: message)
        case .ok(let id, let name, let capacity, let members):
            await audit(request.actor, method: "workspace-create", target: name,
                        outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true, "outcome": "created",
                "workspace": ["id": id.uuidString, "name": name],
                "capacity": capacity,
                "members": members,
            ]))
        }
    }

    /// Löscht einen Grid-Workspace (nur die kuratierte Gruppe — Slots sind
    /// Referenzen, Tabs/Sessions/Prozesse bleiben unangetastet). Belegte
    /// Workspaces verlangen `force`, damit ein Tippfehler kein kuratiertes
    /// Layout kostet. Projekt-Views sind nicht adressierbar (gefiltert wie
    /// bei allen `gridWorkspace.*`-Refs).
    func gridWorkspaceDelete(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let ref = request.params["ref"]?.stringValue, !ref.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "ref fehlt")
        }
        let force = request.params["force"]?.boolValue ?? false

        enum DeleteOutcome {
            case ok(name: String, id: UUID, freedSlots: Int)
            case fail(ChatsControlErrorCode, String)
        }
        let outcome: DeleteOutcome = await MainActor.run {
            let store = AgentWindowStore.shared
            let entity: AgentGridWorkspace
            switch Self.resolveGridWorkspaceRef(
                ref, all: store.gridWorkspaces.filter { $0.sourceProjectID == nil }
            ) {
            case .success(let resolved): entity = resolved
            case .failure(let message): return .fail(.notFound, message)
            }
            let occupied = entity.occupiedSessionIDs.count
            guard occupied == 0 || force else {
                return .fail(.conflict, "Workspace „\(entity.name)\" hat \(occupied) belegte\(occupied == 1 ? "n" : "") Slot\(occupied == 1 ? "" : "s") — mit --force löschen (Chats/Tabs bleiben erhalten)")
            }
            guard store.deleteGridWorkspace(entity.id) else {
                return .fail(.notFound, "Workspace nicht gefunden")
            }
            return .ok(name: entity.name, id: entity.id, freedSlots: occupied)
        }
        switch outcome {
        case .fail(let code, let message):
            return .failure(requestID: request.requestID, code: code, message: message)
        case .ok(let name, let id, let freedSlots):
            await audit(request.actor, method: "workspace-delete", target: name,
                        outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true, "outcome": "deleted",
                "workspace": ["id": id.uuidString, "name": name],
                "freedSlots": freedSlots,
            ]))
        }
    }

    // MARK: gridWorkspace.open

    /// Holt einen Grid-Workspace in den Vordergrund: Grid sichtbar machen,
    /// Slot-Tabs materialisieren, Fenster und App nach vorn. Optional wird ein
    /// Slot fokussiert.
    ///
    /// Rein sichtbarkeitsbezogen — es werden KEINE Prozesse gestartet und
    /// keine Slot-Mitgliedschaften geändert. Ein leerer Slot ist kein Fehler.
    ///
    /// Besitzt bereits ein ANDERES Fenster den Workspace, wird nichts mutiert;
    /// stattdessen wird genau dieses Fenster fokussiert — das Ziel („zeig ihn
    /// mir") ist damit erfüllt, ohne dem anderen Fenster seine Terminal-Views
    /// zu stehlen.
    func gridWorkspaceOpen(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let workspaceRef = request.params["workspaceRef"]?.stringValue, !workspaceRef.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "workspaceRef fehlt")
        }
        let slot = request.params["slot"].flatMap { json -> Int? in
            if case .number(let value) = json { return Int(value) }
            return nil
        }

        enum OpenOutcome {
            case ok(name: String, workspaceID: UUID, windowID: UUID, outcome: String,
                    focusedSessionID: UUID?, slotOccupied: Bool?)
            case fail(ChatsControlErrorCode, String)
        }

        let result: OpenOutcome = await MainActor.run {
            let store = AgentWindowStore.shared
            let entity: AgentGridWorkspace
            switch Self.resolveGridWorkspaceRef(
                workspaceRef, all: store.gridWorkspaces.filter { $0.sourceProjectID == nil }
            ) {
            case .success(let match): entity = match
            case .failure(let message): return .fail(.notFound, message)
            }

            // Slot-Index VOR der Aktivierung prüfen — ein ungültiger Index soll
            // nicht erst das Fenster umschalten und dann scheitern.
            if let slot, slot < 0 || slot >= entity.capacity {
                return .fail(.invalid,
                             "Slot \(slot + 1) liegt außerhalb von „\(entity.name)\" (Kapazität \(entity.capacity))")
            }

            // Zielfenster: das besitzende, sonst das Hauptfenster.
            let ownerWindowID = store.windowID(owningGridWorkspace: entity.id)
            let targetWindowID = ownerWindowID ?? store.primaryWindowID

            let outcome: String
            switch store.keepingTicketsMode({ store.activateGridWorkspace(entity.id, in: targetWindowID) }) {
            case .activated:
                outcome = "activated"
            case .alreadyActiveHere:
                outcome = "alreadyVisible"
            case .alreadyActive:
                // Anderes Fenster besitzt ihn — wir fokussieren nur.
                outcome = "focusedOwnerWindow"
            case .blockedByWindowOwnership(let map):
                let count = map.count
                return .fail(.conflict, "\(count) Slot-Chat(s) von „\(entity.name)\" sind Tabs anderer Fenster — "
                    + "erst dort schließen oder per `chats move` übernehmen.")
            case .rejected:
                return .fail(.notFound, "Workspace oder Zielfenster nicht verfügbar")
            }

            // Slot-Fokus: nur setzen, wenn der Slot belegt ist. Ein leerer Slot
            // ist eine gültige Ansicht, kein Fehler.
            var focused: UUID?
            var slotOccupied: Bool?
            if let slot {
                let current = store.gridWorkspace(id: entity.id) ?? entity
                let sessionID = slot < current.slots.count ? current.slots[slot] : nil
                slotOccupied = sessionID != nil
                if let sessionID {
                    store.setGridFocusedSession(sessionID, in: targetWindowID)
                    focused = sessionID
                }
            }

            WindowRequestCenter.shared.requestWindowFocus(windowID: targetWindowID)
            AppActivation.activate()

            return .ok(name: entity.name, workspaceID: entity.id, windowID: targetWindowID,
                       outcome: outcome, focusedSessionID: focused, slotOccupied: slotOccupied)
        }

        switch result {
        case .fail(let code, let message):
            await audit(request.actor, method: "workspace-open", target: workspaceRef,
                        outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        case .ok(let name, let workspaceID, let windowID, let outcome, let focused, let slotOccupied):
            await audit(request.actor, method: "workspace-open", target: name, outcome: "ok", prompt: nil)
            var payload: [String: Any] = [
                "ok": true,
                "outcome": outcome,
                "workspace": ["id": workspaceID.uuidString, "name": name],
                "windowID": windowID.uuidString,
            ]
            if let slot { payload["slot"] = slot + 1 }
            if let slotOccupied { payload["slotOccupied"] = slotOccupied }
            if let focused {
                payload["focused"] = ["id": focused.uuidString, "title": await sessionLabel(focused)]
            }
            return .success(requestID: request.requestID, result: .object(payload))
        }
    }

    /// Ergebnis der Grid-Workspace-Auflösung (String taugt nicht als
    /// `Result`-Error).
    enum GridRefResolution {
        case success(AgentGridWorkspace)
        case failure(String)
    }

    /// Grid-Workspace-Referenz auflösen: exakte ID → exakter (normalisierter)
    /// Name → eindeutiger Substring. Mehrdeutig/unbekannt → Fehlermeldung.
    /// (Extrahiert aus `gridWorkspaceRename` — eine Auflösung für alle
    /// Workspace-Befehle.)
    static func resolveGridWorkspaceRef(
        _ ref: String, all: [AgentGridWorkspace]
    ) -> GridRefResolution {
        if let id = UUID(uuidString: ref), let match = all.first(where: { $0.id == id }) {
            return .success(match)
        }
        let norm = SessionRefResolver.normalize(ref)
        let exact = all.filter { SessionRefResolver.normalize($0.name) == norm }
        if exact.count == 1 { return .success(exact[0]) }
        if exact.count > 1 {
            return .failure("Workspace-Name \(ref) ist mehrdeutig (\(exact.count) exakte Treffer) — ID nutzen")
        }
        let matches = all.filter { SessionRefResolver.normalize($0.name).contains(norm) }
        if matches.count > 1 {
            return .failure("Workspace-Name \(ref) ist mehrdeutig (\(matches.count) Treffer) — genauer angeben oder ID nutzen")
        }
        guard let match = matches.first else {
            return .failure("Kein Grid-Workspace gefunden für: \(ref)")
        }
        return .success(match)
    }

    // MARK: gridWorkspace.list / .rename

    /// Grid-Workspaces (die „WORKSPACES"-Sektion der Sidebar). Read-über-Socket,
    /// weil die Namen im UI-State liegen (nicht in AgentSessions.json) und die
    /// App der Single Writer dafür ist.
    /// Grid-Workspaces mit Sichtbarkeits- und Slot-Geometrie.
    ///
    /// Bewusst KEIN Feld `isVisible`: `activeWorkspaceID` ist doppelt belegt —
    /// es bezeichnet das aktive Grid ODER nur das Rücksprungziel der
    /// Einzelansicht (`showSingleSession` lässt die Referenz stehen und setzt
    /// nur `showsGrid = false`). Ein einzelnes Sichtbarkeits-Flag würde diesen
    /// Zwischenzustand platt machen. Stattdessen `hostWindowID` und
    /// `gridVisible` getrennt — erst beides zusammen ergibt „logisch sichtbar".
    ///
    /// „Logisch" ist hier wörtlich zu nehmen: Der Store ist UI-Zustand, kein
    /// Fenster-Inventar. Ein geschlossenes Primärfenster bleibt im State
    /// (`removeWindow` weigert sich dort), meldet also weiter `gridVisible`,
    /// obwohl nichts auf dem Bildschirm steht. Minimiert, verdeckt oder auf
    /// einem anderen Space ist überhaupt nicht abbildbar.
    func gridWorkspaceList(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let workspaces = await MainActor.run { () -> [[String: Any]] in
            let store = AgentWindowStore.shared
            let sessions = AgentWorkspaceUIModel.shared.workspace.sessions
            let titles = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.title) })
            let projects = Dictionary(
                uniqueKeysWithValues: AgentWorkspaceUIModel.shared.workspace.projects.map { ($0.id, $0.name) })
            let projectBySession = Dictionary(
                uniqueKeysWithValues: sessions.map { ($0.id, projects[$0.projectID] ?? "?") })

            // Projekt-Views (Live-Ableitung, ⊞ am Projekt-Header) sind keine
            // kuratierten Workspaces — für die CLI unsichtbar.
            return store.gridWorkspaces.filter { $0.sourceProjectID == nil }.map { ws in
                let hostWindowID = store.windowID(owningGridWorkspace: ws.id)
                let gridVisible = hostWindowID.map { store.showsGrid(in: $0) } ?? false

                // Slots in SLOT-Reihenfolge, nicht kompaktiert: Der Index ist
                // eine Modell-Invariante (`workspace add --slot N` adressiert
                // ihn), und ein Loch darf nicht wegrutschen.
                var slots: [[String: Any]] = []
                for index in 0..<ws.capacity {
                    let sessionID = index < ws.slots.count ? ws.slots[index] : nil
                    // 1-basiert wie in der CLI.
                    var slot: [String: Any] = ["index": index + 1]
                    // Eine Slot-UUID ohne lebende Session gilt NICHT als
                    // belegt: `prune` räumt erst bei Load/flush auf, ein Read
                    // kann also kurz eine verwaiste ID sehen.
                    guard let sessionID, let title = titles[sessionID] else {
                        slots.append(slot)
                        continue
                    }
                    let slotHost = store.windowID(containingTab: sessionID)
                    slot["sessionID"] = sessionID.uuidString
                    slot["ref"] = ChatsOutput.shortID(sessionID)
                    slot["title"] = "\(projectBySession[sessionID] ?? "?")/\(title)"
                    if let slotHost { slot["hostWindowID"] = slotHost.uuidString }
                    // `rendered == false`: Der Chat ist Mitglied, sein Tab
                    // gehört aber einem anderen Fenster — das Grid zeigt dort
                    // den Übernahme-Platzhalter statt eines Terminals.
                    slot["rendered"] = slotHost != nil && slotHost == hostWindowID
                    slots.append(slot)
                }

                var dict: [String: Any] = [
                    "id": ws.id.uuidString,
                    "name": ws.name,
                    "capacity": ws.capacity,
                    "gridVisible": gridVisible,
                    "slots": slots,
                ]
                dict["hostWindowID"] = hostWindowID?.uuidString ?? NSNull()
                return dict
            }
        }
        return .success(requestID: request.requestID, result: .object(["workspaces": workspaces]))
    }

    func gridWorkspaceRename(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let ref = request.params["ref"]?.stringValue, !ref.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "ref fehlt")
        }
        guard let newName = request.params["name"]?.stringValue, !newName.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "name fehlt")
        }
        enum GridOutcome { case ok(before: String, after: String); case fail(ChatsControlErrorCode, String) }
        let outcome: GridOutcome = await MainActor.run {
            // Auflösung: exakte ID → exakter (normalisierter) Name →
            // eindeutiger Substring. Mehrdeutig → Fehler (nie raten).
            let workspace: AgentGridWorkspace
            switch Self.resolveGridWorkspaceRef(
                ref, all: AgentWindowStore.shared.gridWorkspaces.filter { $0.sourceProjectID == nil }
            ) {
            case .success(let entity): workspace = entity
            case .failure(let message): return .fail(.notFound, message)
            }
            let before = workspace.name
            guard AgentWindowStore.shared.renameGridWorkspace(workspace.id, to: newName) else {
                return .fail(.conflict, "Umbenennung abgelehnt (leerer/gleicher Name?)")
            }
            return .ok(before: before, after: newName)
        }
        switch outcome {
        case .fail(let code, let message):
            return .failure(requestID: request.requestID, code: code, message: message)
        case .ok(let before, let after):
            await audit(request.actor, method: "workspace-rename", target: after, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true, "before": before, "after": after,
            ]))
        }
    }
}
