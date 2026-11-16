import Foundation
import XCTest
@testable import WhisperM8

/// WM8-101: Tab-Leiste und Auswahl schlagen Chats über einen Index nach,
/// statt je Tab ein Dictionary über alle Chats zu bauen oder linear zu suchen.
/// Profil eines Chatwechsels (15.11.2026): `headerTabs`, das Kopieren von
/// `AgentChatSession` und `first(where:)` waren der größte eigene Posten im
/// Fensterbody. Die neuen Varianten müssen dasselbe liefern wie die alten.
final class TabLookupIndexTests: XCTestCase {
    private let projectID = UUID()

    private func chats(_ count: Int, archivedEvery: Int = 0) -> [AgentChatSession] {
        (0..<count).map { index in
            var session = AgentChatSession(provider: .claude, projectID: projectID, title: "WM8-\(index)")
            if archivedEvery > 0, index % archivedEvery == 0 { session.status = .archived }
            return session
        }
    }

    private func lookup(_ sessions: [AgentChatSession]) -> (UUID) -> AgentChatSession? {
        let index = AgentWorkspaceUIModel.index(of: sessions)
        return { index[$0].map { sessions[$0] } }
    }

    // MARK: - Gleiches Ergebnis wie vorher

    func testHeaderTabsMatchTheOldWay() {
        let sessions = chats(200, archivedEvery: 7)
        var openTabs = stride(from: 0, to: 200, by: 9).map { sessions[$0].id }
        openTabs.insert(UUID(), at: 3)              // gelöschter Chat
        openTabs.append(openTabs[1])                // doppelt offen
        XCTAssertEqual(
            AgentTabOrder.headerTabs(openTabIDs: openTabs, lookup: lookup(sessions)).map(\.id),
            AgentTabOrder.headerTabs(openTabIDs: openTabs, sessions: sessions).map(\.id))
    }

    func testSelectionMatchesTheOldWay() {
        let sessions = chats(120, archivedEvery: 5)
        let openTabs = [sessions[10].id, sessions[3].id, UUID(), sessions[44].id]
        let cases: [UUID?] = [
            nil,
            sessions[3].id,        // offen, nicht archiviert
            sessions[0].id,        // archiviert → Rückfall auf den ersten offenen
            sessions[10].id,       // archiviert und offen
            UUID(),                // unbekannt
            sessions[77].id,       // nicht offen, nicht archiviert
        ]
        for selected in cases {
            XCTAssertEqual(
                AgentSelectionResolver.selected(lookup: lookup(sessions), selectedID: selected, openTabIDs: openTabs)?.id,
                AgentSelectionResolver.selected(sessions: sessions, selectedID: selected, openTabIDs: openTabs)?.id,
                "Auswahl \(String(describing: selected))")
        }
        XCTAssertNil(AgentSelectionResolver.selected(lookup: lookup(sessions), selectedID: nil, openTabIDs: []))
    }

    // MARK: - Der Index

    func testIndexKeepsTheFirstPositionOfADuplicate() {
        var sessions = chats(3)
        sessions.append(sessions[1])
        let index = AgentWorkspaceUIModel.index(of: sessions)
        XCTAssertEqual(index[sessions[1].id], 1)
        XCTAssertEqual(index.count, 3)
    }

    func testSameIDsIgnoresFieldChanges() {
        let sessions = chats(30)
        var renamed = sessions
        renamed[3].title = "umbenannt"
        renamed[4].status = .archived
        XCTAssertTrue(AgentWorkspaceUIModel.sameIDs(sessions, renamed))
        var moved = sessions
        moved.swapAt(0, 1)
        XCTAssertFalse(AgentWorkspaceUIModel.sameIDs(sessions, moved))
        XCTAssertFalse(AgentWorkspaceUIModel.sameIDs(sessions, Array(sessions.dropLast())))
    }

    // MARK: - Am echten Modell (Auflage Noa)

    /// Nach jedem Schritt liefert `session(id:)` für jede ID genau den Chat mit
    /// dieser ID: anlegen, löschen, vertauschen, umbenennen, archivieren.
    @MainActor
    func testModelLookupStaysRightThroughMutations() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let model = AgentWorkspaceUIModel(store: AgentWorkspaceStoreRegistry.store(for: url))
        let projectPath = try makeTempProjectDirectory().path

        func assertLookups(_ step: String, line: UInt = #line) {
            let sessions = store.loadWorkspace().sessions
            XCTAssertEqual(model.workspace.sessions.map(\.id), sessions.map(\.id), "\(step): Modell folgt dem Store", line: line)
            for session in sessions {
                XCTAssertEqual(model.session(id: session.id)?.id, session.id, "\(step)", line: line)
                XCTAssertEqual(model.session(id: session.id)?.title, session.title, "\(step)", line: line)
            }
            XCTAssertNil(model.session(id: UUID()), "\(step): unbekannte ID", line: line)
        }

        let created = try (0..<5).map { try store.createSession(provider: .claude, projectPath: projectPath, title: "WM8-\($0)") }
        assertLookups("angelegt")

        try store.deleteSession(id: created[1].id)
        assertLookups("gelöscht")
        XCTAssertNil(model.session(id: created[1].id))

        var workspace = store.loadWorkspace()
        workspace.sessions.swapAt(0, workspace.sessions.count - 1)
        try store.saveWorkspace(workspace)
        assertLookups("vertauscht")

        try store.renameSession(id: created[2].id, title: "umbenannt")
        assertLookups("umbenannt")
        XCTAssertEqual(model.session(id: created[2].id)?.title, "umbenannt")

        try store.archiveSession(id: created[3].id)
        assertLookups("archiviert")
        XCTAssertEqual(model.session(id: created[3].id)?.status, .archived)
    }

    // MARK: - Messlauf

    /// Die Arbeit der Tab-Leiste je Auswertung: für jeden der 16 Tabs einmal
    /// `headerTabs` und `selectedSession`, wie vorher in `tabStripItemsContent`.
    /// Nur mit `WM8_PERF_BENCH=1`.
    func testTabStripLookupCost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WM8_PERF_BENCH"] == "1", "Messlauf: WM8_PERF_BENCH=1")
        let sessions = chats(5_913, archivedEvery: 3)
        let openTabs = stride(from: 1, to: 5_913, by: 370).map { sessions[$0].id }.filter { _ in true }
        XCTAssertEqual(openTabs.count, 16)
        let selected = openTabs[5]
        let clock = ContinuousClock()
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }

        var old: [Double] = []
        var new: [Double] = []
        for _ in 0..<15 {
            old.append(ms(clock.measure {
                for _ in openTabs {
                    _ = AgentTabOrder.headerTabs(openTabIDs: openTabs, sessions: sessions)
                    _ = AgentSelectionResolver.selected(sessions: sessions, selectedID: selected, openTabIDs: openTabs)
                }
            }))
            new.append(ms(clock.measure {
                // Index einmal je Workspace-Änderung; hier jedes Mal mitgezählt.
                let find = lookup(sessions)
                let tabs = AgentTabOrder.headerTabs(openTabIDs: openTabs, lookup: find)
                let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let current = AgentSelectionResolver.selected(lookup: find, selectedID: selected, openTabIDs: openTabs)
                for id in openTabs { _ = (byID[id], current) }
            }))
        }
        let median = { (values: [Double]) in values.sorted()[values.count / 2] }
        let oldText = String(format: "%.1f", median(old))
        let newText = String(format: "%.1f", median(new))
        print("TAB_BENCH alt=\(oldText)ms neu=\(newText)ms (5.913 Chats, 16 Tabs, Index je Lauf neu gebaut)")

        // Was der Index selbst kostet: Neubau (nur bei geänderter ID-Folge)
        // und die Prüfung davor (bei jeder Workspace-Änderung).
        var build: [Double] = []
        var check: [Double] = []
        let other = sessions.map { $0 }
        for _ in 0..<15 {
            build.append(ms(clock.measure { _ = AgentWorkspaceUIModel.index(of: sessions) }))
            check.append(ms(clock.measure { _ = AgentWorkspaceUIModel.sameIDs(sessions, other) }))
        }
        let buildText = String(format: "%.2f", median(build))
        let checkText = String(format: "%.2f", median(check))
        print("TAB_BENCH index neubau=\(buildText)ms pruefung=\(checkText)ms (5.913 Chats)")
    }
}
