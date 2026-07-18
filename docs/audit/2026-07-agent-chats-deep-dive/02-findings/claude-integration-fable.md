# Claude-Code-Integration — Unabhängige Zweitprüfung (Finder: Fable)

**Datum:** 2026-07-18 · **Geprüfte CLI:** `claude` 2.1.214 (`~/.local/bin/claude`) · **Methode:** reine Code-Analyse + Read-only-Inspektion von `~/.claude/`, `~/.claude-profiles/`, `claude --help` und Binary-Strings. Kein Build, keine Änderungen an `~/.claude`.

## Vorab verifiziert — KEINE Befunde (Negativ-Checks)

- **Hook-Schema:** Alle 8 registrierten Event-Namen (`ClaudeHookSettingsBuilder.trackedEventNames`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:25-34`) existieren in 2.1.214 — `strings ~/.local/bin/claude` liefert u. a. `PostToolUseFailure` (34×) und `PermissionRequest` (139×). Struktur (`hooks → EventName → [{matcher, hooks:[{type:command,command}]}]`) entspricht dem aktuellen Settings-Schema; die geparsten Felder (`hook_event_name`, `session_id`, `reason`, `tool_name`) stimmen.
- **Argv-Flags:** `--settings`, `--bg`, `--resume`, `--fork-session`, `--agent`, `--permission-mode` (alle 5 Modal-Werte in den CLI-Choices `acceptEdits|auto|bypassPermissions|manual|dontAsk|plan` enthalten) sind in `claude --help` vorhanden. Die versteckten Subcommands `attach`, `logs`, `stop`, `respawn`, `rm` existieren weiterhin (Binary: `Usage: claude respawn <id>|--all`, `Usage: claude rm <id>`, `backgrounded · …`-Block inkl. `claude attach ${e}`).
- **PTY-Env:** `environmentOverrides` (u. a. `CLAUDE_CONFIG_DIR`) werden im Terminal-Launch korrekt über die Basis gemergt (`WhisperM8/Views/AgentTerminalView.swift:758-765`); `LoginShellEnvironment.processEnvironment()` entfernt geerbte `CLAUDE_CODE_*`/`CLAUDE_CONFIG_DIR` korrekt (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:106-119`).

---

## F1: `encodeClaudeCwd` weicht vom realen Claude-Encoding ab (Unicode + fehlende Längen-Truncation)

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:320-332`

**Szenario (Auslöser → Wirkung):**
Ein Projektpfad enthält Nicht-ASCII-Zeichen (real vorhanden: `/Users/giulianocosta/repos/Abhörschutz`) ODER der encodierte Pfad ist länger als Claudes Cap (~200 Zeichen). Claude legt das Transcript dann unter einem ANDEREN Ordnernamen ab, als WhisperM8 berechnet. Folgen:
1. Der Runtime-Watcher löst mit `globFallback: false` auf (`AgentSessionRuntimeWatcher.swift:372-386`) → Transcript wird NIE gefunden → für Sessions ohne Hook-Bridge (Hooks deaktiviert, extern gestartete Claude-Läufe) gibt es keinerlei Status; für hook-live Sessions fällt das komplette `turnFinished`-Bookkeeping aus (Auto-Naming, `lastTurnAt`, ESC-Abbruch-Erkennung via `turnAborted`) — ein per ESC abgebrochener Chat pulsiert dauerhaft „arbeitet".
2. `ClaudeAccountProfiles.moveTranscript` (`ClaudeAccountProfiles.swift:434-438`) baut das ZIEL-Verzeichnis mit dem falschen Encoding — der Account-Umzug legt die JSONL in einen Ordner, den Claude nie liest → `--resume` nach Umzug: „No conversation found".
3. `ClaudeTranscriptReader.transcriptURL(forCwd:)` (`ClaudeTranscriptReader.swift:30-38`) zeigt ins Leere (Reader/`transcriptExists` sind durch den Glob-Fallback des Locators abgedeckt, der deterministische Pfad-Helper nicht).

**Beweis:**
App-Seite (Unicode-bewusst, keine Truncation):
```swift
// AgentSessionTranscript.swift:324-330
for char in standardized {
    if char.isLetter || char.isNumber {   // Swift: true auch für „ö", „é", CJK …
        result.append(char)
    } else {
        result.append("-")
    }
}
```
Claude-Seite (Binary 2.1.214, via `grep -a` extrahiert — ASCII-only-Regex + Truncation mit Hash-Suffix):
```js
function PA(e){let t=e.replace(/[^a-zA-Z0-9]/g,"-");if(t.length<=zEt)return t;return`${t.slice(0,zEt)}-${s8m(e)}`}
function _3(){return rte.join(on(),"projects")}
function lV(e){return rte.join(_3(),PA(e))}   // <config>/projects/<PA(cwd)>
```
`/[^a-zA-Z0-9]/` matcht „ö" → Claude schreibt `-Users-…-Abh-rschutz`, WhisperM8 sucht `-Users-…-Abhörschutz`. Zusätzlich kürzt Claude Namen über `zEt` Zeichen (Schwesterfunktion `tcl=200`) und hängt einen Base36-Hash an — WhisperM8 repliziert das gar nicht. Der Nutzer hat reale, tief verschachtelte Pfade (`…GoogleDrive-admin-360Web-manager-com-Meine-Ablage-…`, bereits ~110 Zeichen).

**Fix-Vorschlag:**
In `encodeClaudeCwd` nur ASCII zulassen: `if char.isASCII && (char.isLetter || char.isNumber)`. Für die Truncation (Hash nicht replizierbar): beim Stage-1-Miss den Glob-Fallback EINMALIG auch im Watcher erlauben und die aufgelöste URL cachen (der Locator-Cache existiert pro `WatchedSession` bereits via `transcriptURL`), statt `globFallback: false` pauschal.

**Konfidenz:** hoch (Regex + Truncation direkt aus dem Binary belegt; Swift-`isLetter`-Semantik dokumentiert). Truncation-Cap-Wert `zEt` nicht direkt ausgelesen (mittel für diese Teilaussage).

---

## F2: Headless-`claude -p`-Aufrufe (Auto-Namer/Summarizer) verschmutzen Workspace + Index — 495 Junk-Sessions unter Projekt „/"

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:141` · `AgentSessionSummarizer.swift:35` · `AgentHeadlessCLI.swift:33-37`

**Szenario (Auslöser → Wirkung):**
Jedes Auto-Naming und jede Chat-Zusammenfassung spawnt `claude -p <prompt> --output-format text` (bzw. `codex exec`). `AgentHeadlessCLI.run` setzt **kein** `currentDirectoryURL` → cwd ist das cwd der GUI-App (`/`), und es fehlt `--no-session-persistence`. Claude persistiert damit JEDEN Titel-/Summary-Call als vollwertige Session unter `~/.claude/projects/-/<uuid>.jsonl`. Der Indexer parst diese Dateien (cwd `/`, kein Filter), `mergeIndexedSessions` legt ein Projekt „/" an und hängt die Junk-Sessions als Chats in den Workspace. Folge-Effekte: Sidebar-/Workspace-Aufblähung, die Junk-Sessions konkurrieren um das `limit: 1000` des Indexers, jeder Scan liest hunderte tote JSONLs, und „Sessions scannen" + `forceGenerateTitle` kann für Junk-Sessions WEITERE Headless-Calls auslösen (Selbstverstärkung).

**Beweis:**
```swift
// AgentSessionAutoNamer.swift:141
args = ["-p", prompt, "--output-format", "text"]
// AgentHeadlessCLI.swift:34-37 — kein currentDirectoryURL:
let process = Process()
process.executableURL = executable
process.arguments = arguments
process.environment = environment
```
Empirisch (read-only, 2026-07-18):
- `ls ~/.claude/projects/- | wc -l` → **356** JSONLs (Inhalt z. B.: `"content":"Du fasst eine Coding-Agent-Session für eine Übersichts-Karte zusammen…"` — der Summarizer-Prompt).
- `AgentSessions.json`: Projekt mit `path: "/"` existiert (`E4319057-…`), **495 von 2161 Sessions** (23 %) hängen daran.
`grep -rn "no-session-persistence" WhisperM8` → keine Treffer; kein Filter für `path == "/"` in Indexer/Merge/Sidebar gefunden.

**Fix-Vorschlag:**
`--no-session-persistence` an die `claude -p`-Args anhängen (laut `claude --help` genau für `--print` gedacht); für Codex das Äquivalent prüfen bzw. cwd auf ein dediziertes Scratch-Verzeichnis setzen. Zusätzlich Migration/Aufräum-Pfad: Projekt „/" samt Sessions aus dem Workspace entfernen und cwd `/` im Indexer skippen.

**Konfidenz:** hoch (empirisch belegt: Dateien + Workspace-Zählung).

---

## F3: Account-Profile (`CLAUDE_CONFIG_DIR`) werden in den Nicht-PTY-Spawn-Pfaden ignoriert — Background-Agents & Headless-Calls laufen immer auf `main`

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:255-258` · `AgentChatsView+BackgroundAgents.swift:47-59` · `BackgroundAgentLifecycle.swift:79-146` · `AgentSessionAutoNamer.swift:145` · `AgentSessionSummarizer.swift:39`

**Szenario (Auslöser → Wirkung):**
Der User hat mehrere Accounts (real: `~/.claude-profiles/{Claude2,PowerUser,PowerUser2,RankM8}`) und ein aktives Nicht-main-Profil. Ein neuer interaktiver Chat wird korrekt gestempelt und mit `CLAUDE_CONFIG_DIR` gestartet (`AgentChatsView+SessionLifecycle.swift:56-61` → `AgentCommandBuilder.claudeCommand`). Ein **Background-Agent** dagegen: `dispatchBackgroundAgent` erzeugt die Session OHNE `claudeProfileName`, und `DefaultProcessRunner` baut sein Env aus `LoginShellEnvironment.processEnvironment()` — das `CLAUDE_CONFIG_DIR` explizit LÖSCHT (`LoginShellEnvironment.swift:119`) und keine Override-Möglichkeit bietet. Der `--bg`-Spawn, `attach` (Stempel nil → `[:]`), `logs/stop/respawn/rm` und der Startup-Health-Check laufen daher IMMER unter dem main-Account: falsches Abo/Quota, main-`~/.claude`-Login (Fehlschlag, wenn main ausgeloggt), Jobs/Transcripts landen im main-Root. Gleiches gilt für Auto-Namer/Summarizer-Headless-Calls zu Profil-Sessions.

**Beweis:**
```swift
// BackgroundAgentSpawner.swift:255-258 — kein Profil-Override möglich:
var env = LoginShellEnvironment.shared.processEnvironment()
env["NO_COLOR"] = "1"
env["CLICOLOR"] = "0"
process.environment = env
```
```swift
// AgentChatsView+BackgroundAgents.swift:47-59 — createSession OHNE claudeProfileName:
session = try store.createSession(
    provider: .claude,
    projectPath: project.path,
    …
    backgroundPermissionMode: request.permissionMode
)   // Interaktive Chats stempeln dagegen ClaudeAccountProfiles().activeProfileNameOrNil()
```
Das `ProcessRunner`-Protokoll (`BackgroundAgentSpawner.swift:223-230`) hat keinen Environment-Parameter — kein Aufrufer KANN ein Profil durchreichen.

**Fix-Vorschlag:**
(a) `dispatchBackgroundAgent` stempelt `ClaudeAccountProfiles().activeProfileNameOrNil()` auf die Session; (b) `ProcessRunner.run` um `environmentOverrides: [String: String]` erweitern und in Spawner + Lifecycle die Overrides aus dem Session-Stempel mergen (wie der PTY-Pfad in `AgentTerminalView.start()`); (c) Health-Check/Lifecycle je Session unter deren Config-Dir ausführen.

**Konfidenz:** hoch (alle Pfade Code-belegt; Profile real vorhanden).

---

## F4: Session-ID-Bindung: Indexer-Fallback kann fremde/parallele Sessions kapern; Merge kann Duplikat-Rows mit derselben `externalSessionID` erzeugen

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionStore.swift:621-634` (Fallback-Bindung) · `AgentSessionStore.swift:823-885` (Merge-Adoption/Append)

**Szenario (Auslöser → Wirkung):**
1. **Kapern:** Der Bind-Fallback (läuft bei stummen/deaktivierten Hooks bis ~7,75 s nach Launch, `AgentSessionDetailView.swift:626-696`) filtert nur mit **Untergrenze** und ohne Eindeutigkeits-Check:
```swift
// AgentSessionStore.swift:623-631
guard let indexed = indexedSessions
    .filter({ $0.provider == provider
        && !Self.isClaudeWorktreePath($0.cwd)
        && Self.canonicalProjectPath($0.cwd) == standardizedPath
        && $0.createdAt >= createdAt.addingTimeInterval(-5) })   // KEINE Obergrenze
    .sorted(by: { $0.lastActivityAt > $1.lastActivityAt })
    .first
```
Starten zwei Chats im selben Projekt fast gleichzeitig (oder startet der User parallel `claude` in Terminal.app), können beide Retry-Loops denselben „zuletzt aktiven" Kandidaten wählen — es gibt keinen Check „diese `externalSessionID` ist schon an eine andere lokale Session gebunden". Ergebnis: zwei Tabs zeigen/resumen denselben Chat, der andere Verlauf ist verwaist. (Das Merge-Pendant bekam 2026-07-13 ein echtes ±5s-Fenster, Zeile 835-840 — der Fallback hier nicht.)
2. **Duplikat-Rows:** Kommt der FSEvent-Scan (5 s Debounce) vor der Hook-Bindung zum Merge UND liegt `indexed.createdAt` außerhalb des ±5s-Fensters um `candidate.createdAt` (z. B. Session-Row älter, Launch später — Crash vor Binding-Flush, fehlgeschlagener Erststart), dann hängt `mergeIndexedSessions` die JSONL als NEUE Row an (`AgentSessionStore.swift:869-885`). Bindet der Hook/Fallback anschließend dieselbe ID an die lokale Row, existieren zwei Workspace-Rows mit identischer `externalSessionID` — es gibt keine nachträgliche Row-Deduplizierung (der Dedup in Zeile 749-785 dedupliziert nur Index-KANDIDATEN mehrerer Roots, nicht Workspace-Rows).

**Beweis:** siehe Code oben; `bindExternalSessionID` (`AgentSessionStatusCoordinator.swift:345-367`) prüft ebenfalls nur `old != newID`, nie Kollision mit anderen Rows; `mergeIndexedSessions` matcht bei Bestand nur `firstIndex(where: externalSessionID ==)` (Zeile 803) — die zweite Row bleibt dauerhaft.

**Fix-Vorschlag:** Im Fallback-Filter (a) Obergrenze analog Merge (`abs(diff) <= Fenster` relativ zum LAUNCH-Zeitpunkt, nicht `createdAt` der Row) und (b) `externalSessionID ∉ bereits gebundene IDs` ergänzen; im Merge nach dem Binden einen Row-Dedup (gleiches `provider|externalSessionID` → jüngere/leere Row entfernen bzw. mergen).

**Konfidenz:** mittel (Race-Fenster aus Code + Timings hergeleitet, nicht reproduziert; die fehlenden Guards sind sicher belegt).

---

## F5: Background-Agent-Status bleibt für immer „working", wenn der Supervisor-Daemon stirbt (kein SessionEnd-Hook)

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:151-153, 239-249`

**Szenario (Auslöser → Wirkung):**
Ein Background-Agent arbeitet (`working` via Hooks). Der Supervisor-Daemon bzw. der Job stirbt hart (kill -9, Crash, Reboot während die App weiterläuft, `claude update`-Neustart des Daemons). Es feuert KEIN `SessionEnd`-Hook. Für BG-Sessions ist aber jeder andere Status-Pfad abgeschaltet:
```swift
// AgentSessionStatusCoordinator.swift:151-153 — PTY-Exit (attach-Fenster) wird ignoriert:
if isBackgroundSession(sessionID) {
    return
}
```
```swift
// :239-249 — Transcript-Meinungen zählen nicht mehr, sobald je ein Hook-Event kam:
} else if !hookLiveSessions.contains(sessionID) { … }
```
`hookLiveSessions` wird nur bei `sessionLaunched`/`sessionTerminated` geräumt — beides passiert für BG-Sessions nicht. Der Chat pulsiert für die restliche App-Laufzeit „arbeitet"; der einmalige Startup-Health-Check (`AgentChatsView+BackgroundAgents.swift:218-239`) läuft nur pro Window-Open und klassifiziert einen toten Daemon als `.error` → keine Korrektur.

**Beweis:** Code oben; einzige `.stopped`-Quelle für BG ist der `sessionEnded`-Reducer-Pfad (`AgentSessionStateMachine.swift:222-235`), der ein Hook-Event voraussetzt. `SupervisorJobReader` (`state.json`) wird nur für Dictation-Tail/Tracker genutzt (`AgentChatTailExtractor.swift:104-140`, `ActiveBackgroundSessionTracker.swift:146`), nicht für den Status.

**Fix-Vorschlag:** Für `.backgroundChat`-Sessions periodisch (oder bei Hook-Stille > n Minuten) `~/.claude/jobs/<short-id>/state.json` bzw. `claude agents --json` gegenprüfen und `working`-Zustände ohne lebenden Job auf `stopped` reconciliaten — analog `updateSubagentJobStatus`, das für Codex-Jobs bereits `state.json` als Quelle nutzt.

**Konfidenz:** hoch für den Mechanismus (alle Pfade belegt), mittel für die Häufigkeit im Alltag.

---

## F6: Verlorene Bindung ⇒ stiller Fresh-Start statt Resume (Launch-Guard greift nur bei vorhandener `externalSessionID`)

**Schweregrad:** niedrig
**Fundort:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:302-313` · `AgentSessionDetailView.swift:549-558`

**Szenario (Auslöser → Wirkung):**
Eine Claude-Session hat `hasLaunchedInitialPrompt == true`, aber `externalSessionID == nil` (Hook stumm UND Indexer-Fallback erfolglos, z. B. F1-Encoding-Miss oder App-Tod im Binding-Fenster). Beim nächsten Start wirft `codexCommand` in diesem Fall einen Fehler (`missingExternalSessionID`, Zeile 182-183), `claudeCommand` dagegen baut kommentarlos einen Launch OHNE `--resume` und OHNE Prompt:
```swift
// AgentCommandBuilder.swift:302-307 — Resume nur mit gebundener ID …
} else if session.hasLaunchedInitialPrompt,
          let externalSessionID = session.externalSessionID,
          !externalSessionID.isEmpty {
    resumeSessionID = externalSessionID
}
// … sonst frischer Start; der Initial-Prompt wird ebenfalls unterdrückt (Zeile 341: nur wenn !hasLaunchedInitialPrompt)
```
Der Resume-Guard in der View stoppt nur bei `let ext = candidate.externalSessionID` (`AgentSessionDetailView.swift:549-551`) — bei `nil` läuft der Launch durch. Der User sieht im vermeintlich fortgesetzten Tab einen leeren neuen Chat; der alte Verlauf taucht später (Superset-Merge) als separate Row auf, ohne Hinweis auf den Zusammenhang.

**Fix-Vorschlag:** Im Launch-Pfad `hasLaunchedInitialPrompt && externalSessionID == nil` wie bei Codex als Fehler behandeln (oder Alert „Verlauf noch nicht gebunden — Sessions aktualisieren?"), statt still neu zu starten.

**Konfidenz:** hoch für den Code-Pfad; niedrig eingestuft, weil das Binding sofort geflusht wird (`flushNow(reason: "binding")`) und der Zustand daher selten ist — F1/F4 erhöhen seine Eintrittswahrscheinlichkeit aber.
