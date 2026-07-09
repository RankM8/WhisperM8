# Recherche-Prompt: Audio-Aufnahme unter macOS

## Kontext

Wir entwickeln WhisperM8, eine macOS Speech-to-Text App. Wir müssen Audio vom Mikrofon aufnehmen und in einem Format speichern/senden, das von der OpenAI Whisper API akzeptiert wird.

## Was wir wissen müssen

### 1. Audio-Aufnahme APIs

- Wie nimmt man Audio auf unter macOS mit Swift?
- `AVAudioRecorder` vs `AVAudioEngine` - was ist besser für unseren Use Case?
- Wie wählt man das richtige Eingabegerät (falls mehrere Mikrofone)?

### 2. Audio-Format für Whisper API

- Welche Formate akzeptiert die OpenAI Whisper API? (mp3, mp4, mpeg, mpga, m4a, wav, webm)
- Welches Format ist optimal (Qualität vs. Dateigröße)?
- Welche Sample-Rate und Bitrate sind empfohlen?
- Maximale Dateigröße (25 MB bei OpenAI)?

### 3. Mikrofon-Berechtigungen

- Wie fragt man Mikrofon-Berechtigung an unter macOS?
- `NSMicrophoneUsageDescription` in Info.plist
- Wie prüft man den Berechtigungsstatus?
- Wie reagiert man, wenn Berechtigung verweigert wurde?

### 4. Echtzeit-Feedback

- Wie zeigt man Audio-Pegel während der Aufnahme an (für UI-Feedback)?
- Wie implementiert man eine Wellenform-Visualisierung?

### 5. Code-Beispiele

- Vollständiges Beispiel: Aufnahme starten, stoppen, als Datei speichern
- Beispiel für Audio-Level-Metering

## Recherche-Quellen

- Apple AVFoundation Documentation
- Whisper API Documentation
- GitHub-Projekte mit Audio-Aufnahme

## Erwartetes Ergebnis

1. Empfohlener Ansatz (AVAudioRecorder oder AVAudioEngine)
2. Empfohlenes Audio-Format und Settings
3. Code-Snippets für Aufnahme und Permission-Handling
4. Optional: Audio-Level Visualisierung
