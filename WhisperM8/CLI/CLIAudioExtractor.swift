import AVFoundation
import Darwin
import Foundation

// MARK: - Fehler

enum CLIAudioError: LocalizedError {
    case fileNotFound(String)
    case noAudioTrack(String)
    case readerSetupFailed(String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Datei nicht gefunden: \(path)"
        case .noAudioTrack(let file):
            return "Keine Audiospur in \(file) gefunden."
        case .readerSetupFailed(let message):
            return "Audio konnte nicht gelesen werden: \(message)"
        case .extractionFailed(let message):
            return "Audio-Extraktion fehlgeschlagen: \(message)"
        }
    }
}

// MARK: - Extractor

/// Extrahiert/normalisiert die Audiospur einer beliebigen Audio- oder
/// Videodatei nach 16 kHz mono m4a (AAC, 32 kbps) — das Format, das die
/// Transkriptions-APIs erwarten und das ~1 h 45 min pro 25-MB-Limit zulässt.
enum CLIAudioExtractor {
    static let targetSampleRate: Double = 16000
    static let targetBitRate: Int = 32000

    /// Extrahiert nach `destURL`. Optionaler `timeRange` schneidet einen
    /// Abschnitt heraus (für Chunking). Schlägt AVFoundation beim Voll-Extract
    /// fehl (exotische Container wie mkv/webm), greift der ffmpeg-Fallback.
    static func extractNormalizedAudio(
        from sourceURL: URL,
        to destURL: URL,
        timeRange: CMTimeRange? = nil
    ) async throws {
        if timeRange == nil {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw CLIAudioError.fileNotFound(sourceURL.path)
            }
        }
        do {
            try await extractWithAVFoundation(from: sourceURL, to: destURL, timeRange: timeRange)
        } catch {
            // Fallback nur für den Voll-Extract: AVFoundation kann manche
            // Container nicht öffnen, ffmpeg meist schon.
            if timeRange == nil, let ffmpeg = CLIProcessSupport.which("ffmpeg") {
                CLIIO.err("AVFoundation konnte die Datei nicht lesen — versuche ffmpeg …")
                try FFmpegAudioExtractor.extract(ffmpegPath: ffmpeg, from: sourceURL, to: destURL)
            } else {
                throw error
            }
        }
    }

    static func probeDuration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }

    // MARK: AVFoundation-Pfad

    private static func extractWithAVFoundation(
        from sourceURL: URL,
        to destURL: URL,
        timeRange: CMTimeRange?
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw CLIAudioError.noAudioTrack(sourceURL.lastPathComponent)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CLIAudioError.readerSetupFailed(error.localizedDescription)
        }
        if let timeRange { reader.timeRange = timeRange }

        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CLIAudioError.readerSetupFailed("Audio-Output konnte nicht hinzugefügt werden.")
        }
        reader.add(output)

        try? FileManager.default.removeItem(at: destURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destURL, fileType: .m4a)
        } catch {
            throw CLIAudioError.extractionFailed(error.localizedDescription)
        }
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: targetBitRate
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw CLIAudioError.extractionFailed("Audio-Input konnte nicht hinzugefügt werden.")
        }
        writer.add(input)

        guard reader.startReading() else {
            throw CLIAudioError.readerSetupFailed(reader.error?.localizedDescription ?? "Reader-Start fehlgeschlagen.")
        }
        guard writer.startWriting() else {
            throw CLIAudioError.extractionFailed(writer.error?.localizedDescription ?? "Writer-Start fehlgeschlagen.")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.whisperm8.cli.audio-extract")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            func finish(_ result: Result<Void, Error>) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
                        if !input.append(buffer) {
                            reader.cancelReading()
                            input.markAsFinished()
                            writer.finishWriting {
                                finish(.failure(CLIAudioError.extractionFailed(
                                    writer.error?.localizedDescription ?? "Append fehlgeschlagen.")))
                            }
                            return
                        }
                    } else {
                        input.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            finish(.failure(CLIAudioError.extractionFailed(
                                reader.error?.localizedDescription ?? "Reader-Fehler.")))
                        } else {
                            writer.finishWriting {
                                if writer.status == .completed {
                                    finish(.success(()))
                                } else {
                                    finish(.failure(CLIAudioError.extractionFailed(
                                        writer.error?.localizedDescription ?? "Writer-Fehler.")))
                                }
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}

// MARK: - ffmpeg-Fallback

enum FFmpegAudioExtractor {
    struct ProcessResult {
        var exitCode: Int32
        var stderr: String
    }

    static func extract(ffmpegPath: String, from sourceURL: URL, to destURL: URL) throws {
        try? FileManager.default.removeItem(at: destURL)
        let arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", sourceURL.path,
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "aac",
            "-b:a", "32k",
            "-y", destURL.path
        ]

        let result: ProcessResult
        do {
            result = try runProcess(
                executableURL: URL(fileURLWithPath: ffmpegPath),
                arguments: arguments,
                environment: LoginShellEnvironment.shared.processEnvironment()
            )
        } catch {
            throw CLIAudioError.extractionFailed("ffmpeg konnte nicht gestartet werden: \(error.localizedDescription)")
        }

        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIAudioError.extractionFailed("ffmpeg-Fehler: \(message.isEmpty ? "Exit \(result.exitCode)" : message)")
        }
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 600
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()

        let kill = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: kill)

        // stderr wird für die Fehlermeldung gebraucht und deshalb vor dem
        // Exit-Wait geleert; ungenutztes stdout geht direkt nach nullDevice.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        kill.cancel()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stderr: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - Prozess-Hilfen

enum CLIProcessSupport {
    /// Sucht ein Executable im (korrigierten) Login-Shell-PATH.
    static func which(_ name: String) -> String? {
        let path = LoginShellEnvironment.shared.path
        for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
