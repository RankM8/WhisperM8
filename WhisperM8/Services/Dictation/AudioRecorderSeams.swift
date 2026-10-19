import AVFoundation

/// Kleiner Seam für den `AudioRecorder`: genau die Engine-Operationen, die die
/// Zustandsmaschine (Gerätewechsel, Neustart, Abbruch) braucht. Produktiv
/// steckt `AVAudioEngineRecorderEngine` dahinter; Tests setzen einen Fake ein
/// und treiben Konfigurationswechsel, Formatfehler und Schreibfehler
/// deterministisch — ohne Mikrofon und ohne echte CoreAudio-Hardware.
protocol RecorderEngine: AnyObject {
    var isRunning: Bool { get }
    /// Objekt, an dem `AVAudioEngineConfigurationChange` hängt.
    var notificationSource: AnyObject? { get }
    /// Aktuelles Hardware-Format des Eingangs. `nil` = nicht verfügbar
    /// (Fakes); echte Engines liefern bei ungebundenem Gerät 0 Hz / 0 Kanäle.
    func currentInputFormat() -> AVAudioFormat?
    func removeTap()
    /// Installiert den Aufnahme-Tap. Muss ObjC-Exceptions in einen Swift-Fehler
    /// übersetzen (`ObjCException.catching`) — nie ein nackter `installTap`.
    func installTap(format: AVAudioFormat, handler: @escaping (AVAudioPCMBuffer) -> Void) throws
    func prepare()
    func start() throws
    func stop()
}

/// Ziel der Aufnahme-Buffer (produktiv `AVAudioFile`).
protocol RecordingFileWriter: AnyObject {
    func write(from buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: RecordingFileWriter {}

/// Produktiv-Adapter: `AVAudioEngine` hinter dem `RecorderEngine`-Seam.
final class AVAudioEngineRecorderEngine: RecorderEngine {
    let engine: AVAudioEngine

    init(_ engine: AVAudioEngine) {
        self.engine = engine
    }

    var isRunning: Bool { engine.isRunning }
    var notificationSource: AnyObject? { engine }

    func currentInputFormat() -> AVAudioFormat? {
        // inputFormat(forBus:) — NICHT outputFormat: nur das liefert das echte Hardware-Format.
        engine.inputNode.inputFormat(forBus: 0)
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func installTap(format: AVAudioFormat, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let inputNode = engine.inputNode
        // Der einzige vollständige Schutz: Auch nach dem Neulesen des Formats
        // bleibt ein Zeitfenster, in dem das Gerät wechseln kann. Ohne
        // @try/@catch beendet die NSException aus AVFAudio den Prozess.
        // Größerer Puffer (4096) für bessere Bluetooth-Kompatibilität.
        try ObjCException.catching {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                handler(buffer)
            }
        }
    }

    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}
