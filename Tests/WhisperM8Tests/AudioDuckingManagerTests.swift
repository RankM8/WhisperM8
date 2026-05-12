import CoreAudio
import XCTest
@testable import WhisperM8

@MainActor
final class AudioDuckingManagerTests: XCTestCase {

    // MARK: - Existing baseline behaviour

    func testDuckingRestoresEveryOutputDeviceTouchedDuringRouteChanges() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let controller = FakeAudioVolumeController(
                defaultDeviceID: 1,
                volumes: [
                    1: 0.8,
                    2: 0.7
                ]
            )
            let manager = AudioDuckingManager(volumeController: controller)

            manager.duck()
            XCTAssertEqual(controller.volumes[1] ?? -1, 0.2, accuracy: 0.001)

            controller.defaultDeviceID = 2
            manager.duck()
            XCTAssertEqual(controller.volumes[2] ?? -1, 0.2, accuracy: 0.001)

            manager.restore()

            XCTAssertEqual(controller.volumes[1] ?? -1, 0.8, accuracy: 0.001)
            XCTAssertEqual(controller.volumes[2] ?? -1, 0.7, accuracy: 0.001)
            XCTAssertFalse(manager.hasActiveDuckingSession)
        }
    }

    func testDuckingDoesNothingWhenOutputDeviceCannotBeControlled() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true

            let controller = FakeAudioVolumeController(
                defaultDeviceID: 1,
                volumes: [1: 0.8],
                unsupportedDeviceIDs: [1]
            )
            let manager = AudioDuckingManager(volumeController: controller)

            manager.duck()

            XCTAssertEqual(controller.volumes[1] ?? -1, 0.8, accuracy: 0.001)
            XCTAssertFalse(manager.hasActiveDuckingSession)
        }
    }

    // MARK: - Critical regression tests (the bug user reported)

    /// Wenn der User WAEHREND der Aufnahme die Lautstaerke selbst aendert,
    /// duerfen wir beim Restore NICHT auf den Original-Wert zurueckspringen.
    /// Das ist der Hauptfehler des alten Codes gewesen.
    func testUserVolumeAdjustmentDuringDuckingDisablesRestore() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let controller = FakeAudioVolumeController(
                defaultDeviceID: 1,
                volumes: [1: 0.8]
            )
            let manager = AudioDuckingManager(volumeController: controller)

            manager.duck()
            XCTAssertEqual(controller.volumes[1] ?? -1, 0.2, accuracy: 0.001)

            // User schraubt manuell hoch — Fake propagiert das ueber den Listener.
            // Der Listener-Handler ist in eine `Task { @MainActor in ... }`
            // gewrappt → wir muessen einen kurzen Tick warten, damit die
            // Task lauft bevor wir restoren.
            controller.simulateExternalVolumeChange(deviceID: 1, newVolume: 0.5)
            await Task.yield()
            // Defensive: noch ein Tick auf jeden Fall.
            try? await Task.sleep(for: .milliseconds(20))

            manager.restore()

            // Volume bleibt bei 0.5 (user's choice) — keine Rueckkehr zu 0.8.
            XCTAssertEqual(controller.volumes[1] ?? -1, 0.5, accuracy: 0.001)
            XCTAssertFalse(manager.hasActiveDuckingSession)
        }
    }

    /// Wenn der User NACH dem Restore manuell leiser dreht, darf NICHTS
    /// passieren — vorher hat ein Retry-Loop das auf den Original-Wert
    /// zurueckgekracht.
    func testRestoreDoesNotReapplyVolumeAfterUserChangesIt() async {
        await withIsolatedDuckingPreferencesAsync { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let controller = FakeAudioVolumeController(
                defaultDeviceID: 1,
                volumes: [1: 0.8]
            )
            let manager = AudioDuckingManager(volumeController: controller)

            manager.duck()
            manager.restore()
            XCTAssertEqual(controller.volumes[1] ?? -1, 0.8, accuracy: 0.001)

            // User dreht jetzt manuell leiser.
            controller.volumes[1] = 0.3

            // Wir warten 3 Sekunden — frueher haette der Retry-Loop hier
            // wieder auf 0.8 hochgesprungen.
            try? await Task.sleep(for: .seconds(3))

            XCTAssertEqual(controller.volumes[1] ?? -1, 0.3, accuracy: 0.001,
                "Restore must be one-shot — no retry loop allowed to fight user adjustments")
        }
    }

    /// Wenn das Geraet schon UNTER unserem Target ist, gar nicht ducken —
    /// sonst wuerde Restore auf einen falschen Wert hochspringen.
    func testNoDuckingWhenVolumeAlreadyBelowTarget() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.3

            let controller = FakeAudioVolumeController(
                defaultDeviceID: 1,
                volumes: [1: 0.15]
            )
            let manager = AudioDuckingManager(volumeController: controller)

            manager.duck()

            XCTAssertEqual(controller.volumes[1] ?? -1, 0.15, accuracy: 0.001)
            XCTAssertFalse(manager.hasActiveDuckingSession)
        }
    }

    /// Re-Ducken einer schon geduckten Session darf den `originalVolume`
    /// nicht mit dem Target ueberschreiben — sonst Permanent-Ducking.
    func testRepeatedDuckPreservesOriginalVolume() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true
            preferences.audioDuckingFactor = 0.2

            let controller = FakeAudioVolumeController(
                defaultDeviceID: 1,
                volumes: [1: 0.8]
            )
            let manager = AudioDuckingManager(volumeController: controller)

            manager.duck()
            XCTAssertEqual(controller.volumes[1] ?? -1, 0.2, accuracy: 0.001)

            // Erneut ducken — sollte ohne Effekt sein, weil schon geduckt.
            manager.duck()
            XCTAssertEqual(controller.volumes[1] ?? -1, 0.2, accuracy: 0.001)

            manager.restore()
            XCTAssertEqual(controller.volumes[1] ?? -1, 0.8, accuracy: 0.001,
                "Restore must return to PRE-duck volume, not to our target")
        }
    }

    /// Listener wird beim Restore wieder entfernt — verhindert Memory-Leak
    /// und vermeidet dass Spaetere User-Aenderungen noch reinkommen.
    func testRestoreRemovesVolumeListener() {
        withIsolatedDuckingPreferences { preferences in
            preferences.isAudioDuckingEnabled = true

            let controller = FakeAudioVolumeController(
                defaultDeviceID: 1,
                volumes: [1: 0.8]
            )
            let manager = AudioDuckingManager(volumeController: controller)

            manager.duck()
            XCTAssertEqual(controller.activeListenerCount, 1)

            manager.restore()
            XCTAssertEqual(controller.activeListenerCount, 0)
        }
    }
}

// MARK: - Fakes

private final class FakeAudioVolumeController: AudioVolumeControlling {
    var defaultDeviceID: AudioDeviceID
    var volumes: [AudioDeviceID: Float]
    var unsupportedDeviceIDs: Set<AudioDeviceID>
    private var listeners: [AudioDeviceID: [UUID: () -> Void]] = [:]

    init(
        defaultDeviceID: AudioDeviceID,
        volumes: [AudioDeviceID: Float],
        unsupportedDeviceIDs: Set<AudioDeviceID> = []
    ) {
        self.defaultDeviceID = defaultDeviceID
        self.volumes = volumes
        self.unsupportedDeviceIDs = unsupportedDeviceIDs
    }

    var activeListenerCount: Int {
        listeners.values.reduce(0) { $0 + $1.count }
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID {
        defaultDeviceID
    }

    func readVolume(deviceID: AudioDeviceID) throws -> Float {
        if unsupportedDeviceIDs.contains(deviceID) {
            throw AudioVolumeError.unsupportedProperty(deviceID)
        }
        guard let volume = volumes[deviceID] else {
            throw AudioVolumeError.noDevice
        }
        return volume
    }

    func setVolume(_ volume: Float, deviceID: AudioDeviceID) throws {
        if unsupportedDeviceIDs.contains(deviceID) {
            throw AudioVolumeError.unsupportedProperty(deviceID)
        }
        volumes[deviceID] = volume
        // Wir feuern den Listener NICHT bei eigenen setVolume-Calls —
        // CoreAudio macht das in der Praxis zwar, aber das Suppression-Flag
        // im Manager filtert das raus. In Tests treiben wir externe
        // Aenderungen explizit ueber `simulateExternalVolumeChange`.
    }

    func deviceName(deviceID: AudioDeviceID) -> String {
        "Device \(deviceID)"
    }

    func addVolumeChangeListener(
        deviceID: AudioDeviceID,
        onChange: @escaping () -> Void
    ) -> Any? {
        let id = UUID()
        listeners[deviceID, default: [:]][id] = onChange
        return Token(deviceID: deviceID, id: id)
    }

    func removeVolumeChangeListener(deviceID: AudioDeviceID, token: Any) {
        guard let t = token as? Token else { return }
        listeners[t.deviceID]?.removeValue(forKey: t.id)
        if listeners[t.deviceID]?.isEmpty == true {
            listeners.removeValue(forKey: t.deviceID)
        }
    }

    /// Test-Helper: simuliert eine externe Volume-Aenderung (User dreht am
    /// Slider, andere App ruft setVolume) — feuert die installierten Listener.
    func simulateExternalVolumeChange(deviceID: AudioDeviceID, newVolume: Float) {
        volumes[deviceID] = newVolume
        listeners[deviceID]?.values.forEach { $0() }
    }

    private struct Token {
        let deviceID: AudioDeviceID
        let id: UUID
    }
}

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
