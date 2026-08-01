import AVFoundation
import Foundation

// ==============================================================================
// Die Audio-Quelle des Voice Gates — und damit die einzige Stelle, an der
// AVAudioEngine, Tap und Geraetewechsel angefasst werden.
//
// Warum als Protokoll: Der Gerätewechsel-Pfad war bis 27.07.2026 nicht
// testbar und entsprechend kaputt — nach dem ERSTEN Wechsel (AirPods raus)
// blieb der Konfigurations-Beobachter an der verworfenen Engine haengen, der
// zweite (AirPods rein) kam nie an, und der Listener war stumm ohne Fehler.
// Mit dieser Naht laesst sich genau das im Unit-Test durchspielen.
// ==============================================================================

protocol VoiceGateAudioSource: AnyObject {
    /// Jeder aufgenommene Puffer — auf einem beliebigen Thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }

    /// Nach einem Geraete-/Konfigurationswechsel wurde neu gebunden.
    /// `false` heisst: die Quelle liefert nichts mehr und muss verworfen werden.
    var onRebind: ((Bool) -> Void)? { get set }

    func start() throws
    func stop()

    /// Kurzbeschreibung des aktuell gebundenen Eingangs — fuers Log.
    var deviceLabel: String { get }
}

/// Produktionsimplementierung auf `AVAudioEngine`.
///
/// Folgt bewusst dem seit Langem bewaehrten Ablauf aus `AudioRecorder`:
/// dieselbe Engine behalten, nach dem Wechsel 300 ms fuer die
/// Bluetooth-HFP-Umschaltung warten, das Format mit Wiederholungen abfragen und
/// den Beobachter danach **neu armieren**. Genau diese drei Dinge fehlten hier.
final class AVAudioEngineVoiceGateAudioSource: VoiceGateAudioSource {
    /// Wartezeit, bis die Bluetooth-HFP-Umschaltung steht.
    private let hfpSettleDelay: TimeInterval = 0.3
    /// Das Eingabeformat ist waehrend der Umschaltung kurzzeitig ungueltig.
    private let formatRetries = 5
    private let formatRetryDelay: TimeInterval = 0.1
    /// Verzoegerung vor dem Neu-Armieren, damit der eigene Neustart nicht
    /// sofort die naechste Benachrichtigung ausloest (wie im AudioRecorder).
    private let observerRearmDelay: TimeInterval = 0.1

    private let deviceIDProvider: () -> AudioDeviceID?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var isRebinding = false

    private(set) var deviceLabel: String = "unbekannt"

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onRebind: ((Bool) -> Void)?

    init(deviceIDProvider: @escaping () -> AudioDeviceID? = { AudioDeviceManager.shared.selectedDeviceID }) {
        self.deviceIDProvider = deviceIDProvider
    }

    deinit {
        // Ohne das bleibt bei einem verworfenen Objekt der Beobachter stehen.
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - Lebenszyklus

    func start() throws {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        self.engine = engine
        try bindAndStart(engine)
        armConfigurationObserver()
    }

    func stop() {
        removeConfigurationObserver()

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isRebinding = false
    }

    // MARK: - Bindung

    private func bindAndStart(_ engine: AVAudioEngine) throws {
        // Geraet VOR dem ersten Zugriff auf das Format binden. Fuer Bluetooth
        // liefert der Provider bewusst `nil` (HFP-Umschaltung gehoert macOS) —
        // dann folgt die Engine dem System-Standard. Das ist beabsichtigt.
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
        guard let resolved = resolveInputFormat(of: inputNode) else {
            throw VoiceGateListenerError.audioEngineFailed("kein gültiges Eingabeformat nach \(formatRetries) Versuchen")
        }

        // Dieselbe Absicherung wie im Diktat-Recorder: Zwischen dem Auflösen
        // des Formats und dem Tap kann das Gerät wechseln (HFP-Umschaltung),
        // und `installTap` quittiert einen Mismatch mit einer NSException,
        // die Swift nicht fangen kann — das hat am 01.08.2026 den Prozess
        // gekillt. Format direkt davor noch einmal lesen, den Rest fängt der
        // ObjC-Shim ab.
        let live = inputNode.inputFormat(forBus: 0)
        let format = (live.sampleRate > 0 && live.channelCount > 0) ? live : resolved
        do {
            try ObjCException.catching {
                inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                    self?.onBuffer?(buffer)
                }
            }
        } catch {
            throw VoiceGateListenerError.audioEngineFailed("Tap abgelehnt: \(error.localizedDescription)")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw VoiceGateListenerError.audioEngineFailed(error.localizedDescription)
        }

        deviceLabel = "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
        Logger.voiceGate.info(
            "listener.device bound=\(self.deviceIDProvider() != nil ? "explicit" : "systemDefault", privacy: .public) format=\(self.deviceLabel, privacy: .public)"
        )
    }

    /// Waehrend der HFP-Umschaltung meldet der Eingang kurzzeitig 0 Hz.
    private func resolveInputFormat(of inputNode: AVAudioInputNode) -> AVAudioFormat? {
        for attempt in 1...formatRetries {
            let format = inputNode.inputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                if attempt > 1 {
                    Logger.voiceGate.info("listener.format_ok attempt=\(attempt, privacy: .public)")
                }
                return format
            }
            Thread.sleep(forTimeInterval: formatRetryDelay)
        }
        return nil
    }

    // MARK: - Konfigurationswechsel

    private func armConfigurationObserver() {
        removeConfigurationObserver()
        guard let engine else { return }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        Logger.voiceGate.info("listener.observer_armed engine=\(ObjectIdentifier(engine).debugDescription, privacy: .public)")
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    private func handleConfigurationChange() {
        guard engine != nil, !isRebinding else { return }
        isRebinding = true
        Logger.voiceGate.info("listener.configuration_changed — Rebind startet")

        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.rebind()
            self.isRebinding = false
            Logger.voiceGate.info("listener.restarted ok=\(ok, privacy: .public)")
            self.onRebind?(ok)
        }
    }

    /// Dieselbe Engine behalten und neu aufsetzen — so macht es der
    /// AudioRecorder, und so bleibt auch die Beobachter-Bindung gueltig.
    private func rebind() async -> Bool {
        guard let engine else { return false }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        // Der Bluetooth-Profilwechsel braucht einen Moment, sonst ist das
        // Format noch das alte oder ungueltig.
        try? await Task.sleep(nanoseconds: UInt64(hfpSettleDelay * 1_000_000_000))

        do {
            try bindAndStart(engine)
        } catch {
            Logger.voiceGate.error("listener.rebind_failed \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Neu armieren — ohne das war der Beobachter nach dem ersten Wechsel
        // tot, und der zweite (AirPods rein) kam nie an.
        try? await Task.sleep(nanoseconds: UInt64(observerRearmDelay * 1_000_000_000))
        armConfigurationObserver()
        return true
    }
}
