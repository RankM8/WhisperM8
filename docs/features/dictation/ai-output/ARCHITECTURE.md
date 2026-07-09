---
status: aktiv
updated: 2026-07-09
---

# AI Output — Architektur

AI Output trennt den fachlichen Diktat-Lauf, die Prompt-Erzeugung, den
kurzlebigen Codex-Prozess, Mode-/Template-Persistenz und das lokale
Output-Archiv. Die App hält keine dauerhafte Codex-Session für normales
Post-Processing; jeder Codex-Mode startet genau einen nicht-interaktiven
`codex exec`-Prozess.

## Datenfluss: Recording zu Output

1. `RecordingCoordinator.transcribeAndDeliver` transkribiert Audio mit dem
   konfigurierten STT-Provider und normalisiert das Raw-Transkript.
2. `processTranscriptIfNeeded` gibt Raw-Modes direkt zurück; für Codex-Modes
   führt es einen letzten Kontext-Sweep aus und bevorzugt das Live-
   `appState.contextBundle`, wenn es nicht leer ist.
3. `PostProcessingService.allowedContextBundle` filtert das Bundle anhand der
   Mode-`contextPolicy`.
4. `PostProcessingService.promptPackage` baut vor dem echten Lauf ein
   `PromptPackage` für Overlay-Status, gerenderten Prompt, Router-Intent und
   Visual Manifest im Report.
5. `PostProcessingService.process` ruft bei Codex-Modes den konfigurierten
   `PostProcessing`-Processor auf; produktiv ist das `CodexPostProcessor`.
6. `CodexPostProcessor` lädt das Template, prüft Codex-Status, baut den Prompt
   und startet `codex exec`.
7. Der fertige Text wird normalisiert, ins Clipboard kopiert, optional
   zusammen mit erlaubten Bildanhängen in die Ziel-App gepastet und als
   `TranscriptRunReport` gespeichert.

Der Report entsteht erst in diesem erfolgreichen Delivery-Pfad.
Transkriptionsfehler und User-Cancel während der Transkription werden in
`RecordingCoordinator+Failure` als Failed Recording gesichert und erzeugen
keinen `TranscriptRunReport`.

Bei Fehlern unterscheidet der Coordinator zwischen User-Cancel, Raw-Fallback,
vorsichtigem Fallback und weitergeworfenem Fehler. Vorsichtige Fallbacks werden
nur für agentische oder kontextbasierte Replies in Email/Slack/WhatsApp gebaut;
sonst ist der Fallback das Raw-Transkript.

## PostProcessing-Schicht

`PostProcessing` ist das kleine Protokoll für alle Transcript-Transformer. Es
bekommt Raw-Text, Mode, Sprache und Kontextbundle und liefert finalen Text.
`NoOpPostProcessor` implementiert den Raw-Pfad, `MockPostProcessor` ist der
Test-Double.

`PostProcessingService` ist die Fassade. Es entscheidet über Raw vs.
Post-Processing, filtert Kontext, erzwingt `required`-Kontext und bietet
zusätzlich `renderedPrompt` und `promptPackage` für UI/Reports an. Die Fassade
ist bewusst leicht testbar, weil der eigentliche Processor injiziert wird.

`CodexPostProcessor` ist die produktive Implementierung. Es nutzt
`PostProcessingTemplateStore`, `PromptPackageBuilder`, `CodexStatusCache`,
`CodexVisualInputSelection`, `ProjectPathResolver` und `CodexInvocation`, um
den nicht-interaktiven Codex-Lauf vorzubereiten und auszuführen.

## Codex-Support

`CodexSupport.swift` bündelt vier operative Helfer:

| Komponente | Rolle |
|------------|-------|
| `CodexProcessRegistry` | Hält schwach den aktuell laufenden Codex-Prozess und terminiert ihn bei Cancel aus dem Recording-Overlay. |
| `CodexInvocation` | Baut die Argumentliste für `codex exec`, inklusive Modell, Reasoning, Service-Tier, Sandbox, Output-Datei, Projektpfad, Ephemeral-Flag und Bildern. |
| `CodexVisualInputSelection` | Löst die globale Visual-Input-Einstellung auf und wählt Bild- und Video-URLs aus dem Kontextbundle. |
| `CodexStatusProbe` | Findet das Codex-Binary, liest Version und `codex login status` und öffnet bei Bedarf den Login im Terminal. |

`CodexStatusCache` cached den Status für den Hot-Path. Positive
`.signedIn`-Ergebnisse gelten 300 Sekunden, negative Ergebnisse nur 5
Sekunden, damit ein frisch abgeschlossener Login nicht minutenlang blockiert.
Bei einem Codex-Lauf, dessen Log auf fehlenden Login hinweist, wird der Cache
invalidiert.

`CodexErrorSummary` macht aus stderr/stdout eine kurze Fehlermeldung. Die
Priorität ist Update-Hinweis, Login-Hinweis, letzte nicht-leere Logzeile,
generischer Fallback.

## Codex-Spawn-Vertrag

Der Prozess läuft mit dem durch `LoginShellEnvironment` korrigierten Environment
und mit dem Codex-Binary aus `/Applications/Codex.app/.../codex` oder aus dem
per `AgentCommandBuilder` gefundenen CLI-Pfad. Das Working Directory ist der
aufgelöste Projektpfad oder das temporäre Verzeichnis.

Die Argumentliste besteht aus:

| Teil | Herkunft |
|------|----------|
| `exec` | fester Codex-Unterbefehl für den nicht-interaktiven Lauf. |
| `-m <model>` | Mode-Override oder globaler `codexPostProcessingModel`-Default. |
| `-c model_reasoning_effort=<value>` | Mode-Override oder globaler `codexReasoningEffort`-Default. |
| Service-Tier-Configs | `CodexServiceTier.fast` setzt Fast-Mode und `service_tier=fast`, `standard` setzt `service_tier=default`. |
| `--sandbox read-only` | fester Sandbox-Modus für AI Output. |
| `--skip-git-repo-check` | erlaubt Läufe ohne Git-Repo. |
| `--output-last-message <tempfile>` | Übergabeweg für die finale Codex-Antwort. |
| `-C <projectPath>` | nur bei aufgelöstem Projektpfad. |
| `--ephemeral` | alle Modi außer `Task`. |
| `--image <path>` | pro ausgewählter Bilddatei. |
| `-` | Prompt kommt über stdin. |

Das externe Laufzeitverhalten von `codex exec` wird von WhisperM8 nicht
interpretiert. Die App prüft Exit-Code, liest die Output-Datei und fasst Logs
für Fehlermeldungen zusammen.

## PromptPackageBuilder

`PromptPackageBuilder` liefert `PromptPackage(prompt, intent, visualManifest)`.
Der Prompt ist die Verkettung aus Globalvertrag, optionalem Agent-Chat-Kontext,
Captured-Context-Block und gerenderter Mode-Instruktion.

`ReplyIntentRouter` klassifiziert vor dem Promptbau den Zweck des Runs.
`Prompt` und `Ultra-Prompt` werden `promptPackage`, `Task` wird `taskPrompt`.
Email/Slack/WhatsApp werden je nach Text und Kontext als `rewrite`,
`contextAnswer` oder `agenticReply` eingestuft; Trigger wie recherchieren,
prüfen, look up oder bildbezogene Fragen führen zu `agenticReply`.

`VisualManifestBuilder` erzeugt stabile Labels für Screenshots, Annotationen,
Visual Frames und Screen Clips und übernimmt die
`CodexVisualInputSelection.includes`-Markierung in das Manifest. Bei Bildern
bedeutet diese Markierung, dass sie über `--image` an `codex exec` gehen; bei
Screen Clips bedeutet sie, dass der Clip als AI-Output-Eingabe im Prompt/Report
geführt wird. `CodexInvocation.arguments` erzeugt aktuell nur `--image`-
Argumente und kein eigenes Video-Argument. Im Prompt erscheinen Selected Text,
Visual Summary, Manifest und Bildreferenzen.

## Modes und Templates

`OutputMode` ist der zentrale Mode-Snapshot. Es enthält ID, Name, Overlay-
Label, Kind, Template-ID, Sichtbarkeit, Default-Flag, Kontextpolicy,
Bild-Paste-Flag, Projektzugriff sowie optionale Codex-Overrides für Modell,
Reasoning und Service-Tier.

`OutputModeStore` lädt Modes aus
`~/Library/Application Support/WhisperM8/OutputModes.json`, fällt bei leerem
Store auf Built-ins zurück, normalisiert Built-in-Reihenfolge und Custom-
Sortierung und cached Dateiinhalt per mtime/size. `Fast` wird bei der
Normalisierung als Raw-Mode fest gepinnt: enabled, kein Template, Kontext aus,
keine Bildanhänge, kein Projektzugriff und keine Codex-Overrides.
Nach erfolgreichem `saveModes` schreibt der Store die normalisierten Modes,
aktualisiert den Disk-Cache und postet
`OutputModeStore.modesDidChangeNotification`, damit Konsumenten wie das
Recording-Overlay eventgetrieben neu laden können.

`PostProcessingTemplate` enthält Name, Beschreibung, Instruktion, Zeiten und
Built-in-Flag. `render(...)` ersetzt alle Kontext- und Sprachplatzhalter; nicht
vorhandener Agent-Chat-Kontext wird als leerer String eingesetzt.

`PostProcessingTemplateStore` liefert Built-in-Templates plus Custom-Templates
aus `~/Library/Application Support/WhisperM8/PostProcessingTemplates.json`.
Beim Speichern werden nur nicht eingebaute Templates persistiert; Duplizieren
erzeugt eine Custom-Kopie mit neuer UUID.

## Projektpfad-Auflösung

`ProjectPathResolver` ist die einzige Regel für das Projekt-CWD des
Codex-Laufs und wird sowohl vom echten `CodexPostProcessor` als auch von der
Report-`commandPreview` verwendet.

| Fall | Ergebnis |
|------|----------|
| `projectAccess == .off` | Kein Projektpfad; Codex läuft im temporären Verzeichnis. |
| `Task` mit `readOnly` | Ausschließlich globaler `agentDefaultProjectPath`; Agent-Chat-Pfad wird bewusst ignoriert. |
| andere read-only Modes | Aktiver Agent-Chat-Projektpfad zuerst, danach globaler Default-Projektpfad. |

Leere oder whitespace-only Pfade werden zu `nil` normalisiert.

## Reports und Archiv

`TranscriptRunReportStore` schreibt produktiv unter
`~/Library/Application Support/WhisperM8/Reports/`. Pro Lauf entsteht ein
UUID-Verzeichnis mit `report.json` und `Attachments/`. Der Store kopiert alle
existierenden Kontextanhänge, erzeugt einen `TranscriptRunAttachmentReport`
pro Anhang und speichert einen `CodexSnapshot` nur für Post-Processing-Modes.

`TranscriptRunReport` ist der vollständige, lokale Audit-Snapshot eines Laufs:
Mode, Transkription, Codex, Kontext, Anhänge, Prompt, Raw/Final Output,
Clipboard/Auto-Paste, Delivery-Fehler und optional Task-Agent-Session. Der
Status ist `succeeded`, `rawFallback`, `cautiousFallback` oder `failed`.

`TranscriptRunReportSummary` ist der Listen-Snapshot für Index, Pagination und
Archiv-Liste. Er enthält Titel, Preview, Mode, Status, Quelle, Attachment-
Anzahl und Reply-Intent.

`OutputHistoryFilter` ist die pure Filterregel für Listen: Scope `all` lässt
alles durch, Scope `tasks` matcht Task-Mode oder `agenticReply`; Status und
Suche werden zusätzlich kombiniert.

`OutputArchiveFallback` ist der nicht-persistierte Latest-Run-Fallback aus
`AppState`. `OutputWorkspacePage` nutzt ihn nur, wenn kein geladener Report als
Latest Run verfügbar ist, und zeigt dabei Raw- und Final-Output getrennt an.

`TranscriptRunReportStore` pflegt `reports-index.json` mit Version 1, baut ihn
bei fehlender oder inkonsistenter Datei neu auf, paginiert mit
`createdAt`/UUID-Cursor und sucht Volltext in Mode-Name, Source-App, Raw,
Final und Selected Text. Cleanup läuft nach Save best effort mit der
Produktionspolicy 180 Tage, 500 Reports und 2 GiB.

## ViewModels

`OutputModesViewModel` lädt Modes und Templates, hält die aktuell ausgewählte
Mode-ID, schreibt Änderungen sofort über `OutputModeStore` und setzt Defaults
zusätzlich in `AppPreferences.shared.defaultOutputModeID`. Es kapselt Enable-
Regeln, Default-Pinning, Custom-Mode-Erstellung, Löschung und Codex-Override-
Toggles.

`TemplateEditorModel` lädt Templates, hält editierbare Felder, erkennt Dirty-
State, validiert Name und Instruction beim Speichern und fragt über
`OutputModeStore`, welche Modes ein Template verwenden.

`OutputArchiveViewModel` lädt Report-Summaries seitenweise, hält Auswahl und
Detailreport, cached bis zu fünf Detailreports als kleines LRU, sucht ab zwei
Zeichen im Volltext weiter und löscht Reports über den Store.

`CodexConnectionModel` gehört zur Account-UI und kapselt die frische
Status-/Versionsprobe. (Die frühere GPT-5.5/`0.120.`-Warnheuristik ist
gestrichen — Modell-Warnungen kommen jetzt katalogbasiert direkt aus der
View: „not in catalog" bzw. „not listed for <model>".)

## Settings-UI

`AIOutputSettingsPage` ist der Tab-Container und hält ein gemeinsames
`TemplateEditorModel`, damit der Modes-Tab direkt in den Templates-Tab springen
und dort das zugehörige Template auswählen kann.

`AIOutputAccountTab` liest und schreibt AppStorage-Werte für globales Modell,
Reasoning, Service-Tier, Visual-Input-Modus, Default-Mode und
Fallback-Verhalten; es nutzt `CodexConnectionModel` für Status und Version.
Model- und Thinking-Picker speisen sich aus `CodexModelCatalog`
(Services/Shared): der Service liest die von der Codex CLI gepflegte
`~/.codex/models_cache.json` (Stat-gecacht, read-only), merged sie mit einem
eingebetteten Fallback und liefert die Level pro Modell (bis `ultra`). Der
Model-Picker bietet zusätzlich „Auto — latest": persistiert wird der Sentinel
`auto`, aufgelöst wird er an den Egress-Grenzen (`CodexInvocation.arguments`,
`AppPreferences.resolvedCodexDefaultModelRaw()`).

`AIOutputModesTab` bearbeitet `OutputMode`-Felder. Für Raw-Modes blendet es
Codex- und Template-Abschnitte aus; für Codex-Modes zeigt es Overrides,
Kontextpolicy, Projektzugriff, Template-Auswahl und Template-Edit-Sprung.

`AIOutputTemplatesTab` trennt Built-in- und Custom-Templates. Built-ins sind
read-only, können aber dupliziert werden; Custom-Templates können gespeichert
werden.

`AIOutputTestLabTab` ist ein schmaler Runtime-Test: getippter Text,
aktivierter Mode, normalisierter Input, `PostProcessingService.process`,
Preview, Copy und Fallback-Anzeige. Es erfasst keinen Laufzeitkontext.

## Modelle

- `WhisperM8/Models/OutputMode.swift` beschreibt Modes, Built-ins, retired Chat-Migration, Codex-Overrides, Projektzugriff und Profil-abhängige Verfügbarkeit.
- `WhisperM8/Models/PostProcessingTemplate.swift` beschreibt Template-Metadaten, Placeholder-Rendering und alle Built-in-Instruktionen.
- `WhisperM8/Models/TranscriptRunReport.swift` beschreibt den vollständigen lokalen Run-Report inklusive Codex-, Kontext-, Output- und Delivery-Snapshot.
- `WhisperM8/Models/TranscriptRunReportSummary.swift` beschreibt den kompakten Listen- und Indexeintrag eines Reports.
- `WhisperM8/Models/CodexPostProcessingModel.swift` liefert nur noch den Fallback-Default (`gpt-5.5`); die auswählbaren Modelle kommen dynamisch aus `WhisperM8/Services/Shared/CodexModelCatalog.swift`.
- `WhisperM8/Models/OutputHistoryFilter.swift` beschreibt die pure Filterlogik für Archiv-Scope, Status und Suche.

## Invarianten und Gotchas

- Raw-Modes starten keinen Codex-Prozess und erzeugen keinen Codex-Snapshot im Report.
- `Fast` bleibt als Fallback-Mode aktiv und sichtbar.
- Built-in-Modes werden in Built-in-Reihenfolge normalisiert; Custom-Modes werden alphabetisch sortiert.
- `OutputModeStore.saveModes` postet nach erfolgreichem Schreiben `OutputModeStore.modesDidChangeNotification`; UI-Konsumenten sollen darauf reagieren statt den Store im Hot-Path zu pollen.
- Der stillgelegte Chat-Mode wird aus persistierten Modes herausgefiltert und Custom-Modes mit altem Chat-Template werden auf das Prompt-Template migriert.
- `required`-Kontext ist nur erfolgreich, wenn nach der Mode-Policy noch Kontext vorhanden ist; `TranscriptContextBundle.isEmpty` zählt auch eine aktive Agent-Chat-Referenz als Kontext, obwohl die aktuelle Fehlermeldung nur Selected Text oder Visual Context nennt.
- Prompt-Preview und echter Lauf verwenden dieselbe Prompt-Building-Logik; die Report-Command-Preview verwendet dieselbe Projektpfad-Auflösung wie der echte Codex-Lauf.
- `Task` ist der einzige nicht-ephemere AI-Output-Modus und nutzt bei read-only Projektzugriff nur den globalen Default-Projektpfad.
- Screenshots, Annotationen und Visual Frames gehen als `--image` an Codex; Screen-Clip-Pfade bleiben im Prompt/Report und Frames dienen als Fallback. Ob die externe Codex CLI direkte Video-Uploads unterstützt, ist kein aus dem WhisperM8-Code belegbarer Fakt.
- `CodexStatusCache` probt nicht unter Lock, weil die Probe einen Subprozess startet.
- `OutputModeStore` cached Dateiinhalt über mtime und size, normalisiert aber pro Zugriff, damit Default-Mode-Änderungen sofort sichtbar sind.
- Das Output-Archiv hält nur Summaries im ersten Schritt; Detailreports werden bei Auswahl nachgeladen.
- Cleanup-Fehler beim Report-Save werden geloggt und blockieren den gespeicherten Report nicht.

## Schlüsseldateien

- `WhisperM8/Services/Dictation/PostProcessing.swift` definiert das Processor-Protokoll und die Post-Processing-Fehler.
- `WhisperM8/Services/Dictation/PostProcessingService.swift` ist die Fassade für Raw-Bypass, Kontextfilter, Prompt-Package und Processor-Aufruf.
- `WhisperM8/Services/Dictation/CodexPostProcessor.swift` ist der produktive Codex-Processor und startet den `codex exec`-Prozess.
- `WhisperM8/Services/Dictation/CodexSupport.swift` enthält Codex-Argumentbau, Prozess-Cancel, Status-Probe und Visual-Input-Auswahl.
- `WhisperM8/Services/Dictation/CodexStatusCache.swift` cached Codex-Loginstatus für den Diktat-Hot-Path.
- `WhisperM8/Services/Dictation/CodexErrorSummary.swift` reduziert Codex-Logs auf nutzerlesbare Fehlermeldungen.
- `WhisperM8/Services/Dictation/PromptPackageBuilder.swift` baut Prompt, Router-Intent und Visual Manifest.
- `WhisperM8/Services/Dictation/OutputModeStore.swift` persistiert, cached, normalisiert und migriert Output-Modes.
- `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift` persistiert Custom-Templates und kombiniert sie mit Built-ins.
- `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift` speichert Reports, Anhänge, Summaries, Pagination, Volltextsuche und Cleanup.
- `WhisperM8/Services/Dictation/ProjectPathResolver.swift` löst den Projektpfad für echten Codex-Lauf und Report-Preview identisch auf.
- `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift` kapselt Mode-Bearbeitung und sofortige Persistenz für den Modes-Tab.
- `WhisperM8/Views/Settings/Models/TemplateEditorModel.swift` kapselt Template-Auswahl, Dirty-State, Duplikat und Speichern.
- `WhisperM8/Views/Settings/Models/OutputArchiveViewModel.swift` kapselt Archiv-Pagination, Filter, Volltextsuche, Detailcache und Löschen.

## Test-Cluster

- `Tests/WhisperM8Tests/OutputDashboardTests.swift` deckt Built-in-Modes, Modell-/Reasoning-/Service-Tier-Defaults, Template-Rendering, Post-Processing-Fassade, Codex-Argumente, Prompt-Package, Visual-Input und Report-Persistenz ab.
- `Tests/WhisperM8Tests/AIOutputModelsTests.swift` deckt `CodexConnectionModel`, `OutputModesViewModel` und `TemplateEditorModel` ab.
- `Tests/WhisperM8Tests/OutputModeCompatTests.swift` deckt Legacy-JSON, Built-in-Normalisierung, Raw/Fast-Migration und retired Chat-Migration ab.
- `Tests/WhisperM8Tests/ProjectPathResolverTests.swift` deckt Projektpfad-Regeln für off, Prompt-Plus, Task und Custom read-only Modes ab.
- `Tests/WhisperM8Tests/CodexStatusProbeTests.swift` und `CodexErrorSummaryTests.swift` decken Codex-Status-Parsing, Version und Fehlerzusammenfassung ab.
- `Tests/WhisperM8Tests/OutputArchiveViewModelTests.swift`, `OutputHistoryFilterTests.swift` und `OutputReportIndexTests.swift` decken Archiv-Pagination, Auswahl, Suche, Filter, Delete, Index-Rebuild und Cleanup ab.
