---
status: aktiv
updated: 2026-07-09
---

# AI Output — Post-Processing, Modes und Templates

AI Output ist die Codex-Nachbearbeitung nach der Spracherkennung. WhisperM8
nimmt ein Diktat auf, erzeugt über Whisper/Groq ein Raw-Transkript und liefert
dieses je nach Output-Mode unverändert oder als Codex-verarbeitete Ausgabe aus.
Die Nachbearbeitung läuft nicht über den Agent-Chat-PTY, sondern über einen
kurzlebigen `codex exec`-Prozess, dessen letzte Antwort als fertiger
Nutzertext gelesen wird.

## Output-Modes

Ein Output-Mode beschreibt, ob Codex benutzt wird, welches Template den Auftrag
prägt, wie viel Kontext erlaubt ist, ob visuelle Anhänge beim Auto-Paste in die
Ziel-App eingefügt werden und ob Codex ein Projekt als read-only Working
Directory bekommt.

| Mode-Typ | Bedeutung |
|----------|-----------|
| `raw` | Liefert das normalisierte STT-Transkript direkt aus; Codex wird nicht gestartet. |
| `builtIn` | Verwendet einen eingebauten Modus mit festem Built-in-Template und optionalem Kontext. |
| `custom` | User-Modus aus `OutputModes.json`, mit editierbarem Namen, Label, Template, Kontext- und Codex-Einstellungen. |

Die eingebauten Modi sind `Fast`, `Clean`, `Prompt`, `Ultra-Prompt`, `Task`,
`Email`, `Slack`, `WhatsApp` und `Notes`. `Fast` ist der Raw-Fallback und bleibt
sichtbar; alle anderen Modi gelten als Codex-abhängig. Zusätzlich existiert das
eingebaute Template `Tech/Denglisch clean transcript`; es ist kein eigener
Built-in-Mode, ist aber in der Templates-UI sichtbar und kann als Custom-
Template dupliziert werden. Ohne Codex-Enrichment im Usage-Profil bietet das
Recording-Overlay nur Codex-freie Modi an und ein gespeicherter Codex-Default
fällt effektiv auf `Fast` zurück.

Für Codex-Modes gelten drei Ebenen von Laufzeitparametern: globale Defaults aus
`AIOutputAccountTab`, optionale Mode-Overrides aus `AIOutputModesTab` und die
Fallback-Auflösung im Modell. Pro Mode können Codex-Modell,
Reasoning/Thinking-Level und Service-Tier gesetzt werden; leere Overrides
fallen auf die globalen Werte zurück. Der Codex-Aufruf verwendet diese Werte
als `-m`, `-c model_reasoning_effort=...` und Service-Tier-Configs.

## Templates

Templates sind die mode-spezifische Instruktion im finalen Prompt. Built-in-
Templates sind read-only; eigene Templates werden in
`PostProcessingTemplates.json` gespeichert und können aus Built-ins dupliziert
werden. Ein Template wird vor dem Codex-Lauf gerendert und ersetzt Platzhalter
wie `{rawTranscript}`, `{selectedContext}`, `{visualContextSummary}`,
`{screenClipPaths}`, `{visualInputMode}`, `{attachmentCount}`, `{activeApp}`,
`{agentChatTitle}`, `{agentChatProject}`, `{agentChatPath}`,
`{agentChatProvider}`, `{agentChatExternalID}`, `{agentChatTail}`,
`{language}` und `{date}`.

Der finale Prompt besteht nicht nur aus dem Template. `PromptPackageBuilder`
setzt davor einen globalen Output-Vertrag, optionalen Agent-Chat-Kontext und
den Captured-Context-Block mit Selected Text, Visual Summary, Visual Manifest
und Bildreferenzen. Danach folgt die gerenderte Template-Instruktion als
`Mode Instruction`. Die Quelle und Capture-Policy von Screenshots, Clips,
Annotationen und Selected Text gehört zur Nachbar-Doku
`docs/features/dictation/visual-context/`; AI Output beschreibt hier nur den
Verbrauch dieses Kontextbundles.

## Tatsächlicher Ausführungspfad

Der App-Pfad beginnt in `RecordingCoordinator.transcribeAndDeliver`: nach dem
STT-Call wird der Raw-Text normalisiert, in `lastRawTranscription` geschrieben
und an `processTranscriptIfNeeded` übergeben. Raw-Modes kehren dort sofort mit
dem Raw-Text zurück.

Für Codex-Modes führt der Coordinator kurz vor dem Lauf noch einen Clipboard-
Sweep aus und nimmt das Live-`contextBundle`, falls es seit Recording-Stop
weiter angereichert wurde. Danach berechnet `PostProcessingService` den für den
Mode erlaubten Kontext, baut ein `PromptPackage` für Overlay-Status und Report
und startet `process(...)`.

`PostProcessingService` lässt Kontext nur bei `contextPolicy` `auto` oder
`required` durch; bei `off` wird ein leeres Bundle verwendet. Ist Kontext
`required` und nach dem Filtern leer, bricht der Lauf mit einem
Codex-Unavailable-Fehler ab. Danach lädt `CodexPostProcessor` das Template,
prüft über den TTL-Statuscache, ob Codex für nicht-interaktive Verarbeitung
bereit ist, baut denselben Prompt und startet Codex.

Der Codex-Spawn-Pfad löst zuerst das Binary auf: bevorzugt
`/Applications/Codex.app/Contents/Resources/codex`, sonst über
`AgentCommandBuilder.commandPath("codex")`. Der Prozess läuft mit
`LoginShellEnvironment.shared.processEnvironment()`, schreibt die letzte
Antwort in eine temporäre Datei und bekommt den Prompt über stdin. Die
Argumente sind `exec`, Modell, Reasoning-Config, Service-Tier-Config,
`--sandbox read-only`, `--skip-git-repo-check`, `--output-last-message`, optional
`-C <projectPath>`, optional `--ephemeral`, pro Bild `--image <path>` und am
Ende `-` für stdin. Alle Modi außer `Task` laufen ephemer; `Task` läuft
nicht-ephemer.

Das externe Laufzeitverhalten der Codex CLI selbst ist nicht Teil von
WhisperM8. Aus dem Repo ist nur prüfbar, dass WhisperM8 Bilder per `--image`
übergibt, den Prozess-Exit-Code prüft und eine nicht-leere Datei aus
`--output-last-message` erwartet. Fehlerausgaben werden auf kurze
Nutzermeldungen verdichtet; ein Login-Fehler invalidiert den Statuscache.

Nach dem Codex-Lauf normalisiert der Coordinator den finalen Text, kopiert ihn
ins Clipboard und führt bei aktivem Auto-Paste Text und erlaubte Bildanhänge in
die Ziel-App ein. Bei Post-Processing-Fehlern liefert die App je nach
Preference entweder einen Raw- oder vorsichtigen Fallback aus oder wirft den
Fehler weiter.

## Visual Context und Anhänge

AI Output benutzt denselben `TranscriptContextBundle` wie die Diktat-Pipeline:
Selected Text, aktive App, Agent-Chat-Referenz, optionaler Agent-Chat-Tail,
Screenshots, Annotationen, Visual Frames, Screen Clips und eine
Visual-Context-Zusammenfassung. Agent-Chat-Session, Tail und Projektzuordnung
gehören fachlich zu `docs/features/agent-chats/`; AI Output verwendet diese
Daten nur als Prompt- und Projektkontext. `CodexVisualInputSelection`
entscheidet anhand der globalen Visual-Input-Einstellung, welche Dateien als
AI-Output-Eingabe markiert werden.

Heute sendet WhisperM8 Bilder über `--image`. In `auto` und `frames` werden
Screenshots, Annotationen und Visual Frames als Bilder übergeben. In `video`
werden Screen-Clip-Pfade im Prompt und im Report gehalten; Frames bleiben als
Bild-Fallback für Codex erhalten. Aus dem Code ist nicht ableitbar, ob die
externe Codex CLI direkte Video-Uploads unterstützt; belegbar ist nur, dass
WhisperM8 aktuell keine Video-Dateien als eigenes Prozessargument übergibt.

Für Auto-Paste ist das separate Mode-Feld `pasteVisualAttachments` relevant.
Es entscheidet, ob vorbereitete visuelle Anhänge zusätzlich zum Text in die
Ziel-App eingefügt werden; gesendet wird die Nachricht dabei nicht.

## Test-Lab

Das Test-Lab verarbeitet getippten Text ohne Aufnahme. Es lädt die aktivierten
Output-Modes, normalisiert den eingegebenen Raw-Text und ruft denselben
`PostProcessingService` wie der Recording-Pfad auf. Es erfasst keinen Selected
Text, keine Screenshots und keinen Agent-Chat-Kontext. Bei Fehlern zeigt es je
nach Fallback-Preference den normalisierten Raw-Text oder eine leere Ausgabe mit
Fehlermeldung.

## Run-Reports und Output-Archiv

Ein Run-Report wird im erfolgreichen `transcribeAndDeliver`-Pfad nach
Transkription, optionalem Post-Processing und Delivery gespeichert. Fehler vor
diesem Punkt und User-Cancel während der Transkription laufen über den
Failed-Recording-Preserve-Pfad und schreiben keinen Report. Ein gespeicherter
Report enthält Status, Mode-Snapshot, STT-Provider und Modell, Sprache,
Audiodauer, Raw-Transkript, Final Output, Selected Text, Visual Summary,
gerenderten Prompt, Router-Intent, Visual Manifest, Anhänge, Delivery-Daten,
Paste-Fehler und bei Codex-Modes eine Codex-Snapshot mit Modell, Thinking,
Visual-Input-Modus, Command-Preview und den an Codex gesendeten Bildpfaden.

Die produktiven Reports liegen unter
`~/Library/Application Support/WhisperM8/Reports/<uuid>/report.json`; kopierte
Anhänge liegen pro Run unter `Attachments/`, und `reports-index.json` hält die
sortierten Summaries für schnelle Listen und Pagination. Die Produktions-
Cleanup-Policy entfernt alte Daten nach 180 Tagen, mehr als 500 Reports oder
mehr als 2 GiB belegtem Speicher.

Das Output-Archiv lädt Summary-Seiten, sucht zunächst in Summaries und ab zwei
Suchzeichen zusätzlich im Volltext der Reports. Der Scope `Tasks` zeigt
Task-Mode-Runs und agentische Replies; Statusfilter arbeiten auf
`succeeded`, `rawFallback`, `cautiousFallback` und `failed`. Die Detailansicht
zeigt Output, Kontext, Anhänge, Delivery, Prompt, Visual Manifest und die
Command-Preview. Die Latest-Run-Fläche nutzt zuerst den neuesten geladenen
Report; wenn noch kein Report geladen oder vorhanden ist, kann
`OutputArchiveFallback` den letzten Raw-/Final-Text aus `AppState` anzeigen.

## Settings-Tabs

| Tab | Rolle |
|-----|-------|
| Account & Defaults | Prüft Codex-Login und Version, setzt globale Modell-, Thinking-, Speed- und Visual-Input-Defaults, Default-Mode und Raw-Fallback-Verhalten. |
| Modes | Verwaltet Built-in- und Custom-Modes, Sichtbarkeit, Default, Namen, Overlay-Label, Bild-Paste, Codex-Overrides, Kontextpolicy, Projektzugriff und Template-Zuordnung. |
| Templates | Listet Built-in- und Custom-Templates, erlaubt Duplizieren, Erstellen und Speichern eigener Templates und zeigt, welche Modes ein Template verwenden. |
| Test Lab | Führt einen aktivierten Mode auf getipptem Text aus und kopiert die Preview bei Bedarf in die Zwischenablage. |

## Schlüsseldateien

- `WhisperM8/Services/Dictation/PostProcessing.swift` definiert das Post-Processing-Protokoll, die Fehlerfälle und No-Op-/Mock-Implementierungen.
- `WhisperM8/Services/Dictation/PostProcessingService.swift` ist die Fassade, die Raw-Modes kurzschließt, Kontext nach Mode-Policy filtert und Prompt-Packages für UI/Reports bereitstellt.
- `WhisperM8/Services/Dictation/CodexPostProcessor.swift` lädt Templates, prüft Codex-Bereitschaft, löst Projektpfade auf und startet den echten `codex exec`-Prozess.
- `WhisperM8/Services/Dictation/CodexSupport.swift` enthält Process-Cancel-Registry, Codex-Argumentbau, Status-Probe und Visual-Input-Auswahl.
- `WhisperM8/Services/Dictation/PromptPackageBuilder.swift` baut den finalen Prompt aus Globalvertrag, Agent-Chat-Kontext, Captured Context, Visual Manifest und Template.
- `WhisperM8/Services/Dictation/OutputModeStore.swift` lädt, normalisiert, migriert und speichert Output-Modes in `OutputModes.json`.
- `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift` kombiniert Built-in-Templates mit Custom-Templates aus `PostProcessingTemplates.json`.
- `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift` persistiert Run-Reports, kopiert Anhänge, pflegt den Summary-Index und führt Cleanup aus.
- `WhisperM8/Views/Settings/Pages/AIOutputSettingsPage.swift` bündelt die vier AI-Output-Settings-Tabs.
- `WhisperM8/Views/Settings/Pages/OutputWorkspacePage.swift` rendert Latest Run und Output-Archiv aus Reports und nutzt bei fehlendem geladenem Report einen AppState-Fallback.

## Keywords

AI Output, KI-Ausgabe, Codex-Nachbearbeitung, Post-Processing,
Transkript-Nachbearbeitung, Output-Modus, Ausgabemodus, Fast, Raw, Clean,
Prompt, Ultra-Prompt, Task, Email, Slack, WhatsApp, Notes, Template, Vorlage,
Tech-Denglisch, `template.tech-clean`, Custom Mode, Built-in Mode, Test-Lab,
Run-Report, Output-Archiv, Latest Run, `OutputArchiveFallback`,
Visual Context, Screenshot, Annotation, Visual Frame, Screen Clip, Selected
Text, Agent-Chat-Kontext, Codex CLI, codex exec, Codex-Spawn,
Modell-Override, Thinking-Override, Service-Tier-Override, Raw-Fallback,
vorsichtiger Fallback, `PostProcessingService`, `CodexPostProcessor`,
`CodexInvocation`, `CodexStatusCache`, `CodexErrorSummary`,
`PromptPackageBuilder`, `OutputMode`, `OutputModeStore`,
`OutputModeStore.modesDidChangeNotification`, `CodexConnectionModel`,
`PostProcessingTemplate`, `PostProcessingTemplateStore`,
`TranscriptRunReport`, `TranscriptRunReportStore`,
`TranscriptRunReportSummary`, `CodexPostProcessingModel`,
`CodexReasoningEffort`, `CodexServiceTier`, `CodexVisualInputMode`,
`OutputHistoryFilter`, `OutputModesViewModel`, `TemplateEditorModel`,
`OutputArchiveViewModel`, `AIOutputAccountTab`, `AIOutputModesTab`,
`AIOutputTemplatesTab`, `AIOutputTestLabTab`, `OutputWorkspacePage`,
`ProjectPathResolver`, `ReplyIntentRouter`, `VisualManifest`,
`CodexVisualInputSelection`.
