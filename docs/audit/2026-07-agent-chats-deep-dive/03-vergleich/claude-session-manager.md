---
status: aktiv
updated: 2026-07-18
description: Vergleich von Open-Source-Session-Managern/UIs für Claude Code und Codex CLI mit WhisperM8s Agent-Chats-Ansatz.
---

# Open-Source-Session-Manager für Claude Code & Codex — Vergleich mit WhisperM8

Recherche-Stand: 2026-07-18. Alle Projekte per GitHub-API/Doku verifiziert (Stars/Aktivität = Abrufdatum). Untersuchte Kernprobleme: PTY-/Terminal-Management, Status-Tracking, Session-Discovery + Resume, Multi-Projekt-Organisation, Transcript-Rendering.

## 1. Projektübersicht

| Projekt | Link | Sprache/Stack | Aktivität (2026-07-18) |
|---|---|---|---|
| **Crystal** (Stravu) | [stravu/crystal](https://github.com/stravu/crystal) | TypeScript, Electron, React 19, SQLite, xterm.js, Monaco | ⚠️ **Deprecated** seit Feb 2026 (3,1k Stars, letzter Push Feb 2026); Nachfolger ist das separate Produkt [Nimbalyst](https://nimbalyst.com/crystal/) |
| **claudecodeui / CloudCLI** (Siteboon) | [siteboon/claudecodeui](https://github.com/siteboon/claudecodeui) | TypeScript, Node/Express, React + Vite, node-pty, xterm.js, AGPL-3.0 | ✅ Sehr aktiv (12,7k Stars, Push 2026-07-15); unterstützt Claude Code, Codex, Cursor CLI, OpenCode |
| **opcode** (getAsterisk, ehem. „claudia") | [getAsterisk/opcode](https://github.com/getAsterisk/opcode) (Redirect → winfunc/opcode) | Tauri 2: Rust-Backend + React 18/TS, SQLite (rusqlite), AGPL-3.0 | ⚠️ **Stagnierend**: 22,2k Stars, aber letzter Push Okt 2025 (~9 Monate alt), letztes Release v0.2.0 Aug 2025 |
| **VibeTunnel** (Amantus) | [amantus-ai/vibetunnel](https://github.com/amantus-ai/vibetunnel) | TypeScript-Server (Node), Swift-Menubar-App (macOS), Lit + ghostty-web Frontend, MIT | ✅ Aktiv (4,6k Stars, Push 2026-07-11) |
| **Happy** („happy-coder") | [slopus/happy](https://github.com/slopus/happy) + [slopus/happy-cli](https://github.com/slopus/happy-cli) | TypeScript (React Native Mobile + Web), CLI-Wrapper mit node-pty, Socket.IO-Relay, E2E-Verschlüsselung (TweetNaCl), MIT | ✅ Sehr aktiv (22,7k Stars, Push 2026-07-11) |
| **Conductor** | [conductor.build](https://www.conductor.build/) | Mac-App (Tauri), baut auf dem Claude-Code-TypeScript-SDK auf | ✅ Aktiv, aber **Closed Source** (kostenlos, benötigt eigenes Claude-Abo); Claude Code, Codex, Cursor, OpenCode |
| **opencode** (sst/Anomaly) | [sst/opencode](https://github.com/sst/opencode) (Redirect → anomalyco/opencode) | TypeScript-Monorepo, Bun + Hono-Server, SSE, Drizzle/SQLite, Go-TUI, MIT | ✅ Extrem aktiv (187k Stars, Push 2026-07-18) — aber **eigener Agent**, kein Claude-Code-Manager |
| **claude-squad** (smtg-ai) — Ergänzung | [smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad) | Go-TUI, tmux + git worktrees, AGPL-3.0 | ✅ Aktiv-ish (8,1k Stars, Push Jun 2026) |

Nicht weiter vertieft, aber existent: [sugyan/claude-code-webui](https://github.com/sugyan/claude-code-webui) (schlankes Web-UI, streamt Claude-CLI-Antworten) und diverse Forks der obigen Projekte. Tote/umbenannte Kandidaten: „claudia" ist in opcode aufgegangen; Crystal ist offiziell eingestellt.

## 2. Wie lösen die Projekte die Kernprobleme?

### 2.1 PTY-/Terminal-Management

- **Crystal**: Electron-Main-Prozess mit `CliManagerFactory`/`SessionManager`; Claude-Prozesse laufen pro Session in einem eigenen **git worktree** (`~/.crystal/worktrees/`, verwaltet vom `WorktreeManager`). Output geht per IPC an die React-UI; Terminal-Darstellung via `@xterm/xterm`, Diffs via Monaco. Kein „echtes" interaktives TUI-Hosting — Crystal treibt Claude headless und rendert die Ausgabe selbst.
- **claudecodeui**: Zwei getrennte Ebenen. (a) Chat: seit dem Umbau läuft Claude **ohne Child-Process direkt über das Agent SDK** — `server/claude-sdk.js` importiert `query` aus `@anthropic-ai/claude-agent-sdk` („Direct SDK integration without child processes"), hält `activeSessions` als Map mit Abort-Support und streamt Messages per WebSocket. (b) Shell-Tab: klassisches PTY über **node-pty + xterm.js** (dokumentiert im DeepWiki als „PTY-based shell using node-pty and xterm.js"). Codex/Cursor/OpenCode haben eigene Adapter (`openai-codex.js`, `cursor-cli.js`, `opencode-cli.js`).
- **opcode**: Rust/Tokio-Prozessmanagement (`src-tauri/src/claude.rs`, `process/`-Modul als Registry). Kein PTY — opcode spawnt `claude` headless und rendert den Stream selbst; Agents laufen als isolierte Background-Prozesse mit eigenen Berechtigungen.
- **VibeTunnel**: Der Purist unter den Kandidaten: `vt <cmd>` wrappt jedes Kommando in `vibetunnel fwd`, das ein **echtes PTY allokiert** und I/O zum Node-Server spiegelt; Aufzeichnung im **asciinema-Format**, Browser-Rendering mit ghostty-web. Das Terminal bleibt das native Terminal — der Browser ist nur ein Spiegel.
- **Happy**: `happy` statt `claude` starten; die CLI spawnt Claude via **node-pty** lokal (Terminal bleibt voll interaktiv) und hat parallel einen Remote-Mode über das Claude-SDK. Doku vermerkt, der PTY-Pfad werde „LIKELY … DEPRECATED in favor of running through SDK".
- **Conductor**: kein Terminal-Hosting des Agenten — baut auf dem **Claude-Code-SDK (TypeScript)** auf, jede Task bekommt Workspace + Branch + eigenes Terminal daneben.
- **claude-squad**: delegiert das Problem komplett an **tmux** — jede Session ist eine tmux-Session in eigenem worktree, die Go-TUI attacht/preview't Panes.
- **opencode**: Client/Server — die TUI ist nur ein Client des lokalen Hono/Bun-Servers (HTTP + SSE); es gibt gar kein fremdes TUI zu hosten, weil der Agent-Loop (`SessionPrompt.loop()`) selbst im Server läuft.

**Muster:** Fast niemand hostet das *interaktive* Claude-TUI in einer eigenen Terminal-View, so wie WhisperM8 es mit SwiftTerm tut. Die Konkurrenz umgeht das Problem entweder per Headless-Betrieb (SDK/`stream-json`: Crystal, opcode, claudecodeui, Conductor) oder per Delegation an tmux/natives Terminal (claude-squad, VibeTunnel).

### 2.2 Status-Tracking: Hooks vs. Polling vs. JSONL-Tailing

| Projekt | Mechanismus |
|---|---|
| Crystal | Prozess-Lifecycle + Parsing des `stream-json`-Outputs des selbst gestarteten Prozesses; Zustände (running / waiting / completed…) in SQLite, Events per IPC an die UI. Kein externes Tailing nötig, weil Crystal alle Sessions selbst startet. |
| claudecodeui | SDK-Callbacks in-process (kein Polling): Tool-Approval-Interception mit `pendingToolApprovals` + Timeout (`TOOL_APPROVAL_TIMEOUT_MS`, interaktive Tools wie `AskUserQuestion`/`ExitPlanMode` warten unbegrenzt) — „braucht Eingabe" ist hier ein **synchroner Callback**, kein abgeleiteter Zustand. Session-Listen aus `~/.claude/projects/` werden per File-Watching aktualisiert. |
| opcode | Liest `~/.claude/projects/`-JSONL für Historie; laufende eigene Agents über die Rust-Prozess-Registry. Externe (nicht von opcode gestartete) Sessions haben keinen Live-Status. |
| VibeTunnel | Heuristik: „Activity indicators are based on recent input/output" — I/O-Durchsatz des PTY treibt active/idle. Grob, aber agentenagnostisch. |
| Happy | Dreifach: PTY-I/O, **File-Watcher auf `~/.claude/projects/`-JSONL** („File system watcher for Claude session files") und ein **MCP-Permission-Server**, der Permission-Requests interceptet → Push-Notification „needs input" aufs Handy. |
| Conductor | SDK-Events (in-process), Notifications bei Fertigstellung. |
| claude-squad | tmux-Pane-Capture/Diffing — beobachtet, ob sich der Bildschirminhalt ändert. |
| opencode | Trivial: Der Server *ist* der Agent; Status ist first-class State, Clients bekommen SSE. |

**Muster:** Wer den Prozess selbst startet (SDK/headless), bekommt Status geschenkt. Wer fremde Sessions beobachtet, landet bei JSONL-Tailing (Happy, WhisperM8) oder I/O-Heuristik (VibeTunnel, claude-squad). Nur Happy und WhisperM8 nutzen einen **ereignisbasierten Rückkanal aus dem Prozess selbst** (Happy: MCP-Permission-Server; WhisperM8: `ClaudeHookBridge` via `--settings`-Hooks). WhisperM8s Hook-Ansatz (SessionStart/SessionEnd/Notification → Event-Datei → `DispatchSourceFileSystemObject`) ist dabei der einzige, der ohne MCP-Umweg und ohne eigenen Server auskommt.

### 2.3 Session-Discovery & Resume

- **claudecodeui**: Auto-Discovery „every session from your `~/.claude` folder", zusätzlich Cursor-SQLite und OpenCode-Storage — der breiteste Multi-Provider-Indexer im Feld. Resume über SDK-Session-Fortsetzung.
- **opcode**: Visueller Browser über `~/.claude/projects/` mit „Session-History … und Resume-Möglichkeiten"; zusätzlich ein eigenes **Checkpoint/Timeline-System** (`src-tauri/src/checkpoint/`): Snapshots an beliebigen Punkten, Branching, Diff, Wiederherstellung — mehr als Claude-natives `--resume`.
- **Crystal**: keine externe Discovery — nur selbst erzeugte Sessions (SQLite `~/.crystal/crystal.db`).
- **Happy**: dokumentiert das wichtigste Resume-Gotcha explizit (happy-cli CLAUDE.md): `claude --resume <id>` erzeugt eine **neue Session-ID und eine neue JSONL-Datei, in der alle historischen Messages auf die neue sessionId umgeschrieben sind** — Clients müssen ID-Wechsel tracken. (Genau das Problem, das WhisperM8s Indexer/Hook-Bindung ebenfalls lösen muss.)
- **Conductor/claude-squad**: Discovery-frei — Organisationseinheit ist der worktree/die Task, nicht die fremde Session.
- **opencode**: eigene Persistenz (Drizzle/SQLite), Resume und Session-Share (Web-Link) sind native Server-Features.

### 2.4 Multi-Projekt-Organisation

Zwei Philosophien im Feld:

1. **Verzeichnis-zentriert** (claudecodeui, opcode): Projekt = `~/.claude/projects/<encoded-cwd>`-Ordner, UI gruppiert Sessions darunter. Entspricht WhisperM8s `AgentProjectPath`-Modell.
2. **Task/worktree-zentriert** (Crystal, Conductor, claude-squad): Einheit ist die *Aufgabe*; jede bekommt automatisch worktree + Branch + Setup-Skript (Conductor: „workspace, branch, files, terminal, diff, and review path"; Worktree-Erzeugung in ~10 s inkl. Auto-Branch-Naming). Merge/PR-Flow ist eingebaut (Diff-Viewer, Squash/Rebase zurück auf main).

opencode hat zusätzlich „Project and Worktree Management" als Serverkonzept, bleibt aber ein Einzel-Agent-Tool.

### 2.5 Transcript-Rendering

- **Crystal**: Dual-View — gerendertes Message-View (Tool-Calls strukturiert) + Raw-Output; Diffs in Monaco.
- **claudecodeui**: Chat-UI mit Tool-Output-Rendering, Markdown, CodeMirror-Editor, Bild-Attachments; Thinking-Mode-Selector.
- **opcode**: Session-Historie mit Tool-Output-Rendering und Diff-Viewing, Timeline-Navigation über Checkpoints.
- **VibeTunnel**: gar kein semantisches Rendering — Terminal-Replay (asciinema) ist das Transcript.
- **Happy**: nativer Mobile-Chat aus den JSONL-/SDK-Messages, inkl. Permission-Dialogen.
- **opencode**: TUI-Rendering aus eigenem Message-Modell; Share-Feature rendert dieselbe Session als Webseite.

**Muster:** Alle ernsthaften UIs konvergieren auf „Chat-View aus strukturierten Messages, Terminal nur als Fallback/Detail" — dieselbe Richtung wie WhisperM8s vereinheitlichtes `AgentChatTranscript` + Timeline (Variante E). Niemand im Feld streamt >50-MB-JSONL erkennbar sorgfältiger als WhisperM8s zeilenweise Reader; claudecodeui hatte historisch Performance-Issues mit großen Sessions.

## 3. Direkter Vergleich zu WhisperM8

### Was WhisperM8 besser macht

- **Echtes interaktives TUI-Hosting.** WhisperM8 ist das einzige Tool im Feld, das das *native* Claude-/Codex-TUI vollwertig einbettet (SwiftTerm `LocalProcessTerminalView`, Keyboard-Profile pro TUI-Typ, Link-Interception via `AgentTerminalLinkInterceptor`). Die Konkurrenz ersetzt das TUI (SDK-Headless) oder spiegelt es nur (VibeTunnel, tmux). Vorteil: 100 % Feature-Parität mit dem CLI (Slash-Commands, Plan-Mode, TUI-Dialoge) ohne Nachbau-Aufwand — claudecodeui muss z. B. `AskUserQuestion`/`ExitPlanMode` einzeln im eigenen UI nachimplementieren.
- **Hooks als Status-SoT.** Der `--settings`-Hook-Bridge-Ansatz (SessionStart/SessionEnd/Notification → Event-Datei → vnode-Watch) ist präziser als VibeTunnels I/O-Heuristik und claude-squads Pane-Diffing, und leichtgewichtiger als Happys MCP-Server (kein zusätzlicher Prozess im Claude-Kontext). Kombiniert mit event-getriebenem JSONL-Tailing (`FileEventSource`, stat-first Escalation) deckt WhisperM8 auch *extern gestartete* Sessions ab — das kann sonst nur claudecodeui (nur Listen, kein Live-Status) und Happy (nur eigene Wrapper-Sessions).
- **Discovery beider Provider mit Live-Status.** `AgentSessionIndexer` (Claude *und* Codex-JSONL, mtime+size-Cache) + `AgentDirectoryEventMonitor` (FSEvents) erkennt extern gestartete Sessions automatisch. opcode liest nur Claude; Crystal/Conductor sehen Fremdsessions gar nicht.
- **Performance-Disziplin.** Signpost-Budgets, Sliding-Window-Transcript, Equatable-diff-gated Persistence — nichts Vergleichbares ist bei den Kandidaten dokumentiert; opcode/claudecodeui haben offene Issues zu großen Sessions.
- **Integration Diktat ↔ Agent-Chats** (Transcript-Tail als Sprachkontext) ist ein Alleinstellungsmerkmal; nur Happy hat überhaupt Voice, aber ohne Kontext-Kopplung.

### Was andere besser machen

- **Worktree-/Task-Isolation fehlt WhisperM8 als Produkt-Flow.** Crystal, Conductor und claude-squad machen „N parallele Agents am selben Repo ohne Konflikte" zum Ein-Klick-Flow (worktree + Branch + Setup-Skript + Diff/Merge-UI). WhisperM8 hat zwar `AgentWorktreeManager`-Ansätze, aber keinen durchgängigen Create→Diff→Merge-Pfad mit Review-UI.
- **Checkpoints/Timeline (opcode).** Session-Versionierung mit Branching und Wiederherstellung ist ein Feature-Level über WhisperM8s reinem Transcript-Browsing.
- **Remote-Zugriff.** claudecodeui (Web/Mobile), Happy (E2E-verschlüsseltes Mobile + Push bei „needs input"), VibeTunnel (Browser-Terminal) — WhisperM8 ist rein lokal. Gerade Push-Notification bei `awaitingInput` auf ein anderes Gerät ist ein häufig nachgefragter Flow (Happy: 22,7k Stars).
- **Tool-Approval im UI.** claudecodeui interceptet Permission-Requests als first-class UI-Dialog (approve/deny remote). WhisperM8 erkennt „awaitingInput" nur passiv — beantworten muss der User im Terminal.
- **Diff-/Review-Ansicht.** Crystal (Monaco-Diff pro Session), Conductor (Review-Path pro Workspace), opcode (Diff-Viewer) — WhisperM8 zeigt Transkripte, aber keine aggregierte Code-Diff-Sicht pro Session.
- **Multi-Provider-Breite.** claudecodeui/Conductor/claude-squad unterstützen 4+ Agents (inkl. Cursor, OpenCode, Amp); WhisperM8 zwei (Claude, Codex).

### Strategische Einordnung

Der Markt teilt sich in (a) SDK-basierte Headless-Orchestratoren mit eigenem Chat-UI (claudecodeui, Conductor, Crystal†, opcode~), (b) Terminal-Multiplexer/-Spiegel (VibeTunnel, claude-squad) und (c) eigenständige Agents (opencode). WhisperM8 sitzt bewusst zwischen (a) und (b): natives TUI *plus* strukturierte Projektion (Sidebar-Status, Transcripts). Diese Hybrid-Position hat sonst niemand — sie ist zugleich der Grund, warum WhisperM8 Probleme lösen muss (Status fremder TUIs, JSONL-Tailing, Resume-ID-Rotation), die SDK-Tools per Konstruktion nicht haben.

## 4. Übertragbare Muster für WhisperM8 (priorisiert)

1. **[Hoch] Worktree-Task-Flow produktisieren.** Das validierteste Muster im Feld (Crystal, Conductor, claude-squad, opencode): „Neue Task" = worktree + Branch + optionales Setup-Skript, danach Diff-Ansicht und Merge/PR aus der App. WhisperM8 hat `AgentWorktreeManager` bereits — fehlt sind Auto-Branch-Naming, Setup-Skript-Hook pro Projekt und eine Diff-Summary pro Session (git diff im worktree reicht; kein eigener Diff-Editor nötig).
2. **[Hoch] „Needs input"-Remote-Signal.** Happys populärstes Feature ist die Push-Notification bei Permission-Request. WhisperM8 hat das Signal bereits (Hook-Bridge `Notification`-Event) — es fehlt nur ein Auslieferungskanal (macOS-Notification existiert; ntfy/Telegram/Webhook als opt-in Setting wäre billig und würde den Haupt-Use-Case von Happy/VibeTunnel lokal abdecken).
3. **[Mittel] Resume-ID-Rotation explizit modellieren.** Happys dokumentierter Befund (neue JSONL mit umgeschriebenen sessionIds bei `--resume`) sollte im `AgentSessionIndexer`/`ClaudeHookBridge` als getesteter Fall abgesichert sein: alte Datei als Vorgänger verketten statt als separate Session zu listen (Duplikat-Gefahr in der Sidebar).
4. **[Mittel] Aggregierte Diff-Sicht pro Session.** Ein „Changes"-Tab (git diff des Projekt-/Worktree-Stands seit Session-Start, read-only, FileMerge/PhpStorm als Deep-Link) schließt die größte Feature-Lücke zu Crystal/Conductor mit minimalem UI-Aufwand — passt zum Muster „UI-Wiederverwendung vor Neubau".
5. **[Niedrig] SDK-Headless als zweiter Betriebsmodus.** Für Background-/Subagent-Jobs (nicht für Foreground-Chats!) zeigt claudecodeui, dass das Agent SDK Tool-Approval, Abort und Streaming sauberer liefert als PTY-Parsing. WhisperM8s `claude --bg`-Supervisor deckt das teilweise ab; bei Ausbau der Jarvis-/Subagent-Schiene wäre `@anthropic-ai/claude-agent-sdk`-Parität (Approval-Callbacks statt Terminal) das Referenzmuster.
6. **[Niedrig] Checkpoint-Light.** opcodes Timeline ist aufwendig; ein billiges Derivat wäre „Snapshot = git stash/commit im worktree bei jedem Turn-Ende", nur für Worktree-Sessions. Erst nach Punkt 1 sinnvoll.
7. **[Beobachten] opencode-Serverarchitektur.** Falls je ein Remote-/Zweit-Client für WhisperM8 ansteht: opencodes Muster (lokaler Server, Clients via HTTP+SSE, Session-State server-seitig) ist der sauberste Weg — nicht Terminal-Spiegelung à la VibeTunnel.

## Quellen

- https://github.com/stravu/crystal · https://deepwiki.com/stravu/crystal · https://nimbalyst.com/crystal/
- https://github.com/siteboon/claudecodeui (`server/claude-sdk.js`, README) · https://deepwiki.com/siteboon/claudecodeui
- https://github.com/getAsterisk/opcode (→ winfunc/opcode) · https://deepwiki.com/getAsterisk/claudia
- https://github.com/amantus-ai/vibetunnel
- https://github.com/slopus/happy · https://github.com/slopus/happy-cli (CLAUDE.md)
- https://www.conductor.build/ · https://www.conductor.build/docs/ · HN: „Show HN: Conductor" (44594584)
- https://github.com/sst/opencode (→ anomalyco/opencode) · https://deepwiki.com/sst/opencode
- https://github.com/smtg-ai/claude-squad
