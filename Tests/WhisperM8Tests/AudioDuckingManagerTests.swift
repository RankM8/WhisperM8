import CoreAudio
import XCTest
@testable import WhisperM8

@MainActor
final class AudioDuckingManagerTests: XCTestCase {
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
}

private final class FakeAudioVolumeController: AudioVolumeControlling {
    var defaultDeviceID: AudioDeviceID
    var volumes: [AudioDeviceID: Float]
    var unsupportedDeviceIDs: Set<AudioDeviceID>

    init(
        defaultDeviceID: AudioDeviceID,
        volumes: [AudioDeviceID: Float],
        unsupportedDeviceIDs: Set<AudioDeviceID> = []
    ) {
        self.defaultDeviceID = defaultDeviceID
        self.volumes = volumes
        self.unsupportedDeviceIDs = unsupportedDeviceIDs
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
    }

    func deviceName(deviceID: AudioDeviceID) -> String {
        "Device \(deviceID)"
    }
}

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
