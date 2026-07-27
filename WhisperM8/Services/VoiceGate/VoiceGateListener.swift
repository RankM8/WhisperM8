import AVFoundation
import Foundation
import Speech

// ==============================================================================
// Der mithoerende Listener.
//
// Audio kommt aus einer austauschbaren `VoiceGateAudioSource` — diese Datei
// kuemmert sich nur noch um Erkennung und Lebenszyklus. Die Engine-Details
// (Geraetebindung, HFP-Wartezeit, Format-Retry, Konfigurations-Beobachter)
// liegen dort, weil genau sie im Feld kaputtgingen und testbar sein muessen.
//
// GERAETEBINDUNG: Fuer Bluetooth liefert der `AudioDeviceManager` bewusst
// `nil` — die HFP-Umschaltung gehoert macOS, und der Recorder faehrt seit
// Langem genauso. Bei AirPods folgt die Quelle also dem System-Standard.
// Frueher behauptete dieser Kopf das Gegenteil („nie System Default"); das
// war fuer genau die haeufigste Hardware falsch.
//
// Erkennung strikt on-device (`requiresOnDeviceRecognition`). Faellt die
// On-Device-Faehigkeit aus, startet der Listener GAR NICHT — ein stiller
// Fallback auf Apples Server waere ein Datenschutz-Bruch.
// ==============================================================================

enum VoiceGateListenerError: LocalizedError {
    case speechAuthorizationDenied
    case recognizerUnavailable(locale: String)
    case onDeviceRecognitionUnavailable(locale: String)
    case audioEngineFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechAuthorizationDenied:
            return "Spracherkennung nicht erlaubt — in Systemeinstellungen → Datenschutz & Sicherheit → Spracherkennung freigeben."
        case .recognizerUnavailable(let locale):
            return "Kein Spracherkenner für \(locale) verfügbar."
        case .onDeviceRecognitionUnavailable(let locale):
            return "On-Device-Erkennung für \(locale) fehlt. In Systemeinstellungen → Tastatur → Diktat die Sprache laden. (Kein Server-Fallback — das Voice Gate bleibt aus.)"
        case .audioEngineFailed(let detail):
            return "Audio-Engine konnte nicht starten: \(detail)"
        }
    }
}

/// Eine Erkennungs-Hypothese, wie sie beim Matcher ankommt.
struct VoiceGateHypothesis {
    let segments: [VoiceGateSegment]
    let isFinal: Bool
    /// Zeitpunkt, an dem die Hypothese eintraf — Grundlage der Latenzmessung.
    let receivedAt: Date
}

final class VoiceGateListener {
    /// Wie lange eine Erkennungs-Task laufen darf, bevor sie erneuert wird.
    /// `SFSpeechRecognizer` ist nicht fuer Dauerbetrieb gebaut.
    private let maxTaskDuration: TimeInterval = 50

    private let locale: Locale
    private let audioSource: VoiceGateAudioSource

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStartedAt: Date?

    /// Schuetzt `request`/`task`/`taskStartedAt` und das Lebenszeichen gegen
    /// den Audio-Thread, der parallel Puffer anhaengt.
    private let stateLock = NSLock()
    /// Verhindert den Erneuerungs-Sturm: „No speech detected" kommt bei Stille
    /// regulaer, und eine synchrone Erneuerung im Callback erzeugte daraus eine
    /// Endlosschleife (gemessen: 4796 Fehler in 90 s).
    private var pendingRenewal = false
    private var health = VoiceGateListenerHealth()

    private(set) var isRunning = false

    /// Neue Hypothese. Kommt auf einer beliebigen Queue.
    var onHypothesis: ((VoiceGateHypothesis) -> Void)?
    /// Laufzeitfehler nach erfolgreichem Start (Rebind gescheitert).
    var onRuntimeError: ((Error) -> Void)?

    init(
        locale: Locale = Locale(identifier: "de_DE"),
        audioSource: VoiceGateAudioSource = AVAudioEngineVoiceGateAudioSource()
    ) {
        self.locale = locale
        self.audioSource = audioSource
    }

    // MARK: - Locale-Auswahl

    /// Beste Regionalvariante, fuer die ein On-Device-Modell bereitliegt.
    static func resolveOnDeviceLocale(preferredLanguage: String) -> Locale? {
        VoiceGateLocaleResolver.resolve(preferredLanguage: preferredLanguage) { locale in
            SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
        }
    }

    // MARK: - Berechtigung

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Lebenszeichen

    /// Kommen noch Audio-Puffer an? Grundlage des Wachhunds im Coordinator.
    func healthVerdict(now: Date = Date()) -> VoiceGateListenerHealth.Verdict {
        stateLock.lock()
        defer { stateLock.unlock() }
        return health.verdict(now: now)
    }

    func millisecondsSinceLastBuffer(now: Date = Date()) -> Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return health.millisecondsSinceLastBuffer(now: now)
    }

    // MARK: - Start / Stop

    func start() async throws {
        guard !isRunning else { return }

        let status = await Self.requestAuthorization()
        guard status == .authorized else {
            throw VoiceGateListenerError.speechAuthorizationDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw VoiceGateListenerError.recognizerUnavailable(locale: locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceGateListenerError.onDeviceRecognitionUnavailable(locale: locale.identifier)
        }
        self.recognizer = recognizer

        audioSource.onBuffer = { [weak self] buffer in
            self?.handle(buffer: buffer)
        }
        audioSource.onRebind = { [weak self] success in
            self?.handleRebind(success: success)
        }

        try audioSource.start()

        stateLock.lock()
        health.markStarted(at: Date())
        stateLock.unlock()

        startRecognitionTask()
        isRunning = true
        Logger.voiceGate.info(
            "listener.started locale=\(self.locale.identifier, privacy: .public) device=\(self.audioSource.deviceLabel, privacy: .public)"
        )
    }

    func stop() {
        // Bewusst OHNE `guard isRunning`: nach einem gescheiterten Rebind steht
        // das Flag auf false, die Quelle laeuft aber womoeglich noch. Frueher
        // blieben hier Tap und Beobachter stehen.
        isRunning = false

        audioSource.onBuffer = nil
        audioSource.onRebind = nil
        audioSource.stop()

        finishRecognitionTask()
        recognizer = nil

        stateLock.lock()
        health.markStopped()
        pendingRenewal = false
        stateLock.unlock()

        Logger.voiceGate.info("listener.stopped")
    }

    // MARK: - Audio

    private func handle(buffer: AVAudioPCMBuffer) {
        // Wichtig: JEDER Puffer geht durch, auch Stille. Wuerde hier bei
        // leisem Pegel ausgesetzt, verschwaende die Pause vor dem Codewort —
        // und genau an ihr erkennt der Matcher die Aeusserungsgrenze.
        let now = Date()

        stateLock.lock()
        let currentRequest = request
        let startedAt = taskStartedAt
        let hadBuffer = health.millisecondsSinceLastBuffer(now: now) != nil
        health.recordBuffer(at: now)
        stateLock.unlock()

        if !hadBuffer {
            Logger.voiceGate.info("listener.first_buffer device=\(self.audioSource.deviceLabel, privacy: .public)")
        }

        currentRequest?.append(buffer)

        if let startedAt, now.timeIntervalSince(startedAt) > maxTaskDuration {
            renewRecognitionTask()
        }
    }

    /// Die Quelle hat nach einem Geraetewechsel neu gebunden.
    private func handleRebind(success: Bool) {
        guard isRunning else { return }

        guard success else {
            isRunning = false
            let error = VoiceGateListenerError.audioEngineFailed("Rebind nach Gerätewechsel gescheitert")
            Logger.voiceGate.error("listener.rebind_gave_up")
            onRuntimeError?(error)
            return
        }

        // Erkennung frisch aufsetzen: Die alte Task haengt an einem Stream, der
        // nicht mehr gefuellt wird. `pendingRenewal` muss dabei zurueck, sonst
        // startet 0,4 s spaeter eine ZWEITE Task und die beiden cancellen sich
        // gegenseitig.
        stateLock.lock()
        pendingRenewal = false
        health.markStarted(at: Date())
        stateLock.unlock()

        finishRecognitionTask()
        startRecognitionTask()
        Logger.voiceGate.info("listener.recognition_rebound device=\(self.audioSource.deviceLabel, privacy: .public)")
    }

    // MARK: - Erkennung

    private func startRecognitionTask() {
        guard let recognizer else { return }

        // Nie ueber eine laufende Task druebersetzen — sonst bleibt sie als
        // Waise zurueck, laeuft in ihren Fehler und cancelt aus dem Callback
        // die lebende Task.
        finishRecognitionTask()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        // `.confirmation` ist fuer kurze Ja/Nein-Antworten gedacht und endet
        // aggressiv. Fuer den Dauerbetrieb ist `.dictation` richtig.
        request.taskHint = .dictation

        stateLock.lock()
        self.request = request
        taskStartedAt = Date()
        stateLock.unlock()

        let newTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let segments = result.bestTranscription.segments.map {
                    VoiceGateSegment(
                        text: $0.substring,
                        start: $0.timestamp,
                        duration: $0.duration,
                        confidence: $0.confidence
                    )
                }
                self.onHypothesis?(
                    VoiceGateHypothesis(segments: segments, isFinal: result.isFinal, receivedAt: Date())
                )
                if result.isFinal { self.renewRecognitionTask() }
                return
            }

            if error != nil {
                // „No speech detected" ist bei Stille der Normalfall, kein
                // Fehler — deshalb nur Debug und gedrosselt erneuern.
                guard self.isRunning else { return }
                Logger.voiceGate.debug("listener.task_ended — Erneuerung geplant")
                self.renewRecognitionTask()
            }
        }

        stateLock.lock()
        task = newTask
        stateLock.unlock()
    }

    /// Immer ueber Main serialisiert und mit Mindestabstand. Ohne den
    /// `pendingRenewal`-Riegel erzeugte ein sofort scheiterndes Task ein
    /// Neustart-Karussell mit ~15 ms Periode.
    private func renewRecognitionTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }

            self.stateLock.lock()
            let alreadyPending = self.pendingRenewal
            if !alreadyPending { self.pendingRenewal = true }
            self.stateLock.unlock()
            guard !alreadyPending else { return }

            self.finishRecognitionTask()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                self.pendingRenewal = false
                self.stateLock.unlock()
                guard self.isRunning else { return }
                self.startRecognitionTask()
            }
        }
    }

    private func finishRecognitionTask() {
        stateLock.lock()
        let currentRequest = request
        let currentTask = task
        request = nil
        task = nil
        taskStartedAt = nil
        stateLock.unlock()

        currentRequest?.endAudio()
        currentTask?.cancel()
    }
}
