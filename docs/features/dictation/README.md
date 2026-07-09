---
status: aktiv
updated: 2026-07-09
---

# Dictation — Landkarte der Diktat-Säule

Die Diktat-Säule verbindet den globalen Recording-Hotkey mit Aufnahme,
Kontext-Erfassung, Speech-to-Text, optionaler Codex-Nachbearbeitung und der
Auslieferung des Ergebnisses. `RecordingCoordinator` hält diesen Lifecycle
zusammen: Er startet `AudioRecorder`, stößt danach die parallele
Kontext-Erfassung an und übergibt die Audiodatei an den konfigurierten
`TranscriptionService`. Beim Stop werden Output-Modus und ein Kontext-Snapshot
für den Lauf eingefroren; der Clipboard-Monitor bleibt jedoch aktiv, sodass
späterer Live-Kontext noch in Prompt und Post-Processing einfließen kann. Das
normalisierte Rohtranskript wird je nach Output-Modus direkt verwendet oder
durch AI Output verarbeitet. Das finale Ergebnis wird immer in die
Zwischenablage kopiert und optional per Auto-Paste in die zuvor aktive App
eingefügt. Im Task-Modus sucht WhisperM8 anschließend die jüngste passende
Codex-Session und speichert ihre Zuordnung im Run-Report; das Session-Matching
ist kein eigener Auslieferungskanal.

```text
Hotkey → RecordingCoordinator → AudioRecorder ─────────────────────┐
                              ↘ Kontext-Capture (parallel) → Merge │
                                                                  ↓
TranscriptionService → optional AI Output (Codex) → Clipboard → optional Auto-Paste
                              └─ Task-Modus: Session-Matching → Run-Report
```

Die vier Teilbereiche dokumentieren bewusst unterschiedliche Verträge. Diese
Seite zeigt ihre Übergaben; Providerdetails, Capture-Regeln, Output-Modes,
Fehlerpfade und UI-Verhalten stehen in den verlinkten Detaildokumenten.

## Teilbereiche

### [Recording](recording/)

Recording dokumentiert den Hotkey-gesteuerten Aufnahme-Lifecycle, die
Recording-Pill, Audio-Ducking, Stop/Cancel/Retry und die abschließende
Auslieferung. Dort schlägt man nach, wenn es um Zustandsübergänge,
Aufnahmegeräte, Overlay-Verhalten, fehlgeschlagene Aufnahmen oder
Clipboard/Auto-Paste geht; die Komponenten und Invarianten stehen in der
[Recording-Architektur](recording/ARCHITECTURE.md).

### [Transcription](transcription/)

Transcription beschreibt die gemeinsame Speech-to-Text-Schicht für OpenAI und
Groq mit Provider-/Modellwahl, Keychain-Bezug, Multipart-Upload und Limits.
Diese Doku ist die Anlaufstelle für den Vertrag des `TranscriptionService`,
Request- und Fehlerverhalten sowie die Abgrenzung zwischen GUI-Diktat und CLI;
der technische Datenfluss steht in der
[Transcription-Architektur](transcription/ARCHITECTURE.md).

### [AI Output](ai-output/)

AI Output dokumentiert die optionale Codex-Nachbearbeitung mit Output-Modes,
Templates, Prompt-Paketen, `codex exec`, Fallbacks und Run-Reports. Dort
schlägt man nach, wenn ein Rohtranskript transformiert, mit Kontext angereichert
oder im Task-Modus die jüngste Codex-Session gesucht und ihre Zuordnung im
Run-Report gespeichert wird; die Schichten und Spawn-Verträge stehen in der
[AI-Output-Architektur](ai-output/ARCHITECTURE.md).

### [Visual Context](visual-context/)

Visual Context beschreibt ausgewählten Text, Screenshots, Screen-Clips,
Visual Frames und Agent-Chat-Referenzen im `TranscriptContextBundle`. Diese
Doku beantwortet Fragen zu Capture-Zeitpunkt, Privacy und Permissions,
Merge-Regeln sowie der Weitergabe visueller Inhalte: Nur Screenshots,
Annotationen und Visual Frames gehen als Bilder an Codex oder Auto-Paste.
Screen-Clips werden weder direkt an Codex angehängt noch auto-gepastet. Ihre
Pfade stehen im Prompt und Visual Manifest; der Run-Report erfasst sie als
Anhänge und archiviert eine Kopie. Die Lifecycle-Details stehen in der
[Visual-Context-Architektur](visual-context/ARCHITECTURE.md).

## Settings

Die zugehörigen Einstellungen liegen in der Gruppe **Dictation** des
[Settings-Bereichs](../settings/): **Recording** konfiguriert Hotkey,
Mikrofon, Audio-Ducking, Overlay und Auto-Paste; **Transcription** verwaltet
Provider, API-Key, Modell und Sprache; **AI Output** bündelt Codex-Defaults,
Modes, Templates und Test Lab; **Context & Privacy** steuert ausgewählten und
visuellen Kontext. Systemberechtigungen für Mikrofon, Accessibility und Screen
Recording werden zusätzlich auf der Settings-Seite **Permissions** sichtbar
gemacht.

## Schlüsseldateien

- `WhisperM8/Services/Dictation/RecordingCoordinator.swift` ist die Fassade für Start, Stop und den Top-Level-Zustand des Diktat-Laufs.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift` verbindet Transkription, optionale Codex-Nachbearbeitung und Zustellung; im Task-Modus sucht die Erweiterung die jüngste passende Session und schreibt die Zuordnung in den Run-Report.
- `WhisperM8/Services/Dictation/AudioRecorder.swift` nimmt Audio auf und erzeugt die temporäre M4A-Datei für die Transkription.
- `WhisperM8/Models/TranscriptContextBundle.swift` ist das gemeinsame Datenmodell für Text-, Bild-, Clip- und Agent-Chat-Kontext.
- `WhisperM8/Services/Dictation/TranscriptionService.swift` definiert den Provider-unabhängigen Speech-to-Text-Vertrag.
- `WhisperM8/Services/Dictation/PostProcessingService.swift` entscheidet über Raw-Ausgabe, Kontextpolicy und optionale Codex-Verarbeitung.
- `WhisperM8/Services/Dictation/PasteService.swift` übernimmt Clipboard- und Auto-Paste-Zustellung an die zuvor aktive App.

## Keywords

Diktat, Dictation, Hotkey, Aufnahme, Recording, `RecordingCoordinator`,
`AudioRecorder`, Visual Context, Kontext-Erfassung, `TranscriptContextBundle`,
Transkription, Speech-to-Text, STT, `TranscriptionService`, OpenAI, Groq,
AI Output, Codex-Nachbearbeitung, `codex exec`, Output-Modus, Task-Modus,
Clipboard, Zwischenablage, Auto-Paste, Session-Matching, Run-Report, Live-Kontext,
Kontext-Snapshot, Settings, Dictation-Gruppe.
