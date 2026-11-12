import CoreGraphics
import Foundation
import SwiftUI
@testable import WhisperM8

/// Fixtures fürs Raster: alle Stufen und die Fälle, in denen Chats
/// wegfallen. Gerendert wird der echte `AgentGridSplitContainer` mit
/// Platzhalter-Kacheln (kein Terminal) — Belegung und Stufe kommen aus dem
/// echten `AgentWindowStore`, damit die Bilder zeigen, was die App täte.
extension UISnapshotGallery {
    /// Kachel-Ersatz: Kopfzeile wie eine Pane, darunter ein paar Zeilen.
    private struct GridFixturePane: View {
        let title: String
        let focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(AgentTheme.textTertiary).frame(width: 7, height: 7)
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(AgentTheme.header.opacity(focused ? 1 : 0.55))
                VStack(alignment: .leading, spacing: 4) {
                    Text("> \(title.lowercased())")
                    Text("  ok")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AgentTheme.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AgentTheme.background)
            }
            .overlay {
                if focused {
                    Rectangle().strokeBorder(AgentTheme.accent, lineWidth: 2)
                }
            }
        }
    }

    @MainActor
    private static func gridView(_ entity: AgentGridWorkspace, titles: [UUID: String]) -> AnyView {
        AnyView(
            AgentGridSplitContainer(
                layout: AgentGridAutoLayout.forCapacity(entity.capacity),
                persistedColumnFractions: entity.columnFractions,
                persistedRowFractions: entity.rowFractions,
                commitColumnFractions: { _ in },
                commitRowFractions: { _ in },
                onHandleHoverChanged: { _ in },
                pane: { index in
                    if entity.slots.indices.contains(index), let id = entity.slots[index] {
                        GridFixturePane(title: titles[id] ?? "Chat", focused: index == 0)
                    } else {
                        GridEmptySlotView(index: index)
                    }
                }
            )
            .background(AgentTheme.border)
        )
    }

    /// Store mit Wegwerf-Dateien und `count` Sessions (absteigende Aktivität).
    @MainActor
    private static func gridStore(count: Int) -> (store: AgentWindowStore, ids: [UUID], titles: [UUID: String]) {
        let dir = FileManager.default.temporaryDirectory
        let persistence = AgentSessionStore(
            fileURL: dir.appendingPathComponent("wm8-gridfix-ws-\(UUID().uuidString).json"),
            uiStateFileURL: dir.appendingPathComponent("wm8-gridfix-ui-\(UUID().uuidString).json")
        )
        var ids: [UUID] = []
        var titles: [UUID: String] = [:]
        for index in 0 ..< count {
            var session = AgentChatSession(
                id: UUID(), provider: .claude, projectID: UUID(), title: "Chat \(index + 1)",
                lastActivityAt: Date(timeIntervalSince1970: Double(1_000 - index)),
                createdManually: true
            )
            session.status = .closed
            _ = try? persistence.upsertSession(session)
            ids.append(session.id)
            titles[session.id] = session.title
        }
        return (AgentWindowStore(persistence: persistence), ids, titles)
    }

    @MainActor
    static func gridFixtures() -> [Fixture] {
        let size = CGSize(width: 720, height: 460)
        var fixtures: [Fixture] = []

        // Jede Stufe voll belegt — so legt der Store einen Workspace an.
        for count in AgentGridWorkspace.allowedCapacities {
            fixtures.append(Fixture(name: "raster-stufe-\(count)", size: size) {
                let (store, ids, titles) = gridStore(count: count)
                let id = store.createGridWorkspace(
                    name: "G",
                    capacity: AgentGridWorkspace.smallestCapacity(fitting: count),
                    slots: ids.map { $0 }
                )
                return gridView(store.gridWorkspace(id: id)!, titles: titles)
            })
        }

        // Projekt-Ansicht: 4 aktiv, Chat 2 fällt weg (der Befund des Users).
        fixtures.append(Fixture(name: "raster-projekt-4-auf-3", size: size) {
            let (store, ids, titles) = gridStore(count: 4)
            let projectID = UUID()
            _ = store.activateProjectGridWorkspace(
                projectID: projectID, name: "P", colorHex: "#3E8E63",
                activeSessionIDs: Set(ids), in: store.primaryWindowID
            )
            store.syncActiveProjectGridWorkspaces(activeSessionIDsByProject: [
                projectID: [ids[0], ids[2], ids[3]]
            ])
            let entity = store.gridWorkspaces.first { $0.sourceProjectID == projectID }!
            return gridView(entity, titles: titles)
        })

        // Projekt-Ansicht mit nur einem aktiven Chat.
        fixtures.append(Fixture(name: "raster-projekt-1", size: size) {
            let (store, ids, titles) = gridStore(count: 1)
            let projectID = UUID()
            _ = store.activateProjectGridWorkspace(
                projectID: projectID, name: "P", colorHex: "#3E8E63",
                activeSessionIDs: Set(ids), in: store.primaryWindowID
            )
            let entity = store.gridWorkspaces.first { $0.sourceProjectID == projectID }!
            return gridView(entity, titles: titles)
        })

        // Stufenwähler im Raster-Kopf: 4er-Workspace auf mittlerer Fläche
        // (3×3 passt nicht und fehlt).
        fixtures.append(Fixture(name: "raster-stufenwaehler", size: CGSize(width: 420, height: 60)) {
            let box = GridAreaSizeBox()
            box.update(CGSize(width: 900, height: 500))
            return AnyView(
                GridCapacityPicker(entity: AgentGridWorkspace(capacity: 4), area: box) { _ in }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AgentTheme.background)
            )
        })

        // Leerer eigener Workspace (gerade per ＋ angelegt).
        fixtures.append(Fixture(name: "raster-workspace-leer", size: size) {
            let (store, _, titles) = gridStore(count: 0)
            let id = store.createGridWorkspace(name: "G")
            return gridView(store.gridWorkspace(id: id)!, titles: titles)
        })
        return fixtures
    }
}
