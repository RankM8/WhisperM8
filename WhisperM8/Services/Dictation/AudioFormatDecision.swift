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

    /// Ist das Hardware-Format überhaupt aufnahmefähig? CoreAudio liefert
    /// 0 Hz / 0 Kanäle, wenn das Eingabegerät (noch) nicht gebunden ist —
    /// Bluetooth-Profilwechsel, Gerätewechsel oder träges coreaudiod unter
    /// Last. Ein `installTap` mit so einem Format wirft eine unfangbare
    /// ObjC-NSException und reißt den Prozess (Crash 2026-07-01 + 2026-07-08).
    static func isRecordable(sampleRate: Double, channelCount: UInt32) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    static func isRecordable(_ format: AVAudioFormat) -> Bool {
        isRecordable(sampleRate: format.sampleRate, channelCount: format.channelCount)
    }
}
