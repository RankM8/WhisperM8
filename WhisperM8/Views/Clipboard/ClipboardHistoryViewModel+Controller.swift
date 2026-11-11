import Foundation

/// Einträge des Controller-Menüs (Options) im Zwischenablage-Verlauf —
/// was sonst Tastenkürzel oder Knöpfe der Fußzeile und Kopfzeile sind.
enum ClipboardControllerMenuItem: String, CaseIterable, Sendable {
    case pin, pastePlain, correctSelection, clearHistory, settings
}

/// Bedienung des Verlaufs per Controller (Runde 2 nach dem Handtest). Die
/// Tasten bilden auf dieselben Wege ab wie die Tastatur (`handle`) und die
/// Knöpfe der Fußzeile.
extension ClipboardHistoryViewModel {
    var controllerState: ControllerClipboardState {
        ControllerClipboardState(
            isZoomed: isZoomed,
            isConfirmingClear: isConfirmingClear,
            canCorrect: selectedEntry.map(canCorrect) ?? false,
            selectedIsImage: selectedEntry?.kind == .image,
            menuOpen: controllerMenu != nil
        )
    }

    func perform(controller command: ControllerClipboardCommand) {
        switch command {
        case .up: handle(.moveUp)
        case .down: handle(.moveDown)
        case .paste: handle(.paste)
        case .pin: handle(.togglePin)
        case .delete: handle(.delete)
        case .close: handle(.close)
        case .correctAndPaste: handle(.correctAndPaste)
        // Wie ⌘D: in der großen Bildansicht gesperrt.
        case .filterAll: if !isZoomed { filter = .all }
        case .filterDictations: if !isZoomed { filter = .dictations }
        case .zoom: handle(.toggleZoom)
        case .confirmClear: if isConfirmingClear { confirmClear() }
        case .menuToggle:
            controllerMenu = controllerMenu == nil ? ControllerListMenu(entries: controllerMenuEntries()) : nil
        case .menuUp: controllerMenu?.move(-1)
        case .menuDown: controllerMenu?.move(1)
        case .menuActivate: activateControllerMenu()
        }
    }

    /// Einträge mit an/aus: Anheften und Einfügen brauchen einen Eintrag,
    /// „Markierung korrigieren“ gibt es nur, wenn die Kopfzeile sie anbietet.
    func controllerMenuEntries() -> [ControllerListMenu<ClipboardControllerMenuItem>.Entry] {
        ClipboardControllerMenuItem.allCases.map { item in
            let enabled: Bool
            switch item {
            case .pin, .pastePlain: enabled = selectedEntry != nil
            case .correctSelection: enabled = showsSelectionHeader
            case .clearHistory: enabled = entries.contains { !$0.isPinned }
            case .settings: enabled = true
            }
            return .init(id: item, enabled: enabled)
        }
    }

    private func activateControllerMenu() {
        guard let item = controllerMenu?.selectedEnabled else { return }
        controllerMenu = nil
        switch item {
        case .pin: handle(.togglePin)
        case .pastePlain: handle(.pastePlain)
        case .correctSelection: actions.correctSelection()
        case .clearHistory: isConfirmingClear = true
        case .settings: actions.openSettings()
        }
    }
}
