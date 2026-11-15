import AppKit
import SwiftUI
@testable import WhisperM8

extension UISnapshotGallery {
    /// Insel per Tastatur (⌥Tab, WM8-104): Kopf und Fußzeile mit Tastenkappen,
    /// Markierung auf „vorher“ (Entwurf insel-tastatur.html, Zustände 2, 3, 5, 7).
    @MainActor
    static func keyboardIslandFixtures() -> [Fixture] {
        let notch = ControllerIslandDisplay.Style.notch(width: 184, height: 32)
        let current = UUID()
        let previousChat = UUID()
        func chat(_ title: String, _ project: String, _ status: ControllerIslandStatus?, _ detail: String,
                  id: UUID = UUID()) -> ControllerIslandChatRow {
            ControllerIslandChatRow(id: id, title: title, project: project, status: status, detail: detail,
                                    isCurrent: id == current)
        }
        let chats = [
            chat("Controller Insel", "WhisperM8", .working, "jetzt", id: current),
            chat("Jarvis: Supervisor WhisperM8", "WhisperM8", .awaiting, "wartet · 2 min", id: previousChat),
            chat("Schlüsselbund Diktat", "WhisperM8", .idle, "bereit"),
            chat("Kampagnen Import", "ListM8", .working, "arbeitet · 6 min"),
            chat("Lead Varianten", "ListM8", .idle, "vor 40 min"),
            chat("Release 2.26", "WhisperM8", .idle, "vor 2 h"),
            chat("Archiv Suche", "WhisperM8", .stopped, "gestoppt"),
        ]
        let previousPlace = UUID()
        let places = [
            ControllerWorkspaceChoice(id: UUID(), name: "Controller-Raster", colorHex: "#5E6AD2", chatCount: 4,
                                      hasWaitingChat: false, isCurrent: true),
            ControllerWorkspaceChoice(id: previousPlace, name: "ListM8 Kampagnen", colorHex: "#3FA873", chatCount: 3,
                                      hasWaitingChat: true, isCurrent: false),
            ControllerWorkspaceChoice(id: UUID(), name: "Release 2.26", colorHex: "#C9962A", chatCount: 2,
                                      hasWaitingChat: false, isCurrent: false),
            ControllerWorkspaceChoice(id: UUID(), name: "whisperm8", colorHex: "#7A7D85", chatCount: 4,
                                      hasWaitingChat: false, isCurrent: false, kind: .project),
        ]
        func model(previous: ControllerWhereToState.Destination, grid: Bool = false, reopen: String? = nil,
                   target: ControllerIslandTarget = ControllerIslandTarget(title: "Controller Insel", status: .working))
            -> ControllerIslandModel {
            var state = ControllerWhereToState(
                chats: chats, currentChatID: current, workspaces: places, gridActive: grid, previous: previous)
            state.reopenTitle = reopen
            state.markPreviousForKeyboard()
            return ControllerIslandModel(target: target, content: .whereTo(state), input: .keyboard)
        }
        let chatsModel = model(previous: .chat(previousChat), reopen: "Lead Varianten")
        let placesModel = model(previous: .workspace(previousPlace), grid: true)
        let dictating = model(
            previous: .chat(previousChat),
            target: ControllerIslandTarget(title: "→ Controller Insel", status: .working, dictating: true))

        func island(_ model: ControllerIslandModel, style: ControllerIslandDisplay.Style = notch,
                    counts: ControllerIslandCounts? = ControllerIslandCounts(working: 2, waiting: 1)) -> AnyView {
            let display = ControllerIslandDisplay(style: style, model: model, counts: counts)
            return AnyView(ControllerIslandView(display: display)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppTheme.sidebar))
        }
        let size = CGSize(width: 620, height: 420)
        return [
            Fixture(name: "insel-tastatur-chats", size: size) { island(chatsModel) },
            Fixture(name: "insel-tastatur-workspaces", size: size) { island(placesModel) },
            Fixture(name: "insel-tastatur-diktat", size: size) { island(dictating, counts: nil) },
            Fixture(name: "insel-tastatur-pille", size: size) { island(chatsModel, style: .pill) },
        ]
    }
}
