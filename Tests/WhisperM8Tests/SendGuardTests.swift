import Foundation
import XCTest
@testable import WhisperM8

/// Wiedervorlage-Schutz der Send-Pipeline (Vorfall 2026-08-17: die
/// Claude-CLI legt nach ESC-Abbruch den zugestellten Prompt in den
/// Composer zurück; ein versehentliches Enter würde einen zurückgezogenen
/// Auftrag erneut absenden). Token-Store + pure Guard-Entscheidung +
/// Settings-Verdrahtung.
final class SendGuardTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("send-tokens-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var store: SendDeliveryTokenStore { SendDeliveryTokenStore(directory: directory) }

    // MARK: - Token-Store

    func testStageThenConsumeAuthorizesExactlyOnce() {
        let prompt = "[via whisperm8 chats · von test · 01:00]\nMach X."
        store.stage(promptText: prompt)
        XCTAssertTrue(store.consume(promptText: prompt), "Erst-Submit ist autorisiert")
        XCTAssertFalse(store.consume(promptText: prompt),
                       "Wiedervorlage desselben Texts hat kein Token mehr — der Kern des Schutzes")
    }

    func testConsumeRequiresMatchingText() {
        store.stage(promptText: "Auftrag A")
        XCTAssertFalse(store.consume(promptText: "Auftrag B"))
        XCTAssertTrue(store.consume(promptText: "Auftrag A"), "fremder Text konsumiert nichts")
    }

    func testConsumeToleratesEdgeWhitespaceTrimming() {
        // Die TUI kann Rand-Whitespace des Pastes trimmen, bevor der Hook
        // den Prompt sieht — die Normalisierung muss das abfedern.
        store.stage(promptText: "Auftrag A\n")
        XCTAssertTrue(store.consume(promptText: "Auftrag A"))
    }

    func testExpiredTokenDoesNotAuthorize() {
        let old = Date(timeIntervalSinceNow: -(SendDeliveryTokenStore.timeToLive + 60))
        store.stage(promptText: "Auftrag A", now: old)
        XCTAssertFalse(store.consume(promptText: "Auftrag A"),
                       "abgelaufene Tokens autorisieren nicht")
    }

    func testSamePromptToTwoTargetsYieldsTwoAuthorizations() {
        // Gleicher Prompt an zwei Sessions = zwei Tokens mit gleichem Hash;
        // beide Submissions müssen durchkommen.
        store.stage(promptText: "Auftrag A")
        store.stage(promptText: "Auftrag A")
        XCTAssertTrue(store.consume(promptText: "Auftrag A"))
        XCTAssertTrue(store.consume(promptText: "Auftrag A"))
        XCTAssertFalse(store.consume(promptText: "Auftrag A"))
    }

    func testStagePurgesExpiredTokens() throws {
        let old = Date(timeIntervalSinceNow: -(SendDeliveryTokenStore.timeToLive + 60))
        store.stage(promptText: "alt", now: old)
        store.stage(promptText: "neu")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1, "abgelaufene Tokens werden beim Schreiben weggeräumt")
    }

    func testConsumeOnMissingDirectoryIsFalseNotCrash() {
        XCTAssertFalse(store.consume(promptText: "irgendwas"))
    }

    // MARK: - Guard-Entscheidung (pur)

    func testNonMarkerPromptPassesWithoutTokenLookup() {
        var lookups = 0
        let verdict = ChatsPromptGuard.decide(prompt: "normale User-Eingabe") { _ in
            lookups += 1
            return false
        }
        XCTAssertEqual(verdict, .allow)
        XCTAssertEqual(lookups, 0,
                       "menschliche Prompts dürfen keinen Dateisystem-Lookup kosten")
    }

    func testMarkerPromptWithFreshTokenIsAllowed() {
        let prompt = "[via whisperm8 chats · von jarvis · 01:00]\nMach X."
        let verdict = ChatsPromptGuard.decide(prompt: prompt) { _ in true }
        XCTAssertEqual(verdict, .allow)
    }

    func testMarkerPromptWithoutTokenIsBlockedWithActionableReason() {
        let prompt = "[via whisperm8 chats · von jarvis · 01:00]\nMach X."
        let verdict = ChatsPromptGuard.decide(prompt: prompt) { _ in false }
        guard case .block(let reason) = verdict else {
            return XCTFail("Wiedervorlage ohne Token muss blocken")
        }
        XCTAssertTrue(reason.contains("chats send"),
                      "die Meldung muss den legitimen Ausweg nennen")
    }

    func testMarkerDetectionSurvivesLeadingWhitespace() {
        let prompt = "\n [via whisperm8 chats · von jarvis · 01:00]\nMach X."
        XCTAssertEqual(ChatsPromptGuard.decide(prompt: prompt) { _ in false },
                       .block(reason: blockReason(for: prompt)))
    }

    private func blockReason(for prompt: String) -> String {
        guard case .block(let reason) = ChatsPromptGuard.decide(prompt: prompt, consumeToken: { _ in false })
        else { return "" }
        return reason
    }

    // MARK: - Kopplung an markedPrompt

    func testMarkedPromptStartsWithGuardMarkerPrefix() {
        let marked = AgentControlRequestHandler.markedPrompt("Mach X.", actor: "test/chat")
        XCTAssertTrue(marked.hasPrefix(ChatsPromptGuard.markerPrefix),
                      "Guard und Marker müssen dieselbe Präfix-Quelle teilen")
        XCTAssertTrue(marked.contains("]\nMach X."), "Prompt folgt nach der Markerzeile")
    }

    // MARK: - Settings-Verdrahtung

    func testBuilderAddsGuardAsSecondUserPromptSubmitEntry() throws {
        let settings = ClaudeHookSettingsBuilder.makeSettings(
            eventFilePath: "/tmp/events.jsonl",
            promptGuardCommand: "\"/Applications/WhisperM8.app/Contents/MacOS/WhisperM8\" chats _prompt-guard"
        )
        let hooks = settings["hooks"] as? [String: Any]
        let entries = hooks?["UserPromptSubmit"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 2,
                       "Append-Tracking bleibt Eintrag 1, der Guard kommt additiv dazu")
        let guardHooks = entries?.last?["hooks"] as? [[String: Any]]
        XCTAssertEqual(guardHooks?.first?["command"] as? String,
                       "\"/Applications/WhisperM8.app/Contents/MacOS/WhisperM8\" chats _prompt-guard")
        // Alle anderen Events behalten genau einen Eintrag.
        for name in ClaudeHookSettingsBuilder.trackedEventNames where name != "UserPromptSubmit" {
            XCTAssertEqual((hooks?[name] as? [[String: Any]])?.count, 1, name)
        }
    }

    func testBuilderWithoutGuardKeepsSingleEntries() {
        let settings = ClaudeHookSettingsBuilder.makeSettings(eventFilePath: "/tmp/events.jsonl")
        let hooks = settings["hooks"] as? [String: Any]
        XCTAssertEqual((hooks?["UserPromptSubmit"] as? [[String: Any]])?.count, 1,
                       "Kill-Switch aus = Settings wie bisher")
    }

    func testPromptGuardCommandEscapesQuotesInExecutablePath() {
        let command = ClaudeHookSettingsBuilder.promptGuardCommand(
            executablePath: "/Apps/Whis\"per.app/MacOS/WhisperM8")
        XCTAssertTrue(command.contains("\\\""), "Quotes im Pfad müssen escaped sein")
        XCTAssertTrue(command.hasSuffix(" chats _prompt-guard"))
    }
}
