---
status: aktiv
updated: 2026-07-19
description: Runde-4-Abdeckungssweep der bisher ungeprüften Agent-Chats-bezogenen Views, Transcript-Ansichten, älteren CLI-Pfade und Support-Dateien mit Tiefenangabe und verifizierten Findings.
---

# Runde 4: Abdeckungssweep Views, CLI und Support

## 0. Auftrag, Scope und Methodik

Diese Prüfung schließt die in der Runde-3-Vollständigkeitskritik mechanisch ausgewiesenen Finder-Lücken in Agent-Chats-bezogenen Dateien unter `WhisperM8/Views`, `WhisperM8/Views/Transcript`, im älteren CLI-Bestand vor `whisperm8 chats` sowie unter `WhisperM8/Support`. Separat in Runde 4 auditierte neue Feature-Pfade werden nur zur Abgrenzung genannt, nicht doppelt bewertet.

**Tiefenskala:**

- **oberflächlich:** `rg`-gestützter Struktur-, Fehlerpfad-, Secret-, Prozess-, Timer-/Monitor- und Force-Unwrap-Sweep; relevante Abschnitte gelesen.
- **gezielt:** alle risikotragenden Funktionen und ihre unmittelbaren Aufrufer sowie vorhandene Tests abschnittsweise gelesen.
- **vertieft:** Zustands-, Lifecycle- oder Parserpfad über mehrere Funktionen/Dateien und vorhandene Tests nachvollzogen.

Keine Builds oder Tests wurden ausgeführt. Testaussagen beruhen ausschließlich auf gelesenen Testquellen. Zeilenangaben beziehen sich auf `HEAD` am 2026-07-19.

## 1. Scope-Abgrenzung

Geprüft wurden die Agent-Chats-relevanten Einträge der mechanischen Runde-3-Liste: 26 Dateien der direkten Agent-/Grid-/Tab-UI, neun Transcript-Dateien, die vier dort genannten Support-Dateien sowie die vier explizit als ungedeckt gelisteten CLI-Dateien. Der Auftrag „Alt-Bestand vor `chats`“ wurde zusätzlich auf Dispatcher, `agent`-/`agent-supervise`- und `transcribe`-Abläufe erweitert. Bereits separat dokumentierte neue Runde-4-Flächen wurden nicht doppelt bewertet: `AgentChatsContextProfilesTab` (`runde4-context-profile.md`), `ClaudePluginsSettingsPage` (`runde4-plugin-manager.md`), `CLISkillsSettingsPage` (`runde4-statusline-skills.md`) und GPT-Backend-Settings (`runde4-gpt-setup.md`). Reiner Diktat-/Recording-/Output-Report-Layoutcode aus der 77-Dateien-Liste liegt außerhalb dieses Agent-Chats-Sweeps.

Die Altdatei `AgentCLICommand.swift` war in Runde 2 bereits tief geprüft. Hier wurde deshalb kein zweites Supervisor-Gesamtaudit vorgenommen, sondern der bislang nicht ausgewiesene `logs`-Pfad sowie die von den ungedeckten Parsern ausgehende Short-ID-/Filesystem-Grenze ergänzt. Die bekannten PID-/Detach-/State-Races aus `runde2-cli-supervisor-codex.md` werden nicht als neue R4-Findings dupliziert.

## 2. Verifizierte Findings

### R4-VC-01 — mittel — Legacy-Transcribe-Parser verschluckt folgende Flags als Werte

- **Beleg:** `WhisperM8/CLI/CLIArguments.swift:71-75,80-116`; zum Kontrast schützt der neuere Agent-Parser genau diese Grenze in `WhisperM8/CLI/AgentCLIArguments.swift:88-97`. Die vorhandenen Tests prüfen nur einen am argv-Ende fehlenden `-o`-Wert (`Tests/WhisperM8Tests/CLITranscriptionTests.swift:76-81`).
- **Auslöseszenario:** `whisperm8 transcribe a.mp4 --output --dry-run` interpretiert `--dry-run` als Ausgabepfad; Dry-Run bleibt aus und der echte Upload/Postprocessing-Pfad läuft. Analog wird bei `--api-key --dry-run` der Flag-Text zum Key und bei `--language --provider groq` wird `--provider` zur Sprache, während `groq` anschließend als zweite Eingabedatei gilt. Das ist Parser-Drift gegenüber dem bereits gehärteten `agent`-Parser und kann unbeabsichtigte Netzaufrufe beziehungsweise Dateien erzeugen.
- **Fix-Skizze:** Gemeinsamen `nextValue`-Baustein verwenden, der für normale Optionswerte Folge-Tokens mit `-` als `missingValue` ablehnt; negative/flagartige Werte nur nach explizitem `--` oder für genau definierte Optionen zulassen. Für jeden werttragenden Flag einen „nächster Token ist ein Flag“-Test ergänzen.

### R4-VC-02 — mittel — Beliebig kleiner Chunk-Wert hängt den Lauf oder crasht sogar den Dry-Run

- **Beleg:** Der Parser akzeptiert jeden `Double > 0` ohne Fachgrenze (`WhisperM8/CLI/CLIArguments.swift:111-116`). `computeSplitTimes` erhöht danach `target` ohne Split-/Iterationslimit jeweils nur um diesen Wert (`WhisperM8/CLI/CLIAudioChunker.swift:66-71,88-95`), und `makeChunks` extrahiert für jede Grenze eine Datei (`WhisperM8/CLI/CLIAudioChunker.swift:38-51`). Schon der Dry-Run wandelt `ceil(duration / target)` ungeprüft in `Int` um (`WhisperM8/CLI/CLITranscribe.swift:274-280`); bei subnormalem positivem `target` wird der Quotient unendlich und die Konvertierung trappt. Die Tests decken nur 5/10- und 20/10-Sekunden-Fälle ab (`Tests/WhisperM8Tests/CLITranscriptionTests.swift:150-168`), keinen Dry-Run und keine numerischen Extremwerte.
- **Auslöseszenario:** Eine Stunde Audio mit `--chunk-seconds 0.000001` verlangt Milliarden Split-Iterationen und anschließend potenziell Milliarden Chunk-Dateien. Mit etwa `--chunk-seconds 1e-320 --dry-run` läuft bereits `Int(ceil(duration / target))` in eine nicht fangbare Runtime-Trap. Ohne Dry-Run kann derselbe formal gültige Wert durch Speicher-/Disk-Erschöpfung oder Gleitkomma-Fortschrittsverlust hängen.
- **Fix-Skizze:** Endlichkeit sowie eine fachlich sinnvolle Unter-/Obergrenze validieren; den erwarteten Chunk-Count nur nach endlicher, `Int`-darstellbarer Quotientenprüfung berechnen und gegen ein hartes Chunk-/Iterationsbudget prüfen. In der Schleife `nextTarget > target` erzwingen und bei Budgetüberschreitung mit Usage-Fehler abbrechen; Grenztests für subnormale, sehr kleine, unendliche und Dry-Run-Werte ergänzen.

### R4-VC-03 — hoch — ffmpeg-Fallback kann am vollen stderr-Pipe unbegrenzt deadlocken

- **Beleg:** Der Fallback hängt stderr und stdout an Pipes, liest aber erst **nach** dem synchronen `waitUntilExit()` aus stderr und stdout überhaupt nicht (`WhisperM8/CLI/CLIAudioExtractor.swift:181-210`). Es gibt weder paralleles Drain noch Timeout/Termination. Die CLI-Tests testen nur Parser, Formatter und die pure Split-Berechnung; der Extractor-/ffmpeg-Pfad kommt in `Tests/WhisperM8Tests/CLITranscriptionTests.swift:32-168` nicht vor.
- **Auslöseszenario:** AVFoundation lehnt einen exotischen oder beschädigten Container ab, ffmpeg schreibt bei der Fehleranalyse mehr als die Pipe-Kapazität nach stderr. ffmpeg blockiert beim Schreiben, der Parent blockiert in `waitUntilExit()`, und niemand leert die Pipe: `whisperm8 transcribe` beendet sich nie. Ein hängender Decoder/Input besitzt denselben Effekt, weil keinerlei Deadline existiert.
- **Fix-Skizze:** stdout/stderr ab Prozessstart blockierend auf getrennten Queues drainieren oder `readabilityHandler` mit sauberer EOF-Barriere verwenden; Ausgabe gedeckelt sammeln. Einen Timeout mit SIGTERM, Wait und Prozessgruppen-/identitätsgesicherter SIGKILL-Eskalation einführen. Integrationstest mit Fake-ffmpeg, das mehr als die Pipe-Kapazität schreibt, plus Hängeprozess-Test.

### R4-VC-04 — mittel — Retry-Backoff schluckt Cancellation und startet nach Gruppenabbruch weitere Requests

- **Beleg:** Chunk-Uploads laufen in einer Throwing-TaskGroup (`WhisperM8/CLI/CLITranscribe.swift:155-197`). Der Retry-Pfad verwirft den Fehler von `Task.sleep` mit `try?` und prüft danach weder `Task.isCancelled` noch `Task.checkCancellation()` (`WhisperM8/CLI/CLITranscribe.swift:200-226`). Für Retry/Cancellation existiert in `Tests/WhisperM8Tests/CLITranscriptionTests.swift` kein Test.
- **Auslöseszenario:** Drei Chunks laufen parallel; einer scheitert endgültig und die TaskGroup cancelt die Geschwister, während eines davon im 8-Sekunden-Backoff wartet. Dessen Sleep wirft `CancellationError`, der verworfen wird; die Schleife startet trotz Abbruch noch einen weiteren Multipart-Request mit Audiodaten und API-Key. Der CLI-Fehler kehrt erst zurück, nachdem solche Geschwister beendet sind.
- **Fix-Skizze:** `try await Task.sleep` propagieren lassen und vor jedem Versuch `try Task.checkCancellation()` ausführen. Einen kontrollierten Test mit Sleep-/Client-Seams ergänzen, der nach Gruppencancel beweist, dass kein weiterer Request startet.

### R4-VC-05 — mittel — `agent logs --tail` liest unabhängig von `tail` die vollständige Eventdatei

- **Beleg:** `AgentLogsCLI` lädt `events.jsonl` vollständig als `String`, splittet anschließend alle Zeilen und bildet erst dann `suffix(tail)` (`WhisperM8/CLI/AgentCLICommand.swift:323-341`). Der Parser begrenzt `tail` ebenfalls nicht nach oben (`WhisperM8/CLI/AgentCLIArguments.swift:225-254`). Die vorhandenen Tests prüfen nur das Parsen von `--tail 10` (`Tests/WhisperM8Tests/AgentCLIArgumentsTests.swift:182-192`; `Tests/WhisperM8Tests/AgentCLICommandTests.swift:287-291`), nicht den Datei-I/O-Pfad.
- **Auslöseszenario:** Ein langlebiger Codex-Agent hat eine mehrgigabyte-große `events.jsonl`; selbst `whisperm8 agent logs <id> --tail 10` allokiert Datei plus Split-Substrings komplett und kann durch Speicherdruck beendet werden. Ein lokal beschädigtes oder absichtlich aufgeblähtes Jobfile macht damit auch die kleine Tail-Abfrage unbenutzbar.
- **Fix-Skizze:** Rückwärts blockweise vom Dateiende lesen oder einen gedeckelten Ringpuffer im Streaming-Reader verwenden; `tail` auf ein dokumentiertes Maximum begrenzen. Test mit großer Sparse-/Fixture-Datei und instrumentierter Maximal-Lesemenge ergänzen.

### R4-VC-06 — mittel — Ambiguous-Rebind-Picker ist produktiv unerreichbar

- **Beleg:** Die UI definiert die Notification und konsumiert sie (`WhisperM8/Views/AgentChatsView+RuntimeServices.swift:23-30`; `WhisperM8/Views/AgentChatsView.swift:665-675`), Request und Picker sind vollständig implementiert (`WhisperM8/Views/AmbiguousRebindRequest.swift:2-15`; `WhisperM8/Views/AgentSessionAmbiguousRebindPicker.swift:8-63`). Eine quellbaumweite Suche nach `ambiguousRebindNotification` beziehungsweise `AmbiguousRebindRequest` findet jedoch außerhalb dieser Definitionen/Consumer keinen Producer; insbesondere postet kein Tracker den Request. Tests referenzieren keinen der Typen.
- **Auslöseszenario:** Die Resume-Erkennung hat mehrere plausible externe Sessions. Der dokumentierte UX-Pfad müsste den Picker anzeigen, aber es wird nie eine Notification erzeugt; der User kann keinen Kandidaten wählen und die vorgesehene Recovery findet nicht statt. Der Hinweis, ein späterer Resume-Klick könne erneut triggern (`AgentChatsView.swift:667-669`), ist damit ebenfalls ohne ausführbaren Producer.
- **Fix-Skizze:** Entweder den aktiven Tracker mit einem typisierten, fenster-/sessiongebundenen Callback zum Picker verdrahten und End-to-End testen oder die tote Recovery-UI samt irreführenden Logs entfernen. Bei Multiwindow genau einen Owner pro Request festlegen und die Wahl vor dem Store-Update erneut validieren.

### R4-VC-07 — niedrig — Archivgruppen verwenden Positions- statt Projektidentität für View-State

- **Beleg:** Gruppen werden nach jüngster Session sortiert (`WhisperM8/Views/AgentChatsView+Archive.swift:42-59`), aber per `ForEach(..., id: \.offset)` gerendert (`WhisperM8/Views/AgentChatsView+Archive.swift:78-99`); jede Gruppe besitzt lokalen `@State isExpanded` (`WhisperM8/Views/AgentChatsView+Archive.swift:198-212`). Die Builder-Tests prüfen Sortierung/Suche/Orphans (`Tests/WhisperM8Tests/AgentArchiveListBuilderTests.swift:25-129`), nicht SwiftUI-Identität oder Expansion nach Entfernen/Umsortieren.
- **Auslöseszenario:** Gruppe A an Position 0 ist eingeklappt, Gruppe B an Position 1 aufgeklappt. Nach Wiederherstellen der letzten Session aus A verschwindet A; B rückt auf ID 0 und kann den eingeklappten State der alten Position übernehmen beziehungsweise ihren eigenen State verlieren.
- **Fix-Skizze:** Stabile Gruppen-ID aus `project.id` plus festem Sentinel für „Ohne Projekt“ verwenden; Expansion möglichst im Window-Store nach Gruppen-ID halten. Interaktionstest für Entfernen/Umsortieren bei gemischtem Expansion-State ergänzen.

### R4-VC-08 — mittel — Markdown-Tabellen zerlegen escaped und Code-Pipes als echte Spalten

- **Beleg:** `MarkdownTable.parse` entfernt Rand-Pipes und nutzt anschließend blind `components(separatedBy: "|")` (`WhisperM8/Views/Transcript/MarkdownBlockParser.swift:28-50`). Die View rendert dieses Ergebnis ohne Plausibilitätsprüfung als Grid (`WhisperM8/Views/Transcript/TranscriptMarkdownView.swift:133-177`). Die Tests enthalten nur einfache Pipes und Alignment-Separators (`Tests/WhisperM8Tests/MarkdownBlockParserTests.swift:69-71,115-139`), keine `\|`- oder Backtick-Pipes.
- **Auslöseszenario:** Ein Agent reportet `| Regex | \`a\\|b\` |` oder eine Shell-Pipeline in Backticks. Der Parser erzeugt zusätzliche Spalten, verschiebt Folgewerte und zeigt Audit-/Testergebnisse unter falschen Überschriften; da das Parse formal erfolgreich ist, greift der verlustfreie Monospace-Fallback nicht.
- **Fix-Skizze:** Zeilen zustandsbehaftet scannen und Pipes innerhalb von Escape-Sequenzen sowie Inline-Code nicht trennen; alternativ einen etablierten Markdown-Parser verwenden. Bei inkonsistenter Spaltenzahl auf Rohtext zurückfallen. Regressionstests für escaped Pipes, Inline-Code und gemischte Zeilen ergänzen.

### R4-VC-09 — niedrig — Teammate-Detektor klassifiziert beliebige Literalnennung als Systeminjektion

- **Beleg:** Ein einziges `text.contains("<teammate-message")` genügt für die Spezialdarstellung (`WhisperM8/Views/Transcript/TeammateMessageParser.swift:29-42`); Position, Tagabschluss oder Code-Fence-Kontext werden nicht geprüft. Der Test „normal prompt“ enthält den Marker nicht, während ein nackter Marker ausdrücklich als gültig erwartet wird (`Tests/WhisperM8Tests/TeammateMessageParserTests.swift:27-35`).
- **Auslöseszenario:** Der User bittet in einem normalen Prompt darum, die Zeichenfolge `<teammate-message` oder ein Beispiel dieses Formats zu erklären. Die Timeline tarnt den echten User-Prompt als kompakten Teammate-/Systemblock; bei langen Prompts ist der Inhalt nur noch über Aufklappen erkennbar.
- **Fix-Skizze:** Nur einen vollständig abgegrenzten Top-Level-Tag beziehungsweise das echte strukturierte Provider-Metadatum akzeptieren; fenced/inline Code und umgebenden normalen Text ausschließen. Negative Tests mit Literal, Codeblock und vor-/nachgestelltem Text ergänzen.

### R4-VC-10 — mittel — Sidebar-Resize räumt bei View-Teardown weder Drag- noch Fensterzustand auf

- **Beleg:** `SidebarResizeHandle` meldet `onHoverChanged(false)` und `onDragEnded()` ausschließlich aus regulären Hover-/Gesture-Enden (`WhisperM8/Views/SidebarResizeHandle.swift:36-55`). Sein `onDisappear` setzt nur den Cursor zurück (`WhisperM8/Views/SidebarResizeHandle.swift:57-61`). Der Caller schaltet das Fenster direkt über den Hover-Callback zwischen `isMovable = false/true` (`WhisperM8/Views/AgentChatsView.swift:446-460`); auch der Parent-Teardown stellt diese AppKit-Eigenschaft nicht zurück (`WhisperM8/Views/AgentChatsView.swift:681-700`). Der Live-Drag überschreibt die persistierte Breite, bis allein `commitSidebarDrag()` Basis und Live-Wert nullt (`WhisperM8/Views/AgentChatsView.swift:819-855`). Für Handle-Teardown, Fensterbeweglichkeit oder einen abgebrochenen Sidebar-Drag existiert kein Test (`rg "SidebarResizeHandle|isMovable|sidebar.*hover" Tests/WhisperM8Tests` ohne Treffer).
- **Auslöseszenario:** Die Sidebar-View verschwindet unter dem Zeiger beziehungsweise während eines Resize-Gestures — etwa durch fokussierte Tastatur-/Accessibility-Aktivierung des sichtbaren Sidebar-Toggles, Scene-State-Wechsel oder Fenster-Teardown. `onDisappear` läuft, aber das Fenster kann mit `isMovable == false` zurückbleiben. Bei einem abgebrochenen Drag bleiben außerdem `sidebarDragBaseWidth`/`sidebarLiveWidth` gesetzt; wird dieselbe View-State-Identität mit wieder sichtbarer Sidebar weiterverwendet, überstimmt der alte Live-Wert dauerhaft die gespeicherte Breite. Ein späteres normales Hover-Ende beziehungsweise `onDragEnded` ist nach Entfernung des Handles nicht garantiert.
- **Fix-Skizze:** Einen expliziten Cancel-/Teardown-Callback einführen, der idempotent Cursor, Hover-Aggregat, `sidebarDragBaseWidth` und `sidebarLiveWidth` zurücksetzt; je nach UX den letzten Live-Wert committen oder bewusst verwerfen. `NSWindow.isMovable` nicht aus mehreren unabhängigen Hover-Callbacks direkt setzen, sondern aus einem zentralen aggregierten Interaktionszustand ableiten und auf View-/Window-Disappear sicher auf `true` zurückstellen. Einen Host-View-Test beziehungsweise manuelles Oracle für „Sidebar während Hover/Drag ausblenden und erneut zeigen“ ergänzen.

### R4-VC-11 — mittel — Legacy-Agent-IDs sind ungeprüfte Pfadkomponenten für Read, Signal und rekursives Löschen

- **Beleg:** `parseSend`, `parseIDCommand` und `parseLogs` akzeptieren jede nicht mit `-` beginnende Zeichenfolge als `shortId`, ohne die vom Generator versprochenen acht Hex-Zeichen zu prüfen (`WhisperM8/CLI/AgentCLIArguments.swift:166-210,225-255`); selbst der interne Supervisor-Ingress prüft nur auf Nichtleere (`WhisperM8/CLI/AgentSuperviseCommand.swift:8-11`). `AgentJobStore` hängt diesen Wert direkt als Pfadkomponente an sein Root und bildet darunter sämtliche Dateien (`WhisperM8/Services/AgentChats/AgentJobStore.swift:33-36,58-83`); `removeJob` löscht das so berechnete Verzeichnis rekursiv (`WhisperM8/Services/AgentChats/AgentJobStore.swift:182-188`). `agent stop` liest denselben frei adressierbaren State und signalisiert dessen `supervisorPid` (`WhisperM8/CLI/AgentCLICommand.swift:355-381`), `agent rm` prüft nur, ob sich dort ein decodierbarer inaktiver State befindet, und ruft danach `removeJob` auf (`WhisperM8/CLI/AgentCLICommand.swift:396-428`). Die Parser-/Command-Tests verwenden gültige IDs oder prüfen nur Positional-Anzahlen; Traversal, Slash und State-ID-Mismatch fehlen (`Tests/WhisperM8Tests/AgentCLIArgumentsTests.swift:156-191`; `Tests/WhisperM8Tests/AgentCLICommandTests.swift:200-294`).
- **Auslöseszenario:** Ein verschobenes/gesichertes Jobverzeichnis außerhalb von `agent-jobs` enthält weiterhin eine gültige `state.json`. `whisperm8 agent rm ../backup-job` traversiert aus dem Store-Root, akzeptiert diesen State und entfernt das gesamte fremde Verzeichnis; ein aktiver solcher State lässt `agent stop ../backup-job` die darin gespeicherte PID signalieren. Auch IDs mit eingebetteten Slash-Komponenten sind möglich. Damit ist die dokumentierte Short-ID-Grenze keine tatsächliche Filesystem-/Prozessgrenze.
- **Fix-Skizze:** An jedem CLI- und internen `agent-supervise`-Ingress exakt das kanonische Format `^[0-9a-f]{8}$` erzwingen; im Store zusätzlich Defense-in-Depth: standardisierten Zielpfad auf echten Child des standardisierten Roots prüfen, Symlink-Komponenten nicht folgen und nach Decode `state.shortId == requestedShortId` verlangen. Negative Tests für `../`, Slash, absolute/überlange/Uppercase-ID, Symlink und State-ID-Mismatch ergänzen; `rm` sollte nur einen bereits sicher geöffneten Job-Directory-Anker löschen.

## 3. Kurzreviews je Datei

### 3.1 Direkte Agent-Chats-/Grid-/Tab-Views

| Datei | Tiefe | Kurzurteil |
|---|---|---|
| `Views/AgentChatsView+Archive.swift:14-60,74-99,198-233` | gezielt | Builder, Sortierung, Restore-Wiring und lokaler Expansion-State gelesen; R4-VC-07. Pure Builder-Tests vorhanden, keine Interaktions-/Identitätstests. |
| `Views/AgentChatsView+DragDrop.swift:12-61` | gezielt | Beide Koordinatoren vollständig gelesen; Planner entscheidet vor Store-Mutation, Fehler werden in UI-State überführt. Planner-Tests vorhanden; keine neue Lücke in diesem dünnen Adapter bestätigt. |
| `Views/AgentChatsView+SubagentChildren.swift:16-44,50-81` | gezielt | Selektions-, Archiv- und Expansion-Wiring vollständig gelesen. Kein eigener asynchroner Lifecycle; bewusste duplizierte Darstellung bleibt Drift-Risiko, aber kein konkreter Defekt nachgewiesen. |
| `Views/AgentDragDropTypes.swift:16-72` | gezielt | Codable-/Transferable-Payloads und UTI-Grenzen vollständig gelesen. Optionale Workspace-/Slot-Herkunft ist defensiv; keine Secret-/Pfadnutzlast. |
| `Views/AgentGridLayout.swift:22-84,97-135` | gezielt | Kapazitätsabbildung und geometrische Fokusnavigation vollständig gelesen; Resolver-Tests vorhanden. Korrupte Kapazitäten werden an anderer Modellgrenze normalisiert; hier kein eigener Defekt bestätigt. |
| `Views/AgentGridSplitContainer.swift:26-71,153-281` | gezielt | Drag-Basis, 33-ms-Sampler, Commit-Reihenfolge und `onDisappear`-Cancel gelesen. Task ist MainActor-gebunden und wird gecancelt; Interaktionsfälle „View verschwindet mitten im Drag“ bleiben ungetestet, ohne hinreichenden Beleg für ein Finding. |
| `Views/AgentSessionAmbiguousRebindPicker.swift:7-60` | gezielt | Kandidaten-/Neue-Session-/Cancel-Flow gelesen; UI selbst ist konsistent, aber der Gesamtpfad ist mangels Producer tot (R4-VC-06). |
| `Views/AgentTabSwitcherOverlay.swift:49-113,136-270` | oberflächlich | Struktur, Scroll-/Highlight-Callbacks und Lifecycle-Hooks geprüft; überwiegend UI-only. Pure Grid-/Switcher-Modelle sind getestet, die Overlay-Interaktion nicht. |
| `Views/AgentTerminalLinkInterceptor.swift:20-68` | gezielt | Sämtliche Delegate-Proxies gelesen. Base ist bewusst weak; Clipboard-Read wird verweigert, Copy/Resize/Scroll werden weitergereicht. Kein konkreter Delegate-Ausfall bestätigt; kein direkter Interceptor-Test. |
| `Views/AgentTerminalPalette.swift:16-101` | oberflächlich | Statische Light-/Dark-Palette und 16 ANSI-Farben geprüft; UI-only, kein State/Lifecycle. Keine Tests, aber kein Logikdefekt sichtbar. |
| `Views/AgentUsagePopovers.swift:56-105,128-215,220-293` | gezielt | Gauge-Normalisierung, parallele Profil-Fetches und beide `.onAppear`-Loads gelesen. Tasks sind nicht View-Lifetime-gebunden und Mehrfachloads ungetestet; ohne belegten falschen Endzustand nur Testlücke, kein Finding. |
| `Views/AmbiguousRebindRequest.swift:6-15` | gezielt | Identität/Equatable vollständig gelesen; der Typ ist nur im toten Rebind-Pfad erreichbar (R4-VC-06). |
| `Views/BackgroundDispatchModal.swift:25-65,279-287` | gezielt | Prompt-Trim, Permission-/Subagent-Auswahl und synchrones Submit-Wiring gelesen. Caller schließt das Sheet vor dem asynchronen Spawn; kein reproduzierbarer Doppel-Dispatch-Pfad bestätigt. |
| `Views/GridDropViews.swift:8-89` | oberflächlich | SwiftUI-Drop-Zonen, Target-Zähler-Cleanup und Labels strukturell geprüft. Interaktion UI-only; pure Entscheidung liegt im getesteten Resolver. |
| `Views/GridDropZoneResolver.swift:13-50` | gezielt | Move/Swap/Place-Unterscheidung und Herkunftsbedingungen geprüft; dedizierte Tests vorhanden, kein neuer Defekt. |
| `Views/GridSplitHandle.swift:12-92` | gezielt | Hover-, Doubleclick-, globaler Drag- und Cursor-Teardown vollständig gelesen. Kein Timer/Monitor; SwiftUI-Gestenabbruch bei View-Entfernung bleibt manuelle QA. |
| `Views/GridSplitResolver.swift:9-130` | gezielt | Clamp, Track-Projektion, Rundungsrest und Nachbar-Drag vollständig gelesen; umfangreiche Resolver-Tests vorhanden. Keine Division-durch-null-/Index-Lücke für die produktiven normalisierten Inputs bestätigt. |
| `Views/ProjectPickerKeyboard.swift:5-24` | gezielt | Zwei pure Navigationsfunktionen vollständig gelesen und durch Tests abgedeckt. Kein Finding. |
| `Views/SessionMenuPolicy.swift:8-179` | oberflächlich | Kontext-/Trait-Matrix und Planbildung strukturell geprüft; dedizierte Policy-Tests vorhanden. Keine Lifecycle-/Store-Logik. |
| `Views/SidebarResizeHandle.swift:12-71` | vertieft | Hover-, Drag-/Doubleclick- und Cursor-Teardown samt Caller-State nachvollzogen; beim `onDisappear` fehlen Hover-/Drag-Cleanup und Fenster-Restore (R4-VC-10). Keine Interaktions-/Teardown-Tests. |
| `Views/SidebarWidthResolver.swift:11-55` | gezielt | Min-/Max-/Inspector-Clamps und Dragberechnung geprüft; dedizierte Tests vorhanden. Kein Finding. |
| `Views/TabNavShortcut.swift:14-26` | gezielt | Modifier- und Keycode-Matrix vollständig gelesen; dedizierte Tests vorhanden. Kein Finding. |
| `Views/TabScrollSwipeRecognizer.swift:22-112` | gezielt | Phasen-/Momentum-State-Machine vollständig gelesen; Tests decken horizontale, vertikale und Momentum-Pfade. Kein verbleibender konkreter Fehler bestätigt. |
| `Views/TabSwitcherModel.swift:12-92` | gezielt | Begin/Advance/Commit und Grid-Metrikberechnung geprüft; dedizierte Tests vorhanden. Kein Finding. |
| `Views/TabSwitcherShortcut.swift:11-30` | gezielt | Cmd-Tab-/Shift-Richtung vollständig gelesen; Tests vorhanden. Kein Finding. |
| `Views/TerminalFeedBatcher.swift:17-83` | vertieft | FIFO, High-Water-Flush, Scheduling-Cancel und Aufrufer in `AgentTerminalView` nachvollzogen; dedizierte Tests vorhanden. Feed-/Scheduler-Closures sind weak und Teardown flusht; kein Byteverlustpfad bestätigt. |

`FocusableTextField.swift`, `ProviderIcon.swift`, Recording-/OutputReport-/Overlay-Dateien und die generische Settings-Kit-Liste wurden mechanisch als ungedeckt genannt, besitzen im aktuellen Quellbaum aber keine Agent-Chats-Logik beziehungsweise gehören zum Diktat-/allgemeinen Settings-Scope; sie wurden nicht künstlich als Agent-Chats-Dateien bewertet.

### 3.2 Transcript-Views

| Datei | Tiefe | Kurzurteil |
|---|---|---|
| `Views/Transcript/MarkdownBlockParser.swift:21-59,68-210` | vertieft | Block-State-Machine, Fence-, Listen- und Tabellenparser plus Rendering-Aufrufer und Tests nachvollzogen; R4-VC-08. Zusätzlich sind Fence-Regeln bewusst nur ein Markdown-Subset, aber ohne weiteren Finding-Schweregrad. |
| `Views/Transcript/SessionSummaryCard.swift:86-91,188-203` | gezielt | Notification-/Task-Refresh, Stale-/inFlight-Projektion und manueller Refresh gelesen. Notification wird von SwiftUI automatisch gebunden; kein Observer-Leak. UI-Interaktion ist ungetestet. |
| `Views/Transcript/TeammateMessageParser.swift:6-63` | vertieft | Marker-Erkennung, Regex-Felder, Unescape, Timeline-Nutzung und Tests gelesen; R4-VC-09. |
| `Views/Transcript/TerminalSnapshotView.swift:11-72` | gezielt | 50-Zeilen-Chunking, LazyVStack und Capture-Metadaten vollständig gelesen. Die 2000-Zeilen-Grenze liegt im Store; kein Mega-Text-Regressionpfad in der View bestätigt. |
| `Views/Transcript/TimelineActivityRow.swift:6-89,91-231` | oberflächlich | Expand-/Detaildarstellung und Formatierungshelfer strukturell geprüft; überwiegend UI-only, kein Timer/Monitor/Store. |
| `Views/Transcript/TimelineReportView.swift:6-49,55-100` | gezielt | Report-Vorcheck, Evidence-Listen und Markdown-Übergabe gelesen. Toleranter Parser-Fallback kommt aus `AgentReport`; kein neuer Defekt. |
| `Views/Transcript/TranscriptHistoryState.swift:8-75` | oberflächlich | Value-State und Pill/Startmarker geprüft; reine UI-Projektion ohne I/O oder Lifecycle. |
| `Views/Transcript/TranscriptMarkdownView.swift:8-44,47-211` | vertieft | Budgetierung, Cache-Nutzung, Block- und Tabellenrendering zusammen mit dem Parser geprüft; R4-VC-08. |
| `Views/TranscriptReportDetailView.swift:5-202` | oberflächlich | Reportsektionen, Summary-Chips und Delete-Callback strukturell geprüft; Diktat-Run-Report, keine Agent-Prozesslogik. Kein Finding. |

### 3.3 Legacy-CLI vor `chats`

| Datei | Tiefe | Kurzurteil |
|---|---|---|
| `CLI/AgentCLIArguments.swift:51-255` | vertieft | Run/Send/ID/List/Logs-Parser vollständig gelesen; neuerer `nextValue` ist gegen Flag-Verschlucken gehärtet. Unbegrenztes `tail` verstärkt R4-VC-05; die fehlende Short-ID-Formatgrenze ermöglicht Pfadtraversal (R4-VC-11). |
| `CLI/AgentCLICommand.swift:9-43,323-349,355-434,440-577` | gezielt (Delta) | Dispatch-Matrix, Logs-I/O sowie Stop-/Remove-Ingress gegen Store-Pfadbildung gelesen; R4-VC-05 und R4-VC-11. Die bekannten Supervisor-/PID-Races werden nicht erneut als neue Findings gezählt. |
| `CLI/AgentSuperviseCommand.swift:6-33` | gezielt | Kleine Datei vollständig gelesen: Argument, `setsid`, Signalquelle und Supervisor-Aufruf. Der interne Ingress prüft die ID nur auf Nichtleere und muss in die Härtung von R4-VC-11 einbezogen werden; bekannte Detach-/PID-Wahrheit bleibt Runde-2-Scope. |
| `CLI/CLIArguments.swift:67-146` | vertieft | Gesamter Transcribe-Parser plus Vergleich mit Agent-Parser und Tests gelesen; R4-VC-01 und Eingangsseite von R4-VC-02. |
| `CLI/CLIAudioChunker.swift:18-52,59-97,109-176` | vertieft | Chunkplanung, Grenzschleife, Energieanalyse und produktiver Aufrufer gelesen; R4-VC-02. Reader-Fehler nach partiellem Energie-Read bleibt ungetesteter Robustheitsverdacht, nicht als Finding erhoben. |
| `CLI/CLIAudioExtractor.swift:37-59,70-175,181-229` | vertieft | AVReader/-Writer-Lifecycle und kompletter ffmpeg-Fallback gelesen; R4-VC-03. Keine Extractor-Integrationstests. |
| `CLI/CLIEntryPoint.swift:12-20,26-71,75-105,110-129` | gezielt | CLI-Erkennung, Semaphore-Async-Brücke, Dispatch und stdout/stderr-Trennung gelesen. Keine neue Deadlock-Strecke für die aktuellen nicht-MainActor-CLI-Commands bestätigt. |
| `CLI/CLIOutputFormatter.swift:16-44,49-129` | gezielt | Stitching sowie TXT/SRT/VTT/JSON vollständig gelesen; Basistests vorhanden. Providersegmente werden nicht semantisch validiert, aber aktuelle Decoder liefern endliche Werte; kein belastbares Finding. |
| `CLI/CLITranscribe.swift:84-150,155-238,254-318` | vertieft | Temp-Cleanup, bounded TaskGroup, Retry, Emit und Key-Auflösung in relevanten Abschnitten nachvollzogen; R4-VC-04. Das bereits bekannte `--api-key`-argv-Finding wird nicht dupliziert. |

### 3.4 Support

| Datei | Tiefe | Kurzurteil |
|---|---|---|
| `Support/AppTheme.swift:11-168` | oberflächlich | Dynamische Farben und Hex-Helfer geprüft; überwiegend Design-Tokens. Ungültiges Hex fällt still auf Schwarz, erreicht aber keinen sicherheits-/lifecycle-relevanten Pfad. |
| `Support/AppearanceOverride.swift:8-50` | gezielt | Enum-Mapping zu SwiftUI/AppKit vollständig geprüft; keine Persistenz oder asynchrone Logik. |
| `Support/TextNormalizer.swift:2-9` | gezielt | Vollständig gelesen; trimmt nur Rand-Control-/Zero-Width-Zeichen, verändert keinen Transcript-Inhalt in der Mitte. Kein Finding. |
| `Support/ThemeManager.swift:8-106` | gezielt | Singleton-Init, KVO-Lifetime, Override-Persistenz, Notification und Claude-Theme-Sync gelesen; Resolve-Tests vorhanden. Observer wird vom Singleton absichtlich lebenslang gehalten; kein Teardown-Leak. |

## 4. Testlücken und Gesamturteil

**Bilanz:** elf neue Findings: ein hohes, acht mittlere und zwei niedrige. Die stärksten Lücken liegen nicht im reinen SwiftUI-Layout, sondern an den erwarteten Grenzen: Subprozess-I/O/Timeout (R4-VC-03), Parser-/Arbeitsbudget-Drift (R4-VC-01/02), Cancellation (R4-VC-04), ungebundenes Datei-I/O (R4-VC-05), fehlende CLI-Identitäts-/Pfadvalidierung (R4-VC-11), eine nicht verdrahtete Recovery-State-Machine (R4-VC-06) und unvollständiger View-Teardown über die AppKit-State-Brücke (R4-VC-10).

Die pure Grid-/Tab-/Policy-Logik ist vergleichsweise gut unit-getestet. Nicht abgedeckt sind weiterhin reale SwiftUI-/AppKit-Interaktionen (Expansion-Identität, Drag-Abbruch, Resize-Teardown, Overlay-Fokus), Extractor-Kindprozesse mit großen/hängenden Streams, TaskGroup-Cancellation, Legacy-Short-ID-/Pfadgrenzen und End-to-End-Rebind. Für Transcript-Markdown existieren Basistests, aber gerade die agententypischen Inhalte — Shell-Pipes, escaped Pipes, Backtick-Code und Literal-Systemtags — fehlen.

**Priorität:** Zuerst R4-VC-03 beheben, dann Parser-/Budget-, Cancellation- und Pfadgrenzen R4-VC-01/02/04/05/11 sowie den persistenten Resize-Teardown R4-VC-10. R4-VC-06 benötigt vor einer Reparatur eine Produktentscheidung, ob die alte Resume-Recovery weiterhin Sollfunktion ist; tote UI darf nicht still als vorhandener Recovery-Vertrag in der Architektur verbleiben. Die beiden Darstellungsfindings sollten mit kleinen Regressionstests in demselben Paket geschlossen werden.