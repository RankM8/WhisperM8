import Foundation

// MARK: - Ausgabeformat

enum CLIOutputFormat: String, CaseIterable {
    case txt
    case json
    case srt
    case vtt

    /// Formate, die Segment-Timestamps voraussetzen (also ein Whisper-Modell).
    var requiresSegments: Bool {
        self == .srt || self == .vtt
    }

    static func fromFileExtension(_ ext: String) -> CLIOutputFormat? {
        CLIOutputFormat(rawValue: ext.lowercased())
    }
}

// MARK: - Optionen

struct TranscribeOptions {
    var inputs: [String] = []
    var provider: TranscriptionProvider = .groq
    /// nil → providerspezifischer CLI-Default (Groq: turbo, OpenAI: gpt-4o).
    var model: TranscriptionModel?
    var language: String?
    var format: CLIOutputFormat = .txt
    /// Wurde --format explizit gesetzt? Steuert, ob -o die Endung diktieren darf.
    var formatExplicit = false
    var outputPath: String?
    var modeID: String?
    var apiKey: String?
    var chunkSeconds: Double?
    var dryRun = false

    var resolvedModel: TranscriptionModel {
        if let model { return model }
        return provider == .groq ? .groq_whisper_v3_turbo : .openai_gpt4o
    }
}

// MARK: - Parser

enum CLIArgumentParser {
    enum ParseError: LocalizedError {
        case missingValue(String)
        case unknownFlag(String)
        case invalidValue(flag: String, value: String, allowed: String)
        case noInput

        var errorDescription: String? {
            switch self {
            case .missingValue(let flag):
                return "Option \(flag) erwartet einen Wert."
            case .unknownFlag(let flag):
                return "Unbekannte Option: \(flag)"
            case .invalidValue(let flag, let value, let allowed):
                return "Ungültiger Wert '\(value)' für \(flag). Erlaubt: \(allowed)."
            case .noInput:
                return "Keine Eingabedatei angegeben."
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> TranscribeOptions {
        var options = TranscribeOptions()
        var index = 0

        func nextValue(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue(flag) }
            return arguments[index]
        }

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "-o", "--output":
                options.outputPath = try nextValue(for: arg)
            case "-f", "--format":
                let raw = try nextValue(for: arg)
                guard let format = CLIOutputFormat(rawValue: raw.lowercased()) else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "txt, json, srt, vtt")
                }
                options.format = format
                options.formatExplicit = true
            case "-l", "--language":
                options.language = try nextValue(for: arg)
            case "--provider":
                let raw = try nextValue(for: arg)
                guard let provider = TranscriptionProvider(rawValue: raw.lowercased()) else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "groq, openai")
                }
                options.provider = provider
            case "--model":
                let raw = try nextValue(for: arg)
                guard let model = TranscriptionModel(rawValue: raw) else {
                    throw ParseError.invalidValue(
                        flag: arg,
                        value: raw,
                        allowed: "whisper-large-v3-turbo, whisper-large-v3, gpt-4o-transcribe, whisper-1"
                    )
                }
                options.model = model
            case "--mode":
                options.modeID = try nextValue(for: arg)
            case "--api-key":
                options.apiKey = try nextValue(for: arg)
            case "--chunk-seconds":
                let raw = try nextValue(for: arg)
                guard let value = Double(raw), value > 0 else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "positive Zahl (Sekunden)")
                }
                options.chunkSeconds = value
            case "--dry-run":
                options.dryRun = true
            default:
                if arg.hasPrefix("-") && arg != "-" {
                    throw ParseError.unknownFlag(arg)
                }
                options.inputs.append(arg)
            }
            index += 1
        }

        // Wenn --provider gesetzt wurde, aber das Modell zu einem anderen
        // Provider gehört, ignorieren wir das Modell und nehmen den Default —
        // verhindert sinnlose Kombinationen wie provider=groq + gpt-4o.
        if let model = options.model, model.provider != options.provider {
            options.model = nil
        }

        // -o ohne explizites --format: Format aus der Dateiendung ableiten.
        if !options.formatExplicit, let path = options.outputPath {
            let ext = (path as NSString).pathExtension
            if let inferred = CLIOutputFormat.fromFileExtension(ext) {
                options.format = inferred
            }
        }

        if options.inputs.isEmpty {
            throw ParseError.noInput
        }
        return options
    }
}
