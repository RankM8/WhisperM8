# Claude-Code-CLI-Integration — Integrations-Audit (Codex)

**Datum:** 2026-07-18  
**Geprüfte CLI:** `claude` 2.1.214 (`/Users/giulianocosta/.local/bin/claude`)  
**Methode:** Code- und Testanalyse, Read-only-Inspektion von `~/.claude/projects/`, `~/.claude/jobs/`, `~/.claude/settings.json`, `claude --help`, den Help-Ausgaben der Background-Subcommands sowie ausgewählten Strings des lokal installierten Binaries. Es wurden keine Claude-Dateien verändert und keine Sessions gestartet. Der vorgesehene Kartenordner `01-subsysteme/` war zum Prüfzeitpunkt leer; die genannten Karten konnten daher nicht einbezogen werden.

## Verifizierte Negativ-Checks

- Die aktuelle CLI akzeptiert `--settings`, `--bg`, `--resume`, `--fork-session`, `--agent` und `--permission-mode`. Auch die in der Haupt-Hilfe nicht gelisteten Subcommands `attach`, `logs`, `stop`, `respawn` und `rm` existieren in 2.1.214 und ihre erwartete Grundform (`claude <subcommand> <id>`) stimmt mit dem Builder überein.
- Die acht registrierten Hook-Events existieren im aktuellen Hook-Schema. `matcher: ".*"` ist für die matchbaren Events gültig und wird bei `UserPromptSubmit`/`Stop` laut aktueller Referenz lediglich ignoriert. Die Struktur `hooks -> Event -> [{ matcher, hooks: [{ type, command }] }]` stimmt mit dem aktuellen Schema überein ([Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)).
- `claude --help` beschreibt `--settings` ausdrücklich als „additional settings“. Die Bridge ersetzt die User-Settings daher nicht. Die reale `~/.claude/settings.json` nutzt parallel dasselbe Hook-Grundschema.
- Der Foreground-PTY-Pfad merged `AgentLaunchCommand.environmentOverrides` korrekt in das bereinigte Login-Shell-Environment (`AgentTerminalView.swift:758-765`).

## F1: Nicht-PTY-Pfade umgehen das gewählte Claude-Account-Profil

**Schweregrad:** kritisch  
**Fundort:** `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:47-59`; `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:223-258`; `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:124-171`; `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:132-146`; `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-40`; `WhisperM8/Services/AgentChats/SupervisorJobReader.swift:33-38`

**Szenario (Auslöser → Wirkung):** Der User wählt ein Zusatzprofil und dispatcht einen Background-Agent oder WhisperM8 führt Auto-Naming/Zusammenfassung für eine Profil-Session aus. Der Background-Stub wird ohne `claudeProfileName` angelegt; `ProcessRunner` kann keine Environment-Overrides entgegennehmen; sein Default-Environment entfernt `CLAUDE_CONFIG_DIR` sogar ausdrücklich. Spawn, `logs`/`stop`/`respawn`/`rm`, Health-Check und Headless-Postprocessing laufen damit unter `main`. Das kann den falschen Account belasten, bei ausgeloggtem/limitiertem Main-Account scheitern und legt Job/Transcript im falschen Config-Root ab. Würde der Spawn allein korrigiert, blieben Lifecycle und `SupervisorJobReader` weiterhin auf `~/.claude/jobs` fest verdrahtet und könnten Profil-Jobs nicht verwalten.

**Beweis:**

```swift
// AgentChatsView+BackgroundAgents.swift:47-59
session = try store.createSession(
    provider: .claude,
    projectPath: project.path,
    ...
    backgroundPermissionMode: request.permissionMode
) // kein claudeProfileName
```

```swift
// BackgroundAgentSpawner.swift:223-229, 255-258
protocol ProcessRunner {
    func run(executable: String, arguments: [String],
             workingDirectory: String, timeout: TimeInterval) async throws -> ProcessRunResult
}
var env = LoginShellEnvironment.shared.processEnvironment()
env["NO_COLOR"] = "1"
process.environment = env
```

```swift
// LoginShellEnvironment.swift:110-119
// Account-Routing läuft ausschließlich über die expliziten per-Launch-Overrides
env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
```

`AgentTitleGenerator.generate` und `AgentSummaryGenerator.generate` übergeben ebenfalls nur `LoginShellEnvironment.shared.processEnvironment()` und kennen den Profilstempel der Session nicht. Die offizielle aktuelle Dokumentation bestätigt die Tragweite: `CLAUDE_CONFIG_DIR` verlegt alle Settings, Credentials, Session-History und Plugins und ist explizit für parallele Accounts vorgesehen ([Claude Code Environment Variables](https://code.claude.com/docs/en/env-vars), [Claude directory](https://code.claude.com/docs/en/claude-directory)).

**Fix-Vorschlag:** Background-Sessions beim Erstellen mit `activeProfileNameOrNil()` stempeln. `ProcessRunner.run` um explizite Environment-Overrides erweitern und sie in Spawn, Lifecycle und Health-Check wie im PTY-Pfad mergen. Lifecycle-Aufrufer müssen den Session-Stempel mitgeben. `SupervisorJobReader`/Tracker müssen den passenden `<configDir>/jobs`-Root lesen. Auto-Namer und Summarizer müssen den Profilstempel bis zum Generator durchreichen; alternativ für Postprocessing einen bewusst konfigurierten Account verwenden und dies in der UI transparent machen.

**Konfidenz:** hoch — alle betroffenen Env- und Call-Pfade sind direkt belegt; die aktuelle Claude-Dokumentation bestätigt, dass der Config-Root auch Auth, Jobs und Session-History bestimmt.

## F2: Headless-Postprocessing erzeugt persistente Junk-Chats und verschmutzt den Index

**Schweregrad:** hoch  
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:132-146`; `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-40`; `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:28-38`; `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:43-50,67-99`

**Szenario (Auslöser → Wirkung):** Nach einem Turn oder Session-Ende startet WhisperM8 `claude -p` für Titel bzw. Zusammenfassung. Es fehlt `--no-session-persistence`, und `AgentHeadlessCLI` setzt kein `currentDirectoryURL`. Der Subprozess erbt deshalb das cwd der App (real: `/`) und Claude persistiert jeden internen Hilfsaufruf als normale Session unter `~/.claude/projects/-/`. Der unselektive Claude-Indexer nimmt diese Dateien später als User-Chats auf. Ergebnis: falsches Projekt `/`, hunderte Junk-Sessions, langsamere Scans und Konkurrenz um das globale Index-Limit.

**Beweis:**

```swift
// AgentSessionAutoNamer.swift:139-146
case .claude:
    args = ["-p", prompt, "--output-format", "text"]
...
let env = LoginShellEnvironment.shared.processEnvironment()
let stdout = try await runner(executable, args, env)
```

```swift
// AgentHeadlessCLI.swift:34-38
let process = Process()
process.executableURL = executable
process.arguments = arguments
process.environment = environment
// kein currentDirectoryURL
```

Read-only-Bestand am 2026-07-18:

```text
~/.claude/projects/-/*.jsonl: 356 Dateien
mit Auto-Namer-Prompt „Below is a short excerpt ...": 174
mit Summary-Prompt „Du fasst ... Coding-Agent-Session ...": 182
```

Die aktuelle CLI-Hilfe bietet genau den fehlenden Schalter: `--no-session-persistence` „Disable session persistence ... (only works with --print)“.

**Fix-Vorschlag:** Allen internen Claude-`-p`-Aufrufen `--no-session-persistence` mitgeben und ein explizites, unschädliches cwd setzen. Zusätzlich eine einmalige, eng signaturbasierte Migration für bereits erzeugte `/`-Hilfssessions vorsehen; nicht pauschal echte Sessions unter `/` löschen.

**Konfidenz:** hoch — Code, CLI-Hilfe und alle 356 realen Dateien korrelieren exakt (174 + 182).

## F3: CWD-Encoder weicht bei Unicode und langen Pfaden vom aktuellen Claude-Code-Format ab

**Schweregrad:** hoch  
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:318-332`; `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:372-385`; `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:434-445`

**Szenario (Auslöser → Wirkung):** Ein Projektpfad enthält Unicode-Buchstaben oder erzeugt einen sehr langen encodierten Namen. WhisperM8 lässt Unicode-Buchstaben/Ziffern stehen und kürzt nie; Claude 2.1.214 erlaubt nur ASCII-Alphanumerik und kürzt ab einer internen Grenze mit Hash-Suffix. Der Runtime-Watcher nutzt absichtlich keinen Glob-Fallback und findet das Live-Transcript nie. Besonders kritisch ist `moveTranscript`: Es verschiebt die Datei in das von WhisperM8 falsch berechnete Zielverzeichnis; der spätere `claude --resume` sucht im echten Claude-Verzeichnis und meldet „No conversation found“.

**Beweis:**

```swift
// AgentSessionTranscript.swift:320-331
for char in standardized {
    if char.isLetter || char.isNumber {
        result.append(char)       // Swift: auch ö, é, CJK usw.
    } else {
        result.append("-")
    }
}
```

Read-only aus dem Binary 2.1.214 extrahiert:

```text
function PA(e){let t=e.replace(/[^a-zA-Z0-9]/g,"-");
if(t.length<=zEt)return t;return`${t.slice(0,zEt)}-${s8m(e)}`}
function _3(){return rte.join(on(),"projects")}
function lV(e){return rte.join(_3(),PA(e))}
```

**Fix-Vorschlag:** Den aktuellen ASCII-Encoder und die Längen-/Hash-Regel kompatibel implementieren und mit Golden Tests für Unicode sowie überlange Pfade absichern. Solange der Hash nicht stabil repliziert ist, den Stage-1-Miss einmalig per flacher Session-ID-Suche auflösen und pro Session cachen. `moveTranscript` darf nicht selbst einen potenziell falschen Zielordner erfinden; Zielpfadlogik muss dieselbe verifizierte Implementierung verwenden wie Claude.

**Konfidenz:** hoch — App-Implementierung und Encoderfunktion des lokal installierten Binaries widersprechen sich direkt.

## F4: Worktree-/CWD-Wechsel können ein vorhandenes Transcript für Resume unsichtbar machen

**Schweregrad:** hoch  
**Fundort:** `WhisperM8/Services/AgentChats/AgentProjectPath.swift:9-20`; `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:345-400,403-419`; `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:52-61`; `WhisperM8/Views/AgentSessionDetailView.swift:538-557`

**Szenario (Auslöser → Wirkung):** Claude verschiebt/führt eine Session in einem Worktree weiter oder die Session wechselt ihr cwd. WhisperM8 kanonisiert Worktree-Pfade zurück auf das Basis-Repo. Der deterministische Lookup sucht dadurch im Basisordner. Der Fallback durchsucht zwar andere Projektordner, akzeptiert einen Kandidaten aber nur, wenn der **erste** `cwd`-Eintrag im JSONL exakt dem erwarteten kanonischen Pfad entspricht. Bei einer realen Session liegt die Datei im Worktree-encodierten Ordner, ihr erster cwd ist ein Unterverzeichnis und spätere Einträge zeigen erst auf Basis-Repo/Worktree. Der Fallback verwirft die richtige Datei; `transcriptExists` liefert `false`; der Resume-Guard blockiert einen tatsächlich vorhandenen Chat.

**Beweis:**

```swift
// AgentProjectPath.swift:11-15
let marker = "/.claude/worktrees/"
...
return String(standardizedPath[..<range.lowerBound])
```

```swift
// AgentSessionTranscript.swift:413-418
for line in text.split(...).prefix(200) {
    ... let cwd = obj["cwd"] as? String else { continue }
    return URL(fileURLWithPath: cwd).standardizedFileURL.path == expected
    // beendet die Prüfung beim ersten cwd, statt weitere cwd-Werte zu prüfen
}
```

Realer Read-only-Befund:

```text
Datei:
~/.claude/projects/-Users-giulianocosta-repos-heartbeat--claude-worktrees-monatsabschluss-fixes/
0fa9cd67-edc5-4eb3-8ad0-df31add5c88d.jsonl

früher cwd: /Users/giulianocosta/repos/heartbeat/berichte/monatsabschluss/2026-07
später cwd: /Users/giulianocosta/repos/heartbeat
später cwd: /Users/giulianocosta/repos/heartbeat/.claude/worktrees/monatsabschluss-fixes
```

**Fix-Vorschlag:** Session-ID bleibt der primäre Schlüssel. Beim Fallback alle bounded gelesenen `cwd`-Werte prüfen und Basis-Repo, Worktree sowie reale/standardisierte Pfade semantisch vergleichen; nicht beim ersten fremden cwd abbrechen. Alternativ den vom `SessionStart`-Hook gelieferten `transcript_path` persistieren und für Reader/Resume-Guard als verifizierten Pfad verwenden. Worktree-Transcripts dürfen im Indexer nicht allein anhand eines frühen cwd falsch klassifiziert werden.

**Konfidenz:** hoch — der reale Transcript-Verlauf reproduziert exakt die Codebedingung, die den korrekten Kandidaten verwirft.

## F5: Indexer-Fallback kann parallele Tabs an dieselbe Claude-Session binden

**Schweregrad:** hoch  
**Fundort:** `WhisperM8/Views/AgentSessionDetailView.swift:626-696`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:597-647`; `WhisperM8/Services/AgentChats/ClaudeActiveSessionTracker.swift:27-60`; `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`

**Szenario (Auslöser → Wirkung):** Zwei Chats werden nahezu gleichzeitig im selben Projekt gestartet und mindestens ein `SessionStart`-Hook ist verzögert/deaktiviert. Beide Retry-Loops scannen denselben Index. `bindLatestIndexedSession` nimmt jeweils schlicht den zuletzt aktiven Kandidaten nach einer einseitigen Zeituntergrenze. Es schließt IDs, die bereits an einen anderen lokalen Tab gebunden sind, nicht aus und behandelt mehrere Kandidaten nicht als mehrdeutig. Beide Tabs können daher dieselbe externe ID erhalten; der zweite reale Chat bleibt verwaist. Ein später eintreffender Hook heilt den betroffenen Tab nur, wenn genau dieses Event noch zugestellt wird.

**Beweis:**

```swift
// AgentSessionStore.swift:621-631
guard let indexed = indexedSessions
    .filter({
        $0.provider == provider
            && Self.canonicalProjectPath($0.cwd) == standardizedPath
            && $0.createdAt >= createdAt.addingTimeInterval(-5)
    })
    .sorted(by: { $0.lastActivityAt > $1.lastActivityAt })
    .first
```

Es gibt weder eine Obergrenze noch einen „bereits gebunden“-Guard. Die dafür vorhandene `ClaudeActiveSessionResolver`-Logik würde bei konkurrierenden Kandidaten `.ambiguous` liefern (`ClaudeActiveSessionTracker.swift:49-60`), wird von diesem Bindepfad aber nicht verwendet. Auch das Hook-Binding prüft nur `old != newID`, nicht eine Kollision mit anderen Workspace-Zeilen.

**Fix-Vorschlag:** Binding als atomare Zuordnung behandeln: Kandidaten relativ zum tatsächlichen Launch-Zeitpunkt in einem beidseitigen Fenster filtern, bereits gebundene externe IDs ausschließen und bei mehr als einem plausiblen Kandidaten nicht automatisch binden. Den existierenden Resolver verwenden oder dessen Ambiguitätsregel in den Store verschieben. Zusätzlich eine Workspace-Invariante/Test einführen: pro Provider darf eine `externalSessionID` höchstens einer nicht-archivierten lokalen Session zugeordnet sein (bewusste Aliasfälle explizit modellieren).

**Konfidenz:** hoch für die fehlenden Guards und die mögliche Doppelbindung; mittel für die Häufigkeit, weil ein rechtzeitig zugestellter Hook das Fenster schließt.

## F6: Nach Event-Datei-Rotation oder Hook-Ausfall kann `working`/`awaitingInput` dauerhaft hängen

**Schweregrad:** hoch  
**Fundort:** `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:123-165,202-216`; `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:68-99`; `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:63-69,204-214,238-249`; `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:143-158`

**Szenario (Auslöser → Wirkung):** Nachdem mindestens ein Hook-Event angekommen ist, wird die Event-Datei gelöscht, atomisch ersetzt, rotiert oder verkleinert; alternativ stirbt bei einem Background-Agent der Supervisor ohne `SessionEnd`. Die Bridge registriert zwar `.delete`/`.rename`, öffnet danach aber keinen neuen FD. Der Cursor-Reset bei Verkleinerung ist ebenfalls unwirksam: Ein Seek hinter das neue EOF ist POSIX-konform und wirft nicht, daher bleibt der alte Offset bestehen. Gleichzeitig markiert `hookLiveSessions` die Hooks zeitlich unbegrenzt als alleinige Statusquelle und verwirft Transcript-Meinungen. Nach einem verlorenen Folgeevent bleibt der letzte Zustand — insbesondere `working` oder `awaitingInput` — bis Prozessende bzw. App-Neustart falsch. Background-PTY-Ende wird absichtlich ignoriert, sodass dort auch dieser Korrekturpfad fehlt.

**Beweis:**

```swift
// ClaudeHookBridge.swift:130-139
let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd,
    eventMask: [.write, .extend, .delete, .rename], ...)
source.setEventHandler { ... await self.handleFileEvent(for: entry) }
// handleFileEvent liest nur den Pfad; kein Cancel/Reopen bei delete/rename
```

```swift
// ClaudeHookEventStore.swift:76-83
do {
    try handle.seek(toOffset: cursor.offset)
} catch {
    baseOffset = 0
    try? handle.seek(toOffset: 0)
}
// Seek hinter EOF schlägt nicht fehl; Dateigröße wird nicht gegen offset geprüft.
```

```swift
// AgentSessionStatusCoordinator.swift:241-249
} else if !hookLiveSessions.contains(sessionID) {
    // nur dann werden Transcript-Statusmeinungen angewandt
}
```

**Fix-Vorschlag:** Bei `.delete`/`.rename` die Source schließen und mit Backoff auf die neu erzeugte Datei reattachen; vor dem Seek Dateigröße/Inode prüfen und bei `size < offset` den Cursor explizit auf null setzen. „Hook-live“ braucht eine Liveness-Frist oder Sequenz-/Heartbeat-Reconciliation. Für Background-Agents Supervisor-`state.json` bzw. `claude agents --json` als zweite autoritative Lifecycle-Quelle verwenden; Transcript-Signale dürfen nach nachgewiesener Hook-Stille wieder degradierend eingreifen.

**Konfidenz:** hoch — FD-/Cursor-Verhalten und die unbefristete Statusunterdrückung sind direkt aus dem Code ableitbar.

## F7: `claude attach` kann den bereits korrekten Background-Endstatus wieder überschreiben

**Schweregrad:** mittel  
**Fundort:** `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:87-95`; `WhisperM8/Views/AgentChatsView+Grid.swift:916-929`; `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:123-135,143-153`; `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:155-172`

**Szenario (Auslöser → Wirkung):** Ein kurzer Background-Agent beendet sich zwischen `--bg`-Spawn und dem nachfolgenden Attach. `startTracking` drainiert `SessionStart`/`Stop`/`SessionEnd` und setzt korrekt `.stopped`. Direkt danach triggert die View `claude attach`; dessen PTY-Launch ruft `sessionLaunched`, entfernt `hookLiveSessions` und sendet `.processLaunched`. Die State-Machine belebt `.stopped` dadurch zu `.launching`. Da der echte Background-Prozess bereits fertig ist, kommt kein weiteres Hook-Event; nach der Grace-Period zeigt die UI `.ready/.idle` statt `.stopped`. Das Ende des Attach-PTY wird für Background-Sessions ebenfalls ignoriert.

**Beweis:**

```swift
// AgentChatsView+BackgroundAgents.swift:92-95
AgentSessionStatusCoordinator.shared.hookLaunchDidStart(sessionID: session.id)
sessionActionRequest = AgentSessionActionRequest(sessionID: session.id, kind: .start)
```

```swift
// AgentSessionStatusCoordinator.swift:123-125
func sessionLaunched(sessionID: UUID) {
    hookLiveSessions.remove(sessionID)
    apply(.processLaunched, to: sessionID)
```

```swift
// AgentSessionStateMachine.swift:162-165
if state == .stopped || state == .errored {
    case .processLaunched:
        return Transition(state: .launching)
}
```

**Fix-Vorschlag:** Attach-Lifecycle und Background-Job-Lifecycle getrennt modellieren. Ein Attach-PTY darf den Jobzustand weder auf `launching` setzen noch Hook-Liveness zurücksetzen. Nur Spawn/Respawn oder ein echter Supervisor-`SessionStart` darf einen gestoppten Background-Job wiederbeleben.

**Konfidenz:** mittel — die Zustandsfolge ist code-seitig eindeutig; ihr Eintritt hängt vom Timing eines sehr kurzen Background-Jobs ab.

## F8: Laufende Background-Agents verlieren nach App-Neustart Hook-Binding und Live-Status

**Schweregrad:** mittel  
**Fundort:** `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:24,107-182`; `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:218-239`; `WhisperM8/Views/AgentSessionDetailView.swift:442-455`; `WhisperM8/Views/AgentChatsView+Grid.swift:925-930`

**Szenario (Auslöser → Wirkung):** Ein Background-Agent läuft im Claude-Supervisor weiter, während WhisperM8 beendet und neu gestartet wird. Die `ClaudeHookBridge.entries` sind rein im Speicher. Beim Startup-Health-Check wird nur `claude logs` ausgeführt; für gespeicherte Background-Sessions wird weder `startTracking` auf der vorhandenen Event-Datei aufgerufen noch deren Event-Backlog drainiert. Beim späteren Attach schließt `useHookBridge` Background-Chats ausdrücklich aus. Damit können eine noch nicht persistierte externe Session-ID, Statuswechsel und `SessionEnd` dauerhaft unbemerkt bleiben; ohne externe ID kann auch der Transcript-Watcher nichts lokalisieren.

**Beweis:** Die globale Callsite-Suche findet `hookLaunchDidStart` für Background-Sessions nur unmittelbar nach einem **frischen** erfolgreichen Spawn (`AgentChatsView+BackgroundAgents.swift:93`); der normale `onClaudeHookLaunched`-Pfad ist in `AgentSessionDetailView.swift:452-455` durch `!launchSession.isBackgroundChat` ausgeschlossen. Der Startup-Health-Check (`AgentChatsView+BackgroundAgents.swift:218-239`) kennt nur `shortID` und archiviert bei `.unknown`, stellt aber keine Bridge wieder her.

**Fix-Vorschlag:** Beim Workspace-Start alle nicht archivierten Background-Sessions mit Short-ID und vorhandener Hook-Event-Datei wieder an die Bridge hängen und zunächst den Backlog drainieren. Danach Jobzustand/Session-ID gegen `state.json` bzw. `claude agents --json` reconciliaten. Das Reattach muss idempotent sein und darf nicht erneut Settings/Event-Dateien leeren.

**Konfidenz:** hoch für die fehlende Wiederanbindung; mittel für den sichtbaren Schaden, weil eine bereits persistierte ID den Transcript-Fallback teilweise abfedert.

## F9: Gestarteter Claude-Tab ohne externe ID wird still als neuer Chat geöffnet

**Schweregrad:** niedrig  
**Fundort:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:290-345`; `WhisperM8/Views/AgentSessionDetailView.swift:495-505,538-557`

**Szenario (Auslöser → Wirkung):** Eine Session hat `hasLaunchedInitialPrompt == true`, aber wegen stummer Hooks, App-Tod oder fehlgeschlagenem Indexer-Fallback keine `externalSessionID`. Beim nächsten Start baut ClaudeCommand weder `--resume` noch den alten Initial-Prompt. Der Resume-Guard prüft nur Sessions, bei denen bereits eine nichtleere ID vorhanden ist. Der User öffnet somit im vermeintlich bestehenden Tab kommentarlos einen neuen leeren Claude-Chat; der alte Verlauf kann später als separate Index-Zeile auftauchen.

**Beweis:**

```swift
// AgentCommandBuilder.swift:302-307
} else if session.hasLaunchedInitialPrompt,
          let externalSessionID = session.externalSessionID,
          !externalSessionID.isEmpty {
    resumeSessionID = externalSessionID
}
// ohne ID: kein Resume

// :341-345
if !session.hasLaunchedInitialPrompt, let initialPrompt = session.initialPrompt, ... {
    arguments.append(initialPrompt)
}
```

Der View-Guard bei `AgentSessionDetailView.swift:549-551` wird ebenfalls nur durch `let ext = candidate.externalSessionID, !ext.isEmpty` aktiv.

**Fix-Vorschlag:** `hasLaunchedInitialPrompt && externalSessionID == nil` wie im Codex-Pfad als nicht resumebaren, reparaturbedürftigen Zustand behandeln und den Launch mit erklärender UI stoppen. Optional einen gezielten Scan/Benutzerdialog anbieten; niemals still fresh starten.

**Konfidenz:** hoch für den Codepfad; die Eintrittswahrscheinlichkeit ist durch sofortiges Binding-Flush reduziert, aber F4/F5/F8 machen den Zustand realistisch.

## F10: Hook-Settings und vollständige Hook-Payloads werden für geschlossene/archivierte Sessions unbegrenzt behalten

**Schweregrad:** niedrig  
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift:3-29,38-54`; `WhisperM8/WhisperM8App.swift:255-260`; `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:36-57`

**Szenario (Auslöser → Wirkung):** Sessions werden geschlossen oder archiviert. Die Event-Datei enthält die vollständigen Hook-stdin-Payloads, darunter User-Prompts, Tool-Inputs und Tool-Responses. Der Retention-Job behält jedoch die Dateien für **jede** Workspace-Session, unabhängig von Status oder Alter, und läuft nur beim App-Start. Damit werden alte generierte Settings und duplizierte sensible Ereignisdaten so lange aufgehoben, wie die Session-Zeile existiert — auch wenn die Bridge sie nie wieder benötigt.

**Beweis:**

```swift
// WhisperM8App.swift:258-260
let workspace = AgentSessionStore().loadWorkspace()
let liveIDs = Set(workspace.sessions.map(\.id))
_ = AgentSessionRetentionService().prune(liveLocalSessionIDs: liveIDs)
```

```swift
// AgentSessionRetentionService.swift:47-50
let stem = url.deletingPathExtension().lastPathComponent
guard let id = UUID(uuidString: stem) else { continue }
if keeping.contains(id) { continue }
```

**Fix-Vorschlag:** Settings-Dateien nach Prozess-/Jobende löschen und Event-Dateien nach erfolgreichem Binding plus kurzer Diagnosefrist entfernen oder hart altersbegrenzen. Für laufende Background-Jobs muss die Retention den echten Supervisor-Zustand berücksichtigen. Die App darf nicht ausschließlich aus „Workspace-Zeile existiert“ auf aktive Hook-Nutzung schließen.

**Konfidenz:** hoch — die Keep-Menge umfasst im Code unterschiedslos aktive, geschlossene und archivierte Sessions.

## Zusammenfassung

**10 Findings: 1 kritisch, 5 hoch, 2 mittel, 2 niedrig.** Die kritischste Integrationslücke ist das inkonsistente Account-Routing: Nur der Foreground-PTY-Pfad respektiert zuverlässig den Session-Account; Background-Spawn/Lifecycle und Headless-Postprocessing fallen garantiert auf `main` zurück. Zusätzlich gefährden persistierende interne `claude -p`-Sessions, Pfad-/Worktree-Drift, mehrdeutige Fallback-Bindung und fehlende Hook-Reconciliation die Kernversprechen „richtigen Chat resumen“ und „Status stimmt immer“.
