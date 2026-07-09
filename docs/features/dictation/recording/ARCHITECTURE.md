---
status: aktiv
updated: 2026-07-09
---

# Recording — Architektur

Die Recording-Architektur ist eine MainActor-orchestrierte Pipeline um
`RecordingCoordinator`: Hotkey und Overlay lösen Aktionen aus, `AppState` hält
die sichtbare Wahrheit, `AudioRecorder` schreibt die Audiodatei, und die
Transkriptions-/Delivery-Erweiterungen liefern das Ergebnis aus.

## Komponenten

- `WhisperM8/Services/Dictation/RecordingCoordinator.swift` ist die Fassade für Start, Stop, Cancel, Retry, Overlay-Wiring, Timer, Kontext-Capture und die Top-Level-State-Übergänge.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift` enthält Transkription, Codex-Post-Processing, Clipboard-/Auto-Paste-Delivery, Run-Report und Task-Agent-Session-Matching.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift` überwacht Clipboard-Änderungen während Recording, Transcribing und Post-Processing und importiert Bilder oder Text ins Kontext-Bundle.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift` behandelt Transkriptionsfehler, Cancel während Upload, Preserve im `FailedRecordingsStore` und Retry-Alert.
- `WhisperM8/Services/Dictation/RecordingCoordinator+UI.swift` enthält Netzwerk-Fehlertexte, Alerts, ESC-Key-Monitor, Duration-Timer-Update und Audio-Datei-Logging.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift` führt paralleles Kontext-Capture nach Aufnahmestart aus und verarbeitet Overlay-Aktionen zum Entfernen oder Ergänzen von Kontext.
- `WhisperM8/Services/Dictation/AudioRecorder.swift` kapselt `AVAudioEngine`, Input-Device-Bindung, Tap-Installation, Pegelmessung, Formatkonvertierung und M4A-Ausgabe.
- `WhisperM8/Services/Dictation/AudioDeviceManager.swift` enumeriert CoreAudio-Input-Devices, persistiert die gewählte UID und fällt für Bluetooth-Geräte bewusst auf System Default zurück.
- `WhisperM8/Services/Dictation/AudioLevelMeter.swift` berechnet den normalisierten RMS-Pegel als testbare Pure-Logic-Schicht für die Waveform.
- `WhisperM8/Services/Dictation/RecordingTimer.swift` liefert den 100-ms-MainActor-Tick, aus dem Dauer, Pegel und Overlay-Updates gespeist werden.
- `WhisperM8/Services/Dictation/CoreAudioVolumeController.swift` ist die CoreAudio-Abstraktion für Systemlautstärke und Default-Output-Listener des Audio-Duckings.
- `WhisperM8/Services/Dictation/PasteService.swift` verwaltet Pasteboard-Text, visuelle Pasteboard-Items, Ziel-App-Aktivierung und Cmd+V-CGEvents.
- `WhisperM8/Services/Dictation/FailedRecordingsStore.swift` verschiebt fehlgeschlagene M4A-Dateien mit Sidecar-Metadaten nach Application Support und räumt nach Count- und Age-Limits auf.
- `WhisperM8/Windows/RecordingPanel.swift` definiert das borderless non-activating `NSPanel`, `OverlayController`, tick-isolierte Overlay-Modelle, Hover-Expansion, Drag-Clamp und Reset.
- `WhisperM8/Windows/OverlayFrameResolver.swift` berechnet Panel-Origin, Pill-Anker, Wachstumsrichtung, Legacy-Migration und Clamping der sichtbaren Pill.
- `WhisperM8/Views/OverlayPhase.swift` bildet Recording-, Transcribing- und Improving-Phase auf Farbe, Tooltip, Busy-Status und Cancel-Semantik ab.
- `WhisperM8/Views/RecordingOverlayView.swift` verankert die Pill im fixen Maximalpanel und meldet ihren sichtbaren Frame zurück an den Controller.
- `WhisperM8/Views/RecordingPillView.swift` rendert Kern-Waveform, Timer, Mode-Chip, Kontext-Chip, Visual-Context-Controls sowie Stop- und Cancel-Aktionen.
- `WhisperM8/Views/MenuBarView.swift` projiziert `AppState` in Menübarstatus, Hotkey-Anzeige, Input-Device-Picker, letzte Transkription und Fehler.
- `WhisperM8/Models/AppState.swift` ist das zentrale Observable und delegiert Recording-Aktionen an den Coordinator.
- `WhisperM8/Services/Shared/PerformanceSignposts.swift` definiert die `perf.recording`-Signposts und Budgets für Start, Stop, Engine-Start, Kontext-Capture und Chat-Tail.

## Datenfluss: Start

1. `KeyboardShortcuts.onKeyDown(for: .toggleRecording)` ruft `AppState.startRecording()` auf.
2. `RecordingCoordinator.startRecording()` guardet gegen laufende Aufnahme, Transkription und interne Verarbeitung.
3. `PerfBudgets.recordingStart` misst Hotkey bis Aufnahme läuft; `PerfBudgets.engineStart` umfasst Audio-Ducking-Beginn und `AudioRecorder.startRecording()`.
4. `AudioDuckingManager.shared.beginCapture()` läuft vor dem AVAudioEngine-Start, damit Bluetooth-Profilwechsel nicht als Original-Volume gespeichert werden.
5. `AudioRecorder` fordert Mikrofonzugriff an, bindet das gewählte oder System-Default-Input-Device, validiert das Hardware-Format mit Retries und installiert den Tap.
6. Der Coordinator setzt `AppState.isRecording`, Dauer, Pegel, Output-Modus und Kontext-Bundle zurück, zeigt das Overlay und startet Timer, ESC-Monitor und paralleles Kontext-Capture.

## Audioaufnahme

`AudioRecorder` schreibt in eine temporäre `.m4a`-Datei mit AAC, 16 kHz, mono
und 32 kbit/s. Das Ziel-PCM-Format für die interne Konvertierung ist 16 kHz
mono Float32; `AudioFormatDecision.needsConversion` entscheidet anhand von
Sample-Rate und Kanalzahl, ob ein `AVAudioConverter` nötig ist.

Vor jeder Tap-Installation prüft der Recorder `inputNode.inputFormat(forBus:)`
bis zu fünfmal auf ein recordable Format. Das schützt vor CoreAudio-Zuständen
mit 0 Hz oder 0 Kanälen, die bei Bluetooth- oder Gerätewechseln auftreten und
bei `installTap` als nicht fangbare Objective-C-Exception enden würden.

Im System-Default-Modus beobachtet der Recorder
`.AVAudioEngineConfigurationChange`. Bei einem Wechsel stoppt er Engine und
Tap, wartet 300 ms, liest das neue Hardware-Format mit denselben Retries,
setzt den Converter neu und startet die Engine wieder, ohne die bestehende
Audiodatei zu verwerfen.

## Datenfluss: Stop und Delivery

1. `KeyboardShortcuts.onKeyUp(for: .toggleRecording)` ruft `AppState.stopRecording()` auf; Stops vor 0,3 Sekunden Laufzeit werden als Tap-Start ignoriert.
2. Der Coordinator stoppt einen laufenden Screen-Clip, wartet bis zu 1 Sekunde auf paralleles Kontext-Capture und führt einen finalen Clipboard-Sweep aus.
3. Output-Modus und Kontext-Bundle werden eingefroren, Timer und Recorder stoppen, `AudioDuckingManager.shared.endCapture()` stellt die Lautstärke wieder her.
4. `AppState.isTranscribing` wird gesetzt und das Overlay wechselt in die Transcribing-Phase.
5. `runCancelableTranscription` startet `transcribeAndDeliver` als cancelbaren Task.
6. Nach erfolgreicher Rohtranskription normalisiert der Coordinator Text, führt je nach Output-Modus Codex-Post-Processing aus und wechselt währenddessen in `isPostProcessing`.
7. `PasteService.copyToClipboard` schreibt das finale Ergebnis immer in die Zwischenablage; bei Auto-Paste wird die vorher aktive App reaktiviert und ein Cmd+V-CGEvent gesendet.
8. Nach erfolgreichem Lauf werden Run-Report geschrieben, temporäre Audiodatei und visuelle Kontextdateien bereinigt und die App-State-Flags zurückgesetzt.

Externe Laufzeit: Die eigentliche Transkription hängt vom konfigurierten
Provider und API-Key ab; Codex-Post-Processing hängt vom installierten,
angemeldeten und per Status-Check als bereit bewerteten Codex CLI ab.

## Overlay-Architektur

Das Panel hat immer die fixe Maximalgröße aus `OverlayFrameResolver.panelSize`;
nur die SwiftUI-Pill ändert ihre Breite. Dadurch gibt es keine konkurrierende
Window-Frame-Animation, und transparente Panelbereiche werden über
`PillHitTestHostingView` an darunterliegende Fenster durchgereicht.

`OverlayController` hält die UI-Projektion des `AppState`, aber Pegel und Uhr
sind in `OverlayLevelModel` und `OverlayClockModel` ausgelagert. Der
100-ms-Timer invalidiert deshalb nicht die ganze Pill: Pegel aktualisiert nur
den Waveform-Kern, der Timer-String publiziert nur bei Sekundenwechsel.

`OverlayPhase` kennt genau drei sichtbare Phasen. Recording ist nicht busy und
erlaubt Modus- und Kontextbedienung; Transcribing und Improving sperren diese
Controls und ändern die Semantik des Cancel-Buttons.

## Fehler- und Retry-Pfade

Startfehler wie fehlender Mikrofonzugriff beenden den Startpfad, setzen
`lastError`, stoppen gegebenenfalls Audio-Ducking sofort und zeigen kein
persistentes Recording an. Ein Stop ohne Audiodatei blendet das Overlay aus und
zeigt einen Recording-Error-Alert.

Während `Transcribing...` bleibt ESC aktiv. Ein Cancel oder Netzwerk-/
Transkriptionsfehler landet in `handleTranscriptionCancelled` oder
`handleTranscriptionFailure`; beide Pfade erhalten die M4A über
`FailedRecordingsStore.preserve`. Der Retry hält `FailedRecording`,
Audiodauer, Output-Modus und Kontext-Bundle in `PendingTranscriptionRetry` und
ruft denselben Delivery-Pfad erneut auf.

`FailedRecordingsStore` schreibt pro Audio eine JSON-Sidecar-Datei mit
Aufnahmezeit, Dauer, Sprache, Fehlermeldung und Original-Dateiname. Die
Aufräum-Policy behält höchstens zehn Aufnahmen und höchstens sieben Tage alte
Einträge; verwaiste Audiodateien werden vorsichtig erst über das Alter
entfernt.

## Audio-Ducking

Audio-Ducking ist Teil des Start-/Stop-Pfads, aber fachlich separat
dokumentiert. `CoreAudioVolumeController` stellt dafür Default-Output-Device,
Volume-Lesen/-Setzen, Gerätenamen und Default-Output-Listener bereit; Details
stehen in [audio-ducking.md](audio-ducking.md).

## Performance-Budgets

`PerfSignposts.recording` nutzt die Kategorie `perf.recording`. Die Budgets
loggen `perf_budget_exceeded`, wenn die gemessene Dauer überschritten wird.

| Budget | Grenze | Pfad |
|--------|--------|------|
| `recording.start` | 400 ms | Hotkey bis Aufnahme läuft. |
| `recording.engineStart` | 250 ms | Audio-Ducking-Beginn plus AVAudioEngine-Start. |
| `recording.stop` | 300 ms | Stop-Einstieg bis Start des Transkriptions-Tasks. |
| `recording.contextCapture` | 150 ms | Selektierter-Text-Capture nach Aufnahmestart. |
| `recording.chatTail` | 100 ms | Agent-Chat-Tail-Extraktion off-main. |

## Invarianten und Gotchas

- `AppState.recordingPhase` priorisiert Recording vor Post-Processing und Transcribing; die Pill nutzt zusätzlich `OverlayPhase`, die ohne Idle-Zustand auskommt.
- Audio-Ducking startet vor `audioRecorder.startRecording()` und endet beim Stop oder Cancel, weil Bluetooth-Profile sonst falsche Ausgangslautstärken liefern können.
- `AgentWorkspaceStore` ist nicht Teil des Recording-Hotpaths; Agent-Chat-Bezug entsteht über Kontext-Refs, Codex-Projektpfad und späteres Session-Matching.
- Der Clipboard-Monitor läuft bewusst auch während Transcribing und Improving weiter, damit nachträglich kopierter Kontext noch ins Post-Processing einfließt.
- Nach Eintreffen der Transkriptionsresponse setzt der Coordinator `isDeliveringTranscription`; Cancel ist dann ein No-op, damit Paste-Delays nicht kollabieren.
- Der Task-Output-Modus nutzt den Default-Projektpfad und nicht den aktiven Agent-Chat-Pfad, weil das spätere Session-Matching über genau diesen Pfad läuft.
- Mini-Overlay-Expansion ist hover- und menügetrieben; offene SwiftUI-Menüs halten die Pill expandiert, obwohl AppKit-Menütracking global gemeldet wird.

## Test-Cluster

- `Tests/WhisperM8Tests/RecordingCoordinatorTranscriptionTests.swift` und `Tests/WhisperM8Tests/RecordingCoordinatorClipboardTests.swift` decken Coordinator-Delivery, Fehler-/Cancel-Verhalten und Clipboard-Kontext ab.
- `Tests/WhisperM8Tests/AudioFormatDecisionTests.swift`, `Tests/WhisperM8Tests/AudioLevelMeterTests.swift` und `Tests/WhisperM8Tests/AudioDuckingManagerTests.swift` decken Audioformat-Entscheidung, Pegelberechnung und Ducking-State-Machine ab.
- `Tests/WhisperM8Tests/FailedRecordingsStoreTests.swift` deckt Preserve, Sidecars, Retry-Aufräumen und Prune-Policy ab.
- `Tests/WhisperM8Tests/OverlayFrameResolverTests.swift` und `Tests/WhisperM8Tests/WindowAndOverlayTests.swift` decken Overlay-Geometrie, Clamping und Window-/Overlay-Verhalten ab.
- `Tests/WhisperM8Tests/PerformanceBudgetTests.swift` deckt Budget-Token, idempotentes End und Violation-Callbacks ab.
- `Tests/WhisperM8Tests/MultipartTranscriptionClientTests.swift`, `Tests/WhisperM8Tests/CLITranscriptionTests.swift`, `Tests/WhisperM8Tests/TranscriptionUtilityTests.swift` und `Tests/WhisperM8Tests/AgentChatTailExtractorTests.swift` decken angrenzende Transkriptions- und Kontext-Zulieferer ab.
