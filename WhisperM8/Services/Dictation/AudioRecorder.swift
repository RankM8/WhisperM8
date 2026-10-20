import AppKit
import AVFoundation
import Combine
import CoreAudio

@Observable
class AudioRecorder {
    private var engine: RecorderEngine?
    private var audioFile: RecordingFileWriter?
    private var recordingURL: URL?
    private var converter: AVAudioConverter?
    private let resourceLock = NSLock()

    // For automatic device switching in System Default mode
    private var configurationObserver: NSObjectProtocol?
    private var isUsingSystemDefault: Bool = false
    private var isRestarting: Bool = false
    private var lastConfigChangeTime: Date = .distantPast
    private var buffersWritten: Int = 0
    /// Erster Writer-/Converterfehler dieser Aufnahme (unter `resourceLock`).
    /// Der Audio-Callback setzt nur dieses Flag; die Eskalation läuft async auf Main.
    private var writeFailureMessage: String?

    /// Zählt jede Aufnahme/Engine-Instanz. Fortsetzungen nach einem `await`
    /// (Gerätewechsel) und asynchrone Tap-Meldungen prüfen ihn und tun nichts
    /// mehr, wenn inzwischen gestoppt, unterbrochen oder neu gestartet wurde.
    private var sessionGeneration = 0
    private var reconfigurationTask: Task<Void, Never>?
    /// Serielle Queue für die blockierenden Engine-Aufrufe der Rekonfiguration.
    /// Mitten im Bluetooth-Profilwechsel (AirPods A2DP → HFP) wartet jeder
    /// CoreAudio-Aufruf auf die HAL — am 20.10.2026 fünfmal ~0,8 s hintereinander,
    /// zusammen 4,1 s eingefrorener Main Thread. Seriell, weil AVAudioEngine
    /// nicht threadsicher ist: ein Abbau während der Rekonfiguration reiht sich
    /// hier ein, statt parallel an derselben Engine zu arbeiten.
    private let engineQueue = DispatchQueue(label: "com.whisperm8.audio-engine", qos: .userInitiated)
    /// Teilaufnahme nach einer Unterbrechung — wartet auf das nächste `stopRecording()`.
    private var interruptedPartialURL: URL?
    private var notRunningTicks = 0
    private var wakeObserver: NSObjectProtocol?

    // Target format: 16kHz Mono for optimal API compatibility
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Test-Seams: Benachrichtigungszentrale und Wartefunktion (300-ms-
    /// Stabilisierung, Format-Retries). Defaults = Produktionsverhalten.
    @ObservationIgnored var notificationCenter: NotificationCenter = .default
    @ObservationIgnored var workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    @ObservationIgnored var sleeper: (UInt64) async -> Void = { nanos in
        try? await Task.sleep(nanoseconds: nanos)
    }

    var audioLevel: Float = 0
    var isRecording = false
    /// Engine-Startversuche des letzten Starts (1 = ohne Neustart) — für `debug record`.
    @ObservationIgnored private(set) var lastStartAttempts = 0

    /// Wird (auf dem Main Thread) gemeldet, wenn die Aufnahme von selbst endet.
    @ObservationIgnored var onInterruption: ((RecordingInterruption) -> Void)?

    /// Anzahl aufeinanderfolgender Pegel-Timer-Ticks (100 ms) mit stehender Engine,
    /// bevor die Wiederherstellung angestoßen wird.
    static let healthCheckTicksBeforeRecovery = 3

    /// Vom Pegel-Timer aufgerufen: Steht die Engine ohne Notification still
    /// (Geräteverlust, Ruhezustand), wird sie neu aufgebaut — scheitert das,
    /// endet die Aufnahme sichtbar mit gesicherter Teilaufnahme.
    @MainActor
    func checkEngineHealth() {
        guard isRecording, !isRestarting, let engine else {
            notRunningTicks = 0
            return
        }
        if engine.isRunning {
            notRunningTicks = 0
            return
        }
        notRunningTicks += 1
        guard notRunningTicks >= Self.healthCheckTicksBeforeRecovery else { return }
        notRunningTicks = 0
        Logger.info("[AudioRecorder] Engine steht ohne Konfigurationswechsel still — baue sie neu auf")
        scheduleReconfiguration()
    }

    func startRecording() async throws {
        Logger.debug("[AudioRecorder] ========== START RECORDING ==========")

        // Always cleanup first
        if engine != nil {
            Logger.debug("[AudioRecorder] Cleaning up previous engine")
            _ = stopRecording()
        }

        // Reset state
        audioLevel = 0
        recordingURL = nil
        interruptedPartialURL = nil
        resourceLock.withLock {
            audioFile = nil
            converter = nil
            buffersWritten = 0
            writeFailureMessage = nil
        }
        isRestarting = false
        lastConfigChangeTime = .distantPast

        // Check permission — ist sie erteilt, ohne TCC-Rundreise (Hotkey-Pfad).
        Logger.debug("[AudioRecorder] Requesting microphone permission...")
        let permission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            ? true
            : await AVCaptureDevice.requestAccess(for: .audio)
        Logger.debug("[AudioRecorder] Microphone permission: \(permission)")
        guard permission else {
            Logger.debug("[AudioRecorder] ERROR: Microphone permission denied!")
            throw RecordingError.microphonePermissionDenied
        }

        // Create fresh engine
        let avEngine = AVAudioEngine()
        let engine = AVAudioEngineRecorderEngine(avEngine)
        Logger.debug("[AudioRecorder] Created new AVAudioEngine")

        // Check if using System Default or specific device
        let deviceManager = AudioDeviceManager.shared
        let deviceID = deviceManager.selectedDeviceID
        isUsingSystemDefault = (deviceID == nil)

        Logger.debug("[AudioRecorder] isUsingSystemDefault: \(isUsingSystemDefault)")
        Logger.debug("[AudioRecorder] selectedDeviceUID: \(deviceManager.selectedDeviceUID ?? "nil")")

        // Set specific input device if selected (NOT for System Default)
        if let deviceID = deviceID {
            Logger.debug("[AudioRecorder] Setting specific input device: \(deviceID)")
            let result = setInputDevice(deviceID, for: avEngine)
            Logger.debug("[AudioRecorder] setInputDevice result: \(result)")
        } else {
            Logger.debug("[AudioRecorder] Using System Default - not setting specific device")
            let currentDefault = deviceManager.getDefaultInputDeviceID()
            let currentDefaultName = deviceManager.availableDevices.first { $0.id == currentDefault }?.name ?? "Unknown"
            Logger.debug("[AudioRecorder] Current system default: \(currentDefault) (\(currentDefaultName))")
        }

        // Access inputNode AFTER setting device (this triggers device binding)
        Logger.debug("[AudioRecorder] Accessing inputNode (this binds the device)...")
        let inputNode = avEngine.inputNode

        // Get the actual device being used
        if let audioUnit = inputNode.audioUnit {
            let (currentDeviceID, status) = currentEngineDeviceID(audioUnit)
            if status == noErr {
                let deviceName = deviceManager.availableDevices.first { $0.id == currentDeviceID }?.name ?? "Unknown"
                Logger.debug("[AudioRecorder] Engine actually using device: \(currentDeviceID) (\(deviceName))")
            } else {
                Logger.debug("[AudioRecorder] Could not get current device from AudioUnit: \(status)")
            }
        }

        // Input format from device - MUST use inputFormat(forBus:) for correct hardware format.
        // Mit Retry + Validierung: CoreAudio liefert direkt nach dem Binden
        // (Bluetooth-Wechsel, Systemlast) zeitweise 0 Hz / 0 Kanäle — ein
        // installTap damit wirft eine unfangbare NSException → Prozess-Abort.
        // Gleiche Schutzlogik wie in handleConfigurationChange().
        guard let inputFormat = await waitForRecordableFormat(engine) else {
            Logger.debug("[AudioRecorder] ERROR: No recordable input format after retries — aborting start")
            throw RecordingError.invalidFormat
        }

        // Temp file for M4A output
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        Logger.debug("[AudioRecorder] Recording to: \(url.path)")

        // Audio file settings for M4A (AAC)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)
        try await beginSessionRetryingFormatChange(engine: engine, inputFormat: inputFormat, file: file, url: url)

        Logger.debug("[AudioRecorder] Recording started successfully")
        Logger.debug("[AudioRecorder] =====================================")
    }

    /// Startversuche, wenn `engine.start()` scheitert (siehe unten).
    static let engineStartAttempts = 3

    /// Bluetooth-Headsets (AirPods) wechseln beim Öffnen des Mikrofons das
    /// Profil (A2DP → HFP) — oft erst WÄHREND `engine.start()`. Das
    /// Hardware-Format springt dann (48 → 24 kHz), AVAudioEngine bricht mit
    /// -10868 ab („formats don't match"). Früher endete der Start damit still,
    /// und man musste den Hotkey ein zweites Mal drücken (20.10.2026). Jetzt:
    /// kurz warten, das neue Format lesen, Tap neu installieren, erneut starten.
    func beginSessionRetryingFormatChange(
        engine: RecorderEngine,
        inputFormat: AVAudioFormat,
        file: RecordingFileWriter,
        url: URL
    ) async throws {
        var format = inputFormat
        for attempt in 1...Self.engineStartAttempts {
            lastStartAttempts = attempt
            do {
                try beginSession(engine: engine, inputFormat: format, file: file, url: url)
                if attempt > 1 {
                    Logger.info("[AudioRecorder] Engine-Start im Versuch \(attempt) gelungen (\(format.sampleRate)Hz)")
                }
                return
            } catch {
                guard attempt < Self.engineStartAttempts else { throw error }
                Logger.info(
                    "[AudioRecorder] Engine-Start fehlgeschlagen (Versuch \(attempt), \(format.sampleRate)Hz) — "
                    + "warte auf das neue Geräteformat: \(error.localizedDescription)"
                )
                engine.stop()
                await sleeper(150_000_000)
                guard let newFormat = await waitForRecordableFormat(engine) else { throw error }
                format = newFormat
            }
        }
    }

    /// Liest das Eingangsformat mit bis zu fünf Versuchen à 100 ms: CoreAudio
    /// liefert direkt nach dem Binden (Bluetooth-Wechsel, Systemlast) zeitweise
    /// 0 Hz / 0 Kanäle — ein installTap damit wirft eine unfangbare NSException.
    private func waitForRecordableFormat(_ engine: RecorderEngine) async -> AVAudioFormat? {
        for attempt in 1...5 {
            let format = engine.currentInputFormat()
            if let format, AudioFormatDecision.isRecordable(format) {
                Logger.debug("[AudioRecorder] Input format (attempt \(attempt)): \(format.sampleRate)Hz, \(format.channelCount) channels")
                return format
            }
            Logger.debug("[AudioRecorder] Input format invalid (attempt \(attempt)): \(format?.sampleRate ?? 0)Hz, \(format?.channelCount ?? 0)ch — retrying…")
            await sleeper(100_000_000) // 100ms
        }
        return nil
    }

    /// Gemeinsamer Kern von Erststart und Tests: Converter, Datei, Tap,
    /// Engine-Start und Beobachter. Fehler räumen selbst auf; `startRecording`
    /// reicht sie nur durch.
    func beginSession(
        engine: RecorderEngine,
        inputFormat: AVAudioFormat,
        file: RecordingFileWriter,
        url: URL
    ) throws {
        // Neue Generation VOR dem Tap: seine Meldungen gehören zu genau diesem Lauf.
        sessionGeneration += 1

        // Create converter if needed
        if AudioFormatDecision.needsConversion(from: inputFormat, to: targetFormat) {
            Logger.debug("[AudioRecorder] Creating audio converter (input differs from target)")
            let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
            resourceLock.withLock { converter = newConverter }
        } else {
            Logger.debug("[AudioRecorder] No converter needed - formats match")
        }

        resourceLock.withLock {
            audioFile = file
            buffersWritten = 0
            writeFailureMessage = nil
        }
        recordingURL = url
        interruptedPartialURL = nil

        // Install tap for recording + level metering
        Logger.debug("[AudioRecorder] Installing tap on inputNode...")
        do {
            try installRecordingTap(
                on: engine, inputFormat: inputFormat, label: "TAP",
                logHundredthCallback: true, generation: sessionGeneration
            )
        } catch {
            // Statt Prozess-Abort: sauber abbrechen. Der Nutzer bekommt die
            // normale Fehlermeldung und kann es erneut versuchen — beim
            // zweiten Anlauf steht das Gerät meist stabil.
            Logger.info("[AudioRecorder] ERROR: Tap konnte nicht installiert werden — \(error.localizedDescription)")
            resourceLock.withLock {
                audioFile = nil
                converter = nil
            }
            recordingURL = nil
            throw RecordingError.invalidFormat
        }

        Logger.debug("[AudioRecorder] Starting engine...")
        do {
            try engine.start()
            Logger.debug("[AudioRecorder] Engine started successfully!")
        } catch {
            Logger.debug("[AudioRecorder] ERROR starting engine: \(error)")
            engine.removeTap()
            resourceLock.withLock {
                audioFile = nil
                converter = nil
            }
            recordingURL = nil
            throw error
        }

        self.engine = engine
        notRunningTicks = 0
        isRecording = true

        // Gerätewechsel und Aufwachen beobachten — in JEDEM Modus: Auch ein
        // fest gewähltes Mikrofon kann verschwinden (abgezogen, Ruhezustand).
        setupConfigurationObserver()
        setupWakeObserver()
    }

    func stopRecording() -> URL? {
        Logger.debug("[AudioRecorder] ========== STOP RECORDING ==========")
        guard isRecording else {
            // Von selbst beendet (Unterbrechung): die gesicherte Teilaufnahme
            // wird genau einmal ausgeliefert, damit der Coordinator sie retten kann.
            if let partial = interruptedPartialURL {
                interruptedPartialURL = nil
                Logger.debug("[AudioRecorder] Not recording, delivering partial file: \(partial.path)")
                return partial
            }
            Logger.debug("[AudioRecorder] Not recording, nothing to stop")
            return nil
        }

        // Alles Hängende abschalten: Beobachter, laufende Rekonfiguration
        // (sie prüft die Generation und fasst nichts mehr an).
        let wasReconfiguring = isRestarting
        removeConfigurationObserver()
        removeWakeObserver()
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        sessionGeneration += 1

        if let engine = engine {
            Logger.debug("[AudioRecorder] Removing tap and stopping engine")
            tearDown(engine, behindReconfiguration: wasReconfiguring)
        }
        engine = nil
        resourceLock.withLock {
            converter = nil
            audioFile = nil
        }
        isRecording = false
        isRestarting = false
        isUsingSystemDefault = false
        audioLevel = 0

        // Save URL and reset
        let url = recordingURL
        recordingURL = nil

        Logger.debug("[AudioRecorder] Recording stopped, file: \(url?.path ?? "nil")")
        Logger.debug("[AudioRecorder] =====================================")
        return url
    }

    // MARK: - Configuration Change Handling

    private func setupConfigurationObserver() {
        guard let engine = engine else {
            Logger.debug("[AudioRecorder] Not setting up config observer (no engine)")
            return
        }
        // Vorhandenen Beobachter ersetzen statt verdoppeln.
        removeConfigurationObserver()

        Logger.debug("[AudioRecorder] Setting up config observer (systemDefault=\(isUsingSystemDefault))")

        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.notificationSource,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Logger.debug("[AudioRecorder] AVAudioEngineConfigurationChange received!")

            // Handle config change asynchronously
            Task { @MainActor in
                self.scheduleReconfiguration()
            }
        }
    }

    /// Nach dem Aufwachen aus dem Ruhezustand steht die Engine oft still, ohne
    /// dass eine Konfigurations-Notification kommt: kurz warten, dann prüfen.
    private func setupWakeObserver() {
        removeWakeObserver()
        wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Logger.info("[AudioRecorder] System aufgewacht während der Aufnahme — prüfe Engine")
            let generation = self.sessionGeneration
            Task { @MainActor in
                await self.sleeper(1_000_000_000)
                guard generation == self.sessionGeneration, self.isRecording, !self.isRestarting,
                      let engine = self.engine, !engine.isRunning else { return }
                self.scheduleReconfiguration()
            }
        }
    }

    private func removeWakeObserver() {
        if let observer = wakeObserver {
            workspaceNotificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// Startet die Rekonfiguration als speicherbaren Task, damit `stopRecording`
    /// sie abbrechen kann.
    @MainActor
    func scheduleReconfiguration() {
        guard isRecording, !isRestarting else { return }
        reconfigurationTask = Task { @MainActor [weak self] in
            await self?.handleConfigurationChange()
        }
    }

    /// Beendet die Aufnahme kontrolliert, weil sie nicht fortgesetzt werden kann
    /// (Gerät weg, Engine/Tap nicht neu startbar, Schreibfehler). Das bis dahin
    /// geschriebene Audio bleibt erhalten und wird vom nächsten `stopRecording()`
    /// geliefert; der Coordinator erfährt es über `onInterruption`.
    /// `generation`: Meldungen aus veralteten Läufen werden verworfen.
    @MainActor
    func interrupt(_ reason: RecordingInterruption, generation: Int? = nil) {
        guard isRecording else { return }
        if let generation, generation != sessionGeneration { return }

        Logger.info("[AudioRecorder] Aufnahme unterbrochen: \(reason)")
        let wasReconfiguring = isRestarting
        removeConfigurationObserver()
        removeWakeObserver()
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        sessionGeneration += 1

        if let engine {
            tearDown(engine, behindReconfiguration: wasReconfiguring)
        }
        engine = nil
        let hadAudio = resourceLock.withLock { () -> Bool in
            let written = buffersWritten > 0
            // Datei schließen (AAC-Container finalisieren), bevor sie weitergereicht wird.
            audioFile = nil
            converter = nil
            return written
        }
        isRecording = false
        isRestarting = false
        isUsingSystemDefault = false
        audioLevel = 0

        if hadAudio {
            interruptedPartialURL = recordingURL
        } else if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil

        onInterruption?(reason)
    }

    /// Abbau der Engine: `removeTap` + `stop`. Beides ist synchron und kann auf
    /// die CoreAudio-HAL warten — siehe `PerfBudgets.engineStop`. Läuft gerade
    /// eine Rekonfiguration, arbeitet die Engine-Queue womöglich noch an genau
    /// dieser Engine (Tap, Start): Dann reiht sich der Abbau dahinter ein — nicht
    /// parallel an derselben Engine und ohne den Main Thread warten zu lassen.
    private func tearDown(_ engine: RecorderEngine, behindReconfiguration: Bool) {
        let work = {
            PerfBudgets.engineStop.withInterval {
                engine.removeTap()
                engine.stop()
            }
        }
        if behindReconfiguration {
            engineQueue.async(execute: work)
        } else {
            work()
        }
    }

    /// Führt blockierende Engine-Aufrufe auf `engineQueue` aus; der Main Thread
    /// wartet nur asynchron. Nach dem `await` prüft der Aufrufer mit `isCurrent()`.
    private func onEngineQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            engineQueue.async { continuation.resume(returning: work()) }
        }
    }

    private enum RestartFailure: Error {
        case tap(Error)
        case start(Error)
    }

    private func removeConfigurationObserver() {
        if let observer = configurationObserver {
            Logger.debug("[AudioRecorder] Removing configuration observer")
            notificationCenter.removeObserver(observer)
            configurationObserver = nil
        }
    }

    @MainActor
    func handleConfigurationChange() async {
        Logger.debug("[AudioRecorder] ========== CONFIG CHANGE ==========")
        guard isRecording, !isRestarting, let engine = engine else {
            Logger.debug("[AudioRecorder] Skip: isRecording=\(isRecording), isRestarting=\(isRestarting), engine=\(engine != nil)")
            return
        }

        let generation = sessionGeneration
        // Nach jedem await: Ist das noch DIESER Lauf? Sonst hat stop/neuer Start
        // alles aufgeräumt — die alte Fortsetzung darf weder Tap noch Converter
        // noch Flags eines neuen Laufs anfassen (LR-DIK-005).
        func isCurrent() -> Bool { generation == sessionGeneration && isRecording }

        isRestarting = true

        // Remove observer to prevent re-entry during handling
        removeConfigurationObserver()

        // 1. Stop engine and remove old tap (but DON'T destroy engine).
        // Alle Engine-Aufrufe ab hier laufen auf `engineQueue`, nie auf Main.
        await onEngineQueue {
            engine.stop()
            engine.removeTap()
        }
        Logger.debug("[AudioRecorder] Tap removed, engine stopped")
        guard isCurrent() else {
            Logger.debug("[AudioRecorder] Config change obsolete (stopped during engine stop)")
            return
        }

        // 2. Wait for Bluetooth HFP profile switch to stabilize (300ms is sufficient)
        Logger.debug("[AudioRecorder] Waiting 300ms for HFP stabilization...")
        await sleeper(300_000_000)
        guard isCurrent() else {
            Logger.debug("[AudioRecorder] Config change obsolete (stopped during stabilization)")
            return
        }

        // 3. Query NEW format with retry logic (format may be temporarily invalid)
        var newFormat: AVAudioFormat?
        let maxRetries = 5

        for attempt in 1...maxRetries {
            // CRITICAL: Use inputFormat(forBus:) NOT outputFormat(forBus:)
            let format = await onEngineQueue { engine.currentInputFormat() }
            guard isCurrent() else {
                Logger.debug("[AudioRecorder] Config change obsolete (stopped during format read)")
                return
            }
            if let format, AudioFormatDecision.isRecordable(format) {
                newFormat = format
                Logger.debug("[AudioRecorder] New format (attempt \(attempt)): \(format.sampleRate)Hz, \(format.channelCount)ch")
                break
            }
            Logger.debug("[AudioRecorder] Format invalid (attempt \(attempt)), retrying...")
            await sleeper(100_000_000) // 100ms
            guard isCurrent() else {
                Logger.debug("[AudioRecorder] Config change obsolete (stopped during format retry)")
                return
            }
        }

        guard let inputFormat = newFormat else {
            Logger.info("[AudioRecorder] ERROR: Kein gültiges Format nach \(maxRetries) Versuchen — Aufnahme wird mit Teilaufnahme beendet")
            interrupt(.deviceLost, generation: generation)
            return
        }

        // 4. Create converter for new format if needed
        if AudioFormatDecision.needsConversion(from: inputFormat, to: targetFormat) {
            Logger.debug("[AudioRecorder] Creating converter: \(inputFormat.sampleRate)Hz → 16kHz")
            let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
            resourceLock.withLock {
                converter = newConverter
            }
            if newConverter == nil {
                Logger.debug("[AudioRecorder] ERROR: Failed to create converter!")
            }
        } else {
            resourceLock.withLock {
                converter = nil
            }
            Logger.debug("[AudioRecorder] No converter needed - format matches target")
        }

        // 5. Install tap with NEW format (use larger buffer for Bluetooth)
        Logger.debug("[AudioRecorder] Installing tap with new format...")
        let hasAudioFile = resourceLock.withLock { self.audioFile != nil }
        Logger.debug("[AudioRecorder] audioFile is \(hasAudioFile ? "valid" : "NIL")")

        // 6. Tap + Neustart in einem Schritt auf der Engine-Queue.
        Logger.debug("[AudioRecorder] Restarting engine...")
        let restart: Result<Void, RestartFailure> = await onEngineQueue { [self] in
            do {
                try installRecordingTap(
                    on: engine, inputFormat: inputFormat, label: "NEW TAP",
                    logHundredthCallback: false, generation: generation
                )
            } catch {
                return .failure(.tap(error))
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                return .failure(.start(error))
            }
            return .success(())
        }
        // Während des Neustarts gestoppt: Der Abbau steht schon hinter uns in der Queue.
        guard isCurrent() else {
            Logger.debug("[AudioRecorder] Config change obsolete (stopped during restart)")
            return
        }
        switch restart {
        case .success:
            Logger.debug("[AudioRecorder] Engine restarted successfully!")
        case .failure(.tap(let error)):
            // Reconnect nach Gerätewechsel: Schlägt der Tap fehl, ist die
            // Aufnahme verloren — aber die App bleibt am Leben. Ohne Tap
            // weiterzulaufen wäre schlimmer als ein sauberer Stopp.
            Logger.info("[AudioRecorder] ERROR: Tap-Reinstall fehlgeschlagen — \(error.localizedDescription)")
            interrupt(.engineFailed(error.localizedDescription), generation: generation)
            return
        case .failure(.start(let error)):
            Logger.info("[AudioRecorder] ERROR: Engine-Neustart fehlgeschlagen — \(error.localizedDescription)")
            interrupt(.engineFailed(error.localizedDescription), generation: generation)
            return
        }

        // Re-setup observer after short delay to avoid immediate re-trigger
        await sleeper(100_000_000) // 100ms
        guard isCurrent() else {
            Logger.debug("[AudioRecorder] Config change obsolete (stopped before observer re-install)")
            return
        }
        setupConfigurationObserver()
        Logger.debug("[AudioRecorder] Config observer re-installed")

        isRestarting = false
        reconfigurationTask = nil
        Logger.debug("[AudioRecorder] ========== CONFIG CHANGE DONE ==========")
    }

    // MARK: - Audio Processing

    /// Installiert den Aufnahme-Tap auf `inputNode`: gedrosseltes Callback-Logging,
    /// Pegelmessung und Schreiben in die Datei. `label` unterscheidet die Log-Zeilen
    /// der beiden Aufrufer ("TAP" beim Erststart, "NEW TAP" beim Format-Reinstall).
    /// `logHundredthCallback` bewahrt das bisherige Verhalten: nur der Erststart
    /// loggt zusaetzlich den 100. Callback. Läuft auch auf `engineQueue` — fasst
    /// daher nur Parameter und lock-geschützten Zustand an (`generation` statt
    /// `sessionGeneration`).
    private func installRecordingTap(
        on engine: RecorderEngine,
        inputFormat requestedFormat: AVAudioFormat,
        label: String,
        logHundredthCallback: Bool,
        generation capturedGeneration: Int
    ) throws {
        // Defensiv: ein evtl. vorhandener Tap würde installTap ebenfalls mit
        // einer unfangbaren NSException quittieren; removeTap ohne Tap ist
        // ein No-op.
        engine.removeTap()

        // Das Format DIREKT VOR dem Tap noch einmal lesen. Zwischen der
        // Prüfung in `startRecording()` und diesem Punkt liegen
        // Converter-Aufbau und das Anlegen der AAC-Datei — am 01.08.2026
        // waren das 1,6 Sekunden, in denen das Gerät von 48 kHz auf 24 kHz
        // wechselte (Bluetooth-Profilwechsel). `installTap` verlangt exakte
        // Übereinstimmung mit dem AKTUELLEN Hardware-Format und wirft sonst.
        var inputFormat = requestedFormat
        if let liveFormat = engine.currentInputFormat(),
           AudioFormatDecision.isRecordable(liveFormat),
           liveFormat.sampleRate != requestedFormat.sampleRate
            || liveFormat.channelCount != requestedFormat.channelCount {
            Logger.info(
                "[AudioRecorder] \(label): Format hat sich seit der Prüfung geändert "
                + "(\(requestedFormat.sampleRate)Hz/\(requestedFormat.channelCount)ch → "
                + "\(liveFormat.sampleRate)Hz/\(liveFormat.channelCount)ch) — übernehme das aktuelle"
            )
            inputFormat = liveFormat
            // Der Converter hing am alten Format und würde falsch resampeln.
            let target = self.targetFormat
            resourceLock.withLock {
                converter = AudioFormatDecision.needsConversion(from: liveFormat, to: target)
                    ? AVAudioConverter(from: liveFormat, to: target)
                    : nil
            }
        }

        var tapCallCount = 0
        let capturedTargetFormat = self.targetFormat
        let capturedFormat = inputFormat
        // Installation (inkl. ObjC-Exception-Schutz) liegt im Engine-Adapter.
        try engine.installTap(format: capturedFormat) { [weak self] buffer in
            guard let self else { return }

            tapCallCount += 1
            if tapCallCount == 1 {
                Logger.debug("[AudioRecorder] \(label): First callback received! frameLength=\(buffer.frameLength)")
            } else if tapCallCount == 10 {
                Logger.debug("[AudioRecorder] \(label): 10 callbacks received")
            } else if logHundredthCallback, tapCallCount == 100 {
                Logger.debug("[AudioRecorder] \(label): 100 callbacks received")
            }

            let level = self.calculateLevel(buffer: buffer)
            Task { @MainActor in
                self.audioLevel = level
            }

            let newFailure = self.writeBuffer(buffer, inputFormat: capturedFormat, targetFormat: capturedTargetFormat)
            if let newFailure {
                // Audio-Callback: nur melden, nie selbst UI/Teardown ausführen.
                DispatchQueue.main.async { [weak self] in
                    self?.interrupt(.writeFailed(newFailure), generation: capturedGeneration)
                }
            }
        }
    }

    /// Fragt die DeviceID ab, die das AudioUnit aktuell als Input nutzt.
    /// Gemeinsamer CoreAudio-Boilerplate beider Aufrufer; das Logging und die
    /// Aufloesung des Geraetenamens bleiben bewusst beim jeweiligen Aufrufer.
    private func currentEngineDeviceID(_ audioUnit: AudioUnit) -> (deviceID: AudioDeviceID, status: OSStatus) {
        var currentDeviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDeviceID,
            &propertySize
        )
        return (currentDeviceID, status)
    }

    private func calculateLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        return AudioLevelMeter.normalized(
            samples: UnsafeBufferPointer(start: channelData, count: frames)
        )
    }

    /// Gibt die Fehlermeldung nur beim ERSTEN Schreib-/Converterfehler zurück
    /// (danach `nil`), damit die Eskalation genau einmal passiert.
    private func writeBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) -> String? {
        resourceLock.withLock {
            let hadFailure = writeFailureMessage != nil
            writeBufferLocked(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
            return hadFailure ? nil : writeFailureMessage
        }
    }

    private func writeBufferLocked(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        // Nach dem ersten Fehler nichts mehr schreiben — bis zur Unterbrechung
        // (async auf Main) kommen noch Buffer an.
        guard writeFailureMessage == nil else { return }
        guard let audioFile else {
            // Log only first time
            if buffersWritten == 0 {
                Logger.debug("[AudioRecorder] writeBuffer: No audioFile!")
            }
            return
        }

        do {
            if let converter = converter {
                // Need to convert
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
                )

                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCapacity
                ) else {
                    if buffersWritten == 0 {
                        Logger.debug("[AudioRecorder] writeBuffer: Failed to create convertedBuffer")
                    }
                    return
                }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .haveData {
                    try audioFile.write(from: convertedBuffer)
                    buffersWritten += 1
                    if buffersWritten == 1 {
                        Logger.debug("[AudioRecorder] First buffer written successfully!")
                    } else if buffersWritten % 100 == 0 {
                        Logger.debug("[AudioRecorder] Buffers written: \(buffersWritten)")
                    }
                } else if status == .error {
                    writeFailureMessage = error?.localizedDescription ?? "Converter-Fehler"
                    Logger.info("[AudioRecorder] writeBuffer: Converter-Fehler — \(writeFailureMessage ?? "")")
                } else {
                    if buffersWritten == 0 {
                        Logger.debug("[AudioRecorder] writeBuffer: Converter status = \(status.rawValue), error = \(error?.localizedDescription ?? "nil")")
                    }
                }
            } else {
                // No conversion needed
                try audioFile.write(from: buffer)
                buffersWritten += 1
                if buffersWritten == 1 {
                    Logger.debug("[AudioRecorder] First buffer written successfully (no conversion)!")
                }
            }
        } catch {
            // Erster Schreibfehler (Platte voll, Dateisystem weg): merken; die
            // Eskalation macht der Aufrufer außerhalb des Locks.
            writeFailureMessage = error.localizedDescription
            Logger.info("[AudioRecorder] writeBuffer ERROR nach \(buffersWritten) Buffern: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func setInputDevice(_ deviceID: AudioDeviceID, for engine: AVAudioEngine) -> OSStatus {
        // Access inputNode first to create the AudioUnit
        guard let audioUnit = engine.inputNode.audioUnit else {
            Logger.debug("[AudioRecorder] ERROR: No audioUnit on inputNode!")
            return -1
        }
        var deviceIDValue = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDValue,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        Logger.debug("[AudioRecorder] AudioUnitSetProperty status: \(status)")
        return status
    }
}

/// Grund, warum eine Aufnahme ohne Nutzer-Stopp endete.
enum RecordingInterruption: Equatable {
    case deviceLost
    case engineFailed(String)
    case writeFailed(String)
}

// MARK: - Recording Errors

enum RecordingError: LocalizedError {
    case microphonePermissionDenied
    case recordingFailed
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Please allow access in System Settings."
        case .recordingFailed:
            return "Recording failed. Please try again."
        case .invalidFormat:
            return "Invalid audio format."
        }
    }
}
