# Recherche-Prompt: OpenAI Whisper API

## Kontext

WhisperM8 soll die OpenAI Whisper API nutzen, um aufgenommenes Audio zu transkribieren. Wir brauchen alle technischen Details für die Integration.

## Was wir wissen müssen

### 1. API-Endpunkt und Authentifizierung

- Welcher Endpunkt? (`/v1/audio/transcriptions`)
- Wie wird der API-Key übergeben? (Header: `Authorization: Bearer sk-...`)
- Gibt es Rate Limits?
- Wie viel kostet die Nutzung? (Preis pro Minute Audio)

### 2. Request-Format

- Multipart/form-data Struktur
- Welche Parameter gibt es?
  - `file` (required) - Audio-Datei
  - `model` (required) - z.B. "whisper-1"
  - `language` (optional) - ISO-639-1 Code
  - `prompt` (optional) - Kontext für bessere Transkription
  - `response_format` (optional) - json, text, srt, verbose_json, vtt
  - `temperature` (optional)

### 3. Audio-Anforderungen

- Unterstützte Formate: mp3, mp4, mpeg, mpga, m4a, wav, webm
- Maximale Dateigröße: 25 MB
- Empfohlene Qualität/Settings

### 4. Response-Format

- Wie sieht die JSON-Response aus?
- Welche Felder enthält sie?
- Wie handhabt man Fehler?

### 5. Code-Beispiel

- Vollständiges Swift-Beispiel mit URLSession
- Multipart/form-data Request erstellen
- Response parsen

### 6. Verfügbare Modelle

- Welche Whisper-Modelle gibt es bei OpenAI?
- Unterschiede in Qualität/Geschwindigkeit?

## Recherche-Quellen

- OpenAI API Documentation (https://platform.openai.com/docs/api-reference/audio)
- OpenAI Pricing Page
- Community-Beispiele für Swift-Integration

## Erwartetes Ergebnis

1. Vollständige API-Referenz für unsere Implementierung
2. Swift Code-Beispiel für API-Call
3. Fehlerbehandlung und Edge Cases
4. Kostenübersicht
