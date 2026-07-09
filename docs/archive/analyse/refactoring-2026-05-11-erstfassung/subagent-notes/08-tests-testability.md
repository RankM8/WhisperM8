# Subagent 08 - Tests, Testbarkeit und Coverage

## Kurzbefund

`swift test` laeuft durch: 148 Tests, 0 Fehler, ca. 3.5 Sekunden. Die Suite deckt viele pure Helfer, Stores, Parser, CLI-Argumente und Modell-/Template-Metadaten ab. Die kritischste User-Journey ist kaum testbar: Aufnahme, Transkription, Postprocessing, Clipboard, Auto-Paste, Overlay, Reports und Fehlerpfade.

## Groesste Testluecken

- `WhisperM8/Services/RecordingCoordinator.swift:36`: zu viele feste Abhaengigkeiten (`AudioRecorder`, `OverlayController`, `PasteService`, `RecordingTimer`, `NSWorkspace`, `NSPasteboard`, `AudioDuckingManager.shared`, `KeychainManager`). Es fehlen Tests fuer Start/Stop/Cancel, Short-Recording-Guard, Transkriptionsfehler, Fallback, Report-Status und Auto-Paste.
- `WhisperM8/Services/TranscriptionService.swift:132`: Multipart-Body ist getestet, HTTP-Verhalten nicht: Statuscodes, Decode-Fehler, Header, Timeout, File-too-large, Sanitizing. `URLSession` ist nicht injizierbar.
- `WhisperM8/Services/PasteService.swift:52`: keine Tests fuer fehlende Permissions, fehlendes Ziel, Attachment-Fehler, Clipboard-Restore und Event-Posting.
- `WhisperM8/Services/VisualContextCaptureService.swift:43`: Clipboard-Screenshot, ScreenCaptureKit, Frame-Extraktion und Cleanup sind kaum isolierbar.
- `WhisperM8/Models/AppState.swift:36`: UI-State-Transitions sind wegen intern gebautem `RecordingCoordinator` nur indirekt erreichbar.
- SwiftUI/View-Schicht ist fast ungetestet: `AgentChatsView`, `OutputDashboardView`, `RecordingOverlayView`.

## Brittle / Overbroad

- `Tests/WhisperM8Tests/AgentChatsTests.swift`: 1750 Zeilen, viele Domänen in einer Klasse.
- `Tests/WhisperM8Tests/OutputDashboardTests.swift`: grosse Assertion-Bloecke fuer Reihenfolge/Labels/Flags; Indexzugriffe `modes[0]`, `modes[2]`.
- `Tests/WhisperM8Tests/AgentChatsTests.swift:1213`: schreibt unter `~/.claude/projects`; Risiko fuer lokale Kollisionen/Leaks.
- `Tests/WhisperM8Tests/AgentChatsTests.swift:1279`: invertierte Expectation mit 1 Sekunde ist zeitbasiert/flaky.
- `Tests/WhisperM8Tests/PreferencesTests.swift:103`: mutiert `AppPreferences.shared` global.
- `Tests/WhisperM8Tests/WindowAndOverlayTests.swift:7`: `WindowRequestCenter.shared` wird nicht isoliert/reset.

## Erforderliche Seams

- `AudioRecording`
- `OverlayControlling`
- `PasteDelivering`
- `KeychainProviding`
- `TranscriptionServiceFactory`
- `PermissionChecking`
- `PasteboardProviding`
- `WorkspaceProviding`
- `Clock`/`Sleeper`
- `ProcessRunning`

## Naechste Coverage

- Start setzt State + Kontext.
- Stop friert Mode/Kontext ein.
- fehlender API-Key.
- Transkriptionsfehler.
- Postprocessing-Fallback.
- Auto-Paste an/aus.
- Report-Draft-Felder.
- HTTP-Client mit stubbarem `URLProtocol` oder Session-Abstraktion.
