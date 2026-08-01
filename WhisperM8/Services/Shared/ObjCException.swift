import Foundation
import ObjCExceptionBridge

/// Swift-Hülle um `WM8PerformCatchingObjCException`.
///
/// Nur für die wenigen AppKit-/AVFoundation-Aufrufe gedacht, die Fehler per
/// `NSException` statt per `NSError` melden. Solche Exceptions kann Swift
/// nicht fangen — sie beenden den Prozess mit SIGABRT. Der bekannte Fall ist
/// `AVAudioNode.installTap(onBus:bufferSize:format:)`: Weicht das übergebene
/// Format vom aktuellen Hardware-Format ab, wirft AVFAudio (Absturz
/// 01.08.2026, Gerät wechselte während des Starts von 48 kHz auf 24 kHz).
///
/// **Kein Ersatz für Prüfungen.** Das Format vorher zu validieren bleibt
/// richtig; diese Hülle fängt nur das, was zwischen Prüfung und Aufruf noch
/// passieren kann — und dieses Zeitfenster lässt sich nicht schließen.
enum ObjCException {
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Führt `body` aus und wandelt eine Objective-C-Exception in einen
    /// Swift-Fehler.
    static func catching(_ body: () -> Void) throws {
        var error: NSError?
        let ok = WM8PerformCatchingObjCException(body, &error)
        guard !ok else { return }
        throw Failure(reason: error?.localizedDescription ?? "Unbekannte Objective-C-Exception")
    }
}
