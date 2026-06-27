import Foundation

/// Reine Pegel-Berechnung für das Aufnahme-Overlay — aus `AudioRecorder`
/// herausgezogen, damit sie ohne laufende `AVAudioEngine` testbar ist
/// (Phase-3 Test-Seam). Verhalten 1:1 wie zuvor in `calculateLevel(buffer:)`.
enum AudioLevelMeter {
    /// Empfindlichkeits-Faktor auf den RMS, bevor bei 1.0 gekappt wird.
    static let sensitivity: Float = 3.0

    /// Normalisierter Pegel (0…1) als RMS der Mono-Samples × `sensitivity`,
    /// gekappt bei 1.0. Leeres Sample-Fenster → 0.
    static func normalized(samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        return min(rms * sensitivity, 1.0)
    }

    /// Array-Komfort-Overload (v.a. für Tests).
    static func normalized(samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { normalized(samples: $0) }
    }
}
