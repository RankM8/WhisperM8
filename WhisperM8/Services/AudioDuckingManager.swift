import Foundation
import ISSoundAdditions

/// Manages audio ducking (reducing system volume) during recording
@MainActor
final class AudioDuckingManager {
    static let shared = AudioDuckingManager()

    private var originalVolume: Float?
    private var isDucked = false

    private init() {}

    /// Whether audio ducking is enabled (from UserDefaults)
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "audioDuckingEnabled") == nil ||
        UserDefaults.standard.bool(forKey: "audioDuckingEnabled")
    }

    /// Target volume level during recording (0.1 - 0.5, default 0.2)
    var targetVolume: Float {
        let value = UserDefaults.standard.double(forKey: "audioDuckingFactor")
        return value > 0 ? Float(value) : 0.2
    }

    /// Reduce system volume while recording
    func duck() {
        guard isEnabled else {
            Logger.debug("[AudioDucking] Ducking disabled, skipping")
            return
        }

        let currentVolume = Sound.output.volume

        // If already ducked, just enforce the target volume (for AirPods HFP switch)
        if isDucked {
            if currentVolume > targetVolume {
                Sound.output.volume = targetVolume
                Logger.debug("[AudioDucking] Re-enforcing duck: \(String(format: "%.0f", currentVolume * 100))% → \(String(format: "%.0f", targetVolume * 100))%")
            }
            return
        }

        // Only duck if current volume is above target
        guard currentVolume > targetVolume else {
            Logger.debug("[AudioDucking] Volume (\(String(format: "%.0f", currentVolume * 100))%) already at or below target (\(String(format: "%.0f", targetVolume * 100))%), skipping")
            return
        }

        // First duck: save original and set target
        originalVolume = currentVolume
        Sound.output.volume = targetVolume
        isDucked = true

        Logger.debug("[AudioDucking] Ducked: \(String(format: "%.0f", currentVolume * 100))% → \(String(format: "%.0f", targetVolume * 100))%")
    }

    /// Restore system volume to original level
    func restore() {
        Logger.debug("[AudioDucking] restore() called - isDucked=\(isDucked), originalVolume=\(String(describing: originalVolume))")

        guard isDucked else {
            Logger.debug("[AudioDucking] Not ducked, nothing to restore")
            return
        }
        guard let original = originalVolume else {
            Logger.debug("[AudioDucking] No original volume saved!")
            isDucked = false
            return
        }

        Logger.debug("[AudioDucking] Setting volume to: \(String(format: "%.0f", original * 100))%")
        Sound.output.volume = original

        let actualVolume = Sound.output.volume
        Logger.debug("[AudioDucking] Restored to: \(String(format: "%.0f", original * 100))% (actual: \(String(format: "%.0f", actualVolume * 100))%)")

        // Save for re-enforce
        let savedOriginal = original
        isDucked = false
        originalVolume = nil

        // Re-enforce restore multiple times (AirPods switches back to A2DP)
        Task { @MainActor in
            for delay in [0.3, 0.6, 1.0, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                let currentVolume = Sound.output.volume
                if currentVolume < savedOriginal - 0.05 {
                    Sound.output.volume = savedOriginal
                    Logger.debug("[AudioDucking] Re-enforcing restore: \(String(format: "%.0f", currentVolume * 100))% → \(String(format: "%.0f", savedOriginal * 100))%")
                }
            }
        }
    }
}
