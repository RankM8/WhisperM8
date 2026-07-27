import AVFoundation
import Foundation
import Speech

// ==============================================================================
// Der mithoerende Listener.
//
// Eigener AVAudioEngine-Tap, EXPLIZIT an ein Geraet gebunden — nie „System
// Default". Das ist der Kern der Unabhaengigkeit: der Listener haengt am
// Hardware-Mikrofon und bleibt hoerend, egal was Codex mit seinem eigenen
// Eingang macht. Im Spike am 26.07.2026 nachgewiesen: zwei gleichzeitige
// CoreAudio-Clients auf demselben AirPods-Mikro stoeren sich nicht.
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
    private let deviceIDProvider: () -> AudioDeviceID?

    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStartedAt: Date?
    private var configurationObserver: NSObjectProtocol?
    /// Schuetzt `request`/`task` gegen den Audio-Thread, der parallel Puffer
    /// anhaengt, waehrend die Erneuerung auf Main laeuft.
    private let stateLock = NSLock()
    /// Verhindert den Erneuerungs-Sturm: „No speech detected" kommt bei Stille
    /// regulaer, und eine synchrone Erneuerung im Callback erzeugte daraus eine
    /// Endlosschleife (gemessen: 4796 Fehler in 90 s).
    private var pendingRenewal = false

    private(set) var isRunning = false

    /// Neue Hypothese. Kommt auf einer beliebigen Queue.
    var onHypothesis: ((VoiceGateHypothesis) -> Void)?
    /// Laufzeitfehler nach erfolgreichem Start (Geraetewechsel, Task-Abbruch).
    var onRuntimeError: ((Error) -> Void)?

    init(
        locale: Locale = Locale(identifier: "de_DE"),
        deviceIDProvider: @escaping () -> AudioDeviceID? = { AudioDeviceManager.shared.selectedDeviceID }
    ) {
        self.locale = locale
        self.deviceIDProvider = deviceIDProvider
    }

    // MARK: - Locale-Auswahl

    /// Beste Regionalvariante, fuer die ein On-Device-Modell bereitliegt.
    /// Bindeglied zwischen dem puren `VoiceGateLocaleResolver` und dem
    /// Speech-Framework.
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

        try startEngine()
        startRecognitionTask()
        observeConfigurationChanges()

        isRunning = true
        Logger.voiceGate.info("listener.started locale=\(self.locale.identifier, privacy: .public)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        finishRecognitionTask()

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        recognizer = nil

        Logger.voiceGate.info("listener.stopped")
    }

    // MARK: - Audio

    private func startEngine() throws {
        let engine = AVAudioEngine()

        // Geraet VOR dem ersten Zugriff auf das Format binden — derselbe
        // Ablauf wie im AudioRecorder, sonst haengt der Tap am Default.
        if let deviceID = deviceIDProvider(), let audioUnit = engine.inputNode.audioUnit {
            var value = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &value,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                Logger.voiceGate.warning("listener.device_bind_failed status=\(status)")
            }
        }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceGateListenerError.audioEngineFailed("ungültiges Eingabeformat \(format)")
        }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw VoiceGateListenerError.audioEngineFailed(error.localizedDescription)
        }

        self.engine = engine
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        // Wichtig: JEDER Puffer geht durch, auch Stille. Wuerde hier bei
        // leisem Pegel ausgesetzt, verschwaende die Pause vor dem Codewort —
        // und genau an ihr erkennt der Matcher die Aeusserungsgrenze.
        stateLock.lock()
        let currentRequest = request
        let startedAt = taskStartedAt
        stateLock.unlock()

        currentRequest?.append(buffer)

        if let startedAt, Date().timeIntervalSince(startedAt) > maxTaskDuration {
            renewRecognitionTask()
        }
    }

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            Logger.voiceGate.info("listener.configuration_changed — Engine wird neu gebunden")
            self.restartAfterConfigurationChange()
        }
    }

    private func restartAfterConfigurationChange() {
        finishRecognitionTask()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil

        do {
            try startEngine()
            startRecognitionTask()
        } catch {
            isRunning = false
            Logger.voiceGate.error("listener.restart_failed \(error.localizedDescription, privacy: .public)")
            onRuntimeError?(error)
        }
    }

    // MARK: - Erkennung

    private func startRecognitionTask() {
        guard let recognizer else { return }

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
            guard let self, self.isRunning, !self.pendingRenewal else { return }
            self.pendingRenewal = true
            self.finishRecognitionTask()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.pendingRenewal = false
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
