import Foundation
import GameController

/// Einmaliger Hinweis, wenn zum ersten Mal ein Gamepad erkannt wird, die
/// Controller-Steuerung aber noch aus ist. Hört dafür nur auf die
/// Verbindungs-Meldung des Frameworks — gelesen wird nichts.
@MainActor
final class ControllerConnectHint {
    static let shared = ControllerConnectHint()

    private var observer: NSObjectProtocol?

    /// Entscheidet, ob ein Hinweis fällig ist. Pur, für Tests.
    nonisolated static func shouldShow(featureEnabled: Bool, userEnabled: Bool, alreadyShown: Bool) -> Bool {
        featureEnabled && !userEnabled && !alreadyShown
    }

    /// Beim App-Start und nach dem Umschalten aufrufen.
    func sync(preferences: AppPreferences = .shared) {
        let wanted = Self.shouldShow(
            featureEnabled: preferences.isControllerFeatureEnabled,
            userEnabled: preferences.isControllerEnabled,
            alreadyShown: preferences.controllerConnectHintShown)
        guard wanted else {
            stop()
            return
        }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(preferences: preferences) }
        }
        if !GCController.controllers().isEmpty { show(preferences: preferences) }
    }

    private func show(preferences: AppPreferences) {
        guard Self.shouldShow(
            featureEnabled: preferences.isControllerFeatureEnabled,
            userEnabled: preferences.isControllerEnabled,
            alreadyShown: preferences.controllerConnectHintShown) else { return stop() }
        preferences.controllerConnectHintShown = true
        stop()
        guard AppInstance.isAppBundleProcess else { return }
        DictationNotice.post(
            title: String(localized: "Controller connected"),
            body: String(localized: "WhisperM8 can be used with this gamepad. Turn it on under Settings › Controller."))
    }

    private func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
