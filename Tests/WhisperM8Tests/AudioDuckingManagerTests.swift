import CoreAudio
import XCTest
@testable import WhisperM8

/// Tests fuer die neue State-Machine des AudioDuckingManager.
///
/// **Konventionen:**
/// - `beginCapture()` ersetzt das alte `duck()` und MUSS vor dem Recorder-Start gerufen werden.
/// - `endCapture()` ersetzt das alte `restore()` und startet ein Settle-Window.
/// - Tests koennen die Settle-Window-Dauer ueber den Init-Parameter steuern.
/// - `AudioWorld` modelliert die macOS-CoreAudio-Realitaet: mehrere Devices,
///   Default-Output-Wechsel, BT-Profile-Switches als eigene DeviceIDs,
///   verschwundene Devices und doppelt feuernde Listener.
@MainActor
final class AudioDuckingManagerTests: XCTestCase {

    // MARK: - 1) Baseline

    /// Kanonischer Pfad: ein Device, ducken, restoren — Volume zurueck auf Original.
    func test_baselineDuckRestore_singleDevice() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(defaultDeviceID: 1, devices: [1: ("Built-in", 0.8)])
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001)

            manager.endCapture()
            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001)
        }
    }

    /// Wenn Volume bereits ≤ Target: kein Ducking, kein Capture-Eintrag → kein
    /// fehlerhafter "Restore" der die Volume HOEHER setzen wuerde.
    func test_volumeAlreadyBelowTarget_noOp() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.3

            let world = AudioWorld(defaultDeviceID: 1, devices: [1: ("Built-in", 0.15)])
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.beginCapture()

            XCTAssertEqual(world.volume(1), 0.15, accuracy: 0.001)
            #if DEBUG
            XCTAssertTrue(manager.debug_capturedDeviceIDs.isEmpty,
                          "No capture entry expected when volume already below target")
            #endif
            manager.endCapture()
            XCTAssertEqual(world.volume(1), 0.15, accuracy: 0.001)
        }
    }

    /// Devices ohne kontrollierbare Volume (HDMI/Aggregate): nicht crashen,
    /// nichts tracken.
    func test_unsupportedDevice_doesNothing() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true

            let world = AudioWorld(
                defaultDeviceID: 1,
                devices: [1: ("HDMI", 0.8)],
                unsupported: [1]
            )
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001,
                           "Unsupported device must not have its volume touched")
            #if DEBUG
            XCTAssertTrue(manager.debug_capturedDeviceIDs.isEmpty)
            #endif
            manager.endCapture()
            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001)
        }
    }

    /// Mehrfaches `beginCapture()` ohne dazwischen `endCapture()` darf nicht
    /// das Original mit dem aktuellen (= geduckten) Wert ueberschreiben.
    func test_repeatedBeginCapture_isIdempotent() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(defaultDeviceID: 1, devices: [1: ("Built-in", 0.8)])
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001)

            // Zweiter Aufruf: schon in .capturing → keine Veraenderung am Original.
            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001)

            manager.endCapture()
            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001,
                           "Repeat-capture must NOT corrupt original (would restore to ducked value)")
        }
    }

    // MARK: - 2) Bluetooth / Routing

    /// Original-Volume MUSS vor dem HFP-Switch erfasst worden sein.
    /// Wenn der Coordinator beginCapture() vor `audioRecorder.startRecording()`
    /// ruft, ist das Default-Device noch im A2DP-Mode mit User-Volume 0.8.
    /// Nach Engine-Start switcht macOS auf HFP-Profil; das aendert nichts mehr
    /// an unserem bereits gespeicherten Original.
    func test_originalVolumeCapturedBeforeRecorderStarts_notAfterHFPSwitch() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            // AirPods-A2DP ist Default mit User-Volume 0.8
            let world = AudioWorld(
                defaultDeviceID: 100,
                devices: [
                    100: ("AirPods (A2DP)", 0.8),
                    101: ("AirPods (HFP)", 0.4)
                ]
            )
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            // beginCapture VOR dem (simulierten) Recorder-Start
            manager.beginCapture()

            // Jetzt simuliert macOS den HFP-Switch
            world.simulateDefaultOutputChange(to: 101)

            manager.endCapture()

            // A2DP wurde mit Original 0.8 gecaptured und restored.
            XCTAssertEqual(world.volume(100), 0.8, accuracy: 0.001,
                           "Original A2DP volume must be the pre-switch value, not the HFP value")
        }
    }

    /// Routing-Change waehrend Capture: das neue Device wird ebenfalls geduckt.
    func test_routingChangeDuringCapture_newDeviceAlsoDucked() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(
                defaultDeviceID: 1,
                devices: [
                    1: ("Built-in", 0.8),
                    2: ("USB Headset", 0.7)
                ]
            )
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 1.0)

            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001)

            world.simulateDefaultOutputChange(to: 2)
            // Routing-Listener landet auf MainActor-Task — kurz yielden.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            XCTAssertEqual(world.volume(2), 0.2, accuracy: 0.001,
                           "New default device must also be ducked")
        }
    }

    /// Routing-Change waehrend Capture: beide Devices werden am Ende restored.
    func test_routingChangeDuringCapture_oldAndNewDeviceBothRestored() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(
                defaultDeviceID: 1,
                devices: [
                    1: ("Built-in", 0.8),
                    2: ("USB Headset", 0.7)
                ]
            )
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.beginCapture()
            world.simulateDefaultOutputChange(to: 2)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            manager.endCapture()

            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001, "Old device restored")
            XCTAssertEqual(world.volume(2), 0.7, accuracy: 0.001, "New device restored")
        }
    }

    /// Realistisches AirPods-Szenario: A2DP- und HFP-Profil haben verschiedene
    /// DeviceIDs. Beide werden waehrend Session beruehrt und beide werden
    /// auf ihre jeweiligen Originals zurueckgesetzt.
    func test_bluetoothProfileSwitch_HFPAndA2DPSeparateDevices_bothRestored() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(
                defaultDeviceID: 100,
                devices: [
                    100: ("AirPods (A2DP)", 0.8),
                    101: ("AirPods (HFP)", 0.5)
                ]
            )
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.beginCapture()
            // BT-Profile-Switch zu HFP
            world.simulateDefaultOutputChange(to: 101)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            manager.endCapture()

            XCTAssertEqual(world.volume(100), 0.8, accuracy: 0.001, "A2DP restored to original")
            XCTAssertEqual(world.volume(101), 0.5, accuracy: 0.001, "HFP restored to original")
        }
    }

    // MARK: - 3) End / Settle

    /// `endCapture()` restored sofort alle bekannten Devices — nicht erst nach
    /// Settle-Window.
    func test_endCapture_restoresImmediatelyOnAllCapturedDevices() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(
                defaultDeviceID: 1,
                devices: [1: ("A", 0.8), 2: ("B", 0.6)]
            )
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 5.0)

            manager.beginCapture()
            world.simulateDefaultOutputChange(to: 2)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            manager.endCapture()
            // Sofort nach endCapture (vor Settle-Ablauf) muss Volume oben sein.
            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001)
            XCTAssertEqual(world.volume(2), 0.6, accuracy: 0.001)
        }
    }

    /// Routing-Event INNERHALB des Settle-Windows → Re-Restore aller Devices.
    /// Simuliert: macOS schaltet von HFP zurueck auf A2DP, und beim Reverse-
    /// Switch hat der BT-Stack A2DP-Volume manipuliert. Wir korrigieren das.
    func test_settleWindow_routingChangeAfterEnd_triggersReRestore() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(
                defaultDeviceID: 100,
                devices: [
                    100: ("AirPods (A2DP)", 0.8),
                    101: ("AirPods (HFP)", 0.5)
                ]
            )
            // Settle-Window lang genug, dass wir innerhalb davon agieren koennen.
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 1.0)

            manager.beginCapture()
            world.simulateDefaultOutputChange(to: 101)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            manager.endCapture()
            // BT-Stack manipuliert A2DP-Volume nach Hotkey-Release
            world.setVolumeExternally(deviceID: 100, value: 0.3)
            // Reverse-Switch zurueck auf A2DP
            world.simulateDefaultOutputChange(to: 100)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            XCTAssertEqual(world.volume(100), 0.8, accuracy: 0.001,
                           "Settle-Window must re-apply restore on routing event")
        }
    }

    /// Pollt eine Bedingung bis zur Deadline statt fixer Sleeps — auf
    /// geteilten CI-Runnern unter Last verrutschen sonst die Settle-Timings
    /// (genau so im ersten CI-Lauf passiert).
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Nach Ablauf des Settle-Windows wird der Routing-Listener entfernt und
    /// `phase` ist wieder `.idle`.
    func test_settleWindow_expiresAfterDuration_listenersTornDown() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(defaultDeviceID: 1, devices: [1: ("Built-in", 0.8)])
            let manager = AudioDuckingManager(
                volumeController: world,
                settleWindowDuration: 0.05,
                enforceInterval: 0.02
            )

            manager.beginCapture()
            XCTAssertEqual(world.defaultOutputListenerCount, 1)
            manager.endCapture()

            // Warten bis Settle-Window abgelaufen (Deadline-Polling, CI-robust)
            await waitUntil { world.defaultOutputListenerCount == 0 && manager.phase == .idle }

            XCTAssertEqual(world.defaultOutputListenerCount, 0,
                           "Routing listener must be torn down after settle-window")
            XCTAssertEqual(manager.phase, .idle)
        }
    }

    /// Verspaeteter Routing-Event NACH Ablauf des Settle-Windows: ignoriert,
    /// keine ungewollten Side-Effects.
    func test_lateRoutingEventAfterSettle_ignored() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(
                defaultDeviceID: 1,
                devices: [1: ("A", 0.8), 2: ("B", 0.6)]
            )
            let manager = AudioDuckingManager(
                volumeController: world,
                settleWindowDuration: 0.05,
                enforceInterval: 0.02
            )

            manager.beginCapture()
            manager.endCapture()
            await waitUntil { manager.phase == .idle }

            // Listener ist weg → simulate fire-on-removed-listener: world fires
            // weiter (im Fake), aber Manager hat kein Token mehr installiert.
            // Daher wird keine Routing-Funktion getriggert.
            world.simulateDefaultOutputChange(to: 2)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            // B wurde NICHT geduckt — der Manager ist .idle und reagiert nicht.
            XCTAssertEqual(world.volume(2), 0.6, accuracy: 0.001)
            XCTAssertEqual(manager.phase, .idle)
        }
    }

    // MARK: - 4) Robustheit

    /// Hammer-Triggern: begin → end → begin → end → ... Keine State-Leaks,
    /// keine permanent geduckte Volume, kein falsch gespeichertes Original.
    func test_rapidBeginEndBegin_noStateLeakBetweenSessions() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(defaultDeviceID: 1, devices: [1: ("Built-in", 0.8)])
            // Mittleres Window: nach endCapture noch in .restoring, dann
            // beginCapture(2) reisst die Settle-Phase ab.
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 1.0)

            // Runde 1
            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001)
            manager.endCapture()
            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001)

            // Runde 2 — noch innerhalb Settle-Window
            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001)
            manager.endCapture()
            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001)

            // Runde 3 — Settle ausgelaufen lassen, frisch starten
            // (Deadline-Polling statt 1100-ms-Sleep mit nur 10 % Marge)
            await waitUntil(timeout: 3.0) { manager.phase == .idle }
            XCTAssertEqual(manager.phase, .idle)

            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001)
            manager.endCapture()
            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001)
        }
    }

    /// Wenn der Routing-Listener mehrmals fuer den gleichen Switch feuert
    /// (CoreAudio macht das in der Praxis), bleibt unser State konsistent.
    func test_duplicateRoutingEventsPerSwitch_idempotent() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(
                defaultDeviceID: 1,
                devices: [1: ("A", 0.8), 2: ("B", 0.6)]
            )
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.beginCapture()
            world.simulateDefaultOutputChange(to: 2)
            // Doppelt feuern
            world.fireDefaultOutputListenersManually()
            world.fireDefaultOutputListenersManually()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            manager.endCapture()

            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001)
            XCTAssertEqual(world.volume(2), 0.6, accuracy: 0.001,
                           "Duplicate fires must not corrupt original of device B")
        }
    }

    /// Device verschwindet mid-Capture (z. B. AirPods getrennt). Restore-Pfad
    /// darf nicht crashen und nicht andere Devices in Mitleidenschaft ziehen.
    func test_deviceDisappearsMidCapture_restoreSafelySkipsIt() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(
                defaultDeviceID: 100,
                devices: [
                    100: ("AirPods", 0.8),
                    1: ("Built-in", 0.6)
                ]
            )
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.beginCapture()
            // AirPods getrennt → fallback auf Built-in
            world.disconnectDevice(100, newDefault: 1)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            manager.endCapture()

            // Built-in wurde restored
            XCTAssertEqual(world.volume(1), 0.6, accuracy: 0.001)
            // AirPods-Operation hat keine Exception geworfen und nichts kaputt gemacht
            XCTAssertEqual(manager.phase, .restoring,
                           "Manager is in restoring phase after endCapture")
        }
    }

    /// `endCapture()` ohne vorheriges `beginCapture()` ist ein sauberer No-Op.
    func test_endCaptureWithoutBeginCapture_isNoOp() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true

            let world = AudioWorld(defaultDeviceID: 1, devices: [1: ("Built-in", 0.8)])
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.endCapture()

            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001)
            XCTAssertEqual(manager.phase, .idle)
        }
    }

    // MARK: - 4b) BT-Profile-Drift (kein Routing-Event, aber Volume aendert sich)

    /// **REGRESSION:** Realer Bug, den wir live mit AirPods gesehen haben:
    /// Der BT-Stack aendert die Volume waehrend Recording auf einen hoeheren
    /// Wert (z. B. HFP-Mode-Default), OHNE dass die DeviceID wechselt — also
    /// triggert der Routing-Listener NICHT. Der periodische Enforce-Loop
    /// muss die Volume wieder auf Target ziehen.
    func test_externalVolumeRiseDuringCapture_enforceLoopReDucks() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(defaultDeviceID: 1, devices: [1: ("AirPods", 0.5)])
            let manager = AudioDuckingManager(
                volumeController: world,
                settleWindowDuration: 5.0,
                enforceInterval: 0.03
            )

            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001, "Initial duck")

            // BT-Stack schiebt Volume hoch — KEIN Routing-Event.
            world.setVolumeExternally(deviceID: 1, value: 0.63)

            // Warten bis der Enforce-Loop re-duckt (Deadline-Polling statt
            // fixem 100-ms-Sleep — auf geteilten CI-Runnern verrutschen die
            // Timer-Ticks; im zweiten CI-Lauf genau hier geflaked).
            await waitUntil { abs(world.volume(1) - 0.2) < 0.001 }

            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001,
                           "Enforce loop must re-duck after external volume rise")

            manager.endCapture()
            XCTAssertEqual(world.volume(1), 0.5, accuracy: 0.001,
                           "Original (pre-recording) volume is what gets restored")
        }
    }

    // MARK: - 5) Designtrade-off: KEIN userTookOver

    /// Externe Volume-Aenderung waehrend Capture (egal ob User oder BT-Stack):
    /// Beim Stop wird auf Original zurueckgesetzt. Bewusster Trade-off — siehe
    /// Designdoku im AudioDuckingManager.
    func test_externalVolumeChangeDuringCapture_endStillRestoresToOriginal() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(defaultDeviceID: 1, devices: [1: ("Built-in", 0.8)])
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 0.05)

            manager.beginCapture()
            XCTAssertEqual(world.volume(1), 0.2, accuracy: 0.001)

            // "User" oder System aendert Volume mitten in der Aufnahme
            world.setVolumeExternally(deviceID: 1, value: 0.5)
            await Task.yield()

            manager.endCapture()

            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001,
                           "Bewusster Trade-off: end restores to original even after external change.")
        }
    }

    // MARK: - 6) endCaptureImmediate (App-Quit-Pfad)

    /// `endCaptureImmediate()` setzt sofort zurueck und beendet die Session
    /// ohne Settle-Window — fuer App-Termination.
    func test_endCaptureImmediate_restoresAndGoesIdle() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let world = AudioWorld(defaultDeviceID: 1, devices: [1: ("Built-in", 0.8)])
            let manager = AudioDuckingManager(volumeController: world, settleWindowDuration: 5.0)

            manager.beginCapture()
            manager.endCaptureImmediate()

            XCTAssertEqual(world.volume(1), 0.8, accuracy: 0.001)
            XCTAssertEqual(manager.phase, .idle)
            XCTAssertEqual(world.defaultOutputListenerCount, 0)
        }
    }
}

// MARK: - AudioWorld: Test-Fake fuer macOS-Audio-Verhalten

/// Modelliert die fuer das Ducking relevanten Aspekte des CoreAudio-Universums:
/// - Mehrere Devices mit eigenen Volumes und Namen.
/// - Wechselbares Default-Output-Device.
/// - Optional "unsupported" Devices (HDMI/Aggregate, kein Volume-Control).
/// - "Disappeared" Devices (Bluetooth getrennt).
/// - Default-Output-Listener mit Fire-Trigger fuer doppelte/spaete Events.
///
/// Bewusst NICHT @MainActor — die `AudioVolumeControlling`-Konformitaet darf
/// keine Actor-Isolation einfuehren. Tests greifen aus @MainActor-Kontext drauf
/// zu, was fuer XCTest synchron sequentiell ist.
final class AudioWorld: AudioVolumeControlling, @unchecked Sendable {
    private(set) var defaultDeviceID: AudioDeviceID
    private var deviceVolumes: [AudioDeviceID: Float] = [:]
    private var deviceNames: [AudioDeviceID: String] = [:]
    private var unsupportedDeviceIDs: Set<AudioDeviceID> = []
    private var disappearedDeviceIDs: Set<AudioDeviceID> = []
    private var defaultOutputListeners: [UUID: () -> Void] = [:]

    init(
        defaultDeviceID: AudioDeviceID,
        devices: [AudioDeviceID: (name: String, volume: Float)],
        unsupported: Set<AudioDeviceID> = []
    ) {
        self.defaultDeviceID = defaultDeviceID
        for (id, info) in devices {
            self.deviceNames[id] = info.name
            self.deviceVolumes[id] = info.volume
        }
        self.unsupportedDeviceIDs = unsupported
    }

    // MARK: AudioVolumeControlling

    func defaultOutputDeviceID() throws -> AudioDeviceID {
        if disappearedDeviceIDs.contains(defaultDeviceID) {
            throw AudioVolumeError.noDevice
        }
        return defaultDeviceID
    }

    func readVolume(deviceID: AudioDeviceID) throws -> Float {
        if disappearedDeviceIDs.contains(deviceID) {
            throw AudioVolumeError.noDevice
        }
        if unsupportedDeviceIDs.contains(deviceID) {
            throw AudioVolumeError.unsupportedProperty(deviceID)
        }
        guard let volume = deviceVolumes[deviceID] else {
            throw AudioVolumeError.noDevice
        }
        return volume
    }

    func setVolume(_ volume: Float, deviceID: AudioDeviceID) throws {
        if disappearedDeviceIDs.contains(deviceID) {
            throw AudioVolumeError.noDevice
        }
        if unsupportedDeviceIDs.contains(deviceID) {
            throw AudioVolumeError.unsupportedProperty(deviceID)
        }
        deviceVolumes[deviceID] = volume
    }

    func deviceName(deviceID: AudioDeviceID) -> String {
        deviceNames[deviceID] ?? "Device \(deviceID)"
    }

    func addDefaultOutputDeviceListener(onChange: @escaping () -> Void) -> Any? {
        let id = UUID()
        defaultOutputListeners[id] = onChange
        return Token(id: id)
    }

    func removeDefaultOutputDeviceListener(token: Any) {
        guard let t = token as? Token else { return }
        defaultOutputListeners.removeValue(forKey: t.id)
    }

    // MARK: Test introspection

    var defaultOutputListenerCount: Int {
        defaultOutputListeners.count
    }

    func volume(_ deviceID: AudioDeviceID) -> Float {
        deviceVolumes[deviceID] ?? -1
    }

    // MARK: Test triggers

    /// Aendert das Default-Output-Device und feuert die installierten Listener.
    func simulateDefaultOutputChange(to deviceID: AudioDeviceID) {
        defaultDeviceID = deviceID
        fireDefaultOutputListenersManually()
    }

    /// Simuliert eine externe Volume-Aenderung OHNE dass setVolume aufgerufen wird
    /// (z. B. User-Slider, BT-Stack, andere App). Feuert KEINEN Listener — wir
    /// haben bewusst keine per-Device-Volume-Listener mehr im neuen Design.
    func setVolumeExternally(deviceID: AudioDeviceID, value: Float) {
        deviceVolumes[deviceID] = value
    }

    /// Geraet wird getrennt. Default switcht auf `newDefault`.
    func disconnectDevice(_ deviceID: AudioDeviceID, newDefault: AudioDeviceID) {
        disappearedDeviceIDs.insert(deviceID)
        simulateDefaultOutputChange(to: newDefault)
    }

    /// Doppeltes Listener-Feuern ohne State-Aenderung (modelliert das
    /// CoreAudio-Verhalten "Listener feuert manchmal mehrfach pro Set").
    func fireDefaultOutputListenersManually() {
        for callback in defaultOutputListeners.values {
            callback()
        }
    }

    private struct Token {
        let id: UUID
    }
}

// MARK: - Preferences helpers

@MainActor
private func withIsolatedDuckingPreferences(_ body: (AppPreferences) -> Void) {
    let suiteName = "WhisperM8DuckingTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let original = AppPreferences.shared
    let preferences = AppPreferences(defaults: defaults)
    AppPreferences.shared = preferences
    defer {
        AppPreferences.shared = original
        defaults.removePersistentDomain(forName: suiteName)
    }

    body(preferences)
}

@MainActor
private func withIsolatedDuckingPreferencesAsync(_ body: (AppPreferences) async -> Void) async {
    let suiteName = "WhisperM8DuckingTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let original = AppPreferences.shared
    let preferences = AppPreferences(defaults: defaults)
    AppPreferences.shared = preferences

    await body(preferences)

    AppPreferences.shared = original
    defaults.removePersistentDomain(forName: suiteName)
}
