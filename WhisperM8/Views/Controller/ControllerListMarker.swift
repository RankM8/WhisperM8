import SwiftUI

private struct AgentChatsWindowIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// ID des Agent-Chats-Fensters, zu dem eine Ansicht gehört. Daran erkennt
    /// die Listen-Markierung, ob sie in diesem Fenster gemeint ist.
    var agentChatsWindowID: UUID? {
        get { self[AgentChatsWindowIDKey.self] }
        set { self[AgentChatsWindowIDKey.self] = newValue }
    }
}

/// Markierung einer Zeile der Liste links, wenn die Controller-Steuerung auf
/// ihr steht: Akzentrahmen mit zarter Füllung, getrennt von der Auswahl.
///
/// Eigenes kleines View-Stück: Nur diese Stücke lesen das `ControllerUIModel`,
/// die Zeilen selbst und der große Body der Seitenleiste nicht. Ein Schritt
/// mit dem Stick wertet so nur die Markierungen neu aus.
private struct ControllerListMarker: View {
    let row: SidebarNavigationRow
    @Environment(\.agentChatsWindowID) private var windowID
    @State private var model = ControllerUIModel.shared

    var body: some View {
        if model.area == .list, model.markedRow == row, model.listWindowID == windowID {
            // Nur, wenn das Menü dieser Zeile gilt (beim Öffnen festgehalten).
            let carriesMenu = ControllerMenuPlacement.listRowCarriesMenu(model.menu?.setup, row: row)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppTheme.accentTint)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AppTheme.accent, lineWidth: 2)
                )
                .padding(.horizontal, 4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                // Offenes Options-Menü hängt sich neben die markierte Zeile.
                .anchorPreference(key: ControllerMenuAnchorKey.self, value: .bounds) { anchor in
                    carriesMenu ? [.listRow: anchor] : [:]
                }
        }
    }
}

extension View {
    /// Macht eine Zeile der Liste links für die Controller-Steuerung
    /// erreichbar: Sie bekommt die Markierung und eine ID zum Mitscrollen.
    func controllerListRow(_ row: SidebarNavigationRow) -> some View {
        background(ControllerListMarker(row: row))
            .id(row)
    }
}

/// Hält die markierte Zeile im sichtbaren Bereich der Liste. Sitzt ohne
/// eigene Größe im Scroll-Inhalt und beobachtet als Einziges die Markierung.
struct ControllerListScrollFollower: View {
    let proxy: ScrollViewProxy
    @Environment(\.agentChatsWindowID) private var windowID
    @State private var model = ControllerUIModel.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.markedRow) { _, marked in
                guard let marked, model.listWindowID == windowID else { return }
                // Ohne Anker: nur so weit scrollen, bis die Zeile zu sehen ist.
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(marked) }
            }
    }
}
