import Foundation
import XCTest
@testable import WhisperM8

/// Phase-3 Test-Seam: deckt die aus `AudioRecorder.calculateLevel` extrahierte
/// reine RMS-Pegel-Logik ab (ohne laufende AVAudioEngine testbar).
final class AudioLevelMeterTests: XCTestCase {
    private let accuracy: Float = 1e-5

    func testEmptyWindowIsZero() {
        XCTAssertEqual(AudioLevelMeter.normalized(samples: []), 0)
    }

    func testAllZerosIsZero() {
        XCTAssertEqual(AudioLevelMeter.normalized(samples: [0, 0, 0, 0]), 0)
    }

    func testRMSTimesSensitivity() {
        // RMS([0.1,0.1,0.1]) = 0.1 → ×3.0 = 0.3
        XCTAssertEqual(AudioLevelMeter.normalized(samples: [0.1, 0.1, 0.1]), 0.3, accuracy: accuracy)
    }

    func testSquaringIsSignIndependent() {
        // RMS([0.2,-0.2]) = 0.2 → ×3.0 = 0.6 (Vorzeichen egal, da quadriert)
        XCTAssertEqual(AudioLevelMeter.normalized(samples: [0.2, -0.2]), 0.6, accuracy: accuracy)
    }

    func testLevelIsCappedAtOne() {
        // RMS([0.5]) = 0.5 → ×3.0 = 1.5 → gekappt auf 1.0
        XCTAssertEqual(AudioLevelMeter.normalized(samples: [0.5]), 1.0, accuracy: accuracy)
        XCTAssertEqual(AudioLevelMeter.normalized(samples: [1.0, 1.0]), 1.0, accuracy: accuracy)
    }

    func testQuietSignalBelowCap() {
        // RMS([0.05]) = 0.05 → ×3.0 = 0.15
        XCTAssertEqual(AudioLevelMeter.normalized(samples: [0.05]), 0.15, accuracy: accuracy)
    }

    func testArrayAndPointerOverloadsAgree() {
        let samples: [Float] = [0.03, -0.12, 0.4, 0.0, 0.27]
        let viaArray = AudioLevelMeter.normalized(samples: samples)
        let viaPointer = samples.withUnsafeBufferPointer { AudioLevelMeter.normalized(samples: $0) }
        XCTAssertEqual(viaArray, viaPointer, accuracy: accuracy)
    }
}
