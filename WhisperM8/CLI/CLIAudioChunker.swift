import AVFoundation
import Foundation

/// Zerlegt eine (bereits nach 16 kHz mono normalisierte) Audiodatei in Stücke
/// unterhalb des 25-MB-API-Limits. Geschnitten wird silence-aware: die
/// Schnittgrenze wird auf die energieärmste Stelle in einem Fenster um die
/// Ziel-Marke gelegt — so wird nicht mitten im Wort getrennt.
enum CLIAudioChunker {
    struct Chunk {
        let url: URL
        let startOffset: Double
        let duration: Double
    }

    /// Default-Ziel-Chunklänge: 90 min. Bei 32 kbps ≈ 21,6 MB — sicher unter
    /// dem 25-MB-Limit, und so wenige Grenzen wie möglich.
    static let defaultTargetSeconds: Double = 90 * 60

    static func makeChunks(
        normalizedURL: URL,
        totalDuration: Double,
        targetSeconds: Double,
        tempDir: URL
    ) async throws -> [Chunk] {
        // Kurz genug → ein einziger Chunk, kein Re-Extract nötig.
        if totalDuration <= targetSeconds {
            return [Chunk(url: normalizedURL, startOffset: 0, duration: totalDuration)]
        }

        let analysis = try await analyzeEnergies(url: normalizedURL)
        let splitTimes = computeSplitTimes(
            duration: totalDuration,
            energies: analysis.energies,
            frameDuration: analysis.frameDuration,
            targetSeconds: targetSeconds,
            windowSeconds: min(30, targetSeconds / 3)
        )

        let boundaries = [0.0] + splitTimes + [totalDuration]
        var chunks: [Chunk] = []
        for i in 0..<(boundaries.count - 1) {
            let start = boundaries[i]
            let duration = boundaries[i + 1] - start
            guard duration > 0.1 else { continue }
            let chunkURL = tempDir.appendingPathComponent("chunk-\(i).m4a")
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
            try await CLIAudioExtractor.extractNormalizedAudio(from: normalizedURL, to: chunkURL, timeRange: range)
            chunks.append(Chunk(url: chunkURL, startOffset: start, duration: duration))
        }
        return chunks
    }

    // MARK: - Split-Berechnung

    /// Berechnet Schnittzeiten: an jeder k·target-Marke wird im Fenster ±window
    /// die energieärmste Stelle gesucht. Rein funktional → gut testbar.
    static func computeSplitTimes(
        duration: Double,
        energies: [Float],
        frameDuration: Double,
        targetSeconds: Double,
        windowSeconds: Double
    ) -> [Double] {
        guard duration > targetSeconds, frameDuration > 0, !energies.isEmpty else { return [] }
        let framesPerSecond = 1.0 / frameDuration
        var splits: [Double] = []
        var target = targetSeconds

        while target < duration - 1.0 {
            let windowStart = max(0, target - windowSeconds)
            let windowEnd = min(duration, target + windowSeconds)
            let startIdx = max(0, Int(windowStart * framesPerSecond))
            let endIdx = min(energies.count - 1, Int(windowEnd * framesPerSecond))

            var splitTime = target
            if startIdx <= endIdx {
                var bestIdx = startIdx
                var bestEnergy = Float.greatestFiniteMagnitude
                for idx in startIdx...endIdx where energies[idx] < bestEnergy {
                    bestEnergy = energies[idx]
                    bestIdx = idx
                }
                splitTime = Double(bestIdx) * frameDuration
            }

            // Monotonie + Mindestabstand zur vorherigen Grenze sicherstellen.
            let lowerBound = (splits.last ?? 0) + 1.0
            if splitTime < lowerBound { splitTime = min(target, duration - 0.5) }
            if splitTime > lowerBound && splitTime < duration {
                splits.append(splitTime)
            }
            target += targetSeconds
        }
        return splits
    }

    // MARK: - Energie-Analyse

    struct EnergyAnalysis {
        let frameDuration: Double
        let energies: [Float]
    }

    /// Liest die 16-kHz-mono-PCM-Samples und berechnet pro Frame (50 ms) den
    /// RMS-Pegel. Speicher bleibt flach: nur das kompakte Energie-Array
    /// (8 h ≈ 2,3 MB), nie das volle PCM.
    static func analyzeEnergies(url: URL, frameDuration: Double = 0.05) async throws -> EnergyAnalysis {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw CLIAudioError.noAudioTrack(url.lastPathComponent)
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CLIAudioError.readerSetupFailed("Analyse-Output konnte nicht hinzugefügt werden.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CLIAudioError.readerSetupFailed(reader.error?.localizedDescription ?? "Analyse-Reader-Start fehlgeschlagen.")
        }

        let samplesPerFrame = max(1, Int(16000 * frameDuration))
        var energies: [Float] = []
        var accumulator: Double = 0
        var sampleCount = 0

        while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else {
                CMSampleBufferInvalidate(buffer)
                continue
            }
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            if let dataPointer, totalLength >= 2 {
                let sampleTotal = totalLength / 2
                dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleTotal) { samples in
                    for i in 0..<sampleTotal {
                        let value = Float(samples[i]) / 32768.0
                        accumulator += Double(value * value)
                        sampleCount += 1
                        if sampleCount >= samplesPerFrame {
                            energies.append(Float((accumulator / Double(sampleCount)).squareRoot()))
                            accumulator = 0
                            sampleCount = 0
                        }
                    }
                }
            }
            CMSampleBufferInvalidate(buffer)
        }

        if sampleCount > 0 {
            energies.append(Float((accumulator / Double(sampleCount)).squareRoot()))
        }
        return EnergyAnalysis(frameDuration: frameDuration, energies: energies)
    }
}
