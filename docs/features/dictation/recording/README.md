---
status: aktiv
updated: 2026-07-09
---

# Recording — Aufnahme-Flow und Overlay

Recording ist der Hotkey-gesteuerte Diktat-Flow von WhisperM8: Die App nimmt
Audio auf, zeigt den Zustand in einer schwebenden Pill, transkribiert die M4A
über den konfigurierten Anbieter und liefert das Ergebnis in die Zwischenablage,
per Auto-Paste oder über Codex-Post-Processing in einen Agent-Chat-Kontext.

## Nutzerflow

Der konfigurierte Recording-Hotkey ist als Toggle verdrahtet: KeyDown startet
`AppState.startRecording()`, KeyUp ruft `AppState.stopRecording()` auf. Ein sehr
kurzer Stop innerhalb der ersten 0,3 Sekunden wird ignoriert, damit ein Tap die
Aufnahme startet und der nächste gültige Stop sie beendet.

Beim Start erfasst WhisperM8 die gerade aktive App als Ziel für Auto-Paste,
startet vor dem Recorder das Audio-Ducking und beginnt dann sofort mit der
Audioaufnahme. Kontext wie selektierter Text, aktiver Agent-Chat und visuelle
Anhänge wird parallel nachgereicht, damit der Aufnahmestart nicht auf Clipboard-
oder Dateisystemarbeit wartet. Der Agent-Chat-Kontext wird dabei nur automatisch
übernommen, wenn WhisperM8 selbst beim Start frontmost ist; startet die Aufnahme
aus Cursor, VS Code, Browser oder einer anderen Ziel-App, bleibt der aktive
Agent-Chat bewusst außen vor.

Während der Aufnahme zeigt die Pill Pegel, Dauer, Output-Modus, Kontext und die
Aktionen zum Stoppen oder Abbrechen. Nach Stop friert der Coordinator
Output-Modus und Kontext ein, stoppt den Recorder, setzt das Ducking zurück und
wechselt in die Transkription. Wenn der Modus Codex-Post-Processing nutzt, folgt
nach der Rohtranskription die Improve-Phase.

## Overlay-Phasen

| Phase | Nutzer-Signal | Bedienung |
|-------|---------------|-----------|
| Aufnahme | Mintfarbene, echte Pegel-Bars und Timer. | Modus, Kontext, Screenshots und Screen-Clip sind bedienbar; ✓ stoppt und transkribiert, ✕ verwirft die Aufnahme. |
| Transkription | Amberfarbenes Scan-Lauflicht. | Kontext- und Modus-Bedienung ist gesperrt; ✕ bricht den Upload ab und sichert die Aufnahme. |
| Improve | Violetter Puls mit Codex-Status im Tooltip. | ✕ bricht das Codex-Post-Processing ab; bei erlaubtem Fallback wird das Rohtranskript verwendet. |

Die Pill kann als Full- oder Mini-Overlay laufen. Mini expandiert beim Hover,
hält Menüs während der Bedienung offen und bleibt über einen persistierten
Pill-Anker verschiebbar; ein Doppelklick auf freie Pill-Fläche setzt sie auf
die Default-Position zurück.

Screenshot-, Screen-Clip- und visuelle Kontextdetails gehören zur
Nachbardoku [Visual Context](../visual-context/); Recording beschreibt hier nur
die Bedienpunkte im Aufnahme-Overlay.

## Ergebnis-Auslieferung

WhisperM8 kopiert das finale Transkript immer in die Zwischenablage. Wenn
Auto-Paste aktiviert ist, aktiviert `PasteService` die vor dem Overlay erfasste
Ziel-App und sendet Cmd+V per CGEvent; dafür ist die macOS-Accessibility-
Berechtigung erforderlich. Visuelle Anhänge werden vor dem Paste-Vorgang als
Pasteboard-Payload vorbereitet und nacheinander eingefügt.

Output-Modi ohne Post-Processing liefern die normalisierte Rohtranskription.
Output-Modi mit Post-Processing rufen Codex als externes CLI-Werkzeug auf; der
Erfolg hängt daher vom installierten und angemeldeten Codex-CLI-Zustand ab. Der
Task-Modus läuft nicht-ephemeral im konfigurierten Default-Projekt, damit die
entstehende Codex-Session über den Projektpfad als Agent-Chat wiedergefunden
werden kann. Prompt-basierte Modi bevorzugen, falls vorhanden, das Projekt des
aktiven Agent-Chats als Codex-Arbeitsverzeichnis.

STT-Anbieter, Multipart-Upload und Chunking sind in
[Transcription](../transcription/) dokumentiert. Output-Modi, Templates,
Codex-Post-Processing, Reports und Task-Mode-Details liegen in
[AI Output](../ai-output/); UI-Detailverhalten der Agent-Chats-Sidebar gehört
zur [Agent-Chats-UI-Doku](../../agent-chats/ui/).

## MenuBar

Die Menübar zeigt den aktuellen Recording-Zustand als `Recording...`,
`Transcribing...` oder `Ready`, die letzte Transkription, den letzten Fehler,
den konfigurierten Hotkey und den Input-Device-Picker. Sie startet oder stoppt
die Aufnahme nicht selbst; der eigentliche Toggle läuft über den
KeyboardShortcuts-Hotkey.

## Fehlerfälle

Fehlt die Mikrofonberechtigung oder liefert der Recorder keine Datei, setzt der
Coordinator `lastError`, blendet das Overlay aus und zeigt einen Alert. Fehlt
die Accessibility-Berechtigung für Auto-Paste, bleibt das Ergebnis trotzdem in
der Zwischenablage und der Fehler wird im App-State sichtbar.

Schlägt die Transkription fehl, läuft in ein Netzwerkproblem oder wird während
`Transcribing...` per ESC oder ✕ abgebrochen, wird die M4A nicht gelöscht.
`FailedRecordingsStore` verschiebt sie nach Application Support, schreibt ein
JSON-Sidecar mit Dauer, Sprache und Fehler und hält den Lauf als Retry vor. Der
Retry verwendet dieselbe Audiodatei, denselben Output-Modus und dasselbe
Kontext-Bundle; nach erfolgreichem Retry entfernt der Store Audio und Sidecar.

Bricht der Nutzer die Aufnahme noch während der Recording-Phase ab, stoppt der
Coordinator Timer, Recorder, Kontext-Capture und Screen-Clip, löscht die
temporäre Audiodatei und blendet das Overlay aus.

## Audio-Ducking

Die Aufnahme reduziert während des Captures die Systemlautstärke und stellt sie
beim Stop wieder her. Die Details, Bluetooth-Routing-Fälle und Grenzen stehen
in [audio-ducking.md](audio-ducking.md).

## Schlüsseldateien

- `WhisperM8/WhisperM8App.swift` registriert den `toggleRecording`-Hotkey und leitet KeyDown an `AppState.startRecording()` sowie KeyUp an `AppState.stopRecording()` weiter.
- `WhisperM8/Models/AppState.swift` ist das zentrale Observable für Recording-, Transcribing-, Post-Processing-, Fehler-, Kontext- und Menübar-Zustand.
- `WhisperM8/Services/Dictation/RecordingCoordinator.swift` orchestriert Start, Stop, Cancel, Retry, Overlay-Wiring, Timer, Audio-Ducking und den Übergang in die Transkription.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift` ruft den Transkriptionsanbieter und optional Codex-Post-Processing auf, kopiert das Ergebnis und speichert den Run-Report.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift` sichert fehlgeschlagene oder abgebrochene Transkriptionen im `FailedRecordingsStore` und bietet Retry an.
- `WhisperM8/Services/Dictation/AudioRecorder.swift` nimmt per `AVAudioEngine` auf, schreibt temporäre M4A-Dateien und liefert den Live-Pegel für das Overlay.
- `WhisperM8/Services/Dictation/PasteService.swift` schreibt Text und Anhänge ins Pasteboard und sendet Cmd+V per CGEvent an die vorher aktive App.
- `WhisperM8/Windows/RecordingPanel.swift` stellt das nicht aktivierende Overlay-Panel, den Controller, Hover-Handling, Hit-Testing und Positionspersistenz bereit.
- `WhisperM8/Views/RecordingPillView.swift` rendert die sichtbare Pill mit Waveform, Timer, Modus, Kontext, Screenshot-/Clip-Aktionen und Stop-/Cancel-Buttons.
- `WhisperM8/Views/MenuBarView.swift` zeigt Status, Hotkey, Input-Device-Picker, letzte Transkription und Fehler in der Menübar.

## Keywords

Aufnahme, Diktat, Recording, Hotkey, Aufnahme starten, Aufnahme stoppen,
Tap-to-toggle, Overlay, Recording-Pill, Mini-Pill, Full-Pill, Waveform,
Pegelanzeige, Transkription, Improve, Codex-Nachbearbeitung, Auto-Paste,
Zwischenablage, Clipboard, Agent Chat, Task-Modus, Kontext, Screenshot,
Screen-Clip, FailedRecordings, Retry, Aufnahme sichern, Audio-Ducking,
Input Device, Menübar, `toggleRecording`, `AppState`, `RecordingCoordinator`,
`RecordingCoordinator+Transcription`, `RecordingCoordinator+Failure`,
`RecordingCoordinator+Clipboard`, `RecordingCoordinator+Context`,
`RecordingCoordinator+UI`, `AudioRecorder`, `AudioDeviceManager`,
`AudioDuckingManager`, `AudioLevelMeter`, `RecordingTimer`,
`CoreAudioVolumeController`, `FailedRecordingsStore`, `PasteService`,
`RecordingPanel`, `OverlayFrameResolver`, `OverlayPhase`,
`RecordingPillView`, `MenuBarView`, `PerfBudgets.recordingStart`,
`PerfBudgets.recordingStop`, `PerfBudgets.engineStart`,
`PerfBudgets.contextCapture`, `PerfBudgets.chatTail`.
