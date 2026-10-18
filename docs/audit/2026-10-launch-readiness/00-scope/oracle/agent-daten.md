---
status: aktiv
updated: 2026-10-17
description: Regressions-Oracle des Bereichs agent-daten auf Stand a8e0f35. Neue Einträge seit Juli und korrigierte Juli-Einträge (Persistenz, Indexierung, Verlauf, Zusammenfassungen, Retention, Crash-Recovery).
---

# Regressions-Oracle agent-daten (a8e0f35)

## Leseregel

Das Oracle beschreibt Verhalten, das kein Fix unbeabsichtigt ändern darf. Ein Fix darf eine hier genannte Invariante nur ändern, wenn er das ausdrücklich begründet und den zugehörigen Test mitzieht.

Die Einträge des Juli-Inventars (`docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/feature-inventar-agentchats.md`) gelten weiter, sofern sie hier nicht ersetzt sind. Ein ersetzter Eintrag trägt die Überschrift `(aktualisiert)`. „Befund-Bezug" nennt die LR-IDs aus `findings.jsonl`. Einstiegspunkte sind `pfad:zeile` auf a8e0f35, Pfade relativ zu `WhisperM8/`. Die Offen-Hinweise unter „Befund-Bezug" sind keine Invarianten, sondern Soll-Gates der Fixes.

## Neue Einträge seit Juli

### F-AC-08 · Verlaufsansicht (ein NSTextView, TextKit 2)

- **Funktion:** Zeigt geschlossene und nicht laufende Chats als flachen, CLI-artigen Verlauf (`❯` Prompt, `⏺` Antwort oder Tool, `⎿` Ergebnis, `✻` Thinking) in einer einzigen Ansicht. Löst Timeline-, Roh- und Snapshot-Ansicht ab.
- **Einstiegspunkt:** `Views/Transcript/AgentTranscriptContainerView.swift:21` (View), `Views/Transcript/AgentTranscriptContainerView.swift:98` (`rebuild`), `Services/AgentChats/TranscriptTextRenderer.swift:67` (`render`), `Views/Transcript/TranscriptTextView.swift:190` und `:198` (`NSTextView(usingTextLayoutManager: true)`), `Views/AgentSessionDetailView.swift:116` (Einbindung), `Views/AgentSessionDetailView.swift:239` (Tail-Load).
- **Sichtbares Verhalten:** Textauswahl über den ganzen Verlauf, ⌘F über die native Find-Bar, Kopieren nativ. Neue Inhalte kleben nur am Ende, wenn der Nutzer dort steht. Bei abgeschnittenem Anfang erscheint die Pille „Früheren Verlauf laden" (`Views/Transcript/AgentTranscriptContainerView.swift:192`). Sie vergrößert das Fenster ×4 bis 32 MiB, Start 512 KiB (`Views/AgentSessionDetailView.swift:51`, `:56`, `:286`). Oberhalb steht die Summary-Karte (nur Chats, nicht Subagent-Jobs).
- **Erhaltungsinvarianten:**
  - Genau ein `NSTextView`. Keine Rückkehr zu pro-Nachricht-SwiftUI-Hierarchien oder `.defaultScrollAnchor(.bottom)` (Grund: gemessener Dauerfreeze mit sechs Grid-Panes).
  - Gekürzt werden ausschließlich Tool-Ausgaben (`Limits.default`: 4 Zeilen, 4000 Zeichen). Prompts, Antworten und Thinking bleiben vollständig.
  - Das Attributieren läuft off-main über `Task.detached` und wird nach dem Bau auf `Task.isCancelled` geprüft. Die View vergleicht nur ein Revisions-Token, nicht den Text.
  - Lesen ist Tail-first über den `AgentTranscriptCache`: Key mit Session, CWD und Tail-Größe, LRU 24, höchstens 2 parallele Reads, Invalidierung per Größe und mtime.
  - Der Tail verwirft die angeschnittene erste Zeile und meldet `truncatedHead`.
  - Eine Antwort für eine inzwischen umgeschaltete Session wird verworfen (`targetSessionID`-Guard).
  - Es gibt keinen Terminal-Snapshot-Fallback mehr. Ein leeres Transcript zeigt den Empty-State (`Views/Transcript/TranscriptEmptyStateView.swift`).
- **Befund-Bezug:** LR-AK-007 (großes letztes Event macht den Verlauf unerreichbar; Soll: Nachladen oder Degradation statt leer), LR-AK-015 (abgebrochene Bauten rechnen weiter; Soll: Abbruch innerhalb von Renderer und Attributierung), LR-AK-004 (NSException-Pfad bei skalaren Tool-Payloads im Reader), LR-AK-013 (Tool-Zuordnung bei Parallelität), LR-DOK-006.

### F-AC-09 · Wiederaufnahme laufender Chats nach Absturz

- **Funktion:** Hält einen Marker mit den Sessions, deren PTY läuft. Wurde die App unsauber beendet, markiert sie beim nächsten Start die damals laufenden Chats zum Fortsetzen.
- **Einstiegspunkt:** `Services/AgentChats/AgentCrashRecovery.swift:59` (`beginRun`), `:72` (`record`), `:83` (`endRunCleanly`), `:106` (`AgentCrashRecoveryPlanner.sessionsToResume`), `:129` (`AgentCrashRecoveryCoordinator.start`), `WhisperM8App.swift:336` (Start).
- **Sichtbares Verhalten:** Nach einem Absturz oder SIGKILL öffnen sich die zuvor laufenden Chats wieder und starten beim Anzeigen ihres Tabs (`shouldLaunchOnOpen`). Fehlende Tabs kommen zurück, ohne die Auswahl zu wechseln. Quit per Cmd+Q, Menü oder SIGTERM (`make dev`) gilt als sauber und lässt nichts wiederaufnehmen.
- **Erhaltungsinvarianten:**
  - Die Datei `running-sessions.json` wird bei sauberem Ende entfernt, und nur vom Besitzer (eigene PID).
  - Lebt die PID im vorhandenen Marker noch (zweite Instanz), bleibt der Marker unangetastet und die zweite Instanz nimmt nichts auf.
  - Nur Kinds `chat` und `backgroundChat` werden aufgenommen. `agentView`, `terminal` und `subagentJob` nie. Archivierte nie.
  - Doppelte IDs werden dedupliziert. Gestoppte Chats stehen nicht im Marker.
  - Nach dem sauberen Ende ändern späte `record`-Aufrufe (PTY-Exits während des Quits) den Marker nicht.
  - Der Kill-Switch `agentCrashRecoveryEnabled` verhindert das Vormerken, protokolliert aber `crash_recovery_skipped`.
  - Log `crash_recovery_resumed` bleibt unverändert, weil darauf die Diagnose beruht.
- **Befund-Bezug:** kein eigener Befund. Berührt LR-AK-005 (ein stiller Write-Fehler kann `shouldLaunchOnOpen` verlieren) und LR-AK-011 (Scan-Rennen um Stempel).

### F-AC-12 (Teil Retention) · Aufräumen der Subagent-Job-Spiegel

- **Funktion:** Entfernt die Workspace-Spiegel abgeschlossener CLI-Subagent-Jobs 7 Tage nach der letzten Aktivität und archiviert vorher das Rollout-Transcript.
- **Einstiegspunkt:** `Services/AgentChats/AgentJobWorkspaceSync.swift:236` (`runRetentionIfDue`), `Services/AgentChats/SubagentJobRetention.swift:48` (`expiredSessions`), `:108` (`archive`), `Support/AppPreferences.swift:599` (Kill-Switch), `:616` (Frist).
- **Sichtbares Verhalten:** Alte Subagent-Zeilen verschwinden ohne Nutzeraktion. Der erste Lauf nach dem Update ist eine einmalige, fristlose Altlasten-Bereinigung. Das Prüfintervall beträgt 6 Stunden.
- **Erhaltungsinvarianten:**
  - Fällig ist nur, was auf Disk ohnehin weg ist: Solange das Job-Verzeichnis lebt, bleibt der Eintrag.
  - Laufende (`running`, `pending`) und sichtbare Sessions (offene Tabs aller Fenster, Pins, belegte Grid-Slots) werden nie entfernt.
  - Der fristlose Erstlauf räumt nur Einträge mit bereits genilter Short-ID (`requiresClearedShortID`).
  - Reihenfolge: erst Transcript nach `agent-jobs-archive/`, dann Session löschen. Andernfalls adoptiert der Indexer das Transcript als normalen Codex-Chat.
  - Ab 100 Kandidaten entsteht vorher ein `.pre-retention`-Backup der Workspace-Datei.
  - Job-Verzeichnisse selbst räumt nur `agent rm`.
  - Kill-Switch `subagentJobRetentionEnabled` und Frist `subagentJobRetentionDays` bleiben wirksam.
- **Befund-Bezug:** LR-AK-012 (Schutz-Snapshot wird vor dem `await` gebildet und kann nach der Archivierung veraltet sein; Soll: Schutzmenge unmittelbar vor dem Löschen neu bilden), LR-AK-030/031/032 (Job-Zustände im selben Sync).

### F-AC-06 (Aufräum-Teil) · Hook-Dateien und Altdaten

- **Funktion:** Räumt beim App-Start verwaiste Hook-Settings und Hook-Events weg, die zu keiner lokalen Session mehr gehören. Entfernt einmalig das Verzeichnis der alten Terminal-Snapshots.
- **Einstiegspunkt:** `Services/AgentChats/AgentSessionRetentionService.swift:18` (`prune`), `WhisperM8App.swift:285` (Aufruf), `Services/AgentChats/LegacyDataCleanup.swift:18` (`removeObsoleteTerminalSnapshots`), `WhisperM8App.swift:268`.
- **Sichtbares Verhalten:** Unsichtbar. Logs zeigen entfernte Dateizahlen.
- **Erhaltungsinvarianten:**
  - Behalten wird alles, dessen UUID zu einer lebenden lokalen Session passt. Dateien mit nicht parsebarem Namen bleiben unberührt.
  - Läuft off-main mit Hintergrundpriorität.
  - Der Snapshot-Cleanup läuft genau einmal (`terminalSnapshotsPurged`), off-main, und schreibt nie neue Snapshots.
- **Befund-Bezug:** kein eigener Befund. Der Workspace-Snapshot für `liveIDs` wird beim Start einmal gezogen und kann bei parallelem Merge veralten (gleiche Klasse wie LR-AK-012).

## Aktualisierte Juli-Einträge

### AC-02 (aktualisiert) · Getrennte Domain- und UI-Persistenz

- **Funktion:** Persistiert Projekte und Sessions in `AgentSessions.json` und Fenster, Tabs, Pins und Grid in `agent-ui-state.json`. Der Domain-Kern liegt in einer prozessweiten Registry pro Datei-URL.
- **Einstiegspunkt:** `Services/AgentChats/AgentWorkspaceRepository.swift:16`, `Services/AgentChats/AgentWorkspaceStore.swift:21`, `:52` (`maxDebounceLatency`), `:360` (Registry), `Services/AgentChats/AgentSessionStore.swift:3`, `:41`, `:1499` (`migratedWorkspace`).
- **Sichtbares Verhalten:** Wie im Juli. Zusätzlich übersteht der Workspace eine korrupte Hauptdatei.
- **Erhaltungsinvarianten:**
  - Wie im Juli: Ein Kern pro standardisiertem Produktionspfad. Mutationen unter Lock und Equatable-diff-gated. Produktionswrites debounced (0,5 s), atomar und spätestens nach 2 s fällig. `willTerminate` drainiert die Domainwrites über die eigene `flushQueue`. Runtime-Status bleibt ephemer.
  - Neu: Drei rotierende Generation-Backups (`.bak.1` bis `.bak.3`, Rotation höchstens alle 5 min, erst nach erfolgreichem Write mit den soeben kodierten Bytes).
  - Neu: Vor einer Migration entsteht ein `.pre-migration`-Backup. Bei Decode-Fehler wird die Hauptdatei als `.decode-failed` quarantänisiert und das neueste dekodierbare Backup geladen (`agent_store_recovered_from_backup`).
  - Neu: `loadReadOnly` ist garantiert schreibfrei und gehört der CLI. Migration, Backups und Recovery-Writes passieren dort nie.
  - Neu: `migratedWorkspace` bereinigt bei jeder Normalisierung Duplikat-IDs, Claude-Worktree-Projekte, nicht fortsetzbare Claude-Sessions sowie verwaiste und importierte Background-Sessions. Jedes Entfernen wird als `agent_store_pruned` geloggt.
  - Zustandsänderungen am Schema nur, wenn der Befund-Bezug unten sie ausdrücklich auflöst.
- **Befund-Bezug:** LR-AK-002 und LR-AK-029 (`migratedWorkspace` setzt `schemaVersion` auf den eigenen Wert und der Load schreibt zurück. Das Juli-Soll „Future-Schema read-only" ist weiter unerfüllt), LR-AK-005 (Write-Fehler im Drain werden nur geloggt, kein sichtbarer Zustand, kein Retry).

### AC-10 (aktualisiert) · Native Titel und Session-Zusammenfassungen

- **Funktion:** Titel kommen nicht mehr von einem Modellaufruf, sondern aus dem Transcript des CLI. Zusammenfassungen entstehen weiter per Headless-CLI-Lauf, aber beim Anzeigen statt beim App-Start.
- **Einstiegspunkt:** `Services/AgentChats/NativeSessionTitle.swift:35` (`resolve`), `Services/AgentChats/AgentSessionAutoNamer.swift:256` (`handleTurnFinished`), `:328` (`loadNativeTitle`), `Services/AgentChats/AgentSessionStore.swift:323` (`applyAutoGeneratedTitle`), `Services/AgentChats/AgentSessionSummarizer.swift:258` (`requestSummaryOnDisplay`), `:305` (`summarizeIfNeeded`), `Views/Transcript/SessionSummaryCard.swift:68`.
- **Sichtbares Verhalten:** Titel folgen dem Claude-`custom-title` (`/rename`), dann `ai-title`, dann dem ersten echten Prompt. Bei Codex ist es der erste Prompt. Die Summary-Karte erscheint bei beendeten Chats. Fehlt sie oder ist sie veraltet, wird sie nach 2 s Anzeigedauer erzeugt. „Erneuern" in der Karte erzwingt einen Lauf.
- **Erhaltungsinvarianten:**
  - Manuelle Titel (`titleIsAutoGenerated == false`) gewinnen und werden nie überschrieben, bis „Benennung aufheben" oder `chats rename --reset` greift.
  - Auto-Naming verlangt ein erfasstes Turn-Ende. Fehlendes Transcript führt zu Backoff bis 5 min, andere Fehler bis 1 h. Der Titel wird nur persistiert, wenn er sich ändert.
  - Zusammenfassungen laufen nur, wenn `isAutoSummaryEnabled` an ist (Default an) oder manuell ausgelöst werden. Der Start-Abgleich ist Default aus (`summaryStartupReconciliationEnabled`).
  - Der Digest-Guard (Größe und mtime) verhindert jeden CLI-Lauf bei unverändertem Transcript. Mindestens 4 Nachrichten für automatische Läufe, manuell 1. Subagent-Jobs bekommen nie eine LLM-Zusammenfassung.
  - Automatische Fehler lösen einen globalen Backoff von 30 min und einen Session-Backoff von 2 h aus. Manuelle Läufe sind ausgenommen.
  - Headless-Läufe nutzen `--no-session-persistence` bzw. `--ephemeral`, damit sie keine importierbaren Sessions erzeugen. Log-Zeilen enthalten nie Prompt- oder Ansageinhalte.
  - Der Summary-Prompt bekommt höchstens 12 Runden bzw. 6000 Zeichen und die Belege (Tests, Commits).
- **Befund-Bezug:** LR-AK-001 (Parser-Range-Trap), LR-AK-003 (Inhalt im argv), LR-AK-009 (Konto und Backend gehen verloren), LR-AK-010 und LR-ONB-008 (Datenabfluss unerklärt, Default an), LR-AK-013 und LR-AK-014 (falsche Tool-Zuordnung und falsches „bestanden" im Prompt), LR-AK-006 (Codex-Status bei Turn-Ende).

### AC-30 (aktualisiert) · Terminal-Snapshot: ersatzlos entfallen

- **Funktion:** Gibt es nicht mehr. Geschlossene Chats werden aus den nativen JSONL-Transcripts gerendert. Es werden keine Terminalbuffer mehr gelesen oder gespeichert.
- **Einstiegspunkt:** `Services/AgentChats/LegacyDataCleanup.swift:18` (einmaliges Entfernen von `TerminalSnapshots/`), `WhisperM8App.swift:268`.
- **Sichtbares Verhalten:** Kein Offline-Terminalbild. Bei fehlendem Transcript zeigt die Verlaufsansicht den Empty-State.
- **Erhaltungsinvarianten:** Es entsteht kein neues Plaintext-Sidecar von Terminalinhalt. Die dort offenen Privacy-Soll-Gates des Juli (Dateirechte, Ablauf, Eingabegrenze) sind damit gegenstandslos, solange kein Snapshot zurückkommt. Kehrt er zurück, gelten sie wieder.
- **Befund-Bezug:** LR-DOK-006 (Doku beschreibt noch den Snapshot-Pfad).

### AC-44 (aktualisiert, Teil Auto-Naming) · Turn-Ende und Auto-Naming

- **Funktion:** Das Persistieren von `lastTurnAt` und die Benachrichtigungen bleiben wie im Juli (nicht in diesem Bereich geprüft). Das Auto-Naming nach dem Turn-Ende ist kein Modellaufruf mehr, sondern liest den nativen Titel.
- **Einstiegspunkt:** `Services/AgentChats/AgentSessionAutoNamer.swift:256`, `:345` (`runTitleGeneration`), `Services/AgentChats/AgentSessionStore.swift:343` (`recordTurnEnded`).
- **Sichtbares Verhalten:** Siehe AC-10 (aktualisiert).
- **Erhaltungsinvarianten:** Siehe AC-10 (aktualisiert). Bookkeeping auf Transcript-Ende darf den stärkeren Hook-Status nicht überschreiben.
- **Befund-Bezug:** LR-AK-006.

### AC-50 (aktualisiert) · Scan-Koordination und Directory-FSEvents

- **Funktion:** Coalesced Scan-Auslöser, Debounce für Verzeichnisereignisse, Cooldowns. Neu: Scans lassen sich für Kontoumzüge anhalten und danach nachholen.
- **Einstiegspunkt:** `Services/AgentChats/AgentDirectoryEventMonitor.swift:42` (`relevantPaths`), `:112` (`handleEvents`), `Services/AgentChats/AgentScanCoordinator.swift:93` (`suspendScans`), `:102` (`resumeScans`), `:113` (`requestScan`), `:159` (`startScan`).
- **Sichtbares Verhalten:** Wie im Juli. Während eines Kontoumzugs erscheinen neue Dateien erst nach `resumeScans`.
- **Erhaltungsinvarianten:**
  - Cooldown 30 s für Launch und Foreground, 10 s für FSEvent, 5 s Debounce im Monitor. Manuelle Scans umgehen den Cooldown.
  - Ein Pending-Grund geht nie verloren, weder bei laufendem Scan noch während einer Pause.
  - Subagent-Pfade und live beobachtete Transcripts lösen keinen Scan aus.
  - Neu: Der Wiederaufnahme-Scan nach einer Pause umgeht den Cooldown bewusst.
  - „Höchstens ein Scan aktiv" ist als Invariante gewollt, wird aber auf dem Wiederaufnahmepfad nicht durchgesetzt (siehe Befund-Bezug).
- **Befund-Bezug:** LR-AK-011 (`resumeScans` ruft `startScan` ohne `inFlight`-Prüfung), LR-AK-016 (Debounce verschiebt bei Dauer-Writes endlos).

### AC-53 (aktualisiert, nur Zahlen) · Transcript-Locator und Tail-Cache

- **Funktion:** Unverändert im Kern. Korrigiert: Das Standard-Lesefenster der Reader ist 256 KiB. Die Detailansicht fordert 512 KiB an (`Views/AgentSessionDetailView.swift:51`). Nachladen ×4 bis 32 MiB.
- **Einstiegspunkt:** `Services/AgentChats/ClaudeTranscriptReader.swift:410` (`TranscriptTailReader.defaultTailBytes`), `Services/AgentChats/AgentTranscriptCache.swift:47`, `Services/AgentChats/AgentSessionTranscript.swift:304` (`locate`).
- **Erhaltungsinvarianten:** Wie im Juli: LRU 24, 2 parallele Reads, Invalidierung wiederbelebt keine alten Reads, Tail-Anfang verwirft die angeschnittene Zeile und meldet Truncation. Der Tail-Reader selbst hat keine Obergrenze je Zeile; ein einzelnes übergroßes Event kann das Fenster leeren.
- **Befund-Bezug:** LR-AK-007.

### AC-55 (aktualisiert) · Timeline-, Roh- und Snapshot-Ansicht: abgelöst

- **Funktion:** Die drei Ansichten existieren nicht mehr. `AgentTimelineView`, `TimelineRoundView`, `TimelineActivityRow`, `TimelineReportView`, `TerminalSnapshotView`, `AgentChatTranscriptView` und `TranscriptWindow` sind gelöscht. An ihre Stelle tritt F-AC-08.
- **Einstiegspunkt:** `Views/Transcript/AgentTranscriptContainerView.swift:21`.
- **Erhaltungsinvarianten:** Der `TranscriptTimelineBuilder` bleibt als reine Projektion für die Zusammenfassungen erhalten (verlustfrei bezüglich Blocks, Rundenstart bei User-Text, Notizen vor dem letzten Aktivitäts-Step, stabile IDs). Das Fenster „160 Runden / 600 Nachrichten" des Juli gilt nicht mehr.
- **Befund-Bezug:** LR-DOK-006.

## Juli-Einträge ohne inhaltliche Änderung (nur Zeilen verschoben, nicht neu geschrieben)

AC-09, R4-AS-11, AC-49, AC-51, AC-52, AC-54, AC-56. Stichprobe: Limits (200 Zeilen/1 MiB, 256 KiB, 1000 Resultate), `subagents/`- und Worktree-Filter, Dedupe-Logik, ±5-s-Adoption und FIFO-Tool-Zuordnung gelten weiter. Das C07-Soll-Gate zu AC-52 (Eindeutigkeit statt nächster Kandidat) bleibt offen, ebenso die Tool-Korrelation bei Parallelität in AC-56.
