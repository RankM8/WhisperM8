import SwiftUI

/// Scope-Leiste über der Chat-Liste (aus `AgentChatsView.swift` ausgelagert,
/// WM8-80 Paket 6).
extension AgentChatsView {
    /// Scope-Umschalter (Aktiv·Zuletzt·Alle) mit Zählern + Layout-Toggle
    /// (gruppiert·flach). Fest verankert über der Chat-Liste, scrollt also
    /// nicht mit. Seit WM8-80 (Kleinkram 1) stehen die Zahlen im Umschalter
    /// selbst; die frühere Zeile „N von M Chats · Alle zeigen“ entfällt.
    func sidebarScopeBar(counts: SidebarScopeCounts) -> some View {
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                SidebarScopeSegments(
                    scope: sidebarScope, counts: counts, isSearching: searching,
                    onSelect: { sidebarScope = $0 }
                )

                Button {
                    sidebarLayout = (sidebarLayout == .grouped ? .flat : .grouped)
                } label: {
                    Image(systemName: sidebarLayout.toggleIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 30, height: 26)
                        .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sidebarLayout == .grouped
                    ? String(localized: "Show flat (sorted by activity)")
                    : String(localized: "Group by project"))
            }

            if searching {
                captionRow(text: "Search shows all chats")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    func captionRow(text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
            Spacer(minLength: 0)
        }
    }

    /// Zahl im Umschalter: dieselben Zähler wie die Liste (ohne Gepinnte).
    static func scopeCount(_ scope: SidebarScope, in counts: SidebarScopeCounts) -> Int {
        switch scope {
        case .active: return counts.active
        case .recent: return counts.recent
        case .all: return counts.all
        }
    }
}

/// Umschalter Aktiv · Zuletzt · Alle mit Zählern (WM8-80, Kleinkram 1). Als
/// eigene View, damit die Snapshot-Galerie ihn ohne die Chat-Ansicht zeichnet.
struct SidebarScopeSegments: View {
    let scope: SidebarScope
    let counts: SidebarScopeCounts
    var isSearching = false
    var onSelect: (SidebarScope) -> Void

    var body: some View {
        // Eigener Segmented-Control: der native Picker(.segmented)
        // expandiert auf macOS NICHT auf volle Breite — das darunter
        // liegende NSSegmentedControl behält seine intrinsische Größe,
        // `.frame(maxWidth:.infinity)` wird ignoriert. Eigene Buttons
        // mit maxWidth füllen die Breite zuverlässig (wie im Entwurf,
        // wo `.seg button { flex: 1 }` galt).
        HStack(spacing: 2) {
            ForEach(SidebarScope.allCases) { scope in
                let isOn = self.scope == scope
                Button { onSelect(scope) } label: {
                    // Kein Verkleinern (Regel ≥ 11 pt): Die Zahl bleibt fest,
                    // bei Enge wird das Wort gekürzt.
                    HStack(spacing: 3) {
                        Text(scope.label)
                            .font(.system(size: 11, weight: isOn ? .semibold : .medium))
                            .truncationMode(.tail)
                        Text(verbatim: "\(AgentChatsView.scopeCount(scope, in: counts))")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .opacity(0.7)
                            .fixedSize()
                    }
                    .lineLimit(1)
                    .foregroundStyle(isOn ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 22)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(AgentTheme.segmentActive)
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 8))
        .disabled(isSearching)
        .opacity(isSearching ? 0.55 : 1)
        .help(isSearching ? String(localized: "Search shows all chats") : String(localized: "Which chats the list shows"))
    }
}
