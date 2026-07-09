---
status: aktiv
updated: 2026-07-09
---

# Visual Context — Architektur

Visual Context ist kein eigener Persistenz-Store, sondern ein Kontextpfad im
Recording-Lifecycle. `AppState.contextBundle` ist der Live-Arbeitsstand für
Capture-Aufgaben und Overlay-Edits. Beim Stop wird ein `frozenContextBundle`
für den Transkriptionslauf eingefroren; späte Live-Kopien können danach noch
Prompt-Building und Post-Processing erreichen, während Auto-Paste und der
Bundle-Teil des Run-Reports den an `transcribeAndDeliver` übergebenen
eingefrorenen Kontext verwenden.

## Datenmodell

`SelectedContext` hält den normalisierten Text und die Quell-App. `isEmpty`
trimmt Whitespace, damit leere Selektionen nicht als Kontext gelten.

`TranscriptContextBundle` bündelt alle Kontextarten:

| Feld | Bedeutung |
|------|-----------|
| `selectedText` | Aktive oder währenddessen kopierte Textauswahl |
| `agentChat` | Aktive Agent-Chat-Session beim Recording-Start, nur wenn WhisperM8 selbst frontmost war |
| `agentChatTail` | Gelesener Ausschnitt der letzten User- und Assistant-Nachrichten |
| `screenshots` | Clipboard- oder interaktive Screenshots |
| `annotations` | Annotierte Screenshot-Regionen |
| `screenClips` | MP4-Dateien aus manueller Bildschirmaufnahme |
| `visualFrames` | PNG-Frames, die aus Screen-Clips extrahiert wurden |

`visualAttachments` liefert nur `screenshots + annotations + visualFrames`.
Diese Liste ist absichtlich die Bildliste für Codex-Images und Auto-Paste;
Screen-Clips bleiben eigene Dateipfade im Bundle.

`CodexVisualInputMode` hat `auto`, `frames` und `video`. Der aktuelle
Auswahlcode sendet in allen Modi Bildpfade aus `visualAttachments`; `video`
setzt zusätzlich `usesFrameFallback`, sobald Screen-Clip-Pfade vorhanden sind.

## SelectedContextService

`SelectedContextService.capture(from:)` läuft auf dem MainActor und endet
früh mit `.empty`, wenn `isSelectedContextCaptureEnabled` aus ist. Der
Capture versucht zuerst `kAXSelectedTextAttribute` am fokussierten
Accessibility-Element der Quell-App. Für das AX-Element ist ein Messaging
Timeout von 0,5 Sekunden gesetzt, weil das Capture parallel zum sichtbaren
Overlay läuft und hängende Ziel-Apps sonst die UI blockieren könnten.

Wenn der direkte AX-Lesezugriff keinen Text liefert, prüft der Service die
Accessibility-Permission. Ohne Permission wird nur geloggt und `.empty`
zurückgegeben. Mit Permission aktiviert der Fallback die Ziel-App, sendet
Cmd+C, liest neuen String-Inhalt aus `NSPasteboard.general`, normalisiert den
Text und stellt den vorherigen Pasteboard-Snapshot wieder her.

## VisualContextCaptureService

`VisualContextCaptureService` ist der MainActor-Service für Bild- und
Clip-Dateien. Alle erzeugten Capture-Dateien liegen unter dem temporären
Verzeichnis `WhisperM8Context`.

Clipboard-Screenshots lesen ein `NSImage` aus dem Pasteboard und schreiben es
als PNG. Interaktive Screenshots starten den injizierbaren Runner, dessen
Default das externe macOS-Binary `/usr/sbin/screencapture -i <file>` aufruft.
Die Interaktionsdetails sind externes macOS-Laufzeitverhalten; der Code belegt
den Prozessaufruf und behandelt Abbruch oder leere Auswahl als `nil` ohne
Fehler-Toast.

Screen-Clips prüfen `isVisualContextCaptureEnabled`, Screen-Recording-
Permission, aktiven Display-Zugriff und eine Single-Session-Invariante. Das
Capture-Ziel ist das aktive Overlay-Display, ersatzweise das erste verfügbare
Display. Die `SCContentFilter` schließt die WhisperM8-App selbst aus. Nach
dem Start plant der Coordinator einen automatischen Stop nach
`AppPreferences.shared.maxScreenRecordingDuration`.

Nach `stopScreenClip()` extrahiert der Service aus dem MP4 bis zu fünf
Visual-Frames. Die Anzahl ist `ceil(duration / 4.0)`, begrenzt auf fünf und
mindestens eins; die Frames werden mit maximal 1600 × 1000 Pixel als PNG
geschrieben.

## ManualScreenClipSession

`ManualScreenClipSession` kapselt `SCStream`, `AVAssetWriter` und eine
serielle Sample-Queue. Die Stream-Konfiguration nimmt das ganze Display mit
Cursor auf, 12 fps, BGRA-Pixel, H.264-MP4, ohne Audio und ohne Mikrofon.

Der erste valide Screen-Sample startet den Asset-Writer und die Session-Zeit.
`stop(startedAt:)` stoppt den Stream, verlangt mindestens einen geschriebenen
Frame, beendet den Writer und liefert einen Screen-Clip-Anhang mit Dauer,
Display-ID und Quell-App. `cancel()` stoppt best effort, cancelt den Writer
und löscht die MP4-Datei.

## RecordingCoordinator-Kontextpfad

Beim Recording-Start erstellt `RecordingCoordinator` ein Start-Bundle mit
leerer `SelectedContext` und aktiver Quell-App. Eine
`AppState.activeAgentChat`-Referenz wird nur übernommen, wenn
`contextSourceApp?.bundleIdentifier == Bundle.main.bundleIdentifier` gilt;
bei Ziel-Apps wie Editor oder Browser setzt der Startpfad `activeAgentChat`
auf `nil`. Danach zeigt er das Overlay, startet den Duration-Timer und ruft
`startContextCapture`.

`startContextCapture` erfasst ausgewählten Text über
`SelectedContextService`. Wenn ein Agent-Chat vorhanden ist, liest es den
Chat-Tail in einem detached Task, weil JSONL-Transkripte groß sein können und
File-I/O nicht auf dem MainActor laufen soll. Anschließend ruft der Task
`finishContextCapture`.

`finishContextCapture` merged Text und Tail mit `ContextCaptureMerge`, setzt
`contextBundle`, `selectedContext`, `lastContextBundle` und
`lastSelectedContext`, aktualisiert das Overlay und resynchronisiert den
Pasteboard-ChangeCount. Dadurch werden Cmd+C- und Restore-Bumps des
Clipboard-Fallbacks nicht direkt wieder als User-Kopie importiert.

Beim Stop stoppt der Coordinator zuerst einen laufenden Screen-Clip, wartet
dann bis zu eine Sekunde auf den Capture-Task, führt einen finalen
Clipboard-Sweep aus
und friert dann `frozenContextBundle` für den Transkriptionslauf ein. Während
Transcribing und Post-Processing bleibt der Clipboard-Monitor aktiv; vor dem
Prompt-Build übernimmt `processTranscriptIfNeeded` das Live-Bundle, falls es
nicht leer ist. Diese späten Live-Daten erreichen den Prompt und den
Postprocessor, aber nicht die Auto-Paste-Anhangsauswahl, die auf dem
eingefrorenen Bundle aus `transcribeAndDeliver` basiert.

## Merge und Overlay-Edits

`ContextCaptureMerge.apply` füllt nur leere Slots. Captured Selected Text wird
nur übernommen, wenn der User den Textkontext während des Captures nicht
geleert hat, das Bundle noch keinen Text enthält und das Capture nicht leer
ist. Der Agent-Chat-Tail wird nur ergänzt, wenn die Agent-Chat-Referenz noch
vorhanden ist und noch kein Tail gesetzt wurde.

Overlay-Aktionen verändern dasselbe Bundle:

| Aktion | Effekt |
|--------|--------|
| Kontext leeren | Ruft `cleanup`, leert das Bundle ohne Agent-Chat-Ref und setzt `userClearedContextDuringCapture = true`; Dateien werden nur gelöscht, wenn `deleteContextFilesAfterProcessing` aktiv ist |
| Text entfernen | `selectedText = .empty`, Capture darf ihn nicht nachreichen |
| Agent-Chat entfernen | `agentChat = nil`, Tail wird nicht mehr nachgereicht |
| Anhang entfernen | Entfernt Screenshot, Annotation, Screen-Clip oder Frame aus dem Bundle; die Datei wird nur über `cleanup` gelöscht, wenn `deleteContextFilesAfterProcessing` aktiv ist |
| Interaktiver Screenshot | Hängt einen neuen Screenshot an, wenn Aufnahme noch läuft und die Quote frei ist |
| Screen-Clip Toggle | Startet oder stoppt die aktive Clip-Session |

## Prompt- und Codex-Pfad

Die folgenden Schritte sind die Schnittstelle zu AI-Output und Codex-Exec.
Die Nachbar-Dokumente `docs/features/dictation/ai-output/` und
`docs/features/agent-chats/codex-exec/` beschreiben diese Teilsysteme
eigenständig; hier steht nur, welcher Visual-Context-Anteil übergeben wird.

`PostProcessingService.allowedContextBundle` setzt die Output-Mode-Policy um:
`off` entfernt Kontext, `auto` und `required` behalten ihn. Bei `required`
bricht Post-Processing ab, wenn danach kein Kontext übrig ist.

`PromptPackageBuilder` baut daraus den eigentlichen Prompt. Der
Agent-Chat-Block beschreibt Provider, Titel, Projekt, Projektpfad, externe
Session-ID und optional den Conversation-Tail. Der Captured-Context-Block
enthält aktiven App-Namen, Selected Text, `visualContextSummary`, ein Visual
Manifest und die Liste der angehängten Bilder.

`CodexPostProcessor` bildet aus dem Bundle eine `CodexVisualInputSelection`
und übergibt deren `imageURLs` an `CodexInvocation.arguments`. Dort werden
die Bilder als wiederholte `--image <path>` Argumente an `codex exec`
angehängt. Screen-Clip-Pfade erscheinen im Prompt, werden aber nicht als
Video-Dateien an die aktuelle Codex-CLI übergeben.

## Auto-Paste-Zustellung

Die eigentliche Aufnahme- und Delivery-Pipeline gehört zur Recording- und
AI-Output-Dokumentation unter `docs/features/dictation/recording/` und
`docs/features/dictation/ai-output/`. Visual Context liefert hier nur die
Bildanhänge, die Auto-Paste optional mit ausliefert.

`RecordingCoordinator+Transcription` ruft
`VisualAttachmentDeliveryBuilder.build` nur auf, wenn Auto-Paste aktiv ist.
Der Builder prüft `mode.pasteVisualAttachments`, nimmt höchstens
`maxScreenshotsPerRecording` Einträge aus `contextBundle.visualAttachments`,
kopiert existierende Dateien in `WhisperM8Delivery/<runID>/` und benennt sie
stabil als `Screenshot N.png`.

Das Ergebnis sind `PasteAttachment`-Werte mit Label, Datei-URL und Attachment-
Kind. Die eigentliche Zustellung an die aktive Ziel-App übernimmt danach
`PasteService` über `PastePayload`; fehlende Dateien werden geloggt und beim
Build übersprungen.

## Invarianten und Gotchas

- `visualAttachments` enthält keine `screenClips`; Video-Dateien werden nicht auto-gepastet und nicht als `--image` an Codex übergeben.
- Screen-Clip-Recording ist exklusiv; ein zweiter Start während aktiver Session wirft `alreadyRecording`.
- Laufende Screen-Clips werden nach `maxScreenRecordingDuration` automatisch gestoppt und angehängt, wenn Recording und Clip-Recording noch aktiv sind.
- Interaktive Screenshots sind während einer laufenden Screen-Clip-Aufnahme gesperrt.
- Clipboard-Capture restauriert den vorherigen Pasteboard-Inhalt, kann aber eine echte User-Kopie im Capture-Fenster verschlucken; der Code benennt diese Restlücke im Kommentar.
- `deleteContextFilesAfterProcessing` entscheidet, ob `cleanup` Kontextdateien löscht; das gilt auch für Kontext leeren und Anhang entfernen.
- Agent-Chat-Kontext wird nicht bei beliebigen Ziel-Apps auto-injiziert, sondern nur wenn WhisperM8 selbst beim Recording-Start frontmost war; UI-Details des Agent-Chats liegen unter `docs/features/agent-chats/ui/`.
- `VisualAttachmentDeliveryBuilder` kopiert Anhänge in ein Delivery-Verzeichnis, damit stabile Namen wie `Screenshot 1.png` an Paste- und Prompt-UI anschließen.
- `CodexVisualInputMode.video` bedeutet im aktuellen Stand Video-Pfad im Prompt plus Frame-Fallback, nicht direkte Video-Übergabe an `codex exec`.

## Schlüsseldateien

- `WhisperM8/Services/Dictation/SelectedContextService.swift` ist die Text-Capture-Schicht für direkte AX-Selektion und Clipboard-Fallback.
- `WhisperM8/Services/Dictation/VisualContextCaptureService.swift` ist die Dateicapture-Schicht für Screenshots, Screen-Clips, Frame-Extraktion und Cleanup.
- `WhisperM8/Services/Dictation/ManualScreenClipSession.swift` ist die ScreenCaptureKit/AVFoundation-Session für MP4-Clips.
- `WhisperM8/Services/Dictation/ContextCaptureMerge.swift` ist die reine Merge-Logik für nachgereichten Text- und Agent-Chat-Kontext.
- `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift` ist der Builder für stabile Auto-Paste-Bildanhänge.
- `WhisperM8/Models/SelectedContext.swift` enthält das Textkontext-Modell und die `ContextCapturePolicy`.
- `WhisperM8/Models/TranscriptContextBundle.swift` ist das zentrale Bundle-Modell mit Summaries, Attachment-Listen und Factory.
- `WhisperM8/Models/CodexVisualInputMode.swift` definiert die persistierte Codex-Visual-Input-Einstellung.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift` verdrahtet Kontext-Capture, Merge und Overlay-Edit-Aktionen im RecordingCoordinator.

## Test-Cluster

- `Tests/WhisperM8Tests/DictationHotPathTests.swift` deckt `ContextCaptureMerge` und dessen User-Edit-Invarianten ab.
- `Tests/WhisperM8Tests/VisualContextScreenshotTests.swift` deckt die interaktive Screenshot-Erfassung inklusive Cancel, leerer Datei und Disabled-Pfad ab.
- `Tests/WhisperM8Tests/OutputDashboardTests.swift` deckt Prompt-Package, Visual Manifest, `CodexVisualInputMode` und `VisualAttachmentDeliveryBuilder` ab.
- `Tests/WhisperM8Tests/TranscriptContextBundleTests.swift` deckt Bundle-Summaries und Agent-Chat-Kontext im Bundle ab.
- `Tests/WhisperM8Tests/RecordingCoordinatorClipboardTests.swift` deckt Clipboard-Textimport während Transcription sowie Append- und Dedupe-Verhalten ab.
- `Tests/WhisperM8Tests/PreferencesTests.swift` deckt Persistenz der Kontext- und Visual-Input-Preferences ab.
