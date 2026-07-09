---
status: aktiv
updated: 2026-07-09
---

# Visual Context — Screenshot- und Auswahl-Kontext

Visual Context erweitert ein Diktat um Kontext aus der gerade benutzten App:
ausgewählten Text, Screenshots, Screen-Clips, daraus extrahierte Bildframes
und optional eine Agent-Chat-Referenz. Der Agent-Chat wird nur automatisch
übernommen, wenn WhisperM8 selbst beim Recording-Start die frontmost App war;
bei Diktaten in Cursor, VS Code, Browser oder anderen Ziel-Apps setzt der
Coordinator diesen Kontext bewusst auf `nil`. Der Kontext liegt während der
Aufnahme in einem `TranscriptContextBundle` und wird nur von Output-Modi
verwendet, deren Kontext-Policy das erlaubt.

## Welche Kontexte erfasst werden

| Kontext | Quelle | Ergebnis im Bundle |
|---------|--------|--------------------|
| Ausgewählter Text | Fokus-Element der aktiven App über Accessibility; Fallback per Cmd+C und Clipboard-Restore | `SelectedContext` mit Text, App-Name und Bundle-ID |
| Clipboard-Screenshot | Bilddaten in der macOS-Zwischenablage während Recording, Transcribing oder Post-Processing | `ContextAttachment(kind: .screenshot)` |
| Interaktiver Screenshot | Aufruf des externen Systemwerkzeugs `/usr/sbin/screencapture -i`; die Interaktionssemantik ist macOS-Laufzeitverhalten außerhalb des Repos | `ContextAttachment(kind: .screenshot)` |
| Screen-Clip | `ScreenCaptureKit`-Stream des aktiven Displays, ohne WhisperM8-Fenster | `ContextAttachment(kind: .screenClip)` plus `visualFrame`-Anhänge |
| Agent-Chat-Kontext | Aktive Agent-Chat-Session nur, wenn WhisperM8 beim Recording-Start frontmost ist; dazu optional ein gelesener JSONL-Tail | `AgentChatContextRef` und `agentChatTail` |

Annotationen sind im Modell als eigene `annotation`-Anhänge mit Nummer,
Kommentar und Rechteck vorhanden und werden in Summaries, Manifest, Reports,
Codex-Bildern und Auto-Paste wie Bildanhänge behandelt. In den gelesenen
Visual-Context-Capture-Pfaden gibt es keinen belegten Erzeuger für neue
Annotationen; vorhandene Annotationen sind deshalb unterstützte Bundle-Daten,
nicht ein eigener dokumentierter Capture-Flow.

Der Screen-Clip wird als MP4 gespeichert. Für Codex werden zusätzlich bis zu
fünf visuelle Summary-Frames als PNG extrahiert; der vollständige Videopfad
bleibt im Prompt als lokale Referenz sichtbar.

## Wann der Kontext entsteht

Beim Start der Aufnahme befüllt der `RecordingCoordinator` das Bundle sofort
mit der aktiven App. Eine Agent-Chat-Referenz kommt nur hinzu, wenn die
Quell-App WhisperM8 selbst ist; nur dann kann auch ein Agent-Chat-Tail
nachgeladen werden. Ausgewählter Text und ein vorhandener Agent-Chat-Tail werden
parallel zur laufenden Aufnahme erfasst und später per Merge nachgereicht,
damit der sichtbare Aufnahme-Start nicht auf Accessibility- oder
Dateisystem-I/O wartet.

Während der Aufnahme läuft ein Clipboard-Monitor im 500-ms-Takt. Er übernimmt
kopierte Bilder als Screenshots und kopierten Text als zusätzlichen
Textkontext. Der Monitor bleibt auch während Transcribing und Post-Processing
aktiv; ein letzter Sweep vor dem Prompt-Build übernimmt späte Kopien noch in
das Live-Bundle.

Manuelle Aktionen im Overlay können einen interaktiven Screenshot aufnehmen,
einen Screen-Clip starten oder stoppen, einzelne Anhänge entfernen, den
ausgewählten Text entfernen, die Agent-Chat-Referenz entfernen oder das
gesamte Bundle leeren. Der Merge respektiert diese User-Edits: ein
nachträglich fertig gewordener Capture darf geleerte Slots nicht wieder
auffüllen.

## Wofür der Kontext verwendet wird

Post-Processing-Modi mit `contextPolicy` `auto` oder `required` geben das
Bundle an den Codex-Postprocessor weiter. `off` leitet ein leeres Bundle
weiter; `required` bricht ab, wenn kein erlaubter Kontext vorhanden ist.

Der Prompt enthält den aktiven App-Namen, den ausgewählten Text, eine visuelle
Zusammenfassung, ein Visual Manifest und einen Block für angehängte Bilder.
Templates können zusätzlich Platzhalter wie `{selectedContext}`,
`{visualContextSummary}`, `{screenClipPaths}`, `{visualInputMode}` und
`{attachmentCount}` nutzen.

Für Agent-Prompt-Modi wird aus gesprochenem Auftrag und Kontext ein Prompt
nach dem im Template hinterlegten Agent-Playbook für Claude Code oder Codex
gebaut. Ist beim Recording ein Agent-Chat-Kontext vorhanden, beschreibt der
Prompt außerdem Provider, Titel, Projektpfad und den gelesenen
Conversation-Tail als Orientierung über den Arbeitskontext.

## Zustellung der Anhänge

Für Codex-Post-Processing werden Bilder über `codex exec --image <path>`
angehängt. Die Bildliste besteht aus Screenshots, Annotationen und
Visual-Frames; Screen-Clip-Dateien selbst werden im aktuellen Code nicht als
direktes Video-Attachment an Codex übergeben. Im Visual-Input-Modus `video`
bleiben die Videopfade im Prompt sichtbar, während die Frames weiter als
Bild-Fallback gesendet werden.

Für Auto-Paste bereitet `VisualAttachmentDeliveryBuilder` nur Bildanhänge vor.
Er kopiert vorhandene Screenshots, Annotationen und Visual-Frames in ein
temporäres Delivery-Verzeichnis, benennt sie stabil als `Screenshot 1.png`,
`Screenshot 2.png` usw. und übergibt sie als `PasteAttachment` an den
Paste-Service. Screen-Clips werden dabei nicht gepastet.

## Privacy und Permissions

Textkontext ist per `selectedContextCaptureEnabled` abschaltbar. Der primäre
Pfad liest den ausgewählten Text über Accessibility aus dem fokussierten
UI-Element. Falls das nicht gelingt und Accessibility erlaubt ist, nutzt der
Fallback Cmd+C, liest die Zwischenablage und stellt anschließend den vorherigen
Pasteboard-Inhalt wieder her.

Visueller Kontext ist per `visualContextCaptureEnabled` abschaltbar.
Screen-Clips verlangen Screen-Recording-Permission; bei fehlender Berechtigung
meldet der Coordinator den Fehler und stößt die Permission-Anfrage an.
Interaktive Screenshots laufen über das externe macOS-Werkzeug
`/usr/sbin/screencapture -i`. Der Code belegt den Prozessaufruf und die
Behandlung von Exitstatus, fehlender Datei und Dateigröße; Abbruch per ESC
oder leere Auswahl ist externes macOS-Laufzeitverhalten und ergibt im
WhisperM8-Pfad keinen Kontext-Anhang.

Kontextdateien entstehen unter temporären WhisperM8-Verzeichnissen. Wenn
`deleteContextFilesAfterProcessing` aktiv ist, räumt
`VisualContextCaptureService.cleanup` die Dateien nach der Verarbeitung auf.
Unabhängig davon können visuelle Inhalte an Codex gehen, wenn ein
Post-Processing-Modus sie verwendet, und an die Ziel-App gepastet werden, wenn
Auto-Paste und `pasteVisualAttachments` aktiv sind.

## Schlüsseldateien

- `WhisperM8/Services/Dictation/SelectedContextService.swift` erfasst ausgewählten Text aus der aktiven App per Accessibility oder Clipboard-Fallback.
- `WhisperM8/Services/Dictation/VisualContextCaptureService.swift` erstellt Clipboard-Screenshots, interaktive Screenshots, Screen-Clips, Visual-Frames und temporäre Kontextdateien.
- `WhisperM8/Services/Dictation/ManualScreenClipSession.swift` kapselt den ScreenCaptureKit-Stream und schreibt den manuellen Screen-Clip als MP4.
- `WhisperM8/Services/Dictation/ContextCaptureMerge.swift` merged nachgereichten Kontext, ohne während der Aufnahme entfernte User-Kontexte wiederherzustellen.
- `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift` kopiert Bildanhänge für Auto-Paste in ein stabiles Delivery-Verzeichnis.
- `WhisperM8/Models/SelectedContext.swift` definiert Textkontext und die Output-Mode-Policy für Kontext-Nutzung.
- `WhisperM8/Models/TranscriptContextBundle.swift` bündelt Text, Agent-Chat-Kontext, Screenshots, Annotationen, Screen-Clips und Visual-Frames.
- `WhisperM8/Models/CodexVisualInputMode.swift` beschreibt, ob Codex Bilder als Frames oder mit Video-Pfad-Fallback erhält.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift` bindet Kontext-Capture, Overlay-Aktionen und Merge in den Recording-Lifecycle ein.

## Keywords

Visual Context, visueller Kontext, Screenshot-Kontext, Auswahl-Kontext,
ausgewählter Text, aktive Selektion, Accessibility, Screen Recording,
ScreenCaptureKit, Screen-Clip, Bildschirmaufnahme, Clipboard-Screenshot,
Zwischenablage, interaktiver Screenshot, Bereichsauswahl, Kontext-Bundle,
Diktat-Kontext, Post-Processing-Kontext, Agent-Prompt-Kontext, Bildanhang,
Visual Frames, temporäre Kontextdateien, Privacy, Permissions,
`SelectedContextService`, `VisualContextCaptureService`,
`ManualScreenClipSession`, `ContextCaptureMerge`,
`VisualAttachmentDeliveryBuilder`, `SelectedContext`,
`TranscriptContextBundle`, `ContextAttachment`, `ContextAttachmentKind`,
`CodexVisualInputMode`, `CodexVisualInputSelection`,
`RecordingCoordinator+Context`, `captureInteractiveScreenshot`,
`captureClipboardScreenshot`, `startScreenClip`, `stopScreenClip`,
`visualAttachments`, `visualContextSummary`, `screenClipPaths`,
`pasteVisualAttachments`, `deleteContextFilesAfterProcessing`, `annotation`,
`annotationNumber`, `annotationComment`, `annotationRect`, Mark,
`agentChatTail`, `WhisperM8Delivery`, `maxScreenRecordingDuration`,
`PromptPackageBuilder`, `PostProcessingService`, `CodexPostProcessor`.
