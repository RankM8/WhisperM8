import XCTest
@testable import WhisperM8

/// WM8-123, letzter Rest: `chats submit` schickt einen Auftrag mit
/// zurückgehaltenem Enter nur ab, wenn das abgelesene Feld genau diesem
/// Auftrag entspricht. Tippt jemand direkt nach einer Freigabe eine Ziffer, ein
/// y oder ein n, bevor der Status nachzieht, zählt der Tracker das noch als
/// Dialog-Antwort; am Feld fällt es auf.
final class WithheldFieldMatchTests: XCTestCase {
    private let text = "[via whisperm8 chats · von Test · 12:00] WM8-Doku prüfen"

    private func submit(fieldText: String?, withheldText: String?) -> AgentControlRequestHandler.SubmitDecision {
        AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: .idle, approvalPending: false,
            userDraft: true, insertedText: true, withheldDelivery: true, withheldText: withheldText,
            field: fieldText.flatMap { InsertedTextScreen.field(text: $0) }, screenReadable: true)
    }

    // MARK: - Über `submitCheck`, mit echtem Terminal und echter Ablesung

    func testSameTextIsSent() {
        XCTAssertEqual(InsertedTextScreen.field(text: text)?.hasText, true)
        XCTAssertEqual(submit(fieldText: text, withheldText: text), .allowed)
    }

    /// Der Fall aus dem Ticket: Nach der Freigabe sofort „1“ getippt, der
    /// Status meldete noch „wartet“, die Ziffer stand aber schon im Feld.
    func testAppendedDigitIsRefused() {
        for typed in ["1", "y", "n", "12"] {
            XCTAssertEqual(submit(fieldText: text + typed, withheldText: text),
                           .refused(.conflict, AgentControlRequestHandler.submitRefusedFieldDiffersMessage), typed)
        }
        XCTAssertEqual(submit(fieldText: "y" + text, withheldText: text),
                       .refused(.conflict, AgentControlRequestHandler.submitRefusedFieldDiffersMessage), "davor")
    }

    func testPlaceholderOfALongPasteIsSent() {
        let long = (1...40).map { "Zeile \($0) für WM8-Doku" }.joined(separator: "\n")
        XCTAssertEqual(submit(fieldText: "[Pasted text #1 +39 lines]", withheldText: long), .allowed)
        XCTAssertEqual(submit(fieldText: "[Pasted text #2 +39 lines]1", withheldText: long),
                       .refused(.conflict, AgentControlRequestHandler.submitRefusedFieldDiffersMessage),
                       "Ziffer hinter dem Platzhalter")
    }

    /// Kein Feld zu sehen (Dialog, Ansicht, lädt): nichts abschicken.
    func testUnclearFieldIsRefused() {
        guard case .refused(.notReady, _) = submit(fieldText: nil, withheldText: text) else {
            return XCTFail("ohne abgelesenes Feld nie ein Enter")
        }
        // Ein Feld, in dem der Cursor nicht steht, gilt nicht als sicherer Text.
        let rule = InsertedTextScreen.rule
        let lines = [ControllerScreenLine.plain(rule), .plain("❯ " + text), .plain(rule)]
        let field = ControllerScreenReading.read(lines: lines, cursor: nil, detectViews: true).promptField
        XCTAssertEqual(field?.hasText, false)
        guard case .refused = AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: .idle, approvalPending: false, userDraft: true, insertedText: true,
            withheldDelivery: true, withheldText: text, field: field, screenReadable: true) else {
            return XCTFail("Feld unklar")
        }
    }

    /// Vermerk aus einem älteren Manifest ohne Text: kein Vergleich, kein Enter.
    func testUnknownTextIsRefused() {
        XCTAssertEqual(submit(fieldText: text, withheldText: nil),
                       .refused(.conflict, AgentControlRequestHandler.submitRefusedTextUnknownMessage))
    }

    /// Ohne Vermerk (Feld nach einem Enter stehengeblieben, `inInputField`)
    /// vergleicht `submit` nichts; das bleibt wie bisher.
    func testWithoutWithheldDeliveryNothingIsCompared() {
        let decision = AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: .idle, approvalPending: false, userDraft: false,
            field: InsertedTextScreen.field(text: text), screenReadable: true)
        XCTAssertEqual(decision, .allowed)
    }

    /// Claude bricht lange Aufträge um; die Ablesung verbindet die Zeilen.
    func testWrappedLongTextStillMatches() {
        let long = String(repeating: "WM8-Doku prüfen und Snapshot ansehen. ", count: 4)
        let field = InsertedTextScreen.field(text: long)
        XCTAssertGreaterThan(field?.rows ?? 0, 1, "Fixture bricht um")
        XCTAssertEqual(submit(fieldText: long, withheldText: long), .allowed)
        XCTAssertEqual(submit(fieldText: long + "2", withheldText: long),
                       .refused(.conflict, AgentControlRequestHandler.submitRefusedFieldDiffersMessage))
    }

    // MARK: - Der Vergleich selbst

    func testMultilineTextWithIndentedFollowLines() {
        XCTAssertEqual(WithheldFieldMatch.check(expected: "Erste Zeile\r\nZweite Zeile",
                                                fieldText: "Erste Zeile   Zweite Zeile  "), .matches)
        XCTAssertEqual(WithheldFieldMatch.check(expected: "Erste Zeile\nZweite Zeile",
                                                fieldText: "Erste Zeile │ │ Zweite Zeile │"), .matches,
                       "Rahmen des alten Felds")
    }

    /// Steuerzeichen entfernt das Einfügen; der Vergleich bereinigt genauso.
    func testExpectedTextIsSanitizedLikeThePaste() {
        XCTAssertEqual(WithheldFieldMatch.check(expected: "WM8\u{1B}[31m-Doku\u{07}", fieldText: "WM8-Doku"), .matches)
    }

    func testOnlyOnePlaceholderAndNothingElse() {
        XCTAssertEqual(WithheldFieldMatch.check(expected: "x", fieldText: "[Pasted text #3]"), .matches)
        XCTAssertEqual(WithheldFieldMatch.check(expected: "x", fieldText: "[Pasted text #1 +2 lines] [Pasted text #2 +5 lines]"),
                       .differs, "zweiter Paste")
        XCTAssertEqual(WithheldFieldMatch.check(expected: "x", fieldText: "n[Pasted text #1 +2 lines]"), .differs)
        XCTAssertEqual(WithheldFieldMatch.check(expected: "x", fieldText: "[Pasted text #1 +2 lines]y"), .differs)
    }

    func testEmptyOrMissingText() {
        XCTAssertEqual(WithheldFieldMatch.check(expected: nil, fieldText: "WM8"), .textUnknown)
        XCTAssertEqual(WithheldFieldMatch.check(expected: "", fieldText: "WM8"), .differs)
        XCTAssertEqual(WithheldFieldMatch.check(expected: "WM8", fieldText: "   "), .differs)
    }

    // MARK: - Ablesung und Vermerk

    func testReadingDeliversTheFieldText() {
        let field = InsertedTextScreen.field(text: text)
        XCTAssertEqual(field.map { WithheldFieldMatch.compact($0.text) }, WithheldFieldMatch.compact(text))
    }

    /// Der Zusammenhang der Leiste trägt den Text nicht: Er bliebe sonst nach
    /// jeder Textänderung „neu“ und läge im UI-Modell.
    func testControllerContextDropsTheText() {
        let field = InsertedTextScreen.field(text: text)
        XCTAssertEqual(field?.withoutText.text, "")
        XCTAssertEqual(field?.withoutText, InsertedTextScreen.field(text: text + "x")?.withoutText)
    }

    func testTrackerKeepsTheTextThroughClaimAndTurnStart() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordSubmitted(programmaticAt: Date())
        tracker.recordDeliveryWithheld(text: text)
        XCTAssertTrue(tracker.claimWithheldDelivery(queuedPromptID: nil))
        tracker.recordSubmittedByTurnStart()
        XCTAssertEqual(tracker.submittableWithheldDelivery?.text, text)
    }

    func testManifestCarriesTheText() throws {
        var manifest = HandoverManifest(chatID: "c", kind: "claude", pid: 7, cols: 100, rows: 30,
                                        sendsInterruptOnStop: true)
        manifest.composerWithheldDelivery = true
        manifest.composerWithheldText = text
        let decoded = try JSONDecoder().decode(HandoverManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(AgentTerminalController.withheldDelivery(from: decoded)?.text, text)
    }
}
