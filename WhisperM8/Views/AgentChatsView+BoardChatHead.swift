import Foundation

/// Kopf der Board-Chat-Spalte mit Controller und Tastatur (WM8-126): was das
/// Fenster dem Modell über den Kopf sagt und was ein Knopf dort auslöst.
///
/// Sicherheit: Nichts hier schreibt in einen Chat. Ein Wechsel des Board-Chats
/// ändert nur die gespeicherte Wahl; ein Fokus des Controllers im Board-Chat
/// verfällt dabei von selbst (`ControllerBoardChatFocus.isValid`). Hinein geht
/// es nur mit ▼, über denselben Weg wie ▶ am rechten Rand, mit Ankunftssperre.
extension AgentChatsView {
    /// Modell des Boards dieses Fensters für Ring und Liste im Kopf der
    /// Spalte. Die Spalte gibt es nur im Ticket-Modus, und dort hat das
    /// Fenster sein Board schon (`AgentChatsView+Tickets`).
    var boardChatHeadFocusModel: TicketBoardViewModel? {
        TicketBoardControllers.shared.hasController(for: windowID)
            ? TicketBoardControllers.shared.controller(for: windowID).viewModel : nil
    }

    /// Knöpfe im Kopf der Spalte, wie sie gerade stehen. Im Ereignis-Pfad, je
    /// Druck im Kopf: eine Suche unter offenen Tabs und laufenden Chats
    /// (`boardChatPick`, einige Dutzend), nie über alle Chats. `nil` ohne
    /// Spalte (kein Projekt) oder bevor die Einstellungen geladen sind.
    func boardChatHeadLayout() -> BoardChatHeadLayout? {
        guard let projectID = boardChatProjectID else { return nil }
        let store = BoardChatPreferencesStore.shared
        guard store.isLoaded else { return nil }
        return boardChatHeadLayout(pick: boardChatPick(projectID: projectID), projectID: projectID,
                                   isCollapsed: store.preferences(for: projectID).isCollapsed == true)
    }

    private func boardChatHeadLayout(pick: BoardChatPickResult, projectID: UUID, isCollapsed: Bool) -> BoardChatHeadLayout {
        let session = pick.current
        let choices = BoardChatRules.choices(
            jarvis: pick.jarvis.map(Self.boardChatChoiceChat), product: pick.product.map(Self.boardChatChoiceChat),
            chosen: pick.chosen.map(Self.boardChatChoiceChat), current: session?.id)
        // „Als Tab öffnen“ steht wie im Kopf nur, wenn das Terminal hier steht.
        let canOpenAsTab = session.map { boardChatPlacement(of: $0.id) == .here } ?? false
        return .make(choices: choices, others: pick.others, canOpenAsTab: canOpenAsTab, isCollapsed: isCollapsed)
    }

    /// Befehle, solange die Auswahl im Kopf der Spalte steht. `nil`: wie
    /// sonst auch (L1/R1, Link, Linear, → Jarvis …).
    func performBoardChatHeadCommand(_ command: ControllerTicketCommand, model: TicketBoardViewModel,
                                     header: TicketHeaderContext) -> ControllerTicketOutcome? {
        switch command {
        case .move(let direction):
            return model.columnMove(TicketBoardMove(direction), header, exit: boardChatHeadExit(header))
        case .repeatMove(let direction):
            // Gehalten: wählt nur innerhalb des Kopfs bzw. der Liste. Nie
            // zurück in den Kopf des Boards und nie hinunter in den Chat.
            guard model.columnPickerIndex == nil else {
                return model.columnMove(TicketBoardMove(direction), header, exit: .toBoard)
            }
            guard let layout = header.column, let item = model.columnFocus,
                  case .item = BoardChatHeadSelection.step(item, TicketBoardMove(direction), in: layout) else {
                return .nothing
            }
            return model.columnMove(TicketBoardMove(direction), header, exit: .toBoard)
        case .open:
            return performBoardChatHeadActivation(model.columnActivate(header), model: model)
        case .back:
            model.columnBack()
            return .done
        default:
            return nil
        }
    }

    /// ▼ führt nur dann in den Board-Chat, wenn die Spalte genau den Chat
    /// zeigt, der nach der gespeicherten Wahl dort steht. Gleich nach einem
    /// Wechsel kann die Anmeldung noch den vorigen nennen; dann zurück aufs
    /// Board statt in einen Chat, der gerade verschwindet.
    private func boardChatHeadExit(_ header: TicketHeaderContext) -> BoardChatHeadExit {
        guard let shown = BoardChatInputs.shared.boardChat(in: windowID)?.sessionID,
              shown == header.column?.current else { return .toBoard }
        return .intoBoardChat
    }

    private func performBoardChatHeadActivation(_ activation: BoardChatHeadActivation,
                                                model: TicketBoardViewModel) -> ControllerTicketOutcome {
        guard let projectID = boardChatProjectID else {
            model.leaveColumn()
            return .rejected
        }
        let store = BoardChatPreferencesStore.shared
        switch activation {
        case .done:
            return .done
        case .rejected:
            return .rejected
        case .choose(let id):
            return chooseBoardChatFromHead(id, projectID: projectID, model: model)
        case .openAsTab:
            // Wie der Knopf: Der Chat geht als Tab auf, die Tickets zu. Nichts
            // wird gesendet; Return und Esc warten im Ziel 1 s (Tastatur), am
            // Controller Kreuz und Kreis (`columnTabChatID`).
            guard let shown = BoardChatInputs.shared.boardChat(in: windowID)?.sessionID,
                  boardChatPlacement(of: shown) == .here else { return .rejected }
            model.leaveHeader()
            KeyboardArrivalLock.shared.arrive(at: shown)
            windowStore.navigateToSession(shown, in: windowID)
            return .done
        case .hide:
            // Danach meldet sich kein Board-Chat mehr an; der Ring steht auf
            // dem Knopf der zugeklappten Leiste, damit Kreuz es rückgängig macht.
            store.setCollapsed(true, for: projectID)
            model.reconcileColumn(boardChatHeadLayout())
            return .done
        case .show:
            store.setCollapsed(false, for: projectID)
            model.reconcileColumn(boardChatHeadLayout())
            return .done
        }
    }

    /// Wechsel des Board-Chats per Knopf oder Liste. Dieselbe Regel wie beim
    /// Hineinziehen; was nicht passt, sagt der Hinweis unter der Spalte.
    private func chooseBoardChatFromHead(_ id: UUID, projectID: UUID, model: TicketBoardViewModel) -> ControllerTicketOutcome {
        guard let session = workspaceModel.session(id: id) else { return .rejected }
        if let rejection = boardChatRejection(of: session, projectID: projectID) {
            let projectName = workspace.projects.first { $0.id == projectID }?.name ?? selectedProject?.name ?? ""
            BoardChatInputs.shared.showNotice(
                BoardChatInputRules.message(rejection, chatName: session.title, projectName: projectName), in: windowID)
            return .rejected
        }
        let pick = boardChatPick(projectID: projectID)
        BoardChatPreferencesStore.shared.setChosenSession(
            BoardChatRules.storedChoice(after: id, automaticJarvis: pick.jarvis?.id), for: projectID)
        model.reconcileColumn(boardChatHeadLayout(), chosen: id)
        return .done
    }
}
