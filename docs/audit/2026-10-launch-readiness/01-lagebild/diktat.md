---
status: aktiv
updated: 2026-10-17
description: Lagebild Diktat (Hotkey bis Auto-Paste, Transkription, Ausgabe-Modi, Kontext, CLI-Transkription) und Voice Gate (Labs) auf Stand a8e0f35 — Datenfluss, Schlüsseldateien, Persistenz, Invarianten, Risiken.
---

# Lagebild Diktat

Stand: Commit `a8e0f35`. Ausgeklammert: Agent-Chats-UI, Jarvis-Board, Control-Server, `CLI/Chats*`, `claude-plugin/`. Die Berührungspunkte zu Agent Chats (aktiver Chat als Kontext) sind unten genannt, aber nicht beschrieben.

## Zweck

Hotkey-Diktat: Aufnahme (M4A, 16 kHz mono) -> Transkription über Groq, OpenAI oder (Labs) ChatGPT-Abo -> optionale Nachbearbeitung mit der Codex-CLI in Ausgabe-Modi (Clean, Prompt, E-Mail, Slack …) -> Zwischenablage und Auto-Paste in die vorherige App. Dazu: Kontext-Erfassung (markierter Text, Screenshots, Screen-Clip, aktiver Agent-Chat), Run-Report-Archiv, gesicherte Aufnahmen bei Fehlern, die Datei-Transkription `whisperm8 transcribe` und als Labs-Funktion das Voice Gate (Codewort für Codex-Desktop).

## Datenfluss

```
Hotkey (KeyboardShortcuts, WhisperM8App) -> AppState.startRecording
  -> RecordingCoordinator.startRecording
       |-- SpeechCalloutCenter.holdForRecording, AudioDuckingManager.beginCapture
       |-- AudioRecorder.startRecording (AVAudioEngine, Tap, Converter) -> tmp/<uuid>.m4a
       |-- OverlayController.show (RecordingPanel, nicht aktivierend, merkt previousApp)
       |-- Prewarm (nur Provider chatgpt: GPT-Proxy hochfahren)
       '-- paralleler Kontext-Task: SelectedContextService (AX, sonst Cmd+C-Fallback)
           + Agent-Chat-Tail -> ContextCaptureMerge (füllt nur leere Slots)
  Clipboard-Monitor (500 ms): Screenshots/Text, die der Nutzer währenddessen kopiert
  Screen-Clip (ScreenCaptureKit, VisualContextCaptureService) -> MP4 + Standbilder
Hotkey-Stop / Haken -> stopRecording (Tap-Schutz < 0,3 s, Kontext-Warten <= 1 s,
  Modus + Kontext einfrieren, Ducking zurück)
  -> runCancelableTranscription -> transcribeAndDeliver
       TranscriptionService (Multipart: OpenAI | Groq | lokaler Proxy-Port)
       -> TextNormalizer -> processTranscriptIfNeeded
            PostProcessingService -> PromptPackageBuilder
            -> CodexPostProcessor (codex exec, read-only, stdin)
            Fehler/Abbruch -> Raw-Fallback
       -> PasteService.copyToClipboard (immer)
       -> PasteService.pastePayloadToActiveApp (CGEvent Cmd+V, Anhänge nacheinander)
       -> TranscriptRunReportStore.save, Audio löschen
  Fehler/Abbruch -> FailedRecordingsStore.preserve + Alert "Erneut versuchen"

whisperm8 transcribe <datei> : CLIAudioExtractor/Chunker -> parallele Uploads (3)
  -> CLIOutputFormatter (txt/json/srt/vtt) [optional Output-Mode über Codex]

Voice Gate (Labs): Timer 10 s -> Probe (Codex läuft + Log-Signatur) -> VoiceGateListener
  (SFSpeechRecognizer on-device) -> CommandMatcher -> StateMachine -> Trockenlauf | CodexMuteToggler (Ctrl+Shift+U)
```

## Schlüsseldateien

- `WhisperM8/Services/Dictation/RecordingCoordinator.swift` — Lifecycle-Fassade (Start, Stop, Cancel, Retry), serialisiert über `isProcessing`; Extensions `+Transcription`, `+Context`, `+Clipboard`, `+Failure`, `+UI` tragen je ein Thema.
- `WhisperM8/Models/AppState.swift` — zentraler `@Observable`-Zustand, Einstieg für Hotkey, Overlay-Aktionen und aktive Chat-Referenz.
- `WhisperM8/Services/Dictation/AudioRecorder.swift` — Engine, Tap, Konverter, Gerätewechsel-Neustart; Format-Prüfung über `AudioFormatDecision`, Tap-Installation unter `ObjCException.catching`.
- `WhisperM8/Services/Dictation/AudioDeviceManager.swift`, `AudioDuckingManager.swift`, `CoreAudioVolumeController.swift` — Geräteliste und Default-Fallback; Ducking mit Multi-Device-Restore.
- `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift` — Streaming-Upload mit dauerabhängigem Timeout und 25-MB-Grenze; `TranscriptionProviders.swift` enthält die Dienste OpenAI und Groq.
- `WhisperM8/Services/Dictation/ChatGPTSubscriptionTranscription.swift` — ChatGPT-Abo-Anbieter: Instanz-Port des GPT-Proxys, Fehlerabbildung, Prewarm.
- `WhisperM8/Models/TranscriptionProvider.swift` — Anbieter, Modelle, `TranscriptionCredentialGate`, `TranscriptionSettings.loadProvider` (Kill-Switch-Rückfall auf Groq).
- `WhisperM8/Models/OutputMode.swift`, `Services/Dictation/OutputModeStore.swift` — Built-in- und Custom-Modi, Normalisierung, Cache, Change-Notification.
- `WhisperM8/Services/Dictation/PostProcessingService.swift`, `PromptPackageBuilder.swift`, `PostProcessingTemplateStore.swift` — Kontextpolicy, Intent-Routing, Prompt-Paket mit Bild-Manifest, Vorlagen.
- `WhisperM8/Services/Dictation/CodexPostProcessor.swift`, `CodexSupport.swift`, `CodexStatusCache.swift` — `codex exec`-Lauf, Argumente, Prozess-Registry für Cancel, Login-Status mit TTL.
- `WhisperM8/Services/Dictation/PasteService.swift` — Clipboard und CGEvent-Paste, Anhänge sequenziell.
- `WhisperM8/Services/Dictation/SelectedContextService.swift`, `VisualContextCaptureService.swift`, `ManualScreenClipSession.swift`, `VisualAttachmentDeliveryBuilder.swift` — Textauswahl per AX/Clipboard, Screenshot, Screen-Clip, Anhänge fürs Paste.
- `WhisperM8/Services/Dictation/FailedRecordingsStore.swift`, `TranscriptRunReportStore.swift` — gesicherte Aufnahmen (Sidecar), Run-Reports mit Index und Retention.
- `WhisperM8/Windows/RecordingPanel.swift`, `OverlayFrameResolver.swift` und `Views/RecordingPillView.swift`, `RecordingOverlayView.swift`, `OverlayPhase.swift` — nicht aktivierendes Panel, Pill, Position, Phasen.
- `WhisperM8/Models/AppUsageProfile.swift`, `Services/Shared/AppProfileActivator.swift` — Nutzungsprofile als Weiche für Codex-Modi und Agent Chats.
- `WhisperM8/CLI/CLITranscribe.swift`, `CLIArguments.swift`, `CLIAudioExtractor.swift`, `CLIAudioChunker.swift`, `CLIOutputFormatter.swift` — Datei-Transkription.
- `WhisperM8/Services/VoiceGate/*` — Coordinator (Timer, Zähler, Trockenlauf), Listener und `VoiceGateAudioSource` (eigene Engine), Matcher, Zustandsmaschine, Probe/Execution-Probe (Codex-Logs), `CodexMuteToggler`.

## Zustände und Persistenz

| Ort | Inhalt | Schreiber |
|---|---|---|
| UserDefaults (`AppPreferences`) | Anbieter, Modell, Sprache, Auto-Paste, Overlay-Stil und -Anker, Eingabegerät-UID, Default-Modus, Kontext-Limits, `usageProfile`, `chatGPTTranscriptionEnabled`, `codexVoiceGate*` | Settings-Seiten, Onboarding, Overlay |
| Schlüsselbund (`KeychainManager`) | `groq_apikey`, `openai_apikey`; ChatGPT-Abo braucht keinen Key | Onboarding, Settings |
| `Application Support/WhisperM8/OutputModes.json` | Modi (Built-in-Overrides + Custom) | `OutputModeStore.saveModes` (atomar) |
| `Application Support/WhisperM8/PostProcessingTemplates.json` | Custom-Vorlagen | `PostProcessingTemplateStore` |
| `Application Support/WhisperM8/FailedRecordings/` | Audio + JSON-Sidecar, max. 10 bzw. 7 Tage | `FailedRecordingsStore` |
| `Application Support/WhisperM8/Reports/` | je Lauf `report.json`, Anhänge, `reports-index.json`; 180 Tage, 500 Läufe, 2 GB | `TranscriptRunReportStore` |
| `$TMPDIR/<uuid>.m4a`, `$TMPDIR/WhisperM8Context/` | laufende Aufnahme, Screenshots, Clips, Standbilder | `AudioRecorder`, `VisualContextCaptureService` |
| im Speicher | `pendingRetry`, Kontext-Bundle, `CodexProcessRegistry` (ein Slot), Voice-Gate-Zähler | Coordinator |

## Externe Abhängigkeiten

- Netz: Groq und OpenAI (HTTPS, Audio geht raus); ChatGPT-Abo über `127.0.0.1:<Proxy-Port>` zum inoffiziellen Upstream `chatgpt.com/backend-api/transcribe` (Audio 30 Tage bei ChatGPT).
- CLIs: `codex` (Nachbearbeitung, Login-Status), optional `ffmpeg` (CLI-Transkription), `screencapture` (Bereichs-Screenshot).
- TCC: Mikrofon (Pflicht), Bedienungshilfen (Auto-Paste, Textauswahl, Voice-Gate-Tastendruck), Bildschirmaufnahme (nur Screen-Clip, erst bei Nutzung), Spracherkennung (nur Voice Gate).
- Prozess-Umgebung: Codex läuft mit `LoginShellEnvironment.processEnvironment()`.

## Invarianten für jeden Umbau

1. Tap-to-toggle: KeyDown startet, ein Stop innerhalb 0,3 s wird ignoriert, der nächste Druck stoppt.
2. Audio startet vor jedem Kontext-I/O; nachgereichter Kontext füllt nur leere Slots und respektiert "Kontext geleert".
3. Das Format wird unmittelbar vor `installTap` neu gelesen; jede Tap-Installation steht unter `ObjCException.catching`; Stop entfernt den Tap vor `engine.stop()`.
4. Der Finaltext geht immer zuerst in die Zwischenablage; Paste-Fehler dürfen ihn nicht verlieren.
5. Cancel endet an der Delivery-Grenze (`isDeliveringTranscription`); davor sichert der Abbruch die Aufnahme, danach bleiben Paste-Delays unberührt.
6. Audio wird nur nach erfolgreicher Delivery gelöscht; jeder Misserfolg geht in `FailedRecordings`.
7. Kein stiller Anbieterwechsel: ChatGPT-Abo fällt nie automatisch auf Groq/OpenAI zurück; fehlender Zugang ist ein Fehler mit Sicherung.
8. Raw/Fast umgeht Post-Processing, Kontext und Codex vollständig; Dictation-only-Profile fallen effektiv auf Fast zurück, ohne die gespeicherte Präferenz zu löschen.
9. Codex läuft `--sandbox read-only`, Prompt über stdin, Bilder über `--image`, leere Ausgabe ist ein Fehler; nur `Task` ist nicht ephemer.
10. Ducking umschließt die Engine-Lebensdauer (Snapshot vor dem Bluetooth-Profilwechsel, Restore bei Stop, Cancel, Fehler, Quit).
11. Gültige Nutzer-Modi und -Vorlagen überleben Reparaturen; Quit darf Aufnahmen sichern, aber nie automatisch transkribieren oder einfügen.
12. Voice Gate drückt nie ohne Aktivierung von Codex, pausiert während eigenem Diktat und läuft nur on-device.

## Top-Risiken (Register `findings.jsonl`)

- Datenverlust: Beenden während Aufnahme oder Upload sichert nichts (LR-DIK-001, auch LR-ONB-001); Recorder-Fehler beim Gerätewechsel umgehen die Rettung (LR-DIK-004); Schreibfehler bleiben unsichtbar (LR-DIK-006); gesicherte Aufnahmen haben später keinen Retry-Weg (LR-DIK-012).
- Konfiguration: Ein defekter oder doppelter Modus vernichtet alle Custom-Modi bzw. beendet die App per Trap (LR-DIK-002, LR-DIK-020, LR-DIK-021).
- Falsche Auslieferung: Auto-Paste prüft weder Ziel noch Fokuswechsel (LR-DIK-007, LR-DIK-022); später Kontext wird verarbeitet, aber nicht zugestellt (LR-DIK-011).
- Datenschutz: Entfernter Chat-Kontext und Screen-Clip-Einzelbilder bleiben im Prompt bzw. versendbar (LR-DIK-008, LR-DIK-009), Löschschalter lässt Kopien liegen (LR-DIK-019), Fehlerantworten schreiben Diktattext ins Log (LR-SH-008), Subprozesse erben App-Secrets (LR-SH-006, LR-SH-010), Keychain-Migration kann den einzigen Key löschen (LR-SH-003, LR-SH-009), Abbruch-Audio ist im Handbuch nicht erwähnt (LR-DOK-007).
- Robustheit: Codex-Nachbearbeitung ohne Abschlussgarantie und mit geteiltem Cancel-Slot (LR-DIK-013, LR-DIK-014); Races bei Gerätewechsel und Screen-Clip-Abbruch (LR-DIK-005, LR-DIK-010); fehlende Codex-CLI führt nur zu einer Hilfeseite (LR-DIK-015, LR-ONB-002).
- Datei-CLI: `whisperm8 transcribe` überschreibt vorhandene Ausgabedateien ungefragt (LR-DIK-003).
- ChatGPT-Abo: Eine nachgeahmte Health-Antwort genügt zur Übernahme der Proxy-Kommunikation (LR-GPT-002); der Anbieter ist bei Kill-Switch-Default "an" im Picker sichtbar, obwohl als Labs eingestuft.
- Voice Gate: Auswertung wird bei Diktat oder Abschalten nicht sofort gesperrt (LR-VG-001); bis zu 96 MiB Log-Scan pro Takt auf dem MainActor (LR-VG-002).
- Performance: Stop wartet bis 1 s auf Kontext (LR-DIK-018); jeder Report-Save durchsucht das Archiv auf dem MainActor (LR-DIK-017); Clipboard-Fallback überschreibt Nutzerkopien (LR-DIK-016).
