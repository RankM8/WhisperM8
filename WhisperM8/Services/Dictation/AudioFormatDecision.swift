import AVFoundation

/// Reine Format-Entscheidung des Aufnahme-Pfads — aus `AudioRecorder`
/// herausgezogen (Phase-3 Test-Seam), ohne laufende `AVAudioEngine` testbar.
/// Verhalten 1:1 wie die bisherigen Inline-Checks in `startRecording()` und
/// `handleConfigurationChange()`.
enum AudioFormatDecision {
    /// Braucht das Eingabe-Format eine Konvertierung auf das Ziel-Format?
    /// (Transkription erwartet 16 kHz Mono.) `true`, sobald Sample-Rate **oder**
    /// Kanalzahl abweichen — exakt die frühere Bedingung
    /// `sampleRate != 16000 || channelCount != 1` (Ziel = `targetFormat`).
    static func needsConversion(from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) -> Bool {
        inputFormat.sampleRate != targetFormat.sampleRate
            || inputFormat.channelCount != targetFormat.channelCount
    }
}
