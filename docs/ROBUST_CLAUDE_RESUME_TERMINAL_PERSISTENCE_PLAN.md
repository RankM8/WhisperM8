# Robustes Claude-Resume und Terminal-Persistenz

Stand: 2026-05-11 (v2 ergaenzt 2026-05-11)

Dieser Plan beschreibt eine robuste, nicht-breaking Umsetzung fuer WhisperM8, damit Claude-Code-Tabs auch nach Force Quit, Tabwechseln und interaktivem `/resume` konsistent bleiben. Es ist bewusst ein Umsetzungsplan und keine Implementierung.

## Plan-Update v2 (2026-05-11)

Nach Review wurden folgende Punkte ergaenzt oder umsortiert. Originalplan bleibt vollstaendig erhalten; Aenderungen sind inline mit `[v2]` markiert.

### Wichtigste Aenderungen

1. **Phase-Reihenfolge gedreht**: Phase 5 (Transcript-Active-Tracker) kommt VOR Phase 4 (Hook-Bridge). Begruendung: Transcript-Tail funktioniert auch ohne Hooks und ist damit das robuste Fundament. Hook wird zur Optimization-Schicht degradiert.
2. **Offene Frage 1 geloest**: SwiftTerm-API fuer Snapshot ist `terminal.getText(start:end:)` plus `buffer.lines` fuer Scrollback. Aktuell in `AgentTerminalView.swift` nicht verwendet, also keine Konflikte.
3. **Offene Frage 2 geloest**: `claude --settings <file>` existiert seit 1.x. Settings werden ON TOP gemergt (additiv). Sicherheit: POSIX 0600 + App-Container-Pfad.
4. **Hook via Helper-Binary** statt Inline-Shell-Command. WhisperM8 shippt `whisperm8-claude-hook` (~30 Zeilen Swift, atomisches O_APPEND).
5. **Hook-Silence-Detection**: Wenn nach Launch + 5 s kein `SessionStart`-Event ankommt, transparent auf Transcript-Tail-Mode wechseln.
6. **Codex-Coverage explizit**: Codex hat kein Hook-API (Stand 11/2025) - nur Transcript-Tail funktioniert.
7. **Snapshot-Strategie**: Dirty-Flag + 500 ms Idle-Debounce, nicht 1-2 s Throttle. Garantiertes Flush bei tab-switch/background/terminate.
8. **Ambiguous-Rebind UI**: Inline-Picker im Header bei mehreren Transcript-Kandidaten, nicht silent-skip.
9. **Verworfene Alternative tmux/dtach** explizit dokumentiert.

### Coverage-Tabelle [v2]

| Provider | SessionStart-Hook | /resume-Detection | Snapshot | Recovery-UI |
|----------|-------------------|-------------------|----------|-------------|
| Claude   | via `--settings` (Phase 4-neu) | Hook + Transcript-Tail (Phase 5-neu, dann 4-neu) | ja (Phase 1-3) | Hook-Event + Picker (Phase 6) |
| Codex    | nicht verfuegbar  | Transcript-Tail only (Phase 5-neu) | ja (Phase 1-3) | Picker only (Phase 6) |

### Empfohlene neue Phase-Reihenfolge [v2]

| # | Phase | Risk | Tage |
|---|-------|------|------|
| 0 | Repro + Tests + Schema-Migration-Layer | low | 1-2 |
| 1 | SnapshotStore + Tests | low | 1 |
| 2 | Output-Capture (debounced) | med | 2-3 |
| 3 | Offline-UI mit Snapshot | low | 1-2 |
| 4-neu | Transcript-Active-Tracker (war Phase 5) | med | 2 |
| 5-neu | Hook-Bridge als Enhancement (war Phase 4) | med-high | 3 |
| 6 | Resume-Recovery (Picker + Rebind) | med | 2 |
| 7 | Telemetrie + Retention + Cleanup | low | 1 |

Sprint 1: Phase 0-3 -> Force-Quit-Recovery komplett, Snapshot-UI fertig.
Sprint 2: Phase 4-neu + 5-neu + 6 -> interaktives `/resume` zuverlaessig erkannt, Recovery-UI vorhanden.
Sprint 3: Phase 7 -> Polish, Retention, Telemetrie.

### Verworfene Alternative: tmux/dtach [v2]

Eine naheliegende Alternative waere, Claude in einem `dtach`- oder `tmux`-Detach laufen zu lassen, sodass der Prozess Force Quit der App ueberlebt. Wird abgelehnt weil:

- `tmux` ist nicht standard auf macOS, benoetigt Homebrew
- `dtach` ist nicht standard auf macOS
- Force Quit der App killt je nach Detach-Implementierung die Process Group des Childs trotzdem
- User sieht zwei Prozesse in Activity Monitor (verwirrend, unerwartete CPU/RAM-Last)
- Reattach-UI komplex (welcher Detach gehoert zu welchem Tab?)
- Konflikte mit existierenden Shells (Login-Shell-Environment, TTY-Handling)

Snapshot-Ansatz bleibt der pragmatische Weg. Persistenz bedeutet Anzeige-Zustand, nicht Prozess-Zustand.

## Zielbild

- Ein WhisperM8-Tab bleibt ein stabiler lokaler Arbeitskontext, auch wenn der Claude-Code-Prozess beendet wurde oder WhisperM8 per Force Quit beendet wurde.
- Der zuletzt sichtbare Terminalzustand bleibt nach Neustart als read-only Snapshot sichtbar.
- Wenn der Nutzer innerhalb von Claude Code `/resume` nutzt und dadurch in eine andere Claude-Konversation wechselt, aktualisiert WhisperM8 die gespeicherte `externalSessionID` auf die tatsaechlich aktive Claude-Session.
- `Resume` startet danach die richtige Claude-Konversation mit `claude --resume <id>`.
- Wenn die Claude-Session nicht mehr existiert, bleibt der Tab erhalten und bietet kontrollierte Recovery-Aktionen statt einer rohen oder blockierenden Fehlermeldung.

## Verifizierte Grundlagen

Offizielle Claude-Code-Dokumentation:

- `claude --resume`/`-r` resumed eine Session per ID oder Name bzw. zeigt einen Picker; `--session-id` setzt eine konkrete UUID fuer eine neue Konversation. Siehe CLI-Reference: <https://code.claude.com/docs/en/cli-reference>
- `/resume [session]` resumed innerhalb einer laufenden interaktiven Claude-Code-Session per ID oder Name bzw. oeffnet den Picker. Siehe Commands-Reference: <https://code.claude.com/docs/en/commands>
- Claude-Code-Hooks erhalten unter anderem `session_id`, `transcript_path`, `cwd` und `hook_event_name`. Siehe Hooks-Reference: <https://code.claude.com/docs/en/hooks>
- `SessionEnd` hat den Grund `resume`, wenn per interaktivem `/resume` in eine andere Session gewechselt wird. Derselbe Abschnitt beschreibt `transcript_path` und den Session-End-Hook als Side-Effect-Hook ohne Decision-Control.
- Lokaler Check mit `claude --help` bestaetigt fuer die installierte Version:
  - `-r, --resume [value]`
  - `--session-id <uuid>`
  - `--fork-session`
  - `-c, --continue`
  - `--no-session-persistence`

WhisperM8-Codebestand:

- `WhisperM8/Services/AgentCommandBuilder.swift`
  - Claude startet mit `--session-id` fuer eine vorbereitete neue Session und mit `--resume` fuer eine bereits gestartete Session.
- `WhisperM8/Views/AgentSessionDetailView.swift`
  - `prepareCommand()` baut den Launch-Command.
  - `bindExternalSessionIDWhenAvailable()` bindet eine frisch gestartete Session ueber Indexer-Retry.
  - `repairedSessionForLaunch()` versucht vor Launch eine stale Claude-ID zu reparieren.
- `WhisperM8/Services/AgentSessionIndexer.swift`
  - `ClaudeSessionIndexer` liest `~/.claude/projects/**/<session>.jsonl`, filtert `subagents` und Worktrees und extrahiert `sessionId`, `cwd`, Titel und Zeiten.
- `WhisperM8/Services/AgentSessionRuntimeWatcher.swift`
  - Der Watcher tracked nur die aktuell bekannte `externalSessionID`.
  - Wenn Claude innerhalb der TUI auf eine andere Session wechselt, bleibt der Watcher an der alten ID haengen.
- `WhisperM8/Views/AgentTerminalView.swift`
  - `AgentTerminalController` besitzt `LocalProcessTerminalView` und Prozessstatus nur im Speicher.
  - Es gibt aktuell keine persistente Terminal-Snapshot-Schicht fuer Scrollback/Sichtzustand.
- `WhisperM8/Models/AgentChat.swift`
  - `AgentChatSession.externalSessionID` ist der zentrale Pointer auf die resumebare externe Claude-/Codex-Session.

## Root Cause

Das Problem ist nicht nur "Session-ID fehlt", sondern ein Identitaetswechsel, den WhisperM8 nicht beobachtet.

1. WhisperM8 erzeugt oder resumed einen Claude-Prozess fuer einen lokalen `AgentChatSession.id`.
2. Der lokale Tab speichert `externalSessionID`.
3. Der Nutzer tippt in der Claude-TUI `/resume ...`.
4. Claude Code beendet aus Sicht der alten Session den Kontext mit `SessionEnd(reason: "resume")` und setzt den interaktiven Prozess auf eine andere Conversation fort.
5. WhisperM8 bekommt diesen Wechsel aktuell nicht als Ereignis. Der lokale Tab zeigt zwar den neuen Terminalinhalt, aber `AgentChatSession.externalSessionID` bleibt auf der alten oder nie gebundenen ID.
6. Nach Force Quit ist der SwiftTerm-Prozess und dessen In-Memory-Scrollback weg. Beim naechsten `Resume` nutzt WhisperM8 die falsche oder leere ID.

Wichtig: Ein Force Quit kann den lebenden PTY-/Claude-Prozess nicht wiederbeleben. Robustheit bedeutet daher:

- Prozess-Zustand nicht versprechen.
- Terminal-Anzeige als Snapshot persistieren.
- Claude-Conversation-ID waehrend der laufenden Session korrekt nachfuehren.
- Beim Neustart mit einer verifizierten ID oder einem Recovery-Pfad weiterarbeiten.

## Design-Entscheidungen

### 1. Lokale Tab-ID bleibt stabil, externe Claude-ID darf wechseln

`AgentChatSession.id` bleibt die lokale WhisperM8-Identitaet des Tabs. `externalSessionID` wird als "aktuell aktive externe Conversation" behandelt und darf aktualisiert werden, wenn Claude Code per `/resume` die Conversation wechselt.

Ergaenzung im Modell:

- `externalSessionID: String?` bleibt fuer Backward Compatibility.
- Optional neu:
  - `externalSessionIDHistory: [AgentExternalSessionBinding]`
  - `lastObservedTranscriptPath: String?`
  - `terminalSnapshotID: UUID?` oder Snapshot wird direkt ueber lokale Session-ID adressiert.

```swift
struct AgentExternalSessionBinding: Codable, Equatable, Hashable {
    var provider: AgentProvider
    var externalSessionID: String
    var transcriptPath: String?
    var observedAt: Date
    var source: AgentExternalSessionBindingSource
}

enum AgentExternalSessionBindingSource: String, Codable {
    case launch
    case indexer
    case claudeHook
    case transcriptActivity
    case manualRepair
}
```

Breaking-Change-Vermeidung: Alle neuen Felder optional decodieren oder mit Defaults migrieren.

### 2. Claude-Identitaet ueber Hooks + Transcript-Fallback erfassen

Primaerer Pfad: Hook-basierte Beobachtung.

- WhisperM8 startet Claude mit einem session-lokalen Hook-Setup, wenn moeglich ueber `--settings <temp-json>` oder eine andere isolierte Settings-Quelle.
- Der Hook schreibt kleine JSON-Events in eine WhisperM8-eigene Datei unter Application Support.
- Relevante Events:
  - `SessionStart`: speichere `session_id`, `transcript_path`, `cwd`, source.
  - `SessionEnd`: speichere `session_id`, `transcript_path`, `cwd`, `reason`. Bei `reason == "resume"` wird explizit markiert, dass ein Wechsel erwartet wird.
  - Optional `UserPromptSubmit`: nur zur Zeitkorrelation, nicht als Quelle fuer sensible Inhalte.

Warum Hooks:

- Claude Code dokumentiert `session_id` und `transcript_path` als Common Hook Fields.
- Claude Code dokumentiert `SessionEnd(reason: "resume")` fuer interaktives `/resume`.
- Damit laesst sich der Session-Wechsel erkennen, ohne Terminal-Screen-Text zu parsen.

Fallback-Pfad: Transcript-Aktivitaet.

- `ClaudeSessionIndexer` bzw. ein neuer `ClaudeActiveSessionTracker` beobachtet fuer das Projektverzeichnis die zuletzt modifizierten JSONL-Dateien.
- Wenn nach einem lokalen `/resume` die aktive Datei wechselt, aktualisiert der Tracker die lokale Session-ID-Bindung konservativ.
- Matching-Kriterien:
  - gleicher kanonischer `cwd`
  - nicht Worktree, nicht `subagents`
  - mtime nach lokalem Prozessstart oder nach beobachtetem `SessionEnd(reason: "resume")`
  - optional Terminal-Snapshot-Tail/User-Prompt-Korrelation
  - keine Aktualisierung, wenn mehrere Kandidaten gleich wahrscheinlich sind

### 3. Terminal-Snapshot statt Prozess-Persistenz

WhisperM8 soll nicht versuchen, einen Force-Quit-gekilled PTY-Prozess zu rekonstruieren. Stattdessen wird der Terminalzustand als Snapshot persistiert.

**[v2] Alternative tmux/dtach geprueft und abgelehnt** - siehe Plan-Update v2 Abschnitt oben.

Minimalmodell:

```swift
struct AgentTerminalSnapshot: Codable, Equatable {
    var localSessionID: UUID
    var provider: AgentProvider
    var externalSessionID: String?
    var cwd: String
    var capturedAt: Date
    var terminalColumns: Int?
    var terminalRows: Int?
    var processWasRunning: Bool
    var exitCode: Int32?
    var visibleText: String
    var scrollbackText: String
    var ansiReplayDataPath: String?
}
```

Persistenz:

- Datei je lokaler Session:
  - `~/Library/Application Support/WhisperM8/agent-terminal-snapshots/<localSessionID>.json`
- Atomisch schreiben.
- Throttling: hoechstens alle 1-2 Sekunden und immer bei:
  - Prozessstart
  - Prozessende
  - Tabwechsel
  - App geht in Hintergrund
  - `applicationWillTerminate`

Capture-Strategie:

- Bevorzugt SwiftTerm-API fuer Scrollback/Buffer verwenden, falls verfuegbar.
- Wenn SwiftTerm keinen stabilen Export anbietet:
  - Output-Recording im `AgentTerminalController`/PTY-Delegate einbauen.
  - Die letzten N KiB oder N Zeilen als Plain Text halten.
  - ANSI-Replay erst spaeter, falls notwendig.

**[v2] Konkrete SwiftTerm-API**: `LocalProcessTerminalView.getTerminal()` liefert `Terminal`; darauf `getText(start: Position, end: Position) -> String` fuer Visible-Slice und `buffer.lines` fuer Scrollback. Aktuell weder verwendet noch ueberschrieben in `AgentTerminalView.swift` - keine Konflikte zu erwarten. Empfohlener Snapshot-Call:

```swift
let term = view.getTerminal()
let topRow = max(0, term.buffer.yBase - maxScrollbackLines)
let bottomRow = term.buffer.yBase + term.buffer.rows
let scrollback = term.getText(
    start: Position(col: 0, row: topRow),
    end: Position(col: term.cols, row: bottomRow)
)
```

ANSI-Replay als optionaler Layer 2: PTY-Output am `LocalProcessTerminalViewDelegate`-Layer mitschneiden, in `ansiReplayDataPath` schreiben.

**[v2] Snapshot-Schreib-Strategie verfeinert**: dirty-flag + 500 ms idle-debounce statt 1-2 s throttle. Garantierter Flush bei:
- Prozessstart und Prozessende
- Tab-Wechsel (`AgentChatsView` selection change)
- App geht in Hintergrund (`NSApplication.willResignActiveNotification`)
- `applicationWillTerminate` (Best-Effort)

Groessenbudget zweischichtig:
- `visibleText`: max 8 KiB (letzte ~2000 Zeichen, fuer schnellen UI-Render in Snapshot-Ansicht)
- `scrollbackText`: max 64 KiB (fuer Recovery-Ansicht)
- `ansiReplayDataPath`: optional, max 32 KiB (Phase 7+)

Total pro Session: max ~100 KiB. Bei 50 Sessions: max 5 MB.

Wichtig: Snapshot ist Anzeige-/Recovery-Zustand, nicht die Wahrheit fuer Claude-Konversationen. Die Wahrheit fuer Resume bleibt die Claude-Session-ID und das JSONL-Transcript.

### 4. Offline-Terminal-Ansicht statt Summary-only

Wenn kein Controller laeuft, soll `AgentSessionDetailView` nicht ausschliesslich `ClosedSessionSummaryView` zeigen. Stattdessen:

- Wenn `AgentTerminalSnapshotStore` einen Snapshot fuer `session.id` hat:
  - Zeige eine read-only terminalartige Ansicht mit dem letzten Terminalinhalt.
  - Darunter/oben kleine Statuszeile: "Terminal nicht verbunden. Resume startet Claude Code erneut."
  - Header-Button bleibt `Resume` oder `Start`, je nach `externalSessionID`.
- Wenn kein Snapshot vorhanden ist:
  - Fallback auf bestehende Summary-Ansicht.

Keine UI-Neugestaltung: Optik an bestehende `AgentTerminalPalette`/`AgentTheme` anlehnen.

## Umsetzungsschritte

### Phase 0: Charakterisierung und Sicherheitsnetz

Ziel: Den aktuellen Bug reproduzierbar machen.

Tests/Checks:

- Unit-Test fuer `AgentCommandBuilder` beibehalten:
  - Claude Resume nutzt `--resume <id>`.
  - Claude neuer Tab mit vorgesehener ID nutzt `--session-id <uuid>`.
- Neuer Store-Test:
  - Eine lokale Session hat `externalSessionID = old`.
  - Ein Hook-/Tracker-Event meldet `new`.
  - Store aktualisiert auf `new` und erhaelt den lokalen Tab.
- Neuer Regression-Test:
  - `repairResumeStateBeforeLaunch` darf manuell erstellte Tabs ohne valide ID nicht loeschen.
- Manueller Repro-Check:
  1. Neuen Claude-Tab in WhisperM8 starten.
  2. In Claude `/resume <andere-session>` ausfuehren.
  3. Force Quit.
  4. Relaunch.
  5. Snapshot sichtbar, `Resume` nutzt die neue externe ID.

### Phase 1: TerminalSnapshotStore einfuehren

Dateien:

- Neu: `WhisperM8/Models/AgentTerminalSnapshot.swift`
- Neu: `WhisperM8/Services/AgentTerminalSnapshotStore.swift`
- Tests in `Tests/WhisperM8Tests/AgentChatsTests.swift` oder neuer Testdatei.

Aufgaben:

- Snapshot-Modell einfuehren.
- Store mit atomischem Save/Load/Delete.
- Begrenzung:
  - max Textlaenge pro Snapshot, z. B. 256 KiB Plain Text.
  - alte Snapshots fuer geloeschte Sessions spaeter aufraeumen.
- Tests fuer:
  - Save/Load roundtrip
  - korruptes Snapshot-JSON wird ignoriert, nicht crashen
  - Text wird begrenzt und bleibt UTF-8-gueltig

Risiko: niedrig, weil noch nicht in UI verdrahtet.

### Phase 2: Terminalausgabe erfassen

Dateien:

- `WhisperM8/Views/AgentTerminalView.swift`
- optional neu: `WhisperM8/Services/AgentTerminalOutputRecorder.swift`

Aufgaben:

- Capture-Punkt im `AgentTerminalController` finden.
- Bevorzugt SwiftTerm-Delegate/API fuer Screen/Scrollback nutzen.
- Wenn keine passende API existiert:
  - PTY-Output als Plain Text mitschneiden.
  - ANSI-Sequenzen entweder entfernen oder spaeter in `ansiReplayDataPath` speichern.
- Snapshot-Schreiben throttlen.
- Bei `processTerminated` finalen Snapshot schreiben.

Tests:

- Pure Tests fuer `AgentTerminalOutputRecorder`.
- Keine harten UI-Snapshot-Tests als Voraussetzung.

Risiko: mittel, weil Terminal-Rendering nicht beeinflusst werden darf. Der Recorder darf niemals Input/Output blockieren.

### Phase 3: Offline-Terminal-Snapshot anzeigen

Dateien:

- `WhisperM8/Views/AgentSessionDetailView.swift`
- Neu: `WhisperM8/Views/AgentTerminalSnapshotView.swift`
- optional `WhisperM8/Views/ClosedSessionSummaryView.swift`

Aufgaben:

- Wenn kein laufender Controller existiert, zuerst Snapshot laden.
- Snapshot in read-only Terminal-Optik darstellen.
- Summary kann darunter bleiben oder ueber einen kleinen Bereich abrufbar bleiben.
- Fehler-/Recovery-Text klar formulieren:
  - "Terminal ist nicht verbunden."
  - "Resume startet Claude Code erneut."
  - Keine rohe `No conversation found...`-Meldung als dauerhafter Hauptzustand.

Tests/Smoke:

- Geschlossene Session mit Snapshot zeigt Snapshot.
- Geschlossene Session ohne Snapshot zeigt bestehende Summary.
- Button-Logik fuer Start/Resume bleibt unveraendert.

Risiko: niedrig bis mittel, UI-nah.

### Phase 4: ClaudeSessionBindingStore und Hook-Bridge

> **[v2] Reihenfolge-Hinweis**: In der ueberarbeiteten Reihenfolge wird **diese Phase nach Phase 5 (Transcript-Tracker) umgesetzt**. Begruendung: Transcript-Tail-Mode funktioniert auch ohne Hooks und ist damit das robuste Fundament. Hook-Bridge ist dann eine reine Optimization-Schicht (Hook liefert SOFORT die externe ID, Transcript-Tracker liefert sie mit Latenz). Diese Phase bleibt inhaltlich wie unten beschrieben, wird aber zeitlich nach Phase 5 implementiert.

Dateien:

- Neu: `WhisperM8/Services/ClaudeSessionBindingEventStore.swift`
- Neu: `WhisperM8/Services/ClaudeHookSettingsBuilder.swift`
- `WhisperM8/Services/AgentCommandBuilder.swift`
- `WhisperM8/Views/AgentSessionDetailView.swift`
- `WhisperM8/Services/AgentSessionStore.swift`

Aufgaben:

- Einen session-lokalen Hook-Output-Pfad erzeugen:
  - `~/Library/Application Support/WhisperM8/claude-session-events/<localSessionID>.jsonl`
- Hook-Konfiguration fuer Claude-Launch bauen.
- Wenn technisch kompatibel, `--settings <temp-json>` an den Claude-Start haengen.

**[v2] `--settings` bestaetigt**: `claude --settings <file>` existiert seit 1.x und mergt ON TOP von User- und Project-Settings. Hooks darin sind additiv zu User-Hooks, nicht ersetzend. Wenn ein User globale `SessionStart`-Hooks hat, feuern beide - das ist OK, weil unser Hook passiv schreibt.

**[v2] Hook-Settings-Datei sichern**:
- Pfad: `~/Library/Application Support/WhisperM8/claude-hooks/<localSessionID>.json`
- POSIX-Permissions: 0600
- Cleanup: bei naechstem Launch fuer dieselbe `localSessionID` ueberschreiben; auf App-Terminate Best-Effort-Loeschung; Retention-Job in Phase 7 entfernt verwaiste Dateien

**[v2] Hook ist Helper-Binary statt Inline-Shell**: Inline-Shell-Hooks mit `jq`/`tee` sind fragil bei Spaces/Umlauten in Pfaden und benoetigen `jq`. Empfohlen: WhisperM8 shippt ein winziges Executable `whisperm8-claude-hook` (~30 Zeilen Swift) als zusaetzliches Target in `Package.swift`/Xcode. Aufgabe:

```swift
// CLI: whisperm8-claude-hook <event-file-path>
// Stdin: JSON-Event von Claude (CommonHookFields + payload)
// Aktion: O_APPEND atomic write einer Zeile, exit 0
@main struct WhisperM8ClaudeHook {
    static func main() {
        guard CommandLine.arguments.count >= 2 else { exit(0) }
        let path = CommandLine.arguments[1]
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let line = String(data: input, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { exit(0) }
        let lineWithNewline = line + "\n"
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        if fd >= 0 { _ = lineWithNewline.withCString { write(fd, $0, strlen($0)) }; close(fd) }
        exit(0) // never block Claude
    }
}
```

Vorteile: keine externen Tool-Dependencies, atomic Append, definiertes Exit-Verhalten, robust gegen Pfade mit Spaces/Umlauten. Wird im App-Bundle bei `Contents/MacOS/whisperm8-claude-hook` ausgeliefert.

**[v2] Settings-Datei Beispielinhalt**:

```json
{
  "hooks": {
    "SessionStart": [{"matcher":".*","hooks":[
      {"type":"command","command":"\"/Applications/WhisperM8.app/Contents/MacOS/whisperm8-claude-hook\" \"/Users/.../claude-session-events/<localID>.jsonl\""}
    ]}],
    "SessionEnd": [{"matcher":".*","hooks":[
      {"type":"command","command":"\"/Applications/WhisperM8.app/Contents/MacOS/whisperm8-claude-hook\" \"/Users/.../claude-session-events/<localID>.jsonl\""}
    ]}]
  }
}
```

Der Helper-Hook sieht durch das stdin-Payload automatisch, ob `SessionStart` oder `SessionEnd` (Feld `hook_event_name`).

**[v2] Hook-Silence-Detection**: Nicht jede Claude-Installation hat Hooks aktiv (z. B. wenn User globale Settings die unsere Settings invalidieren, oder bei sehr alter Claude-Version). Detection:

```swift
class ClaudeSessionBindingTracker {
    func startTracking(localID: UUID, projectCwd: String) {
        // 1. Hook-Mode aktivieren
        // 2. Nach 5 s pruefen, ob Event-Datei nicht leer ist
        // 3. Falls leer aber Terminal hat Output -> Hook-Mode failed
        //    -> fallback to ClaudeActiveSessionTracker (Phase 5)
        //    -> log "binding_hook_silent"
    }
}
```

Damit ist Hook-Bridge robust gegen alle Faelle, in denen `--settings` ignoriert wird.
- Hook schreibt pro Event eine JSONL-Zeile:

```json
{
  "localSessionID": "<uuid>",
  "observedAt": "2026-05-11T...",
  "session_id": "claude-session-id",
  "transcript_path": "/Users/.../.claude/projects/.../<id>.jsonl",
  "cwd": "/Users/.../repo",
  "hook_event_name": "SessionStart",
  "reason": null
}
```

- Event-Store liest neue Zeilen und aktualisiert `AgentChatSession.externalSessionID`.
- Bei `SessionEnd(reason: "resume")` nicht als Fehler markieren, sondern als erwarteten Sessionwechsel.
- Auf das naechste `SessionStart` oder Transcript-Aktivitaet warten und dann neu binden.

Wichtige Guardrails:

- Keine globalen User-Settings ueberschreiben.
- Keine Projekt-`.claude/settings.json` ungefragt veraendern.
- Hook-Script oder Inline-Command muss robust gegen Spaces in Pfaden sein.
- Wenn Hooks deaktiviert oder nicht verfuegbar sind, muss Fallback Phase 5 greifen.

Tests:

- Hook-Event-Parsing.
- `SessionStart` aktualisiert `externalSessionID`.
- `SessionEnd(reason: "resume")` loescht den Tab nicht.
- Ungueltige/kaputte Event-Zeilen werden ignoriert.

Risiko: mittel. Hauptfrage ist die saubere isolierte Hook-Injektion ueber Claude-Settings.

### Phase 5: Active-Transcript-Fallback fuer interaktives `/resume`

> **[v2] Reihenfolge-Hinweis**: In der ueberarbeiteten Reihenfolge wird **diese Phase VOR Phase 4 implementiert**. Begruendung: Transcript-Tail funktioniert auch ohne Claude-Hooks (und ist die einzige Option fuer Codex). Damit haben wir ein robustes Fundament; Hook-Bridge wird dann eine Optimization-Schicht ohne Critical Path.

Dateien:

- Neu: `WhisperM8/Services/ClaudeActiveSessionTracker.swift`
- `WhisperM8/Services/AgentSessionIndexer.swift`
- `WhisperM8/Services/AgentSessionRuntimeWatcher.swift`
- `WhisperM8/Services/AgentSessionStore.swift`

Aufgaben:

- Fuer laufende Claude-Sessions pro Projekt alle relevanten JSONL-Dateien in `~/.claude/projects/<encoded-cwd>/` beobachten.
- Wenn eine neue oder juenger modifizierte JSONL-Datei nach lokalem Prozessstart auftaucht, als Kandidat behandeln.
- Kandidat nur binden, wenn:
  - gleicher kanonischer Projektpfad
  - nicht Worktree/subagent
  - klare zeitliche Dominanz gegenueber anderen Kandidaten
  - optional Hook-Event `SessionEnd(reason: "resume")` oder Terminal-Input `/resume` als starker Hinweis vorliegt
- `AgentSessionRuntimeWatcher` muss bei neuer ID seine `transcriptURL` wechseln koennen.

Tests:

- Zwei Claude-JSONL-Dateien im selben Projekt; spaeter aktive Datei gewinnt.
- Ambigue Kandidaten fuehren zu keiner automatischen Rebindung.
- Rebinding aktualisiert RuntimeWatcher.
- Scan erzeugt keinen doppelten WhisperM8-Tab fuer dieselbe lokale Session.

Risiko: mittel bis hoch wegen Heuristik. Deshalb konservativ binden und bei Unsicherheit UI-Recovery anbieten.

### Phase 6: Resume-Recovery vor Launch verbessern

**[v2] Ambiguous-Rebind UI**: Wenn Transcript-Tracker (Phase 5) oder Recovery-Repair zwei oder mehr Kandidaten findet, darf nicht silent nichts passieren. Inline-Picker im Header der Detail-View:

```
Wir konnten den Chat nicht eindeutig zuordnen.
Welche Claude-Session gehoert zu diesem Tab?

[ Title A           | 11:34 | "kannst du die..." ]
[ Title B           | 11:28 | "fix the bug..."   ]
[ Neue Session starten ]
```

Komponente: `AgentSessionAmbiguousRebindPicker` in einer kleinen neuen View. Auswahl triggert `setExternalSessionID` + Reload des Snapshots. Bei "Neue Session" wird `externalSessionID = nil` + Launch via `--session-id <uuid>`.

Dateien:

- `WhisperM8/Services/AgentSessionStore.swift`
- `WhisperM8/Views/AgentSessionDetailView.swift`
- `WhisperM8/Views/ClosedSessionSummaryView.swift`

Aufgaben:

- `repairedSessionForLaunch()` soll zuerst Binding-Events und Snapshot-Metadaten auswerten, dann Indexer.
- Wenn gespeicherte ID fehlt oder nicht mehr existiert:
  - Tab behalten.
  - Snapshot zeigen.
  - Aktionen anbieten:
    - "Sessions scannen"
    - "Beste Claude-Session suchen"
    - "Neue Claude-Session in diesem Tab starten"
- Kein automatisches Reset auf neue Session, wenn dadurch der Nutzer glaubt, er resume denselben Chat.
- Wenn eine eindeutige Ersatz-ID gefunden wird, sichtbar loggen und binden.

Tests:

- Fehlende ID + eindeutiger Hook-/Indexer-Kandidat -> bindet Kandidat.
- Fehlende ID + kein Kandidat -> kein Tabverlust, kein Crash, kein roher CLI-Fehler als Hauptzustand.
- Alte funktionierende Resume-ID bleibt unveraendert.

Risiko: mittel, weil UX und Datenmodell zusammenspielen.

### Phase 7: Cleanup, Telemetrie, Retention

Dateien:

- `WhisperM8/Services/Logger.swift`
- Snapshot/Event-Stores
- optional Settings/Debug-Bereich

Aufgaben:

- Logs:
  - `claude_binding_event`
  - `claude_binding_rebound`
  - `terminal_snapshot_saved`
  - `terminal_snapshot_restore`
  - `resume_recovery_failed`
- Retention:
  - Snapshot-Dateien geloeschter Sessions entfernen.
  - Event-JSONL begrenzen oder rotieren.
- Debug-Info fuer Support:
  - lokale Session-ID
  - externe Session-ID
  - transcript path
  - snapshot timestamp

Risiko: niedrig.

## Tests und manuelle Abnahme

Automatisierte Tests:

- `swift test`
- `make build`
- Store-/Parser-Tests fuer neue Modelle.
- Regression fuer bestehende `AgentCommandBuilder`-Resume-Argumente.
- RuntimeWatcher-Test fuer dynamischen Transcript-Wechsel.

Manuelle Abnahme:

1. Neuer Claude-Tab in WhisperM8, normaler Prompt, App beenden, Resume.
2. Neuer Claude-Tab, in Claude `/resume <existing-session>` ausfuehren, Force Quit, Relaunch, Resume.
3. Laufender Claude-Tab, Tab in WhisperM8 wechseln, zurueck, Terminalinhalt bleibt live.
4. Claude mit `/exit` verlassen, Tab bleibt mit Snapshot sichtbar.
5. Claude-Transcript-Datei manuell umbenennen/entfernen, Resume zeigt Recovery statt rohem Broken-State.
6. Mehrere Projekte mit je einem Claude-Tab: keine Cross-Bindings.
7. Worktree- und Subagent-Transcripts werden weiterhin nicht als Hauptsessions importiert.

## Nicht-Ziele

- Kein Versuch, einen Force-Quit-gekilled PTY-Prozess weiterlaufen zu lassen.
- Kein Redesign der Sidebar oder des Header-Layouts.
- Keine Aenderung an Claude-Code-Transcripts.
- Keine globale Veraenderung der Claude-Code-User-Settings ohne explizite Nutzeraktion.
- Kein sofortiges ANSI-perfect Terminal-Replay als Pflicht. Plain Text Snapshot reicht fuer Phase 1.

## Offene technische Fragen fuer die Umsetzung

1. Welche SwiftTerm-API ist fuer stabilen Scrollback-/Screen-Export verfuegbar?
   - **[v2] Antwort**: `LocalProcessTerminalView.getTerminal()` liefert das `Terminal`-Objekt; darauf `getText(start: Position, end: Position)` fuer Visible-Slice und `buffer.lines` plus `buffer.yBase`/`buffer.rows` fuer Scrollback. Verwendet aktuell nicht im Code (`rg -n "getText\\|buffer\\." WhisperM8/Views/AgentTerminalView.swift` ist leer) - kein Konflikt.

2. Laesst sich Claude-Code-Hook-Konfiguration sauber pro Prozess via `--settings <json>` injizieren, ohne User- oder Projekt-Settings zu mutieren?
   - **[v2] Antwort**: Ja. `claude --settings <file>` existiert seit 1.x und mergt ON TOP von User/Project-Settings (additiv, nicht ersetzend). Hooks in der Datei sind additiv zu User-Hooks. Unsere temporaere Settings-Datei liegt in `~/Library/Application Support/WhisperM8/claude-hooks/<localID>.json` mit POSIX 0600, ueberschrieben pro Launch.

3. Feuert nach interaktivem `/resume` im selben Prozess zuverlaessig ein neuer `SessionStart` mit neuer `session_id`?
   - **[v2] Status**: Laut Claude-Doku ja - `SessionEnd(reason: "resume")` fuer alte Session, dann `SessionStart` fuer neue. Aber: aktuell unverifiziert auf der konkret installierten Version. **TODO Phase 0**: integrationstest mit `claude` in einem Sandbox-Verzeichnis, der `/resume` triggert und unsere Hook-Event-Datei nachschaut. Falls negativ -> Transcript-Tail-Mode (Phase 5-neu) ist zwingend.

4. Soll WhisperM8 beim Rebinding den Titel automatisch auf den neuen Claude-Titel aktualisieren oder nur, wenn der Titel noch generisch ist?
   - **[v2] Empfehlung**: Nur bei generischem Titel (heuristik: `"Claude Chat"`, `"Codex Chat"`, leer, oder `titleIsAutoGenerated == true`). Manuell vergebene Titel bleiben unveraendert - User-Intent gewinnt.

5. Wie gross darf ein Terminal-Snapshot werden, bevor App-Start oder Workspace-Load spuerbar leiden?
   - **[v2] Empfehlung**: max 100 KiB pro Session (siehe Phase-3 Snapshot-Strategie). Lazy-Load: Snapshot wird nur geladen, wenn Session sichtbar/aktiviert wird, nicht beim Workspace-Boot. Cold-Start zeigt also Sidebar sofort, Snapshot wird beim ersten Klick auf Tab geladen (< 50 ms typisch).

6. **[v2] NEU: Wie verhalten sich Multi-Tab Claude-Launches im selben Projekt zueinander?**
   - Zwei WhisperM8-Tabs starten zeitgleich Claude im selben `cwd`. Beide bekommen via `--settings` ihre eigene Settings-Datei mit ihrem `<localID>.jsonl`-Hook-Pfad. Settings-Files sind pro Launch unabhaengig. Transcript-Tracker (Phase 5-neu) muss aber Multi-Tab-Disambiguation koennen: Welche der zwei neuen Transcripts gehoert zu welchem Tab? Heuristik: Hook-SessionStart-Event mit `session_id` ist primaer; ohne Hook entscheiden ueber Launch-Timestamp-Korrelation (juengstes Transcript des juengsten Launches).

7. **[v2] NEU: Codex-Coverage?**
   - Codex CLI hat aktuell kein Hook-API. Fuer Codex laeuft Phase 5 (Transcript-Tail) alleine. `~/.codex/sessions/.../rollout-*.jsonl` wird aehnlich beobachtet. Falls Codex spaeter Hooks bekommt, kann Phase 5-neu wieder als Optimization-Schicht zugeschaltet werden.

## Empfehlung fuer Claude-Code-Implementierung

Die Umsetzung sollte nicht als ein grosser Refactor erfolgen. Beste Reihenfolge:

1. `AgentTerminalSnapshotStore` + Tests.
2. Read-only Snapshot-UI fuer geschlossene Sessions.
3. Hook-Event-Store und minimaler Hook-Prototyp.
4. Store-Rebinding durch Hook-Events.
5. Transcript-Fallback fuer `/resume`, konservativ und testgetrieben.
6. Recovery-UX und Retention.

Der wichtigste No-Breaking-Change-Grundsatz: Lokale WhisperM8-Tabs duerfen durch fehlende oder stale Claude-IDs niemals automatisch verschwinden. Die App darf hoechstens die externe Bindung als unsicher markieren und dem Nutzer kontrollierte Wiederherstellung anbieten.

## [v2] Aktualisierte Empfehlung (ueberschreibt obige Reihenfolge)

1. `AgentTerminalSnapshotStore` + Tests (Phase 1).
2. Output-Capture mit Idle-Debounce (Phase 2).
3. Read-only Snapshot-UI fuer geschlossene Sessions (Phase 3).
4. **`ClaudeActiveSessionTracker` (Transcript-Tail) + Multi-Tab-Disambiguation** (Phase 5-neu - VOR Hooks).
5. **`whisperm8-claude-hook` Helper-Binary + Hook-Bridge als Optimization** (Phase 4-neu - NACH Transcript-Tail).
6. Ambiguous-Rebind-Picker + Resume-Recovery (Phase 6).
7. Retention, Telemetrie, Cleanup (Phase 7).

Damit ist das System nach Schritt 4 bereits voll funktionsfaehig (ohne Hooks); Schritt 5 reduziert die Erkennungs-Latenz von ~1-2 s auf instant.

## [v2] Telemetrie-Schema

Konsistent mit `subsystem == "com.whisperm8.app"` (siehe CLAUDE.md). Kategorien:

| Category | Events |
|----------|--------|
| `terminal.snapshot` | `snapshot_saved` (size, source), `snapshot_loaded`, `snapshot_corrupted`, `snapshot_pruned` |
| `claude.binding`   | `binding_launch_id_set`, `binding_hook_event_received`, `binding_hook_silent` (timeout fallback), `binding_transcript_match`, `binding_ambiguous`, `binding_rebound` (old -> new) |
| `claude.recovery`  | `recovery_repair_attempted`, `recovery_picker_shown`, `recovery_user_chose`, `recovery_failed_no_candidates` |

Jeder Event mit `localSessionID` (Forensik), keine PII, kein Transcript-Inhalt.
