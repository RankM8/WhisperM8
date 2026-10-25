import AudioToolbox
import CoreAudio
import Foundation

/// Reduziert die System-Lautstaerke waehrend einer Aufnahme und stellt sie
/// am Ende deterministisch wieder her — auch bei AirPods und anderen
/// Bluetooth-Devices, die ihr eigenes Profil-Switching machen.
///
/// **Designprinzipien:**
///
/// 1. **Pre-Switch-Capture.** Die Original-Volume wird *vor* dem Start des
///    `AVAudioEngine` gelesen (also vor dem A2DP→HFP-Profile-Switch bei
///    Bluetooth-Devices). Der Coordinator MUSS `beginCapture()` aufrufen
///    bevor er den Recorder startet.
///
/// 2. **Bluetooth erst im Headset-Profil ducken.** AirPods merken sich fuer
///    Musik- (A2DP) und Headset-Profil (HFP) je eine eigene Lautstaerke. Wer
///    im Musik-Profil auf 20 % stellt, bekommt diese 20 % beim Rueckwechsel
///    nach der Aufnahme wieder — auch dann, wenn wir laengst zurueckgestellt
///    haben (das Zurueckstellen trifft ja das Headset-Profil). Nimmt die
///    Aufnahme ueber ein Bluetooth-Mikrofon auf, wartet das Ducken deshalb, bis
///    der Ausgang im Headset-Profil ist; das Musik-Profil bleibt unangetastet.
///    Vorfall 25.10.2026: Rueckwechsel 2,1 s nach dem Stop, Settle-Window war
///    nach 2,0 s zu, AirPods blieben auf 10 %.
///
/// 3. **Multi-Device-Capture.** Jedes Device, das waehrend der Session jemals
///    Default-Output war, wird tracked und am Ende restored.
///
/// 4. **Settle-Window erkennt den eigenen Duck-Wert.** Nach `endCapture()`
///    wird alles sofort zurueckgestellt und danach 8 s lang beobachtet. In
///    dieser Zeit stellt der Manager nur dann erneut zurueck, wenn ein Geraet
///    wieder auf *unserem* Duck-Wert steht — das ist das Profil-Gedaechtnis
///    des Bluetooth-Stacks, nicht der Nutzer. Dreht der Nutzer selbst, bleibt
///    sein Wert stehen; deshalb darf das Fenster grosszuegig sein.
///
/// 5. **Journal auf Disk.** Jede geduckte Lautstaerke steht bis zur
///    bestaetigten Rueckstellung im `AudioDuckingJournal`. Absturz, `make kill`
///    oder ein mitten in der Aufnahme getrenntes Geraet werden beim naechsten
///    Start bzw. beim Wiederauftauchen des Geraets nachgeholt.
///
/// 6. **Keine User-Eingriff-Detection waehrend der Aufnahme.** Dreht der User
///    mitten in der Aufnahme, wird am Ende trotzdem auf Original gesetzt: Ein
///    BT-Profile-Switch erzeugt waehrend der Aufnahme dasselbe Signal wie ein
///    Slider-Klick.
@MainActor
final class AudioDuckingManager {
    static let shared = AudioDuckingManager()

    enum Phase: Equatable {
        case idle
        case capturing
        case restoring
    }

    private struct DeviceCapture {
        let deviceID: AudioDeviceID
        let uid: String?
        let name: String
        var originalVolume: Float
        /// `nil`, solange das Geraet noch nicht geduckt ist (Bluetooth wartet
        /// auf das Headset-Profil). Nur geduckte Geraete werden restored.
        var appliedTarget: Float?
    }

    private let volumeController: AudioVolumeControlling
    private let journal: AudioDuckingJournal
    private let recordingInputDeviceID: () -> AudioDeviceID?
    private let now: () -> Date
    private let settleWindowDuration: TimeInterval
    private let enforceInterval: TimeInterval
    private let headsetSwitchTimeout: TimeInterval
    private(set) var phase: Phase = .idle
    private var captures: [AudioDeviceID: DeviceCapture] = [:]
    private var deferredDuckDeadline: Date?
    private var routingListenerToken: Any?
    private var recoveryListenerToken: Any?
    private var settleTask: Task<Void, Never>?
    private var enforceTask: Task<Void, Never>?

    /// Toleranz fuer Volume-Vergleiche. CoreAudio quantisiert intern auf
    /// ~ 1/100 Schritten; 0.01 fasst das gut.
    private static let volumeTolerance: Float = 0.01
    /// So nah muss ein Wert am Duck-Wert liegen, um als „unser" Wert zu gelten.
    /// Breiter als `volumeTolerance`, weil das Headset-Profil auf 1/16-Stufen
    /// rundet (10 % kommt dort als 6,25 % oder 12,5 % zurueck).
    private static let ownDuckTolerance: Float = 0.05

    init(
        volumeController: AudioVolumeControlling = CoreAudioVolumeController(),
        journal: AudioDuckingJournal = AudioDuckingJournal(),
        recordingInputDeviceID: @escaping () -> AudioDeviceID? = AudioDuckingManager.currentRecordingInputDeviceID,
        now: @escaping () -> Date = Date.init,
        settleWindowDuration: TimeInterval = 8.0,
        enforceInterval: TimeInterval = 0.2,
        headsetSwitchTimeout: TimeInterval = 3.0
    ) {
        self.volumeController = volumeController
        self.journal = journal
        self.recordingInputDeviceID = recordingInputDeviceID
        self.now = now
        self.enforceInterval = enforceInterval
        self.settleWindowDuration = settleWindowDuration
        self.headsetSwitchTimeout = headsetSwitchTimeout
    }

    /// Das Mikrofon, das der Recorder benutzen wird: die Auswahl in den
    /// Einstellungen, sonst der System-Default (Bluetooth-Auswahlen loest
    /// `AudioDeviceManager` ohnehin auf den System-Default auf).
    nonisolated static func currentRecordingInputDeviceID() -> AudioDeviceID? {
        let manager = AudioDeviceManager.shared
        let deviceID = manager.selectedDeviceID ?? manager.getDefaultInputDeviceID()
        return deviceID == 0 ? nil : deviceID
    }

    /// Whether audio ducking is enabled (from UserDefaults).
    var isEnabled: Bool {
        AppPreferences.shared.isAudioDuckingEnabled
    }

    /// Target volume level during recording.
    var targetVolume: Float {
        min(max(Float(AppPreferences.shared.audioDuckingFactor), 0.01), 1)
    }

    var hasActiveDuckingSession: Bool {
        phase != .idle
    }

    /// Eintritt in die Capturing-Phase. MUSS vor `audioRecorder.startRecording()`
    /// aufgerufen werden — sonst capturen wir die Volume erst nach dem
    /// Bluetooth-Profile-Switch und merken uns einen falschen "Original"-Wert.
    func beginCapture() {
        Logger.audio.info("[AudioDucking] beginCapture entered: phase=\(String(describing: self.phase), privacy: .public) enabled=\(self.isEnabled, privacy: .public) target=\(self.format(self.targetVolume), privacy: .public)")
        guard isEnabled else {
            Logger.audio.info("[AudioDucking] Disabled; skipping beginCapture")
            return
        }

        switch phase {
        case .capturing:
            // Schon aktiv — KEIN teardown, sonst wuerde der frische captureAndDuck
            // die bereits geduckte Volume als neues "Original" einlesen → Permadown.
            Logger.audio.info("[AudioDucking] beginCapture during .capturing — no-op")
            return
        case .restoring:
            // Zweites Diktat im Settle-Window: Originale mitnehmen statt neu
            // lesen — sonst gilt ein vom BT-Stack zurueckgespielter Duck-Wert
            // als „schon leise genug" und wird nie mehr restored.
            Logger.audio.info("[AudioDucking] beginCapture during .restoring — carrying over \(self.captures.count, privacy: .public) capture(s)")
            settleTask?.cancel()
            settleTask = nil
            carryOverCaptures()
        case .idle:
            break
        }

        phase = .capturing
        deferredDuckDeadline = now().addingTimeInterval(headsetSwitchTimeout)
        installRoutingListener()
        captureAndDuckCurrentDevice()
        startCapturingEnforceLoop()
    }

    /// Der Recorder laeuft. Bei Bluetooth ist der Ausgang jetzt meist im
    /// Headset-Profil — ein wartendes Ducken sofort nachziehen statt erst
    /// beim naechsten Enforce-Tick.
    func recorderDidStart() {
        guard phase == .capturing else { return }
        captureAndDuckCurrentDevice()
    }

    /// Verlaesst die Capturing-Phase: setzt alle bekannten Devices auf ihre
    /// Original-Volumes und startet das Settle-Window.
    func endCapture() {
        Logger.audio.info("[AudioDucking] endCapture entered: phase=\(String(describing: self.phase), privacy: .public) capturedDevices=\(self.captures.count, privacy: .public)")
        guard phase == .capturing else {
            Logger.audio.info("[AudioDucking] endCapture called in phase \(String(describing: self.phase), privacy: .public); ignoring")
            return
        }

        enforceTask?.cancel()
        enforceTask = nil
        phase = .restoring
        restoreAllDevices(onlyOwnDuck: false)
        startSettleWindow()
    }

    /// Sofortiger Abbau ohne Settle-Window — nur fuer App-Quit.
    /// Was danach noch geduckt ist, holt das Journal beim naechsten Start nach.
    func endCaptureImmediate() {
        guard phase != .idle else { return }
        restoreAllDevices(onlyOwnDuck: phase == .restoring)
        finishSession()
    }

    /// Holt Rueckstellungen nach, die eine fruehere Session nicht abschliessen
    /// konnte (Absturz, getrenntes Geraet). Beim App-Start und immer dann,
    /// wenn sich der Default-Output aendert, solange noch etwas offen ist.
    func recoverPendingRestores() {
        defer { updateRecoveryListener() }
        // Waehrend einer Session uebernimmt `captureAndDuck` das Journal.
        guard phase == .idle else { return }

        for entry in journal.entries {
            if now().timeIntervalSince(entry.duckedAt) > AudioDuckingJournal.maxAge {
                Logger.audio.info("[AudioDucking] Dropping stale pending restore for \(entry.name, privacy: .public)")
                journal.remove(uid: entry.uid)
                continue
            }
            guard let deviceID = volumeController.deviceID(forUID: entry.uid),
                  let current = try? volumeController.readVolume(deviceID: deviceID) else {
                // Geraet (noch) nicht da — Eintrag bleibt fuer spaeter.
                continue
            }
            if isOwnDuck(current, target: entry.duckedVolume),
               abs(current - entry.originalVolume) > Self.volumeTolerance {
                do {
                    try volumeController.setVolume(entry.originalVolume, deviceID: deviceID)
                    Logger.audio.info("[AudioDucking] Recovered \(entry.name, privacy: .public): \(self.format(current), privacy: .public) → \(self.format(entry.originalVolume), privacy: .public)")
                } catch {
                    Logger.audio.error("[AudioDucking] Recovery failed for \(entry.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            journal.remove(uid: entry.uid)
        }
    }

    // MARK: - Test introspection

    #if DEBUG
    var debug_capturedDeviceIDs: Set<AudioDeviceID> {
        Set(captures.keys)
    }

    func debug_originalVolume(for deviceID: AudioDeviceID) -> Float? {
        captures[deviceID]?.originalVolume
    }

    var debug_hasRecoveryListener: Bool {
        recoveryListenerToken != nil
    }
    #endif

    // MARK: - Internals

    private func captureAndDuckCurrentDevice() {
        do {
            let deviceID = try volumeController.defaultOutputDeviceID()
            captureAndDuck(deviceID: deviceID)
        } catch {
            Logger.audio.error("[AudioDucking] Could not determine default output device: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func captureAndDuck(deviceID: AudioDeviceID) {
        // Wenn wir das Geraet schon in der Session beruehrt haben, nur ggf.
        // nachducken (Volume wurde extern erhoeht) — Original bleibt unveraendert.
        // Bluetooth noch im Musik-Profil: weder ducken noch nachducken (auch
        // nicht bei einem mitgenommenen Capture aus dem Settle-Window).
        if let existing = captures[deviceID] {
            guard !waitsForHeadsetMode(deviceID: deviceID) else { return }
            if existing.appliedTarget == nil {
                guard let current = try? volumeController.readVolume(deviceID: deviceID) else { return }
                duck(deviceID: deviceID, current: current)
            } else {
                redockIfNeeded(deviceID: deviceID, name: existing.name)
            }
            return
        }

        // Erstkontakt mit diesem Device: Volume lesen.
        let current: Float
        do {
            current = try volumeController.readVolume(deviceID: deviceID)
        } catch {
            // Geraet hat keine kontrollierbare Volume (HDMI, Aggregate, ...)
            // oder ist verschwunden. Wir tracken es nicht.
            Logger.audio.info("[AudioDucking] Skip capture for device \(deviceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let name = volumeController.deviceName(deviceID: deviceID)
        let uid = volumeController.deviceUID(deviceID: deviceID)
        let target = targetVolume

        // Steht das Geraet noch auf einem Duck-Wert einer abgebrochenen
        // Session, ist der gemerkte Wert das echte Original.
        var original = current
        if let uid, let pending = journal.entry(forUID: uid),
           isOwnDuck(current, target: pending.duckedVolume) {
            original = pending.originalVolume
            Logger.audio.info("[AudioDucking] \(name, privacy: .public) still at a ducked level (\(self.format(current), privacy: .public)); original from journal: \(self.format(original), privacy: .public)")
        }

        guard original > target + Self.volumeTolerance else {
            // Schon leise genug — nichts tun. Insbesondere KEIN Capture-Eintrag
            // erzeugen, sonst wuerde Restore spaeter eine eventuell vom User
            // erhoehte Volume wieder runterdruecken.
            Logger.audio.info("[AudioDucking] \(name, privacy: .public) already at/below target (\(self.format(current), privacy: .public)); skipping capture")
            return
        }

        captures[deviceID] = DeviceCapture(
            deviceID: deviceID,
            uid: uid,
            name: name,
            originalVolume: original,
            appliedTarget: nil
        )

        if waitsForHeadsetMode(deviceID: deviceID) {
            Logger.audio.info("[AudioDucking] Captured \(name, privacy: .public) at \(self.format(original), privacy: .public); duck waits for headset profile")
            return
        }
        duck(deviceID: deviceID, current: current)
    }

    /// Bluetooth-Ausgang, Aufnahme ueber ein Bluetooth-Mikrofon, noch im
    /// Musik-Profil: Ducken wuerde das Musik-Profil treffen (siehe Prinzip 2).
    private func waitsForHeadsetMode(deviceID: AudioDeviceID) -> Bool {
        guard volumeController.isBluetooth(deviceID: deviceID),
              !volumeController.isInHeadsetMode(deviceID: deviceID),
              let inputID = recordingInputDeviceID(),
              volumeController.isBluetooth(deviceID: inputID) else {
            return false
        }
        if let deadline = deferredDuckDeadline, now() >= deadline {
            return false
        }
        return true
    }

    private func duck(deviceID: AudioDeviceID, current: Float) {
        guard var capture = captures[deviceID] else { return }
        let target = targetVolume

        if current > target + Self.volumeTolerance {
            do {
                try volumeController.setVolume(target, deviceID: deviceID)
            } catch {
                Logger.audio.error("[AudioDucking] Duck failed for \(capture.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        capture.appliedTarget = target
        captures[deviceID] = capture
        if let uid = capture.uid {
            journal.record(.init(
                uid: uid,
                name: capture.name,
                originalVolume: capture.originalVolume,
                duckedVolume: target,
                duckedAt: now()
            ))
        }
        let headset = volumeController.isInHeadsetMode(deviceID: deviceID) ? " (headset profile)" : ""
        Logger.audio.info("[AudioDucking] Captured+ducked \(capture.name, privacy: .public)\(headset, privacy: .public): \(self.format(current), privacy: .public) → \(self.format(target), privacy: .public) original=\(self.format(capture.originalVolume), privacy: .public)")
    }

    private func redockIfNeeded(deviceID: AudioDeviceID, name: String) {
        let target = targetVolume
        let current: Float
        do {
            current = try volumeController.readVolume(deviceID: deviceID)
        } catch {
            return
        }
        guard current > target + Self.volumeTolerance else { return }

        do {
            try volumeController.setVolume(target, deviceID: deviceID)
            captures[deviceID]?.appliedTarget = target
            // Periodischer Re-Duck nach BT-Profile-Switch — auf .info, weil das die
            // Stelle ist an der wir die System-Volume gegen den BT-Stack durchsetzen.
            Logger.audio.info("[AudioDucking] Re-ducked \(name, privacy: .public): \(self.format(current), privacy: .public) → \(self.format(target), privacy: .public)")
        } catch {
            Logger.audio.error("[AudioDucking] Re-duck failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `onlyOwnDuck: false` direkt beim Stop: alles Geduckte zurueck.
    /// `onlyOwnDuck: true` im Settle-Window: nur Geraete, die wieder auf
    /// unserem Duck-Wert stehen — ein Wert, den der Nutzer selbst gedreht
    /// hat, bleibt.
    private func restoreAllDevices(onlyOwnDuck: Bool) {
        for capture in captures.values {
            guard let target = capture.appliedTarget else { continue }
            let current: Float
            do {
                current = try volumeController.readVolume(deviceID: capture.deviceID)
            } catch {
                if !onlyOwnDuck {
                    Logger.audio.error("[AudioDucking] \(capture.name, privacy: .public) unreachable for restore (journal keeps it): \(error.localizedDescription, privacy: .public)")
                }
                continue
            }
            guard abs(current - capture.originalVolume) > Self.volumeTolerance else { continue }
            if onlyOwnDuck, !isOwnDuck(current, target: target) { continue }

            do {
                try volumeController.setVolume(capture.originalVolume, deviceID: capture.deviceID)
                Logger.audio.info("[AudioDucking] Restored \(capture.name, privacy: .public): \(self.format(current), privacy: .public) → \(self.format(capture.originalVolume), privacy: .public)")
            } catch {
                Logger.audio.error("[AudioDucking] Restore failed for \(capture.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Zweites Diktat im Settle-Window: das Original bleibt, wenn das Geraet
    /// gerade auf unserem Duck-Wert steht; sonst gilt der aktuelle Wert (der
    /// Nutzer hat zwischen den Diktaten gedreht).
    private func carryOverCaptures() {
        for (deviceID, capture) in captures {
            guard let current = try? volumeController.readVolume(deviceID: deviceID) else { continue }
            let isLeftover = capture.appliedTarget.map { isOwnDuck(current, target: $0) } ?? false
            guard !isLeftover else { continue }
            captures[deviceID]?.originalVolume = current
        }
    }

    private func isOwnDuck(_ volume: Float, target: Float) -> Bool {
        abs(volume - target) <= Self.ownDuckTolerance
    }

    private func installRoutingListener() {
        guard routingListenerToken == nil else { return }
        routingListenerToken = volumeController.addDefaultOutputDeviceListener { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleRoutingChange()
            }
        }
    }

    private func handleRoutingChange() {
        switch phase {
        case .capturing:
            // Neues Default-Device → ggf. capturen und ducken.
            captureAndDuckCurrentDevice()
        case .restoring:
            // Verzoegerter Routing-Switch (z. B. HFP→A2DP-Reverse).
            restoreAllDevices(onlyOwnDuck: true)
        case .idle:
            // Spaeter Listener-Fire nach Teardown — unschaedlich.
            break
        }
    }

    /// Periodisches Re-Ducken waehrend `.capturing`. Notwendig weil Bluetooth-
    /// Profile-Switches (A2DP↔HFP auf dem GLEICHEN Device) KEIN Default-Output-
    /// Routing-Event ausloesen — sie aendern aber die Volume-Property. Derselbe
    /// Tick zieht ein wartendes Bluetooth-Ducken nach, sobald das Headset-
    /// Profil steht.
    private func startCapturingEnforceLoop() {
        enforceTask?.cancel()
        let interval = enforceInterval
        enforceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard let self, self.phase == .capturing else { return }
                self.captureAndDuckCurrentDevice()
            }
        }
    }

    /// Settle-Window: macOS haelt das Headset-Profil nach dem Stop noch ~2 s
    /// offen und schaltet dann zurueck. Waehrend des Fensters wird alle
    /// `enforceInterval` Sekunden geprueft, ob ein Geraet wieder auf unserem
    /// Duck-Wert steht.
    private func startSettleWindow() {
        settleTask?.cancel()
        let duration = settleWindowDuration
        let interval = enforceInterval
        settleTask = Task { @MainActor [weak self] in
            let stepsRaw = duration / interval
            let steps = max(1, Int(stepsRaw.rounded(.up)))
            for _ in 0..<steps {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard let self, self.phase == .restoring else { return }
                self.restoreAllDevices(onlyOwnDuck: true)
            }
            guard !Task.isCancelled else { return }
            self?.finishSession()
        }
    }

    /// Session-Ende: Journal-Eintraege bestaetigter Rueckstellungen loeschen,
    /// alles andere (Geraet weg, steht noch auf dem Duck-Wert) bleibt fuer
    /// `recoverPendingRestores()`.
    private func finishSession() {
        for capture in captures.values {
            guard let target = capture.appliedTarget, let uid = capture.uid else { continue }
            guard let current = try? volumeController.readVolume(deviceID: capture.deviceID) else {
                Logger.audio.info("[AudioDucking] \(capture.name, privacy: .public) unreachable at session end; restore stays pending")
                continue
            }
            let restored = abs(current - capture.originalVolume) <= Self.volumeTolerance
            if restored || !isOwnDuck(current, target: target) {
                journal.remove(uid: uid)
            } else {
                Logger.audio.error("[AudioDucking] \(capture.name, privacy: .public) still ducked at session end (\(self.format(current), privacy: .public)); restore stays pending")
            }
        }
        teardown()
        updateRecoveryListener()
    }

    private func teardown() {
        if let token = routingListenerToken {
            volumeController.removeDefaultOutputDeviceListener(token: token)
            routingListenerToken = nil
        }
        enforceTask?.cancel()
        enforceTask = nil
        settleTask?.cancel()
        settleTask = nil
        captures.removeAll()
        deferredDuckDeadline = nil
        phase = .idle
    }

    /// Solange das Journal etwas offen hat, auf Default-Output-Wechsel hoeren:
    /// Wiederverbundene AirPods werden zum Default und loesen die Nachholung aus.
    private func updateRecoveryListener() {
        if journal.isEmpty {
            if let token = recoveryListenerToken {
                volumeController.removeDefaultOutputDeviceListener(token: token)
                recoveryListenerToken = nil
            }
            return
        }
        guard recoveryListenerToken == nil else { return }
        recoveryListenerToken = volumeController.addDefaultOutputDeviceListener { [weak self] in
            Task { @MainActor [weak self] in
                self?.recoverPendingRestores()
            }
        }
    }

    private func format(_ volume: Float) -> String {
        "\(Int(round(volume * 100)))%"
    }
}
