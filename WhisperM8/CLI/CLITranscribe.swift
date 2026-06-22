import AVFoundation
import Foundation

// MARK: - transcribe

enum CLITranscribeCommand {
    static func run(arguments: [String]) async -> Int32 {
        let options: TranscribeOptions
        do {
            options = try CLIArgumentParser.parse(arguments)
        } catch {
            CLIIO.err("Fehler: \(error.localizedDescription)")
            CLIIO.err("Hilfe: whisperm8 --help")
            return 64
        }

        let model = options.resolvedModel

        // Validierung: Untertitel-Formate brauchen Segment-Timestamps.
        if options.format.requiresSegments && !modelSupportsSegments(model) {
            CLIIO.err("Format '\(options.format.rawValue)' braucht Timestamps, aber Modell '\(model.rawValue)' liefert keine Segmente.")
            CLIIO.err("Nutze ein Whisper-Modell, z. B. --model whisper-large-v3-turbo.")
            return 65
        }

        // Validierung: Nachbearbeitung erzeugt Fließtext → keine Untertitel.
        if options.modeID != nil && options.format.requiresSegments {
            CLIIO.err("--mode ist mit Format '\(options.format.rawValue)' nicht kombinierbar. Nutze -f txt oder -f json.")
            return 65
        }

        var resolvedMode: OutputMode?
        if let modeID = options.modeID {
            guard let mode = OutputModeStore().modes.first(where: { $0.id == modeID }) else {
                CLIIO.err("Unbekannter Mode '\(modeID)'. Verfügbare Modes: whisperm8 modes")
                return 65
            }
            resolvedMode = mode
        }

        if options.inputs.count > 1 && options.outputPath != nil {
            CLIIO.err("-o ist bei mehreren Eingabedateien nicht erlaubt — Ergebnisse landen neben den Quelldateien.")
            return 64
        }

        var apiKey = ""
        if !options.dryRun {
            guard let key = CLIKeyResolver.resolve(provider: options.provider, explicit: options.apiKey) else {
                let envName = options.provider == .groq ? "GROQ_API_KEY" : "OPENAI_API_KEY"
                CLIIO.err("Kein API-Key für \(options.provider.displayName) gefunden.")
                CLIIO.err("Setze --api-key, die Umgebungsvariable $\(envName) oder hinterlege den Key in WhisperM8.")
                return 78
            }
            apiKey = key
        }

        var hadError = false
        for input in options.inputs {
            let sourceURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
            do {
                if options.dryRun {
                    try await runDryRun(sourceURL: sourceURL, options: options, model: model)
                    continue
                }
                let result = try await transcribeFile(
                    sourceURL: sourceURL,
                    options: options,
                    model: model,
                    apiKey: apiKey,
                    mode: resolvedMode
                )
                let rendered = CLIOutputFormatter.render(result, as: options.format)
                try emit(rendered, for: sourceURL, options: options)
            } catch {
                CLIIO.err("✗ \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                hadError = true
            }
        }
        return hadError ? 1 : 0
    }

    // MARK: Pipeline pro Datei

    private static func transcribeFile(
        sourceURL: URL,
        options: TranscribeOptions,
        model: TranscriptionModel,
        apiKey: String,
        mode: OutputMode?
    ) async throws -> CLITranscriptResult {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperm8-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        CLIIO.err("→ \(sourceURL.lastPathComponent): extrahiere Audio …")
        let normalizedURL = tempDir.appendingPathComponent("audio.m4a")
        try await CLIAudioExtractor.extractNormalizedAudio(from: sourceURL, to: normalizedURL)
        let duration = try await CLIAudioExtractor.probeDuration(of: normalizedURL)

        let target = options.chunkSeconds ?? CLIAudioChunker.defaultTargetSeconds
        let chunks = try await CLIAudioChunker.makeChunks(
            normalizedURL: normalizedURL,
            totalDuration: duration,
            targetSeconds: target,
            tempDir: tempDir
        )
        if chunks.count > 1 {
            CLIIO.err("  \(formatDuration(duration)) → \(chunks.count) Chunks (transkribiere) …")
        } else {
            CLIIO.err("  \(formatDuration(duration)) → transkribiere via \(options.provider.displayName)/\(model.rawValue) …")
        }

        let config: ProviderConfig = options.provider == .groq
            ? .groq(model: model.rawValue)
            : .openAI(model: model.rawValue)
        let responseFormat: TranscriptionResponseFormat = modelSupportsSegments(model) ? .verboseJSON : .json

        let detailed = try await transcribeChunks(
            chunks,
            apiKey: apiKey,
            config: config,
            language: options.language,
            responseFormat: responseFormat
        )
        let parts = zip(detailed, chunks).map { ($0.0, $0.1.startOffset) }
        let stitched = CLITranscriptStitcher.stitch(parts)

        var text = stitched.text
        var segments = stitched.segments
        if let mode, mode.usesPostProcessing {
            CLIIO.err("  Nachbearbeitung via Mode '\(mode.name)' …")
            text = try await PostProcessingService().process(
                rawText: text,
                mode: mode,
                language: options.language ?? ""
            )
            // Post-Processing erzeugt Fließtext, der nicht mehr zu den
            // Roh-Timestamps passt → Segmente verwerfen.
            segments = []
        }

        return CLITranscriptResult(
            text: text,
            segments: segments,
            language: stitched.language ?? options.language,
            duration: stitched.duration ?? duration,
            provider: options.provider.rawValue,
            model: model.rawValue
        )
    }

    // MARK: Chunk-Transkription (bounded concurrency + retry)

    private static func transcribeChunks(
        _ chunks: [CLIAudioChunker.Chunk],
        apiKey: String,
        config: ProviderConfig,
        language: String?,
        responseFormat: TranscriptionResponseFormat,
        maxConcurrent: Int = 3
    ) async throws -> [DetailedTranscription] {
        var results = [DetailedTranscription?](repeating: nil, count: chunks.count)
        let total = chunks.count

        try await withThrowingTaskGroup(of: (Int, DetailedTranscription).self) { group in
            var next = 0
            var running = 0

            func addTask() {
                let idx = next
                next += 1
                running += 1
                let chunk = chunks[idx]
                group.addTask {
                    let result = try await transcribeWithRetry(
                        apiKey: apiKey,
                        config: config,
                        audioURL: chunk.url,
                        language: language,
                        responseFormat: responseFormat,
                        audioDuration: chunk.duration,
                        label: "Chunk \(idx + 1)/\(total)"
                    )
                    return (idx, result)
                }
            }

            while next < total && running < maxConcurrent { addTask() }
            while running > 0 {
                let (idx, result) = try await group.next()!
                results[idx] = result
                running -= 1
                if next < total { addTask() }
            }
        }
        return results.compactMap { $0 }
    }

    private static func transcribeWithRetry(
        apiKey: String,
        config: ProviderConfig,
        audioURL: URL,
        language: String?,
        responseFormat: TranscriptionResponseFormat,
        audioDuration: Double,
        label: String,
        maxAttempts: Int = 4
    ) async throws -> DetailedTranscription {
        let client = MultipartTranscriptionClient(apiKey: apiKey, config: config)
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await client.transcribeDetailed(
                    audioURL: audioURL,
                    language: language,
                    responseFormat: responseFormat,
                    audioDuration: audioDuration
                )
            } catch {
                guard attempt < maxAttempts, isRetryable(error) else { throw error }
                let backoff = pow(2.0, Double(attempt)) // 2, 4, 8 s
                CLIIO.err("  \(label): \(shortError(error)) — neuer Versuch in \(Int(backoff)) s …")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let transcription = error as? TranscriptionError,
           case let .apiError(statusCode, _) = transcription {
            return statusCode == 429 || statusCode >= 500
        }
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(urlError.code)
        }
        return false
    }

    private static func shortError(_ error: Error) -> String {
        if let transcription = error as? TranscriptionError,
           case let .apiError(statusCode, _) = transcription {
            return "HTTP \(statusCode)"
        }
        if let urlError = error as? URLError {
            return "Netzwerk (\(urlError.code.rawValue))"
        }
        return error.localizedDescription
    }

    // MARK: Ausgabe

    private static func emit(_ rendered: String, for sourceURL: URL, options: TranscribeOptions) throws {
        if options.inputs.count > 1 {
            let dest = sourceURL.deletingPathExtension().appendingPathExtension(options.format.rawValue)
            try rendered.write(to: dest, atomically: true, encoding: .utf8)
            CLIIO.err("✓ \(sourceURL.lastPathComponent) → \(dest.lastPathComponent)")
        } else if let outputPath = options.outputPath {
            let dest = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            try rendered.write(to: dest, atomically: true, encoding: .utf8)
            CLIIO.err("✓ geschrieben: \(dest.path)")
        } else {
            CLIIO.outRaw(rendered.hasSuffix("\n") ? rendered : rendered + "\n")
        }
    }

    // MARK: Dry-Run

    private static func runDryRun(sourceURL: URL, options: TranscribeOptions, model: TranscriptionModel) async throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CLIAudioError.fileNotFound(sourceURL.path)
        }
        let asset = AVURLAsset(url: sourceURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let minutes = max(0, duration) / 60.0
        let pricePerMinute = options.provider == .groq ? 0.002 : 0.006
        let target = options.chunkSeconds ?? CLIAudioChunker.defaultTargetSeconds
        let estimatedChunks = max(1, Int(ceil(duration / target)))

        CLIIO.err("Datei: \(sourceURL.lastPathComponent)")
        CLIIO.err("  Dauer:            \(formatDuration(duration))")
        CLIIO.err("  Provider/Modell:  \(options.provider.displayName) / \(model.rawValue)")
        CLIIO.err("  Format:           \(options.format.rawValue)")
        CLIIO.err("  Geschätzte Chunks: \(estimatedChunks)")
        CLIIO.err(String(format: "  Geschätzte Kosten: ~$%.3f", minutes * pricePerMinute))
    }

    // MARK: Helpers

    static func modelSupportsSegments(_ model: TranscriptionModel) -> Bool {
        model != .openai_gpt4o
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Key-Auflösung

enum CLIKeyResolver {
    static func resolve(provider: TranscriptionProvider, explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        let envName = provider == .groq ? "GROQ_API_KEY" : "OPENAI_API_KEY"
        if let env = ProcessInfo.processInfo.environment[envName], !env.isEmpty {
            return env
        }
        if let key = KeychainManager.load(key: provider.keychainKey), !key.isEmpty {
            return key
        }
        return nil
    }
}

// MARK: - modes

enum CLIModesCommand {
    static func run() -> Int32 {
        let modes = OutputModeStore().modes.filter { $0.usesPostProcessing }
        guard !modes.isEmpty else {
            CLIIO.out("Keine Post-Processing-Modes konfiguriert.")
            return 0
        }
        CLIIO.out("Verfügbare OutputModes (für --mode):\n")
        for mode in modes {
            let id = mode.id.count >= 20 ? mode.id : mode.id.padding(toLength: 20, withPad: " ", startingAt: 0)
            CLIIO.out("  \(id)\(mode.name)")
        }
        CLIIO.out("\nHinweis: Nachbearbeitung nutzt die Codex-CLI (muss installiert + eingeloggt sein).")
        return 0
    }
}
