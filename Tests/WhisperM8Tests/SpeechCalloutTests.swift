import XCTest
@testable import WhisperM8

@MainActor
final class SpeechCalloutTests: XCTestCase {
    private final class FakeEngine: SpeechCalloutEngine {
        var onFinish: (() -> Void)?
        var spoken: [String] = []
        var stops = 0
        func speak(_ text: String) { spoken.append(text) }
        func stop() { stops += 1 }
        func finish() { onFinish?() }
    }

    private final class World {
        var now = Date(timeIntervalSince1970: 1_000)
        var blocked = false
        var muted = false
        var enabled = true
        var scheduled: [@MainActor () -> Void] = []

        @MainActor
        func runScheduled() {
            let actions = scheduled
            scheduled.removeAll()
            actions.forEach { $0() }
        }
    }

    private func makeCenter(_ world: World = World()) -> (SpeechCalloutCenter, FakeEngine, World) {
        let engine = FakeEngine()
        let center = SpeechCalloutCenter(engine: engine, dependencies: .init(
            isEnabled: { world.enabled },
            loadMuted: { world.muted },
            storeMuted: { world.muted = $0 },
            isBlocked: { world.blocked },
            now: { world.now },
            schedule: { _, action in world.scheduled.append(action) }
        ))
        return (center, engine, world)
    }

    private let jarvis = UUID()
    private let other = UUID()

    func testSpeaksImmediatelyWithChatNamePrefixed() {
        let (center, engine, _) = makeCenter()
        let outcome = center.enqueue(sessionID: jarvis, speaker: "Jarvis", text: "Der Outreach-Chat wartet.")
        XCTAssertEqual(outcome, .queued(position: 1))
        XCTAssertEqual(engine.spoken, ["Jarvis: Der Outreach-Chat wartet."])
    }

    func testNeverTwoAtOnce() {
        let (center, engine, _) = makeCenter()
        _ = center.enqueue(sessionID: jarvis, speaker: "Jarvis", text: "Eins.")
        XCTAssertEqual(center.enqueue(sessionID: other, speaker: "Outreach", text: "Zwei."), .queued(position: 2))
        XCTAssertEqual(engine.spoken.count, 1)
        engine.finish()
        XCTAssertEqual(engine.spoken, ["Jarvis: Eins.", "Outreach: Zwei."])
    }

    func testHoldsDuringRecordingAndSpeaksAfterwards() {
        let (center, engine, world) = makeCenter()
        world.blocked = true
        XCTAssertEqual(center.enqueue(sessionID: jarvis, speaker: nil, text: "Fertig."), .queued(position: 1))
        XCTAssertEqual(engine.spoken, [])
        world.runScheduled()
        XCTAssertEqual(engine.spoken, [], "läuft die Aufnahme noch, wartet die Ansage weiter")
        world.blocked = false
        world.runScheduled()
        XCTAssertEqual(engine.spoken, ["Fertig."])
    }

    func testRecordingStartInterruptsAndRepeatsFromStart() {
        let (center, engine, world) = makeCenter()
        _ = center.enqueue(sessionID: jarvis, speaker: "Jarvis", text: "Lange Ansage.")
        center.holdForRecording()
        world.blocked = true
        XCTAssertEqual(engine.stops, 1)
        XCTAssertNil(center.current)
        world.runScheduled()
        XCTAssertEqual(engine.spoken.count, 1)
        // Aufnahme vorbei, Schonfrist abgelaufen: dieselbe Ansage von vorn.
        world.blocked = false
        world.now = world.now.addingTimeInterval(SpeechCalloutCenter.recordingGrace + 0.1)
        world.runScheduled()
        XCTAssertEqual(engine.spoken, ["Jarvis: Lange Ansage.", "Jarvis: Lange Ansage."])
    }

    func testGraceAfterRecordingStartEvenBeforeIsRecording() {
        let (center, engine, world) = makeCenter()
        center.holdForRecording()
        _ = center.enqueue(sessionID: jarvis, speaker: nil, text: "Jetzt nicht.")
        XCTAssertEqual(engine.spoken, [])
        world.now = world.now.addingTimeInterval(SpeechCalloutCenter.recordingGrace + 0.1)
        world.runScheduled()
        XCTAssertEqual(engine.spoken, ["Jetzt nicht."])
    }

    func testDebouncePerSession() {
        let (center, engine, world) = makeCenter()
        _ = center.enqueue(sessionID: jarvis, speaker: nil, text: "Eins.")
        engine.finish()
        world.now = world.now.addingTimeInterval(5)
        XCTAssertEqual(center.enqueue(sessionID: jarvis, speaker: nil, text: "Zwei."), .debounced(retryAfterSeconds: 15))
        // Andere Session ist nicht betroffen.
        XCTAssertEqual(center.enqueue(sessionID: other, speaker: nil, text: "Drei."), .queued(position: 1))
        world.now = world.now.addingTimeInterval(SpeechCalloutCenter.debounceInterval)
        engine.finish()
        XCTAssertEqual(center.enqueue(sessionID: jarvis, speaker: nil, text: "Vier."), .queued(position: 1))
        XCTAssertEqual(engine.spoken, ["Eins.", "Drei.", "Vier."])
    }

    func testWaitingCalloutOfSameSessionIsReplaced() {
        let (center, engine, _) = makeCenter()
        _ = center.enqueue(sessionID: other, speaker: nil, text: "Spricht gerade.")
        _ = center.enqueue(sessionID: jarvis, speaker: nil, text: "Alt.")
        XCTAssertEqual(center.enqueue(sessionID: jarvis, speaker: nil, text: "Neu."), .replaced(position: 2))
        engine.finish()
        XCTAssertEqual(engine.spoken, ["Spricht gerade.", "Neu."])
    }

    func testMuteRejectsAndStopsCurrent() {
        let (center, engine, world) = makeCenter()
        _ = center.enqueue(sessionID: jarvis, speaker: nil, text: "Eins.")
        _ = center.enqueue(sessionID: other, speaker: nil, text: "Zwei.")
        center.setMuted(true)
        XCTAssertTrue(world.muted, "Stumm überlebt den Neustart")
        XCTAssertEqual(engine.stops, 1)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.enqueue(sessionID: UUID(), speaker: nil, text: "Drei."), .muted)
        XCTAssertEqual(engine.spoken, ["Eins."])
    }

    func testMutedStateLoadsFromPreferences() {
        let world = World()
        world.muted = true
        let (center, _, _) = makeCenter(world)
        XCTAssertTrue(center.isMuted)
    }

    func testEmptyTextIsRejected() {
        let (center, engine, _) = makeCenter()
        XCTAssertEqual(center.enqueue(sessionID: jarvis, speaker: "Jarvis", text: "  `**`  \n"), .empty)
        XCTAssertEqual(engine.spoken, [])
    }

    // MARK: Textregeln

    func testCleanStripsMarkdownAndNewlines() {
        XCTAssertEqual(SpeechCalloutText.clean("**Fertig.**\n\n`make test` ist grün."), "Fertig. make test ist grün.")
    }

    func testCleanClipsAtSentenceEnd() {
        let first = String(repeating: "a", count: 200) + "."
        let text = first + " " + String(repeating: "b ", count: 100)
        XCTAssertEqual(SpeechCalloutText.clean(text), first)
    }

    func testCleanClipsAtWordWithoutSentenceEnd() {
        let text = String(repeating: "wort ", count: 100)
        let cleaned = SpeechCalloutText.clean(text)
        XCTAssertLessThanOrEqual(cleaned.count, SpeechCalloutText.maxCharacters + 2)
        XCTAssertTrue(cleaned.hasSuffix("wort …"))
    }

    func testSpokenNameUsesPartBeforeColon() {
        XCTAssertEqual(SpeechCalloutText.spokenName(fromTitle: "Jarvis: Supervisor ListM8"), "Jarvis")
        XCTAssertEqual(SpeechCalloutText.spokenName(fromTitle: "Outreach Copy-Review"), "Outreach Copy-Review")
        XCTAssertEqual(SpeechCalloutText.spokenName(fromTitle: "Ab: kurzer Präfix bleibt ganz"), "Ab: kurzer Präfix")
        XCTAssertEqual(SpeechCalloutText.spokenName(fromTitle: "Eins zwei drei vier fünf"), "Eins zwei drei")
        XCTAssertNil(SpeechCalloutText.spokenName(fromTitle: "  "))
    }

    func testVoiceRankingPrefersQualityThenAnnaNeverEloquence() {
        typealias Voice = (String, String, Int)
        func best(_ voices: [Voice]) -> String? {
            voices.max { SystemSpeechCalloutEngine.precedes(lhs: $0, rhs: $1) }?.0
        }
        let standard = 1, enhanced = 2, premium = 3
        let fresh: [Voice] = [
            ("com.apple.eloquence.de-DE.Grandpa", "de-DE", standard),
            ("com.apple.voice.compact.de-DE.Anna", "de-DE", standard),
            ("com.apple.eloquence.de-DE.Rocko", "de-DE", standard),
        ]
        XCTAssertEqual(best(fresh), "com.apple.voice.compact.de-DE.Anna")
        XCTAssertEqual(best(fresh + [("com.apple.voice.enhanced.de-DE.Petra", "de-DE", enhanced)]),
                       "com.apple.voice.enhanced.de-DE.Petra")
        XCTAssertEqual(best(fresh + [("com.apple.voice.premium.de-DE.Anna", "de-DE", premium),
                                      ("com.apple.voice.premium.de-CH.Petra", "de-CH", premium)]),
                       "com.apple.voice.premium.de-DE.Anna")
    }

    // MARK: CLI

    func testSpeakArguments() throws {
        XCTAssertEqual(try SpeakCLIArguments.parse(["Der", "Chat", "wartet."]), .speak(text: "Der Chat wartet."))
        XCTAssertEqual(try SpeakCLIArguments.parse(["-"]), .speak(text: nil))
        XCTAssertEqual(try SpeakCLIArguments.parse(["--help"]), .help)
        XCTAssertThrowsError(try SpeakCLIArguments.parse([]))
        XCTAssertThrowsError(try SpeakCLIArguments.parse(["--from", "x"]))
        XCTAssertTrue(CLIModeDetector.shouldRunCLI(["/x/WhisperM8", "speak", "hallo"]))
    }

    func testOutcomeJSONForTheMod() {
        XCTAssertEqual(SpeechCalloutOutcome.queued(position: 2).json["status"] as? String, "queued")
        XCTAssertEqual(SpeechCalloutOutcome.queued(position: 2).json["position"] as? Int, 2)
        XCTAssertEqual(SpeechCalloutOutcome.muted.json["status"] as? String, "muted")
        XCTAssertEqual(SpeechCalloutOutcome.debounced(retryAfterSeconds: 7).json["retryAfterSeconds"] as? Int, 7)
    }
}
