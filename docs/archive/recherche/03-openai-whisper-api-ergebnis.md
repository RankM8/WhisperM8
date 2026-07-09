# Recherche-Ergebnis: OpenAI Whisper API

# OpenAI Whisper API: Vollständige Swift/iOS-Integrationsanleitung

Die OpenAI Whisper API ermöglicht Audio-Transkription über einen REST-Endpunkt mit multipart/form-data Requests. **Kernfakten:** Maximale Dateigröße **25 MB**, Preis ab **$0.003/Minute** (gpt-4o-mini-transcribe), und das empfohlene Modell für iOS-Apps mit Timestamps ist **whisper-1**. Diese Anleitung deckt alle technischen Details für eine produktionsreife Swift-Integration ab.

## API-Endpunkt und Authentifizierung

Der Transkriptions-Endpunkt ist `https://api.openai.com/v1/audio/transcriptions` mit HTTP-Methode **POST**. Die Authentifizierung erfolgt über einen Bearer-Token im Authorization-Header:

```
Authorization: Bearer sk-XXXXXXXXXXXX
Content-Type: multipart/form-data; boundary=<boundary>
```

**Rate Limits** variieren nach Usage-Tier. Neue Accounts starten bei Tier 1 mit etwa **50 RPM** (Requests pro Minute). OpenAI erhöht Limits automatisch basierend auf Zahlungshistorie. Aktuelle Limits sind unter `platform.openai.com/settings/organization/limits` einsehbar. Für Audio gilt zusätzlich ein Limit für verarbeitete Megabytes pro Minute.

| Modell | Preis/Minute | Preis/Stunde |
|--------|-------------|--------------|
| whisper-1 | **$0.006** | $0.36 |
| gpt-4o-transcribe | $0.006 | $0.36 |
| gpt-4o-mini-transcribe | **$0.003** | $0.18 |

## Request-Format und alle Parameter

Der Request wird als `multipart/form-data` gesendet. Jeder Parameter benötigt einen eigenen Part mit `Content-Disposition: form-data; name="parameter"`.

**Pflichtfelder:**

| Parameter | Typ | Beschreibung |
|-----------|-----|--------------|
| `file` | binary | Audio-Datei als Binary-Data mit Filename |
| `model` | string | Modell-ID: `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` |

**Optionale Felder:**

| Parameter | Typ | Default | Beschreibung |
|-----------|-----|---------|--------------|
| `language` | string | auto | ISO-639-1 Code (z.B. "de", "en") – verbessert Genauigkeit und Latenz |
| `prompt` | string | null | Kontext-Prompt; whisper-1 nutzt nur die letzten **224 Tokens** |
| `response_format` | string | json | Ausgabeformat (siehe unten) |
| `temperature` | float | 0 | Sampling-Temperatur (0-1); 0 = deterministisch |
| `timestamp_granularities` | array | null | `["word"]`, `["segment"]`, oder beide; erfordert `verbose_json` |

**Verfügbare response_format Werte:**

- `json` – Einfaches `{"text": "..."}` (alle Modelle)
- `text` – Nur Klartext ohne JSON (alle Modelle)
- `verbose_json` – Mit Timestamps, Segmenten, Wörtern (**nur whisper-1**)
- `srt` – SubRip Untertitel-Format (**nur whisper-1**)
- `vtt` – WebVTT Untertitel-Format (**nur whisper-1**)

## Audio-Anforderungen und Formate

Die API akzeptiert neun Audioformate: **flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, webm**. Die maximale Dateigröße beträgt **25 MB**. Für GPT-4o-Modelle gilt zusätzlich ein Limit von **1.500 Sekunden** (25 Minuten) pro Datei.

**Empfohlene Recording-Einstellungen für iOS:**

| Einstellung | Empfohlener Wert | Begründung |
|-------------|------------------|------------|
| Sample Rate | **16.000 Hz** | Optimal für Spracherkennung |
| Kanäle | **Mono** | Stereo bietet keinen Vorteil |
| Format | **M4A/AAC** | Beste Qualität-zu-Größe-Ratio |
| Bitrate | 128 kbps | Gute Balance zwischen Qualität und Dateigröße |

Bei Aufnahmen über 10 Minuten empfiehlt sich AAC mit 64-96 kbps, um unter 25 MB zu bleiben. Ein 10-Minuten-Audio bei 128 kbps ergibt etwa 9.6 MB.

## Response-Strukturen im Detail

**Standard JSON Response** (`response_format: json`):
```json
{
  "text": "Die transkribierte Audioaufnahme..."
}
```

**Verbose JSON Response** (`response_format: verbose_json`) – enthält Timestamps und Metadaten:

```json
{
  "task": "transcribe",
  "language": "german",
  "duration": 45.32,
  "text": "Vollständiger Text hier...",
  "segments": [
    {
      "id": 0,
      "seek": 0,
      "start": 0.0,
      "end": 4.5,
      "text": " Erstes Segment...",
      "tokens": [2425, 11, 341],
      "temperature": 0.0,
      "avg_logprob": -0.263,
      "compression_ratio": 1.28,
      "no_speech_prob": 0.02
    }
  ],
  "words": [
    {"word": "Erstes", "start": 0.0, "end": 0.3},
    {"word": "Segment", "start": 0.32, "end": 0.8}
  ]
}
```

**Fehler-Response Format:**
```json
{
  "error": {
    "message": "Invalid file format. Supported formats: ['m4a', 'mp3', 'webm', 'mp4', 'mpga', 'wav', 'mpeg']",
    "type": "invalid_request_error",
    "param": null,
    "code": null
  }
}
```

**HTTP Status Codes:** 200 (Erfolg), 400 (ungültige Parameter), 401 (fehlende/ungültige API-Key), 429 (Rate Limit), 500/503 (Server-Fehler).

## Vollständiges Swift-Implementierungsbeispiel

### Multipart-Request-Builder

```swift
import Foundation

public extension Data {
    mutating func append(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        append(data)
    }
}

public struct MultipartRequest {
    public let boundary: String
    private let separator = "\r\n"
    private var data = Data()
    
    public init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
    }
    
    public mutating func add(key: String, value: String) {
        data.append("--\(boundary)\(separator)")
        data.append("Content-Disposition: form-data; name=\"\(key)\"\(separator)\(separator)")
        data.append("\(value)\(separator)")
    }
    
    public mutating func add(key: String, fileName: String, mimeType: String, fileData: Data) {
        data.append("--\(boundary)\(separator)")
        data.append("Content-Disposition: form-data; name=\"\(key)\"; filename=\"\(fileName)\"\(separator)")
        data.append("Content-Type: \(mimeType)\(separator)\(separator)")
        data.append(fileData)
        data.append(separator)
    }
    
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    public var httpBody: Data {
        var body = data
        body.append("--\(boundary)--")
        return body
    }
}
```

### Response-Modelle

```swift
// Standard Response
public struct TranscriptionResponse: Codable {
    public let text: String
}

// Verbose Response mit Timestamps
public struct VerboseTranscriptionResponse: Codable {
    public let task: String
    public let language: String
    public let duration: Double
    public let text: String
    public let segments: [Segment]?
    public let words: [Word]?
    
    public struct Segment: Codable {
        public let id: Int
        public let start, end: Double
        public let text: String
        public let temperature: Double
        public let avgLogprob: Double
        public let noSpeechProb: Double
        
        enum CodingKeys: String, CodingKey {
            case id, start, end, text, temperature
            case avgLogprob = "avg_logprob"
            case noSpeechProb = "no_speech_prob"
        }
    }
    
    public struct Word: Codable {
        public let word: String
        public let start, end: Double
    }
}

// Error Response
public struct OpenAIError: Codable {
    public let error: ErrorDetail
    public struct ErrorDetail: Codable {
        public let message: String
        public let type: String?
    }
}
```

### Whisper-Service mit async/await

```swift
public actor WhisperService {
    private let apiKey: String
    private let session: URLSession
    
    public enum WhisperError: LocalizedError {
        case fileTooLarge(Int), rateLimited, httpError(Int, String), decodingFailed
        
        public var errorDescription: String? {
            switch self {
            case .fileTooLarge(let size): return "Datei \(size / 1_000_000) MB überschreitet 25 MB Limit"
            case .rateLimited: return "Rate Limit erreicht – bitte warten"
            case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
            case .decodingFailed: return "Response konnte nicht dekodiert werden"
            }
        }
    }
    
    public init(apiKey: String, timeout: TimeInterval = 120) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }
    
    public func transcribe(
        audioData: Data,
        fileName: String,
        model: String = "whisper-1",
        language: String? = nil,
        prompt: String? = nil,
        responseFormat: String = "json"
    ) async throws -> TranscriptionResponse {
        // Validate file size
        guard audioData.count <= 25 * 1024 * 1024 else {
            throw WhisperError.fileTooLarge(audioData.count)
        }
        
        // Build multipart request
        var multipart = MultipartRequest()
        let mimeType = mimeType(for: fileName)
        multipart.add(key: "file", fileName: fileName, mimeType: mimeType, fileData: audioData)
        multipart.add(key: "model", value: model)
        
        if let language { multipart.add(key: "language", value: language) }
        if let prompt { multipart.add(key: "prompt", value: prompt) }
        multipart.add(key: "response_format", value: responseFormat)
        
        // Create request
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.httpBody
        
        // Execute
        let (data, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        
        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        case 429:
            throw WhisperError.rateLimited
        default:
            let msg = (try? JSONDecoder().decode(OpenAIError.self, from: data))?.error.message ?? "Unbekannt"
            throw WhisperError.httpError(httpResponse.statusCode, msg)
        }
    }
    
    private func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mp3", "mpeg", "mpga": return "audio/mpeg"
        case "mp4", "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "webm": return "audio/webm"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        default: return "audio/mpeg"
        }
    }
}
```

### Verwendungsbeispiel

```swift
let service = WhisperService(apiKey: "sk-...")

Task {
    do {
        let audioData = try Data(contentsOf: audioFileURL)
        let result = try await service.transcribe(
            audioData: audioData,
            fileName: "recording.m4a",
            language: "de"
        )
        print(result.text)
    } catch {
        print("Fehler: \(error.localizedDescription)")
    }
}
```

## Modellvergleich und Empfehlungen

| Feature | whisper-1 | gpt-4o-transcribe | gpt-4o-mini-transcribe |
|---------|-----------|-------------------|------------------------|
| **Preis/Min** | $0.006 | $0.006 | **$0.003** |
| **Genauigkeit** | Gut | **Beste WER** | Sehr gut |
| **Word Timestamps** | ✅ | ❌ | ❌ |
| **SRT/VTT Export** | ✅ | ❌ | ❌ |
| **Streaming** | ❌ | ✅ | ✅ |
| **Übersetzung→EN** | ✅ | ❌ | ❌ |

**Empfehlungen nach Anwendungsfall:**

- **Untertitel/Karaoke:** whisper-1 (einziges Modell mit Word-Timestamps)
- **Maximale Genauigkeit:** gpt-4o-transcribe (niedrigste Word Error Rate)
- **Kostenoptimierung:** gpt-4o-mini-transcribe (50% günstiger)
- **Meetings mit Sprechererkennung:** gpt-4o-transcribe-diarize ($0.006/Min)

## Edge Cases und Best Practices

**Dateien über 25 MB:** Audio muss in Chunks aufgeteilt werden. Der empfohlene Ansatz nutzt AVAssetExportSession:

```swift
func chunkAudio(url: URL, maxMB: Int = 24) async throws -> [URL] {
    let asset = AVAsset(url: url)
    let duration = try await asset.load(.duration)
    let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
    
    guard fileSize > maxMB * 1024 * 1024 else { return [url] }
    
    let bytesPerSec = Double(fileSize) / CMTimeGetSeconds(duration)
    let secondsPerChunk = Double(maxMB * 1024 * 1024) / bytesPerSec
    // ... Export-Logic für jeden Chunk
}
```

Für Kontextkontinuität zwischen Chunks: Den letzten Satz des vorherigen Chunks als `prompt` für den nächsten verwenden.

**Timeout-Handling:** Empfohlener Timeout ist **120 Sekunden** für längere Dateien. Bei Timeout sollte ein automatischer Retry mit Exponential Backoff erfolgen:

```swift
func transcribeWithRetry(maxAttempts: Int = 3) async throws -> TranscriptionResponse {
    for attempt in 0..<maxAttempts {
        do {
            return try await service.transcribe(...)
        } catch WhisperService.WhisperError.rateLimited {
            let delay = pow(2.0, Double(attempt)) // 1s, 2s, 4s
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
    throw WhisperService.WhisperError.rateLimited
}
```

**iOS-Recording für Whisper:** Verwende AVAudioRecorder mit diesen optimalen Settings:

```swift
let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey: 16000,      // Optimal für Sprache
    AVNumberOfChannelsKey: 1,    // Mono reicht
    AVEncoderBitRateKey: 128000
]
```

**Wichtige Einschränkungen:**
- `timestamp_granularities` funktioniert nur mit `response_format: verbose_json`
- Word-Level Timestamps verursachen zusätzliche Latenz
- Whisper hört die ersten 30 Sekunden zur Spracherkennung, wenn `language` nicht gesetzt ist
- Der `prompt`-Parameter bei whisper-1 berücksichtigt nur die letzten 224 Tokens

## Fazit

Für eine typische iOS-App mit Audio-Transkription ist **whisper-1** die beste Wahl, wenn Timestamps oder Untertitel benötigt werden. Für reine Text-Transkription ohne Timestamps bietet **gpt-4o-mini-transcribe** das beste Preis-Leistungs-Verhältnis. Die Swift-Implementation sollte Retry-Logic, File-Size-Validierung und angemessene Timeouts beinhalten. Bei professionellen Anwendungen mit langen Aufnahmen ist eine Chunking-Strategie mit Prompt-Chaining unerlässlich.
---

## API-Endpunkt

<!-- Nach der Recherche ausfüllen -->

## Request-Format

<!-- Nach der Recherche ausfüllen -->

## Response-Format

<!-- Nach der Recherche ausfüllen -->

## Code-Beispiel (Swift)

<!-- Nach der Recherche ausfüllen -->

## Preise

<!-- Nach der Recherche ausfüllen -->

## Fehlerbehandlung

<!-- Nach der Recherche ausfüllen -->
