import XCTest
@testable import WhisperM8

/// WM8-121, der Ablauf aus dem Befund über die echten Bausteine
/// (`QueueFlowFixture`). Eingefügt wird über `noteComposerTextInserted`
/// (dieselbe Schätzung wie beim Einfügen ohne Enter), abgeschickt über
/// `submitComposer` (`chats submit`).
@MainActor
final class InsertedTextQueueFlowTests: XCTestCase {
    private var f: QueueFlowFixture!
    private var controller: AgentTerminalController { f.controller }

    override func setUpWithError() throws {
        f = try QueueFlowFixture()
    }

    override func tearDown() {
        f?.tearDown()
    }

    // MARK: Text darf nicht hinaus

    func testInsertedTextHoldsTheQueueAfterTheChatsOwnTurnWhileScrolledUp() throws {
        XCTAssertTrue(controller.isRunning)
        f.drawClaude(fieldText: "Triage: WM8-12 schließen, WM8-13 zurückstellen")
        controller.noteComposerTextInserted()   // „→ Jarvis“ / Diktat ohne Senden
        XCTAssertEqual(f.queueDecision(), .draftPending)

        let before = f.deliveries.count
        f.ownTurn()
        XCTAssertEqual(f.deliveries.count, before + 1, "das Turn-Ende stößt die Warteschlange an")
        XCTAssertEqual(f.status, .idle)

        // Ganz unten fängt auch die Bildschirmprüfung den Text ab.
        XCTAssertEqual(f.queueDecision(), .draftPending)
        XCTAssertTrue(PromptSubmitCheck.visibleDraft(
            field: controller.controllerScreenSnapshot()?.promptField, profile: .claudeCodeChat,
            clearsBeforeSubmit: false), "Gegenprobe: der Bildschirm ist richtig nachgebaut")
        // Hochgescrollt hält der Vermerk; seit WM8-123 sieht auch der Leser den Text.
        f.scrollUp()
        XCTAssertTrue(controller.isScrolledBack)
        XCTAssertNil(controller.controllerScreenSnapshot())
        XCTAssertEqual(f.queueDecision(), .draftPending, "vorher: .deliver, und die Meldung hing am Text")
        XCTAssertEqual(AgentPromptQueueDelivery.draftPendingError(controller.composerDraft),
                       AgentPromptQueueDelivery.insertedTextError)
    }

    // MARK: Die Schlange darf nicht verstopfen

    func testSubmittedTextDoesNotHoldTheQueueAfterTheTurn() throws {
        f.drawClaude(fieldText: "Weiter mit WM8-12")
        controller.noteComposerTextInserted()
        controller.submitComposer()            // abgeschickt
        f.drawClaude(fieldText: "")
        f.ownTurn()
        f.scrollUp()
        XCTAssertNil(controller.controllerScreenSnapshot())
        XCTAssertEqual(f.queueDecision(), .deliver, "stellt zu wie bisher")
    }

    /// Weg ins Freie, wenn der Vermerk falsch stehen bleibt (Text mit der
    /// Rücktaste gelöscht): Sobald das Terminal unten steht und das Feld leer
    /// ist, geht die Meldung beim nächsten Versuch raus.
    func testEmptyFieldAtTheBottomReleasesAStaleMark() throws {
        f.drawClaude(fieldText: "Triage: WM8-12 schließen")
        controller.noteComposerTextInserted()
        f.ownTurn()
        f.drawClaude(fieldText: "")              // per Rücktaste geleert
        f.scrollUp()
        XCTAssertEqual(f.queueDecision(), .draftPending, "hochgescrollt gibt ein leeres Feld nichts frei")
        f.scrollToBottom()
        XCTAssertFalse(controller.isScrolledBack)
        XCTAssertEqual(f.queueDecision(), .deliver)
    }

    /// Zurückgehaltenes Enter (WM8-75): Der Text bleibt eingefügt, auch nach
    /// dem Turn, der auf die beantwortete Freigabe folgt. `submit` lehnt ab
    /// und nennt den Ausweg; die Warteschlange hängt nichts an.
    func testWithheldEnterStaysInsertedAndSubmitSaysSo() throws {
        f.drawClaude(fieldText: "Auftrag von Jarvis")
        controller.noteComposerTextInserted()   // wie `delayedEnterAllowed` beim Zurückhalten
        f.ownTurn()                             // Freigabe beantwortet, Claude arbeitet und ruht wieder
        let decision = AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: f.status,
            approvalPending: false, userDraft: controller.composerDraft.mayHaveUnsentInput,
            insertedText: controller.composerDraft.mayHoldInsertedText,
            field: controller.controllerScreenSnapshot()?.promptField, screenReadable: true)
        XCTAssertEqual(decision, .refused(.conflict, AgentControlRequestHandler.submitRefusedInsertedMessage))
        XCTAssertEqual(f.queueDecision(), .draftPending)
    }

    func testControlCReleasesInsertedText() throws {
        f.drawClaude(fieldText: "Triage: WM8-12 schließen")
        controller.noteComposerTextInserted()
        f.ownTurn()
        controller.noteComposerCleared()       // Feld geleert (Controller R3 halten)
        f.drawClaude(fieldText: "")
        f.scrollUp()
        XCTAssertEqual(f.queueDecision(), .deliver)
    }
}
