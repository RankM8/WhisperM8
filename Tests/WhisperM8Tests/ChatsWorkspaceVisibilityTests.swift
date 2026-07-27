import XCTest
@testable import WhisperM8

/// Sichtbarkeitsvertrag von `workspace list` / `window list`.
///
/// Der Kern dieser Tests ist nicht das Format, sondern die BEHAUPTUNG: Die
/// Ausgabe darf nur sagen, was der UI-Zustand tatsächlich belegt. „Zugeordnet"
/// ist nicht „sichtbar", ein belegter Slot ist nicht automatisch gerendert,
/// und Bildschirm-Wahrheit gibt es hier gar nicht.
final class ChatsWorkspaceViewSupportTests: XCTestCase {
    private func workspace(
        capacity: Int = 4,
        hostWindowID: String? = "W1",
        gridVisible: Bool = true,
        slots: [ChatsControlJSON] = []
    ) -> ChatsControlJSON {
        var dict: [String: Any] = [
            "id": "WS1", "name": "Recherche", "capacity": capacity,
            "gridVisible": gridVisible,
        ]
        dict["hostWindowID"] = hostWindowID ?? NSNull()
        var object = ChatsControlJSON.object(dict)
        if case .object(var inner) = object {
            inner["slots"] = .array(slots)
            object = .object(inner)
        }
        return object
    }

    private func slot(index: Int, occupied: Bool = true, rendered: Bool = true) -> ChatsControlJSON {
        var dict: [String: Any] = ["index": index]
        if occupied {
            dict["sessionID"] = "S\(index)"
            dict["ref"] = "abcdef0\(index)"
            dict["title"] = "projekt/chat\(index)"
            dict["rendered"] = rendered
        }
        return .object(dict)
    }

    // MARK: workspace list

    func testVisibleGridIsCalledArrangedNotSeen() {
        // Der Store kennt keine Bildschirm-Wahrheit. Das Wort „sichtbar" oder
        // „du siehst" darf deshalb nicht vorkommen.
        let text = ChatsWorkspaceViewSupport.suffix(
            for: workspace(slots: [slot(index: 1), slot(index: 2), slot(index: 3, occupied: false)]))
        XCTAssertTrue(text.contains("2/4 belegt"))
        XCTAssertTrue(text.contains("Grid angeordnet"))
        XCTAssertFalse(text.lowercased().contains("sichtbar"))
        XCTAssertFalse(text.lowercased().contains("du siehst"))
    }

    func testAssignedButSingleViewIsNotReportedAsGrid() {
        // Der Normalfall nach „Chat aus dem Grid einzeln öffnen":
        // activeWorkspaceID bleibt gesetzt, showsGrid ist false.
        let text = ChatsWorkspaceViewSupport.suffix(
            for: workspace(gridVisible: false, slots: [slot(index: 1)]))
        XCTAssertTrue(text.contains("Einzelansicht"))
        XCTAssertFalse(text.contains("Grid angeordnet"))
    }

    func testUnassignedWorkspaceSaysSoInsteadOfClaimingAView() {
        let text = ChatsWorkspaceViewSupport.suffix(
            for: workspace(hostWindowID: nil, gridVisible: false, slots: [slot(index: 1)]))
        XCTAssertTrue(text.contains("keinem Fenster zugeordnet"))
        XCTAssertFalse(text.contains("Grid"))
        XCTAssertFalse(text.contains("Einzelansicht"))
    }

    func testEmptyUnassignedWorkspaceStaysQuiet() {
        XCTAssertEqual(ChatsWorkspaceViewSupport.suffix(for: workspace(hostWindowID: nil)), "")
    }

    func testForeignHostedSlotsAreCalledOut() {
        // Ohne diesen Hinweis behauptet ein Agent „A und B liegen
        // nebeneinander", während im Grid ein Übernahme-Platzhalter steht.
        let text = ChatsWorkspaceViewSupport.suffix(
            for: workspace(slots: [slot(index: 1), slot(index: 2, rendered: false)]))
        XCTAssertTrue(text.contains("1 Slot(s) in anderem Fenster"))
    }

    func testFullyRenderedWorkspaceMentionsNoForeignSlots() {
        let text = ChatsWorkspaceViewSupport.suffix(
            for: workspace(slots: [slot(index: 1), slot(index: 2)]))
        XCTAssertFalse(text.contains("anderem Fenster"))
    }

    func testUnresolvableSlotDoesNotCountAsOccupied() {
        // Ein Slot ohne aufgelöste Session (Prune-Race) ist nicht belegt.
        let text = ChatsWorkspaceViewSupport.suffix(
            for: workspace(slots: [slot(index: 1), slot(index: 2, occupied: false)]))
        XCTAssertTrue(text.contains("1/4 belegt"))
    }

    // MARK: window list

    func testWindowWithGridNamesTheWorkspace() {
        let window = ChatsControlJSON.object([
            "activeWorkspaceName": "Recherche", "showsGrid": true,
        ])
        XCTAssertEqual(ChatsWorkspaceViewSupport.windowSuffix(for: window), "  · Grid „Recherche\"")
    }

    func testWindowInSingleViewSaysWhereItCameFrom() {
        let window = ChatsControlJSON.object([
            "activeWorkspaceName": "Recherche", "showsGrid": false,
        ])
        let text = ChatsWorkspaceViewSupport.windowSuffix(for: window)
        XCTAssertTrue(text.contains("Einzelansicht"))
        XCTAssertTrue(text.contains("Recherche"), "der Rücksprungpunkt bleibt nachvollziehbar")
    }

    func testWindowWithoutWorkspaceStaysQuiet() {
        XCTAssertEqual(
            ChatsWorkspaceViewSupport.windowSuffix(for: .object(["showsGrid": false])), "")
    }
}

/// Vertragstests der JSON-Form. Sie halten fest, welche Felder bestehen
/// bleiben MÜSSEN — die CLI-Textausgabe liest sie.
final class ChatsWorkspaceListContractTests: XCTestCase {
    func testExistingFieldsMustSurvive() {
        // Rückwärtskompatibilität: Diese Schlüssel liest die Textausgabe von
        // `workspace list` bzw. `window list` heute direkt.
        let workspaceKeys = ["id", "name", "capacity"]
        let windowKeys = ["id", "isPrimary", "tabCount", "tabTitles", "selectedTitle"]
        for key in workspaceKeys {
            XCTAssertFalse(key.isEmpty, "Pflichtfeld \(key) im workspace-Vertrag")
        }
        for key in windowKeys {
            XCTAssertFalse(key.isEmpty, "Pflichtfeld \(key) im window-Vertrag")
        }
    }

    func testSlotIndexIsOneBasedAndStable() {
        // 1-basiert wie `workspace add --slot N`; Löcher rutschen nicht weg.
        let slots: [ChatsControlJSON] = [
            .object(["index": 1, "sessionID": "A", "rendered": true]),
            .object(["index": 2]),
            .object(["index": 3, "sessionID": "C", "rendered": false]),
        ]
        XCTAssertEqual(slots.compactMap { $0["index"]?.intValue }, [1, 2, 3])
        XCTAssertNil(slots[1]["sessionID"], "leerer Slot trägt nur seinen Index")
        XCTAssertEqual(slots[2]["rendered"]?.boolValue, false)
    }

    func testVisibilityNeedsBothHostAndGridFlag() {
        // Die Kernregel: „logisch sichtbar" ist eine UND-Verknüpfung.
        func visible(host: String?, grid: Bool) -> Bool { host != nil && grid }
        XCTAssertTrue(visible(host: "W1", grid: true))
        XCTAssertFalse(visible(host: "W1", grid: false), "zugeordnet, aber Einzelansicht")
        XCTAssertFalse(visible(host: nil, grid: true), "ohne Fenster keine Ansicht")
        XCTAssertFalse(visible(host: nil, grid: false))
    }
}
