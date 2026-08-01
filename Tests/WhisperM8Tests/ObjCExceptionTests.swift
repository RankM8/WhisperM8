import AVFoundation
import Foundation
import XCTest
@testable import WhisperM8

/// Diese Tests sind der Beleg dafür, dass der Absturz vom 01.08.2026 nicht
/// mehr möglich ist: Eine Objective-C-Exception aus AVFoundation beendete den
/// Prozess mit SIGABRT, weil Swift sie nicht fangen kann. Schlägt einer dieser
/// Tests fehl, ist der Schutz weg — und zwar so, dass man es beim nächsten
/// Gerätewechsel als Absturz merkt.
final class ObjCExceptionTests: XCTestCase {

    func testExceptionWirdZuSwiftFehler() {
        var gelaufen = false
        XCTAssertThrowsError(
            try ObjCException.catching {
                gelaufen = true
                NSException(name: .genericException, reason: "Testfall", userInfo: nil).raise()
            }
        ) { error in
            // Die Reason gehört in den Fehler — sonst steht der Nutzer vor
            // einer nichtssagenden Meldung und wir vor einem blinden Log.
            XCTAssertTrue(error.localizedDescription.contains("Testfall"),
                          "war: \(error.localizedDescription)")
        }
        XCTAssertTrue(gelaufen, "der Block muss ausgeführt worden sein")
    }

    func testOhneExceptionLaeuftAllesDurch() {
        var zaehler = 0
        XCTAssertNoThrow(try ObjCException.catching { zaehler += 1 })
        XCTAssertEqual(zaehler, 1)
    }

    /// Der echte Fall, nachgestellt: ein Tap mit einem Format, das nicht zur
    /// Hardware passt. Ohne den Shim endet dieser Test nicht mit einem
    /// Fehlschlag, sondern mit einem abgestürzten Testprozess.
    func testFormatMismatchBeimTapStuerztNichtAb() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardware = inputNode.inputFormat(forBus: 0)
        // Auf Maschinen ohne Eingabegerät (CI) gibt es nichts zu prüfen.
        try XCTSkipUnless(hardware.sampleRate > 0 && hardware.channelCount > 0,
                          "kein Eingabegerät verfügbar")

        // Bewusst falsche Abtastrate — genau der Mismatch aus dem Absturz
        // (Hardware 24 kHz, angefordert 48 kHz).
        let abweichend = AVAudioFormat(
            standardFormatWithSampleRate: hardware.sampleRate == 48_000 ? 24_000 : 48_000,
            channels: hardware.channelCount
        )
        let format = try XCTUnwrap(abweichend)

        var fehler: Error?
        do {
            try ObjCException.catching {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
            }
        } catch {
            fehler = error
        }
        inputNode.removeTap(onBus: 0)

        // Kernaussage: Der Prozess lebt noch. Ob AVFoundation den Mismatch in
        // dieser Konstellation überhaupt beanstandet, hängt vom Gerät ab —
        // beanstandet sie ihn, muss es ein Fehler sein und kein Absturz.
        if let fehler {
            XCTAssertFalse(fehler.localizedDescription.isEmpty)
        }
    }
}
