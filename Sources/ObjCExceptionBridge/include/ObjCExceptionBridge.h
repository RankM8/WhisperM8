#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Fuehrt `block` aus und faengt eine Objective-C-Exception ab, statt den
/// Prozess sterben zu lassen.
///
/// **Warum es das braucht:** Einige AppKit-/AVFoundation-APIs melden Fehler
/// nicht per NSError, sondern per `NSException` — allen voran
/// `-[AVAudioNode installTapOnBus:bufferSize:format:block:]`, das bei einem
/// Format-Mismatch wirft. Swift kann Objective-C-Exceptions **nicht** fangen:
/// Jede solche Exception laeuft in `std::terminate` und beendet den Prozess
/// mit SIGABRT. Genau so ist WhisperM8 am 01.08.2026 beim Start einer
/// Transkription abgestuerzt (Hardware wechselte waehrend des Starts von
/// 48 kHz auf 24 kHz).
///
/// Kein Swift-seitiger Guard kann das schliessen: Zwischen jeder Pruefung und
/// dem eigentlichen Aufruf bleibt ein Zeitfenster, in dem sich das
/// Audio-Geraet aendern kann. Nur ein `@try`/`@catch` auf der
/// Objective-C-Seite macht aus dem Absturz einen behandelbaren Fehler.
///
/// @param block Der auszufuehrende Code.
/// @param error Bei einer Exception gefuellt (Domain `WM8ObjCException`,
///              `localizedDescription` = `reason` der Exception).
/// @return `YES` wenn der Block ohne Exception durchlief, sonst `NO`.
BOOL WM8PerformCatchingObjCException(void (NS_NOESCAPE ^block)(void),
                                     NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
