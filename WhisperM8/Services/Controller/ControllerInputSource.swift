import Foundation

/// Was die App über einen verbundenen Controller weiß.
struct ControllerDeviceInfo: Equatable, Sendable {
    var name: String
    /// Kategorie laut Framework, z. B. „DualSense“.
    var category: String
    /// 0…1, oder `nil`, wenn der Controller keinen Stand meldet (der DualSense
    /// liefert über Bluetooth oft nichts — dann nie „0 %“ anzeigen).
    var batteryLevel: Float?
    var hasLight: Bool
    var hasHaptics: Bool
}

struct ControllerLightColor: Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
}

/// Fühlbare Rückmeldungen am Controller.
enum ControllerHapticPattern: String, CaseIterable, Sendable {
    /// Aufnahme beginnt: ein kräftiger Impuls.
    case recordingStarted
    /// Aufnahme endet: ein weicher Impuls.
    case recordingStopped
    /// Ein anderer Chat wartet neu auf eine Entscheidung: Doppelimpuls.
    case chatWaiting
    /// „Geht hier nicht“: drei kleine Ticks.
    case rejected
    /// Eingabe geleert (R3 halten): ein kurzer, leichter Impuls.
    case inputCleared
}

/// Quelle für Controller-Eingaben. Die Live-Fassung spricht mit dem
/// GameController-Framework; Tests und der Debug-Kanal speisen dieselbe Kette
/// ohne Hardware.
protocol ControllerInputSource: AnyObject {
    /// Roh-Ereignisse. Aufgerufen auf der Queue aus `start(queue:)`.
    var onEvent: (@Sendable (ControllerInputEvent) -> Void)? { get set }
    /// Alles Gehaltene gilt als losgelassen (Trennung, Wechsel des Controllers).
    /// Aufgerufen auf der Queue aus `start(queue:)`.
    var onReset: (@Sendable () -> Void)? { get set }
    /// Controller verbunden, gewechselt oder getrennt (`nil`). Auf dem Main Thread.
    var onDeviceChange: (@MainActor (ControllerDeviceInfo?) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func stop()

    /// Eingaben auch empfangen, wenn die App nicht vorne ist.
    /// - Returns: der vom System zurückgelesene Wert. `false` trotz `true`
    ///   heißt: auf diesem System nicht verfügbar.
    @discardableResult
    func setBackgroundMonitoring(_ enabled: Bool) -> Bool

    /// Farbe der Lichtleiste; `nil` lässt sie unverändert.
    func setLight(_ color: ControllerLightColor?)
    func play(_ pattern: ControllerHapticPattern)
}
