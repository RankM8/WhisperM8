import Foundation
import XCTest
@testable import WhisperM8

// ==============================================================================
// Voice Gate — reine Logik.
//
// Audio, Fokus und CGEvent bleiben manuelle QA; alles hier ist deterministisch
// und laeuft ohne Mikrofon.
// ==============================================================================

final class VoiceGateCommandMatcherTests: XCTestCase {
    /// Bewusst ein LANGES Traegerwort statt des Defaults: diese Tests pruefen
    /// die allgemeinen Regeln inklusive Fuzzy-Toleranz, und die greift erst ab
    /// `minCarrierLengthForFuzzyMatch`. Den Default deckt
    /// `VoiceGateDefaultVocabularyTests` ab.
    private let matcher: VoiceGateCommandMatcher = {
        var vocabulary = VoiceGateVocabulary.default
        vocabulary.carrier = "jarvis"
        return VoiceGateCommandMatcher(vocabulary: vocabulary)
    }()

    /// Segmente mit sauberer Aeusserungsgrenze davor.
    private func phrase(_ words: [String], leadingSilence: TimeInterval = 1.0, confidence: Float = 0.9) -> [VoiceGateSegment] {
        var segments: [VoiceGateSegment] = []
        var cursor = leadingSilence
        for word in words {
            segments.append(VoiceGateSegment(text: word, start: cursor, duration: 0.3, confidence: confidence))
            cursor += 0.35
        }
        return segments
    }

    func testMatchesMutePhrase() {
        let result = matcher.match(segments: phrase(["Jarvis", "Pause"]))
        guard case .matched(let intent, _, _) = result else {
            return XCTFail("erwartet: Treffer, bekommen: \(result)")
        }
        XCTAssertEqual(intent, .mute)
    }

    func testMatchesUnmutePhrase() {
        let result = matcher.match(segments: phrase(["Jarvis", "weiter"]))
        guard case .matched(let intent, _, _) = result else {
            return XCTFail("erwartet: Treffer, bekommen: \(result)")
        }
        XCTAssertEqual(intent, .unmute)
    }

    /// Der Erkenner verbiegt den Eigennamen gern — kleine Tippdistanz muss durch.
    func testToleratesRecognizerVariantsOfCarrier() {
        for variant in ["Jervis", "Jarvis,", "JARVIS"] {
            let result = matcher.match(segments: phrase([variant, "Pause"]))
            guard case .matched(let intent, _, _) = result else {
                return XCTFail("Variante \(variant) sollte greifen, bekommen: \(result)")
            }
            XCTAssertEqual(intent, .mute)
        }
    }

    /// Das Traegerwort allein darf nichts ausloesen — es faellt im Alltag
    /// beilaeufig („sei mein Jarvis").
    func testCarrierAloneDoesNotTrigger() {
        let result = matcher.match(segments: phrase(["Jarvis"]))
        XCTAssertEqual(result, .rejected(.noCommandAfterCarrier))
    }

    func testUnknownCommandAfterCarrierIsRejected() {
        let result = matcher.match(segments: phrase(["Jarvis", "Gutenberg"]))
        XCTAssertEqual(result, .rejected(.noCommandAfterCarrier))
    }

    /// Regression: „Wetter" liegt eine Editierdistanz von „weiter" entfernt,
    /// „Hause" eine von „Pause". Beides ist Alltagsdeutsch — Kommandowoerter
    /// muessen deshalb exakt sitzen.
    func testNearMissCommandWordsDoNotTrigger() {
        for nearMiss in ["Wetter", "Hause", "Pausen", "weite"] {
            XCTAssertEqual(
                matcher.match(segments: phrase(["Jarvis", nearMiss])),
                .rejected(.noCommandAfterCarrier),
                "\(nearMiss) darf nicht auslösen"
            )
        }
    }

    /// Mitten im Satz gesprochen — keine Stille davor, also kein Treffer.
    func testRejectsPhraseInsideRunningUtterance() {
        var segments = phrase(["ich", "sage"], leadingSilence: 1.0)
        let last = segments[segments.count - 1]
        segments.append(VoiceGateSegment(text: "Jarvis", start: last.end + 0.05, duration: 0.3, confidence: 0.9))
        segments.append(VoiceGateSegment(text: "Pause", start: last.end + 0.40, duration: 0.3, confidence: 0.9))

        XCTAssertEqual(matcher.match(segments: segments), .rejected(.noUtteranceBoundary))
    }

    func testRejectsCommandTooFarAfterCarrier() {
        let segments = [
            VoiceGateSegment(text: "Jarvis", start: 1.0, duration: 0.3, confidence: 0.9),
            VoiceGateSegment(text: "Pause", start: 5.0, duration: 0.3, confidence: 0.9)
        ]
        XCTAssertEqual(matcher.match(segments: segments), .rejected(.gapTooLarge))
    }

    func testRejectsLowConfidence() {
        let result = matcher.match(segments: phrase(["Jarvis", "Pause"], confidence: 0.1))
        XCTAssertEqual(result, .rejected(.lowConfidence))
    }

    /// Teilergebnisse liefern Konfidenz 0 — das darf nicht als „unsicher" gelten.
    func testZeroConfidencePartialResultsStillMatch() {
        let result = matcher.match(segments: phrase(["Jarvis", "Pause"], confidence: 0))
        guard case .matched = result else {
            return XCTFail("Teilergebnis ohne Konfidenz sollte greifen, bekommen: \(result)")
        }
    }

    func testNoCarrierIsReported() {
        XCTAssertEqual(matcher.match(segments: phrase(["Pause"])), .rejected(.noCarrier))
    }

    /// Bei mehreren Traegerwoertern zaehlt die juengste Aeusserung.
    func testUsesLastCarrierOccurrence() {
        var segments = phrase(["Jarvis", "Wetter"], leadingSilence: 1.0)
        let last = segments[segments.count - 1]
        segments.append(VoiceGateSegment(text: "Jarvis", start: last.end + 1.0, duration: 0.3, confidence: 0.9))
        segments.append(VoiceGateSegment(text: "weiter", start: last.end + 1.4, duration: 0.3, confidence: 0.9))

        guard case .matched(let intent, _, _) = matcher.match(segments: segments) else {
            return XCTFail("letzter Kandidat sollte greifen")
        }
        XCTAssertEqual(intent, .unmute)
    }
}

final class VoiceGateStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testPressesWhenStateMismatches() {
        var machine = VoiceGateStateMachine(assumed: .open)
        XCTAssertEqual(machine.handle(.mute, now: t0), .press(intent: .mute, reason: .stateMismatch))
    }

    func testUnknownStateAlwaysPresses() {
        var machine = VoiceGateStateMachine(assumed: .unknown)
        XCTAssertEqual(machine.handle(.unmute, now: t0), .press(intent: .unmute, reason: .unknownState))
    }

    func testSkipsWhenAlreadyInTargetState() {
        var machine = VoiceGateStateMachine(assumed: .muted)
        XCTAssertEqual(machine.handle(.mute, now: t0), .skip(.alreadyInTargetState))
    }

    /// Der Mensch widerspricht: dieselbe Phrase nochmal binnen weniger
    /// Sekunden ueberstimmt die Annahme.
    func testRepeatWithinWindowOverridesAssumedState() {
        var machine = VoiceGateStateMachine(assumed: .open)
        XCTAssertEqual(machine.handle(.unmute, now: t0), .skip(.alreadyInTargetState))
        XCTAssertEqual(
            machine.handle(.unmute, now: t0.addingTimeInterval(1.5)),
            .press(intent: .unmute, reason: .repeatOverride)
        )
    }

    func testRepeatOutsideWindowDoesNotOverride() {
        var machine = VoiceGateStateMachine(assumed: .open)
        _ = machine.handle(.unmute, now: t0)
        XCTAssertEqual(
            machine.handle(.unmute, now: t0.addingTimeInterval(30)),
            .skip(.alreadyInTargetState)
        )
    }

    func testCooldownBlocksImmediateSecondPress() {
        var machine = VoiceGateStateMachine(assumed: .open)
        _ = machine.handle(.mute, now: t0)
        machine.confirmPress(.mute, now: t0)

        XCTAssertEqual(machine.handle(.unmute, now: t0.addingTimeInterval(0.5)), .skip(.cooldown))
        XCTAssertEqual(
            machine.handle(.unmute, now: t0.addingTimeInterval(3.0)),
            .press(intent: .unmute, reason: .stateMismatch)
        )
    }

    func testConfirmPressAdoptsTargetState() {
        var machine = VoiceGateStateMachine(assumed: .open)
        machine.confirmPress(.mute, now: t0)
        XCTAssertEqual(machine.assumed, .muted)
    }

    /// Unbestaetigte Ausfuehrung: lieber ehrlich unbekannt als falsch sicher.
    func testFailedPressFallsBackToUnknown() {
        var machine = VoiceGateStateMachine(assumed: .open)
        machine.failPress(now: t0)
        XCTAssertEqual(machine.assumed, .unknown)
    }

    /// Passiver Abgleich: Codex empfaengt nachweislich Sprache ⇒ nicht stumm.
    func testObservingReceivedAudioCorrectsDrift() {
        var machine = VoiceGateStateMachine(assumed: .muted)
        machine.observeCodexReceivedAudio()
        XCTAssertEqual(machine.assumed, .open)
    }
}

final class CodexVoiceSessionGateTests: XCTestCase {
    private let gate = CodexVoiceSessionGate(maxSessionAge: 8 * 60 * 60)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testArmedWhenCodexRunningAndSessionRecent() {
        let state = gate.armState(
            codexRunning: true,
            lastSessionStart: now.addingTimeInterval(-60),
            now: now
        )
        XCTAssertEqual(state, .armed)
    }

    func testNotArmedWhenCodexNotRunning() {
        let state = gate.armState(codexRunning: false, lastSessionStart: now, now: now)
        XCTAssertEqual(state, .codexNotRunning)
    }

    /// Das Codex-Log kennt keinen Ende-Marker — die Schaerfe muss deshalb
    /// von selbst verfallen.
    func testSessionExpiresAfterMaxAge() {
        let state = gate.armState(
            codexRunning: true,
            lastSessionStart: now.addingTimeInterval(-9 * 60 * 60),
            now: now
        )
        XCTAssertEqual(state, .noRecentSession)
    }

    func testNoSessionAtAll() {
        XCTAssertEqual(gate.armState(codexRunning: true, lastSessionStart: nil, now: now), .noRecentSession)
    }

    /// Echtes Log-Format aus dem Spike vom 26.07.2026.
    func testParsesSessionStartTimestampFromLogTail() {
        let tail = """
        2026-07-26T16:34:05.488Z error [electron-message-handler] Realtime voice WebRTC connection failed conversationId=019f
        2026-07-26T16:34:19.785Z info [AppServerConnection] realtime_session_started hostId=local realtimeSessionId=null
        2026-07-26T16:34:22.702Z info [electron-message-handler] realtime_session_updated realtimeSessionId=rtc_u2_E5w5
        """
        let parsed = CodexVoiceSessionProbe.lastSessionStartTimestamp(inLogTail: tail)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(
            parsed.map { ISO8601DateFormatter().string(from: $0) },
            "2026-07-26T16:34:19Z"
        )
    }

    func testLogTailWithoutSessionStartYieldsNil() {
        let tail = "2026-07-26T16:30:48.611Z error [electron-message-handler] ResizeObserver loop completed"
        XCTAssertNil(CodexVoiceSessionProbe.lastSessionStartTimestamp(inLogTail: tail))
    }

    /// Regression vom 28.07.2026: Codex schreibt Tagesordner nach UTC. Kurz
    /// nach lokaler Mitternacht liegt die aktive Sitzung deshalb noch im
    /// Ordner des lokalen Vortags. Zudem darf normaler Log-Traffic den Marker
    /// nicht bereits nach 64 KiB aus dem Lesefenster schieben.
    func testProbeFindsLongRunningSessionAcrossLocalMidnight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3 * 60 * 60)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 28,
            hour: 0,
            minute: 15
        ))!
        let previousDay = root.appendingPathComponent("2026/07/27", isDirectory: true)
        try FileManager.default.createDirectory(at: previousDay, withIntermediateDirectories: true)

        let marker = "2026-07-27T20:23:51.404Z info [AppServerConnection] realtime_session_started hostId=local\n"
        let noise = String(repeating: "2026-07-27T21:00:00.000Z info normal application event\n", count: 3_000)
        try (marker + noise).write(
            to: previousDay.appendingPathComponent("codex-desktop-test.log"),
            atomically: true,
            encoding: .utf8
        )

        let probe = CodexVoiceSessionProbe(
            logRoot: root,
            now: { now },
            codexRunningProvider: { true }
        )
        XCTAssertEqual(probe.currentArmState(), .armed)
    }
}

final class VoiceGateLocaleResolverTests: XCTestCase {
    /// Der reale Fall auf diesem Mac (26.07.2026): nur de_CH liegt vor.
    func testFallsBackToAvailableGermanRegion() {
        let locale = VoiceGateLocaleResolver.resolve(preferredLanguage: "de") {
            $0.identifier == "de_CH"
        }
        XCTAssertEqual(locale?.identifier, "de_CH")
    }

    func testPrefersStandardRegionWhenAvailable() {
        let locale = VoiceGateLocaleResolver.resolve(preferredLanguage: "de") {
            ["de_DE", "de_CH"].contains($0.identifier)
        }
        XCTAssertEqual(locale?.identifier, "de_DE")
    }

    func testReturnsNilWhenNoRegionHasOnDeviceModel() {
        XCTAssertNil(VoiceGateLocaleResolver.resolve(preferredLanguage: "de") { _ in false })
    }

    func testEnglishFallbackChain() {
        let locale = VoiceGateLocaleResolver.resolve(preferredLanguage: "en") {
            $0.identifier == "en_GB"
        }
        XCTAssertEqual(locale?.identifier, "en_GB")
    }
}

final class CodexCommandExecutionProbeTests: XCTestCase {
    /// Echte Zeile aus dem Spike — so sieht eine ausgefuehrte Codex-Aktion aus.
    func testDetectsExecutionSignature() {
        let text = """
        2026-07-26T16:43:39.663Z info [AppServerConnection] response_routed broadcastFallback=false conversationId=null durationMs=2 errorCode=null
        """
        XCTAssertTrue(CodexCommandExecutionProbe.containsExecutionSignature(text))
    }

    /// Zeilen mit Conversation-Bezug gehoeren zum normalen Chat-Verkehr und
    /// duerfen nicht als Kommando-Ausfuehrung durchgehen.
    func testIgnoresRoutedLinesWithConversation() {
        let text = """
        2026-07-26T16:34:18.520Z info [AppServerConnection] response_routed broadcastFallback=false conversationId=019f9f09-6f86 durationMs=4
        """
        XCTAssertFalse(CodexCommandExecutionProbe.containsExecutionSignature(text))
    }

    func testIgnoresUnrelatedNoise() {
        let text = "2026-07-26T16:30:48.611Z error [electron-message-handler] ResizeObserver loop completed"
        XCTAssertFalse(CodexCommandExecutionProbe.containsExecutionSignature(text))
    }
}

final class VoiceGateVocabularyTests: XCTestCase {
    /// Geaenderte Codewoerter muessen ohne Codeaenderung greifen.
    func testCustomVocabularyIsHonoured() {
        var vocabulary = VoiceGateVocabulary.default
        vocabulary.carrier = "computer"
        vocabulary.muteCommand = "schweig"
        vocabulary.unmuteCommand = "sprich"
        let matcher = VoiceGateCommandMatcher(vocabulary: vocabulary)

        let segments = [
            VoiceGateSegment(text: "Computer", start: 1.0, duration: 0.3, confidence: 0.9),
            VoiceGateSegment(text: "schweig", start: 1.4, duration: 0.3, confidence: 0.9)
        ]
        guard case .matched(let intent, _, _) = matcher.match(segments: segments) else {
            return XCTFail("eigenes Vokabular sollte greifen")
        }
        XCTAssertEqual(intent, .mute)
    }

    /// Das alte Vokabular darf danach nicht mehr ausloesen.
    func testDefaultWordsDoNotTriggerWithCustomVocabulary() {
        var vocabulary = VoiceGateVocabulary.default
        vocabulary.carrier = "computer"
        let matcher = VoiceGateCommandMatcher(vocabulary: vocabulary)

        let segments = [
            VoiceGateSegment(text: "Jarvis", start: 1.0, duration: 0.3, confidence: 0.9),
            VoiceGateSegment(text: "Pause", start: 1.4, duration: 0.3, confidence: 0.9)
        ]
        XCTAssertEqual(matcher.match(segments: segments), .rejected(.noCarrier))
    }
}

final class VoiceGateCarrierToleranceTests: XCTestCase {
    private func matcher(carrier: String) -> VoiceGateCommandMatcher {
        var vocabulary = VoiceGateVocabulary.default
        vocabulary.carrier = carrier
        return VoiceGateCommandMatcher(vocabulary: vocabulary)
    }

    private func segments(_ words: [String]) -> [VoiceGateSegment] {
        var result: [VoiceGateSegment] = []
        var cursor = 1.0
        for word in words {
            result.append(VoiceGateSegment(text: word, start: cursor, duration: 0.3, confidence: 0.9))
            cursor += 0.35
        }
        return result
    }

    /// Kurzes Traegerwort: exakt, sonst oeffnet Distanz 1 die Tuer fuer
    /// „Anne", „Hanna", „Manna", „wanna" — alles Alltagssprache.
    func testShortCarrierRequiresExactMatch() {
        let m = matcher(carrier: "anna")
        for nearMiss in ["Anne", "Hanna", "Manna", "Anni"] {
            XCTAssertEqual(
                m.match(segments: segments([nearMiss, "Pause"])),
                .rejected(.noCarrier),
                "\(nearMiss) darf bei kurzem Trägerwort nicht greifen"
            )
        }
    }

    func testShortCarrierStillMatchesExactly() {
        guard case .matched(let intent, _, _) = matcher(carrier: "anna").match(segments: segments(["Anna", "Pause"])) else {
            return XCTFail("exaktes kurzes Trägerwort muss greifen")
        }
        XCTAssertEqual(intent, .mute)
    }

    /// Langes Traegerwort behaelt die Toleranz — dort ist ein Nachbar in
    /// Distanz 1 praktisch immer dasselbe Wort, nur verhoert.
    func testLongCarrierKeepsFuzzyTolerance() {
        guard case .matched = matcher(carrier: "jarvis").match(segments: segments(["Jervis", "Pause"])) else {
            return XCTFail("langes Trägerwort sollte Distanz 1 tolerieren")
        }
    }
}

final class VoiceGateRepeatOverrideRegressionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// REGRESSION (gemessen 27.07.2026, 09:18): Nach einem erfolgreichen Druck
    /// wurde eine Doppelerkennung derselben Phrase als „Widerspruch" gewertet
    /// und drueckte erneut — womit der erste Druck rueckgaengig gemacht wurde
    /// und die Annahme dauerhaft von der Realitaet abwich.
    /// Eine Wiederholung darf nur nach einem UEBERSPRUNGENEN Befehl greifen.
    func testRepeatAfterSuccessfulPressDoesNotToggleBack() {
        var machine = VoiceGateStateMachine(assumed: .open)

        XCTAssertEqual(machine.handle(.mute, now: t0), .press(intent: .mute, reason: .stateMismatch))
        machine.confirmPress(.mute, now: t0)

        // 3 s spaeter: Cooldown vorbei, aber im Wiederholungsfenster.
        let later = t0.addingTimeInterval(3.0)
        XCTAssertEqual(machine.handle(.mute, now: later), .skip(.alreadyInTargetState))
        XCTAssertEqual(machine.assumed, .muted, "Zustand muss stumm bleiben")
    }

    /// Der eigentlich gewollte Fall bleibt erhalten: erst uebersprungen,
    /// dann wiederholt → drueckt.
    func testRepeatAfterSkipStillOverrides() {
        var machine = VoiceGateStateMachine(assumed: .muted)

        XCTAssertEqual(machine.handle(.mute, now: t0), .skip(.alreadyInTargetState))
        XCTAssertEqual(
            machine.handle(.mute, now: t0.addingTimeInterval(1.5)),
            .press(intent: .mute, reason: .repeatOverride)
        )
    }

    /// Nach dem Uebersteuern darf eine dritte Erkennung nicht erneut drucken.
    func testOverrideIsNotRepeatable() {
        var machine = VoiceGateStateMachine(assumed: .muted)
        _ = machine.handle(.mute, now: t0)
        _ = machine.handle(.mute, now: t0.addingTimeInterval(1.5))
        machine.confirmPress(.mute, now: t0.addingTimeInterval(1.5))

        XCTAssertEqual(
            machine.handle(.mute, now: t0.addingTimeInterval(5.0)),
            .skip(.alreadyInTargetState)
        )
    }
}

final class CodexVoiceSessionAgeRegressionTests: XCTestCase {
    /// REGRESSION (27.07.2026): Die Schaerfe verfiel nach 30 Minuten, waehrend
    /// die Sprachsitzung weiterlief — das Codex-Log kennt weder Ende-Marker
    /// noch Lebenszeichen, also darf die Frist nicht knapp sein.
    func testSessionStaysArmedForHours() {
        let gate = CodexVoiceSessionGate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for hoursAgo in [0.5, 1.0, 3.0, 7.0] {
            XCTAssertEqual(
                gate.armState(
                    codexRunning: true,
                    lastSessionStart: now.addingTimeInterval(-hoursAgo * 3600),
                    now: now
                ),
                .armed,
                "\(hoursAgo) h alte Sitzung muss scharf bleiben"
            )
        }
    }
}

final class VoiceGateGluedTokenTests: XCTestCase {
    private func matcher() -> VoiceGateCommandMatcher {
        var vocabulary = VoiceGateVocabulary.default
        vocabulary.carrier = "anna"
        return VoiceGateCommandMatcher(vocabulary: vocabulary)
    }

    private func single(_ text: String) -> [VoiceGateSegment] {
        [VoiceGateSegment(text: text, start: 1.0, duration: 0.6, confidence: 0.9)]
    }

    /// REGRESSION (gemessen 27.07.2026, 11:10): Der On-Device-Erkenner lieferte
    /// „anna pause" mal als zwei Segmente und mal als EIN Token „annapause".
    /// Nur die getrennte Form griff — dadurch funktionierte die Phrase
    /// scheinbar zufaellig mal und mal nicht.
    func testGluedPhraseMatches() {
        for (text, expected) in [("annapause", VoiceGateIntent.mute), ("annaweiter", .unmute)] {
            guard case .matched(let intent, _, _) = matcher().match(segments: single(text)) else {
                return XCTFail("\(text) muss greifen")
            }
            XCTAssertEqual(intent, expected)
        }
    }

    /// Getrennte Form bleibt unveraendert gueltig.
    func testSplitPhraseStillMatches() {
        let segments = [
            VoiceGateSegment(text: "anna", start: 1.0, duration: 0.3, confidence: 0.9),
            VoiceGateSegment(text: "pause", start: 1.4, duration: 0.3, confidence: 0.9)
        ]
        guard case .matched(let intent, _, _) = matcher().match(segments: segments) else {
            return XCTFail("getrennte Form muss weiter greifen")
        }
        XCTAssertEqual(intent, .mute)
    }

    /// Auch verschmolzen darf es nicht mitten im Redefluss greifen.
    func testGluedPhraseNeedsUtteranceBoundary() {
        let segments = [
            VoiceGateSegment(text: "ich", start: 1.0, duration: 0.3, confidence: 0.9),
            VoiceGateSegment(text: "annapause", start: 1.35, duration: 0.6, confidence: 0.9)
        ]
        if case .matched = matcher().match(segments: segments) {
            XCTFail("ohne Pause davor darf die verschmolzene Form nicht greifen")
        }
    }

    /// Das Traegerwort allein bleibt wirkungslos, auch verschmolzen mit etwas anderem.
    func testGluedCarrierWithUnknownCommandDoesNotMatch() {
        if case .matched = matcher().match(segments: single("annagutenberg")) {
            XCTFail("annagutenberg darf nicht auslösen")
        }
    }
}

final class VoiceGateDefaultVocabularyTests: XCTestCase {
    /// Das Standard-Traegerwort ist Teil des Nutzerversprechens — es steht in
    /// der Doku, in den Platzhaltern der Oberflaeche und im Onboarding.
    func testDefaultVocabulary() {
        let vocabulary = VoiceGateVocabulary.default
        XCTAssertEqual(vocabulary.carrier, "anna")
        XCTAssertEqual(vocabulary.muteCommand, "pause")
        XCTAssertEqual(vocabulary.unmuteCommand, "weiter")
    }

    /// „Anna" ist kurz und muss deshalb exakt sitzen — sonst waeren „Anne" und
    /// „Hanna" Treffer. Diese Kopplung ist beabsichtigt und darf nicht
    /// versehentlich gelockert werden.
    func testDefaultCarrierRequiresExactRecognition() {
        XCTAssertEqual(VoiceGateVocabulary.default.carrierDistanceAllowance(), 0)
    }

    func testDefaultPhrasesMatch() {
        let matcher = VoiceGateCommandMatcher()
        for (command, expected) in [
            ("Pause", VoiceGateIntent.mute),
            ("Stopp", .mute),
            ("Stop", .mute),
            ("weiter", .unmute),
            ("Resume", .unmute),
            ("Resümee", .unmute)
        ] {
            let segments = [
                VoiceGateSegment(text: "Anna", start: 1.0, duration: 0.3, confidence: 0.9),
                VoiceGateSegment(text: command, start: 1.4, duration: 0.3, confidence: 0.9)
            ]
            guard case .matched(let intent, _, _) = matcher.match(segments: segments) else {
                return XCTFail("Anna \(command) muss mit dem Default greifen")
            }
            XCTAssertEqual(intent, expected)
        }
    }

    func testAliasesStillRequireExactCarrierAndUtteranceBoundary() {
        let matcher = VoiceGateCommandMatcher()
        let noCarrier = [
            VoiceGateSegment(text: "Resume", start: 1.0, duration: 0.3, confidence: 0.9)
        ]
        XCTAssertEqual(matcher.match(segments: noCarrier), .rejected(.noCarrier))

        let runningSentence = [
            VoiceGateSegment(text: "sag", start: 1.0, duration: 0.3, confidence: 0.9),
            VoiceGateSegment(text: "Anna", start: 1.31, duration: 0.3, confidence: 0.9),
            VoiceGateSegment(text: "Stopp", start: 1.65, duration: 0.3, confidence: 0.9)
        ]
        XCTAssertEqual(matcher.match(segments: runningSentence), .rejected(.noUtteranceBoundary))
    }

    /// Ein Trockenlauf darf die Live-Annahme nicht so verändern, als sei die
    /// Taste wirklich gedrückt worden. Der Coordinator ruft in diesem Modus
    /// bewusst kein `confirmPress` auf.
    func testUnconfirmedDryRunDecisionLeavesAssumedStateUntouched() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var machine = VoiceGateStateMachine(assumed: .open)
        XCTAssertEqual(machine.handle(.mute, now: now), .press(intent: .mute, reason: .stateMismatch))
        XCTAssertEqual(machine.assumed, .open)
        XCTAssertEqual(
            machine.handle(.mute, now: now.addingTimeInterval(3)),
            .press(intent: .mute, reason: .stateMismatch)
        )
    }
}
