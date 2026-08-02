import AppKit
import Foundation

// ==============================================================================
// Verdrahtung des Voice Gates.
//
// PHASE 1 = TROCKENLAUF. Es gibt in dieser Phase bewusst KEINEN Code, der eine
// Taste drueckt oder den Fokus wechselt — nicht abgeschaltet, sondern schlicht
// nicht vorhanden. Der Pfad laeuft vollstaendig bis zur Entscheidung und endet
// in Log, Zaehler und einem kurzen Ton.
// ==============================================================================

@MainActor
@Observable
final class VoiceGateCoordinator {
    static let shared = VoiceGateCoordinator()

    // MARK: - Sichtbarer Zustand (Menueleiste)

    private(set) var isEnabled = false
    private(set) var armState: VoiceGateArmState = .codexNotRunning
    private(set) var assumedState: VoiceGateAssumedState = .unknown
    private(set) var startupError: String?

    /// Zaehler seit App-Start. Im Trockenlauf ist `wouldPressCount` die
    /// Kennzahl: waehrend des Fehlalarm-Soaks muss sie auf 0 bleiben.
    private(set) var wouldPressCount = 0
    /// Tatsaechlich ausgefuehrte Umschaltungen (nur wenn der Trockenlauf aus ist).
    private(set) var pressCount = 0
    private(set) var skippedCount = 0
    private(set) var rejectionCounts: [String: Int] = [:]
    private(set) var lastEvent: String?
    private(set) var lastEventAt: Date?

    // MARK: - Innereien

    /// Frisch aus den Einstellungen gebaut — geaenderte Codewoerter wirken
    /// damit sofort, ohne Neustart. Der Matcher ist ein Struct ohne Zustand,
    /// das Erzeugen kostet nichts.
    private var matcher: VoiceGateCommandMatcher {
        VoiceGateCommandMatcher(vocabulary: Self.vocabularyFromPreferences())
    }

    static func vocabularyFromPreferences() -> VoiceGateVocabulary {
        var vocabulary = VoiceGateVocabulary.default
        vocabulary.carrier = AppPreferences.shared.codexVoiceGateCarrier
        vocabulary.muteCommand = AppPreferences.shared.codexVoiceGateMuteWord
        vocabulary.unmuteCommand = AppPreferences.shared.codexVoiceGateUnmuteWord
        return vocabulary
    }

    private let probe: CodexVoiceSessionProbe
    private let toggler = CodexMuteToggler()
    private let executionProbe = CodexCommandExecutionProbe()
    /// Verhindert, dass eine zweite Erkennung mitten in den Fokus-Roundtrip faellt.
    private var pressInFlight = false
    private var stateMachine = VoiceGateStateMachine()
    private var listener: VoiceGateListener?
    private var armTimer: Timer?

    /// Entprellung der Teilergebnisse: dieselbe Phrase taucht in mehreren
    /// Hypothesen auf, bis sie final ist.
    private var lastDetection: (intent: VoiceGateIntent, at: Date)?
    private let detectionDebounce: TimeInterval = 2.0

    /// Gesetzt bei Fehlern, die sich ohne Zutun des Menschen nicht aendern
    /// (Berechtigung, fehlende On-Device-Sprachdaten).
    private var startupFailedPermanently = false

    /// Hat die Log-Signatur in dieser Sitzung schon einmal getragen? Nur dann
    /// wird ihr Ausbleiben als Fehlschlag gewertet. Faellt sie mit einem
    /// Codex-Update ersatzlos weg, bleibt das Verhalten damit unveraendert.
    private var hasEverConfirmed = false
    private var lastVerboseLogAt: Date?

    /// Erkennt einen tauben Listener und baut ihn neu — gedeckelt, damit daraus
    /// keine Neustart-Schleife wird.
    private var watchdog = VoiceGateWatchdogPolicy()
    private var lastAliveLogAt: Date?

    private init(probe: CodexVoiceSessionProbe = CodexVoiceSessionProbe()) {
        self.probe = probe
    }

    // MARK: - Lebenszyklus

    func start() {
        guard AppPreferences.shared.isCodexVoiceGateEnabled else {
            Logger.voiceGate.info("gate.disabled — Feature-Flag aus")
            return
        }
        guard !isEnabled else { return }
        isEnabled = true
        startupError = nil
        startupFailedPermanently = false
        // Manuelles Aus/An ist die Geste „probier es nochmal" — der Wachhund
        // darf danach wieder von vorn zaehlen.
        watchdog.reset()
        lastAliveLogAt = nil

        Logger.voiceGate.info(
            "gate.start dryRun=\(AppPreferences.shared.isCodexVoiceGateDryRun, privacy: .public)"
        )

        refreshArmState()
        armTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshArmState() }
        }
    }

    /// Schaltet das Mithoeren zur Laufzeit um — aus den Einstellungen heraus.
    /// „Aus" beendet den Listener sofort, gibt das Mikrofon frei (die
    /// Aufnahme-Anzeige in der Menueleiste verschwindet) und blockiert damit
    /// auch die Codewoerter.
    func setEnabled(_ enabled: Bool) {
        AppPreferences.shared.isCodexVoiceGateEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        isEnabled = false
        armState = .codexNotRunning
        armTimer?.invalidate()
        armTimer = nil
        stopListening()
        Logger.voiceGate.info("gate.stop")
    }

    /// Manuelle Korrektur, wenn der Mensch selbst im Codex-Overlay geklickt hat.
    func correctAssumedState(to state: VoiceGateAssumedState) {
        stateMachine.setAssumed(state)
        assumedState = state
        note("Zustand manuell auf \(state.rawValue) gesetzt")
        Logger.voiceGate.info("state.manual_correction to=\(state.rawValue, privacy: .public)")
    }

    func resetCounters() {
        wouldPressCount = 0
        pressCount = 0
        skippedCount = 0
        rejectionCounts = [:]
        lastEvent = nil
        lastEventAt = nil
    }

    // MARK: - Scharfschaltung

    private func refreshArmState() {
        guard isEnabled else { return }

        // Waehrend eines eigenen Diktats pausiert der Listener: sonst konkurrieren
        // zwei Engines um dasselbe Geraet und das Codewort landet im Diktat.
        let dictationActive = AppState.shared.isRecording
        let state: VoiceGateArmState = dictationActive ? .pausedForDictation : probe.currentArmState()

        if state != armState {
            armState = state
            Logger.voiceGate.info("gate.arm_state=\(state.rawValue, privacy: .public)")
        }

        if state == .armed {
            startListeningIfNeeded()
            superviseListenerHealth()
        } else {
            stopListening()
        }
    }

    /// Wachhund gegen stilles Taubwerden.
    ///
    /// Der Gerätewechsel-Fehler vom 27.07.2026 war deshalb so zaeh, weil der
    /// Listener nicht abstuerzte: Engine lief, `isRunning` blieb true, das Gate
    /// meldete „scharf" — nur kamen keine Puffer mehr. Der Wachhund fragt
    /// bewusst nicht nach der URSACHE, sondern nur danach, ob noch Audio
    /// eintrifft; damit faengt er auch stille Tode, die wir nicht kennen.
    private func superviseListenerHealth() {
        guard let listener else { return }

        let now = Date()
        let verdict = listener.healthVerdict(now: now)

        // Regelmaessiges Lebenszeichen auf `info` — eine gesunde und eine taube
        // Sitzung sahen im Log bisher identisch aus, und Nutzer-Mitschriften
        // haben `debug` nicht an.
        if lastAliveLogAt == nil || now.timeIntervalSince(lastAliveLogAt!) >= 30 {
            lastAliveLogAt = now
            let since = listener.millisecondsSinceLastBuffer(now: now).map(String.init) ?? "—"
            Logger.voiceGate.info(
                "listener.alive verdict=\(String(describing: verdict), privacy: .public) sinceLastBufferMs=\(since, privacy: .public)"
            )
        }

        switch watchdog.decide(armed: true, verdict: verdict, now: now) {
        case .none:
            break

        case .restart:
            if case .deaf(let gap) = verdict {
                Logger.voiceGate.error(
                    "listener.watchdog_restart gapMs=\(Int(gap * 1000), privacy: .public)"
                )
            }
            note("Kein Audio mehr — Listener wird neu gebunden")
            stopListening()
            startListeningIfNeeded()

        case .giveUp:
            Logger.voiceGate.error("listener.watchdog_gave_up")
            startupError = "Das Mikrofon liefert nichts mehr, und mehrere Neustarts haben nicht geholfen. Voice Gate aus- und wieder einschalten."
            note("Wachhund hat aufgegeben")
            stopListening()
        }
    }

    private func startListeningIfNeeded() {
        guard listener == nil else { return }
        // Fehlende Berechtigung oder fehlende On-Device-Sprachdaten aendern
        // sich nicht von selbst — sonst liefe hier alle 10 s ein Fehlversuch.
        guard !startupFailedPermanently else { return }

        let language = AppPreferences.shared.language
        guard let locale = VoiceGateListener.resolveOnDeviceLocale(preferredLanguage: language) else {
            startupFailedPermanently = true
            let hint = VoiceGateLocaleResolver.unavailableHint(preferredLanguage: language)
            startupError = hint
            note(hint)
            Logger.voiceGate.error("gate.no_on_device_locale language=\(language, privacy: .public)")
            return
        }
        Logger.voiceGate.info("gate.locale=\(locale.identifier, privacy: .public)")

        let listener = VoiceGateListener(locale: locale)
        listener.onHypothesis = { [weak self] hypothesis in
            Task { @MainActor in self?.handle(hypothesis) }
        }
        listener.onRuntimeError = { [weak self] error in
            Task { @MainActor in self?.handleRuntimeError(error) }
        }
        self.listener = listener

        Task { @MainActor in
            do {
                try await listener.start()
                self.startupError = nil
            } catch {
                self.startupError = error.localizedDescription
                self.listener = nil
                if case VoiceGateListenerError.audioEngineFailed = error {
                    // Vorübergehend (Gerätewechsel) — beim nächsten Tick erneut.
                } else {
                    self.startupFailedPermanently = true
                }
                self.note("Start fehlgeschlagen: \(error.localizedDescription)")
                Logger.voiceGate.error("gate.start_failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stopListening() {
        listener?.stop()
        listener = nil
    }

    private func handleRuntimeError(_ error: Error) {
        startupError = error.localizedDescription
        stopListening()
        note("Laufzeitfehler: \(error.localizedDescription)")
    }

    // MARK: - Auswertung

    private func handle(_ hypothesis: VoiceGateHypothesis) {
        let vocabulary = Self.vocabularyFromPreferences()
        let match = VoiceGateCommandMatcher(vocabulary: vocabulary).match(segments: hypothesis.segments)
        logVerbose(hypothesis, vocabulary: vocabulary, match: match)

        switch match {
        case .rejected(let reason):
            // Nur finale Hypothesen zaehlen, sonst explodiert die Statistik
            // durch Teilergebnisse.
            guard hypothesis.isFinal else { return }
            rejectionCounts[reason.rawValue, default: 0] += 1
            Logger.voiceGate.debug("candidate.rejected reason=\(reason.rawValue, privacy: .public)")

        case .matched(let intent, _, let confidence):
            // Bewusst AUCH auf Teilergebnisse: gemessen am 26.07.2026 erschien
            // die Phrase zweimal als `partial`, tauchte im finalen Ergebnis
            // aber nicht mehr auf — der Erkenner segmentiert beim Abschluss neu.
            // Wer nur auf `isFinal` wartet, verliert die Treffer. Doppelfeuer
            // faengt die Entprellung plus Cooldown ab.
            Logger.voiceGate.debug(
                "candidate.match intent=\(intent.rawValue, privacy: .public) final=\(hypothesis.isFinal, privacy: .public)"
            )
            handleMatch(intent: intent, confidence: confidence, at: hypothesis.receivedAt)
        }
    }

    private func handleMatch(intent: VoiceGateIntent, confidence: Float, at date: Date) {
        if let lastDetection,
           lastDetection.intent == intent,
           date.timeIntervalSince(lastDetection.at) < detectionDebounce {
            return
        }
        lastDetection = (intent, date)

        let action = stateMachine.handle(intent, now: date)
        switch action {
        case .skip(let reason):
            skippedCount += 1
            note("\(phrase(for: intent)) erkannt — übersprungen (\(reason.rawValue))")
            Logger.voiceGate.info(
                "detected intent=\(intent.rawValue, privacy: .public) action=skip reason=\(reason.rawValue, privacy: .public)"
            )

        case .press(let intent, let reason):
            // Der Trockenlauf-Schalter wird HIER gelesen, nicht beim Start —
            // damit `defaults write … codexVoiceGateDryRun -bool NO` sofort
            // greift, ohne Rebuild und ohne Neustart.
            guard !AppPreferences.shared.isCodexVoiceGateDryRun else {
                wouldPressCount += 1
                note("\(phrase(for: intent)) erkannt — WÜRDE drücken (\(reason.rawValue))")
                Logger.voiceGate.info(
                    """
                    would_press intent=\(intent.rawValue, privacy: .public) \
                    reason=\(reason.rawValue, privacy: .public) \
                    confidence=\(String(format: "%.2f", confidence), privacy: .public) \
                    assumedUnchanged=\(self.stateMachine.assumed.rawValue, privacy: .public)
                    """
                )
                playFeedbackSound()
                return
            }
            performPress(intent: intent, reason: reason)
        }
    }

    // MARK: - Scharfer Tastendruck (Phase 2)

    private func performPress(intent: VoiceGateIntent, reason: VoiceGatePressReason) {
        guard !pressInFlight else {
            Logger.voiceGate.debug("press.skipped — Roundtrip läuft bereits")
            return
        }
        pressInFlight = true

        Task { @MainActor in
            defer { self.pressInFlight = false }

            let snapshot = self.executionProbe.snapshot()
            do {
                let result = try await self.toggler.toggle()
                self.stateMachine.confirmPress(intent, now: Date())
                self.assumedState = self.stateMachine.assumed
                self.pressCount += 1
                self.playFeedbackSound()

                var confirmed = await self.executionProbe.awaitExecutionSignature(after: snapshot)
                Logger.voiceGate.info(
                    """
                    pressed intent=\(intent.rawValue, privacy: .public) \
                    reason=\(reason.rawValue, privacy: .public) \
                    durationMs=\(Int(result.duration * 1000), privacy: .public) \
                    restoredTo=\(result.restoredTo ?? "-", privacy: .public) \
                    confirmed=\(confirmed, privacy: .public) \
                    assumedAfter=\(self.stateMachine.assumed.rawValue, privacy: .public)
                    """
                )

                if confirmed {
                    self.hasEverConfirmed = true
                } else if self.hasEverConfirmed {
                    // Die Signatur hat sich in dieser Sitzung schon bewaehrt —
                    // ihr Ausbleiben ist also ein echter Hinweis auf einen
                    // verpufften Tastendruck (gemessen 27.07.2026: Codex hatte
                    // das Key-Window noch nicht). Genau einmal nachfassen.
                    confirmed = await self.retryPress(intent: intent)
                }

                if confirmed {
                    self.note("\(self.phrase(for: intent)) → umgeschaltet")
                } else {
                    self.note("\(self.phrase(for: intent)) → ohne Bestätigung")
                }

            } catch {
                // Mechanisches Scheitern ist echter Beleg: Zustand auf unbekannt,
                // damit der naechste Befehl in jedem Fall drueckt.
                self.stateMachine.failPress(now: Date())
                self.assumedState = self.stateMachine.assumed
                self.note("Umschalten fehlgeschlagen: \(error.localizedDescription)")
                Logger.voiceGate.error("press_failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Genau ein Nachfass-Versuch. Bleibt auch der unbestaetigt, wird der
    /// Zustand ehrlich auf `unbekannt` gesetzt statt weiter zu druecken —
    /// eine Schleife waere hier schlimmer als ein offenes Ergebnis.
    private func retryPress(intent: VoiceGateIntent) async -> Bool {
        Logger.voiceGate.info("press.retry intent=\(intent.rawValue, privacy: .public)")
        let snapshot = executionProbe.snapshot()
        do {
            _ = try await toggler.toggle()
        } catch {
            stateMachine.failPress(now: Date())
            assumedState = stateMachine.assumed
            Logger.voiceGate.error("press.retry_failed \(error.localizedDescription, privacy: .public)")
            return false
        }

        let confirmed = await executionProbe.awaitExecutionSignature(after: snapshot)
        Logger.voiceGate.info("press.retry_result confirmed=\(confirmed, privacy: .public)")
        if !confirmed {
            stateMachine.failPress(now: Date())
            assumedState = stateMachine.assumed
        }
        return confirmed
    }

    private func playFeedbackSound() {
        guard AppPreferences.shared.isCodexVoiceGateSoundEnabled else { return }
        SystemSoundCatalog.play(AppPreferences.shared.codexVoiceGateSoundName)
    }

    private func phrase(for intent: VoiceGateIntent) -> String {
        let vocabulary = matcher.vocabulary
        switch intent {
        case .mute: return "\(vocabulary.carrier) \(vocabulary.muteCommand)"
        case .unmute: return "\(vocabulary.carrier) \(vocabulary.unmuteCommand)"
        }
    }

    /// Nur mit ausdruecklich eingeschalteter Diagnose: zeigt, WAS der Erkenner
    /// verstanden hat und gegen welches Vokabular geprueft wurde. Ohne das ist
    /// „mein Codewort greift nicht" nicht diagnostizierbar.
    private func logVerbose(
        _ hypothesis: VoiceGateHypothesis,
        vocabulary: VoiceGateVocabulary,
        match: VoiceGateMatch
    ) {
        guard AppPreferences.shared.isCodexVoiceGateVerboseLoggingEnabled else { return }

        // Nur auf finale Ergebnisse zu warten war nutzlos: die Phrase steckt
        // praktisch immer in Teilergebnissen, und das finale Ergebnis beim
        // Task-Wechsel ist meist leer (gemessen 27.07.2026 — kein einziger
        // Eintrag ueber eine ganze Testreihe). Also Teilergebnisse mitnehmen,
        // aber gedrosselt, sonst ertrinkt das Log.
        let now = hypothesis.receivedAt
        let isMatch: Bool
        let outcome: String
        switch match {
        case .matched(let intent, _, _):
            isMatch = true
            outcome = "match:\(intent.rawValue)"
        case .rejected(let reason):
            isMatch = false
            outcome = "rejected:\(reason.rawValue)"
        }
        if !isMatch, let lastVerboseLogAt, now.timeIntervalSince(lastVerboseLogAt) < 2.0 { return }

        let heard = hypothesis.segments
            .map { VoiceGateCommandMatcher.normalize($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !heard.isEmpty else { return }
        lastVerboseLogAt = now

        // Die Option heißt ausdrücklich „erkannte Wörter protokollieren".
        // Deshalb INFO statt DEBUG: Nur so bleibt der Eintrag in `log show`
        // nachträglich abrufbar und ist nicht ausschließlich live sichtbar.
        Logger.voiceGate.info(
            """
            heard="\(heard, privacy: .public)" final=\(hypothesis.isFinal, privacy: .public) \
            outcome=\(outcome, privacy: .public) \
            vocabulary="\(vocabulary.carrier, privacy: .public)/\
            \(vocabulary.muteCommand, privacy: .public)/\
            \(vocabulary.unmuteCommand, privacy: .public)"
            """
        )
    }

    private func note(_ message: String) {
        lastEvent = message
        lastEventAt = Date()
    }

}
