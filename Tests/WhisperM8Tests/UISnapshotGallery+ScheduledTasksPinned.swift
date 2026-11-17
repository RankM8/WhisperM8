import SwiftUI
@testable import WhisperM8

/// „Geplant“ fest unten in der Seitenleiste (WM8-110, Entscheidung 17.11.2026):
/// lange Chat-Liste darüber, angeheftet zu und auf, ohne Aufgaben und mit
/// ausgeschaltetem Schalter (dann sitzt die Fußzeile direkt unter der Liste).
/// Die Chat-Zeilen sind schlichte Platzhalter in den Maßen der echten Zeilen.
extension UISnapshotGallery {
    @MainActor
    static func scheduledTasksPinnedFixtures() -> [Fixture] {
        let fixture = ScheduledTasksFixtureData()
        let on: [String: Any] = [PreferenceKeys.scheduledTasksEnabled: true]
        let size = CGSize(width: 270, height: 640)
        let titles = ["Linear: Feedback umsetzen", "Feedback: Wünsche sammeln", "Supervisor Beispiel-App",
                      "Fix: Exportierte Leads", "Kurs: Übersicht der Module", "MCP: Kampagnen anlegen",
                      "Limit: Chats erkennen", "Neustart ohne Verlust", "Terminal-Tab: fertig",
                      "Arbeitskopie-Marke", "Belege März abgleichen", "Tabs: Breite merken",
                      "Notch: Anzeige ruhiger", "Diktat: Kontext prüfen", "Export: CSV-Spalten",
                      "Statistik: Wochenwerte", "Doku: Einstieg kürzen", "Release-Notizen 2.26"]

        func sidebar(expanded: Set<UUID> = [], model: ScheduledTasksOverviewModel? = nil) -> AnyView {
            AnyView(VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                            HStack(spacing: 8) {
                                Circle().fill(index < 3 ? AgentTheme.statusWorking : AgentTheme.textTertiary.opacity(0.6))
                                    .frame(width: 6, height: 6)
                                    .frame(width: 11)
                                Text(verbatim: title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AgentTheme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 28)
                            .frame(height: 26)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Spacer(minLength: 0)
                ScheduledTasksSidebarSection(
                    selectedTaskID: nil, selectedRunSessionID: nil,
                    maxListHeight: ScheduledTasksSidebarSection.maxListHeight(sidebarHeight: size.height),
                    model: model ?? fixture.model(), expandedTaskIDs: expanded)
                SidebarFooterBar(onOpenSettings: {}) { sidebarFooterTrailingPlaceholders() }
            }
            .background(AgentTheme.sidebar))
        }

        let empty = ScheduledTasksOverviewModel(dependencies: .fixture { .init() })
        empty.apply(.init(), at: fixture.now)
        let collapsed = on.merging(["agentScheduledTasksSectionCollapsed": true]) { a, _ in a }
        let expanded = on.merging(["agentScheduledTasksSectionCollapsed": false]) { a, _ in a }

        return [
            Fixture(name: "geplant-angeheftet-zu", size: size, storage: collapsed) { sidebar() },
            // Zwei Aufgaben mit ihren Läufen offen: mehr, als in die Höhe passt — der Abschnitt scrollt selbst.
            Fixture(name: "geplant-angeheftet-auf", size: size, storage: expanded) {
                sidebar(expanded: [fixture.failing.id, fixture.running.id])
            },
            Fixture(name: "geplant-angeheftet-leer", size: size, storage: expanded) {
                sidebar(model: empty)
            },
            Fixture(name: "geplant-angeheftet-aus", size: size,
                    storage: [PreferenceKeys.scheduledTasksEnabled: false]) { sidebar() },
        ]
    }
}
