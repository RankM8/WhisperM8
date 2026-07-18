---
status: aktiv
updated: 2026-07-18
description: Vergleichsrecherche, wie Ökosystem-Tools die Claude-Code-CLI integrieren (Session-Bindung, Status-Erkennung, Multi-Account) — und was davon offiziell stabil vs. Reverse-Engineering ist.
---

# Claude-CLI-Ökosystem: Wie andere Tools die Claude-Code-CLI integrieren

Recherche-Stand: 2026-07-18. Quellen: offizielle Claude-Code-Doku (code.claude.com/docs) und die GitHub-Repos bzw. Doku-Seiten der genannten Projekte. Alle Projekte wurden live verifiziert; tote/eingestellte Kandidaten sind als solche markiert.

## 1. Projektübersicht

| Projekt | Link | Sprache/Stack | Aktivität (Stand 07/2026) |
|---|---|---|---|
| **Crystal** (→ Nimbalyst) | [stravu/crystal](https://github.com/stravu/crystal) | Electron, TypeScript, node-pty, SQLite | ⚠️ **Deprecated** seit 02/2026, Nachfolger ist das (closed-source-nähere) Produkt Nimbalyst |
| **claudecodeui** | [siteboon/claudecodeui](https://github.com/siteboon/claudecodeui) | Node/Express + React/Vite, SQLite, WebSockets | ✅ Sehr aktiv, ~12,7k Stars, 83 Releases; Multi-Provider (Claude, Codex, Cursor, Gemini, OpenCode) |
| **happy** (Happy Coder) | [slopus/happy](https://github.com/slopus/happy) | TypeScript-Monorepo: CLI-Wrapper, Expo-App, E2E-verschlüsselter Relay-Server | ✅ Aktiv, ~22,7k Stars; das frühere Repo [slopus/happy-cli](https://github.com/slopus/happy-cli) wurde 02/2026 archiviert und ins Haupt-Repo gemerged |
| **opcode** (ex „claudia") | [getAsterisk/opcode](https://github.com/getAsterisk/opcode) | Tauri 2 (Rust) + React 18, SQLite | ⚠️ Semi-aktiv: ~22,2k Stars, letztes Release v0.2.0 (08/2025) — fast ein Jahr alt |
| **CCManager** | [kbwo/ccmanager](https://github.com/kbwo/ccmanager) | Node/TypeScript TUI (Ink-artig), PTY | ✅ Sehr aktiv: v4.2.1 vom 11.07.2026, 153 Releases; 8 CLIs unterstützt |
| **claude-squad** | [smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad) | Go TUI, tmux + git worktrees | ✅ Aktiv; max. 10 parallele Instanzen |
| **Vibe Kanban** | [BloopAI/vibe-kanban](https://github.com/BloopAI/vibe-kanban) | Rust-Backend + TS-Frontend | ⚠️ **Sunsetting** laut README (trotz ~27,4k Stars) — als Architektur-Referenz noch brauchbar, als Abhängigkeit tot |
| **claude-code-profiles** | [quinnjr/claude-code-profiles](https://github.com/quinnjr/claude-code-profiles) | Shell/CLI | Kleines Nischen-Tool, funktional; repräsentativ für die ganze Gattung „CLAUDE_CONFIG_DIR-Switcher" (ccs, aimux, direnv-Setups) |
| **claude-code-log** | [daaain/claude-code-log](https://github.com/daaain/claude-code-log) | Python CLI | Aktiv; JSONL→HTML/Markdown-Konverter, gute Referenz fürs JSONL-Schema |

Nicht weiter vertieft: **Conductor** (conductor.build, closed source, macOS-nativ — kein einsehbarer Code) und diverse tmux-Statusleisten wie [samleeney/tmux-agent-status](https://github.com/samleeney/tmux-agent-status) (nutzt Hooks statt Polling — bestätigt den Hook-Ansatz).

## 2. Der offizielle Vertrag: Was ist stabil, was ist Reverse-Engineering?

Die entscheidende Trennlinie zieht Anthropic selbst in der [Sessions-Doku](https://code.claude.com/docs/en/sessions):

> „The entry format is internal to Claude Code and changes between versions, so scripts that parse these files directly can break on any release. To build on session data, use `/export` or the script interfaces instead."

### Offiziell stabil (dokumentierte Schnittstellen)

| Schnittstelle | Status | Relevanz |
|---|---|---|
| **Hooks** ([Doku](https://code.claude.com/docs/en/hooks)) | Offiziell, dokumentiertes JSON-Schema auf stdin: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, seit v2.1.196 auch `prompt_id`. Inzwischen 30+ Events (`SessionStart`, `SessionEnd`, `Stop`, `Notification`, `PreToolUse`, `PermissionRequest`, `SubagentStart/Stop`, …) | **Der** sanktionierte Weg für Event-getriebene Integration. Explizit empfohlen: „React to session events: read the `transcript_path` field that hooks … receive as input." |
| **`--settings <pfad-oder-json>`** ([CLI-Ref](https://code.claude.com/docs/en/cli-reference)) | Offiziell: „Values you set here override the same keys in your settings.json files for this session." | Session-scoped Hook-Injection ohne die User-Settings anzufassen — genau WhisperM8s Mechanik. |
| **`--resume <id\|name>` / `--continue` / `--session-id <uuid>` / `--fork-session` / `--name`** | Offiziell dokumentiert. Wichtig: `--session-id` erlaubt, die UUID **vorzugeben**; Resume-per-ID ist auf das Projektverzeichnis (+ Worktrees) gescoped. | Session-Bindung ohne jedes Parsing möglich (ID selbst vergeben statt hinterher suchen). |
| **`-p` + `--output-format json/stream-json`** ([Headless-Doku](https://code.claude.com/docs/en/headless)) | Offiziell: strukturierte Events inkl. Session-ID, Usage, Cost. | Basis der „Headless-Fraktion" (Crystal, Vibe Kanban, claudecodeui-Chat-Modus). |
| **`--bg` / `claude attach <id>` / `claude agents --json`** | Offiziell (Agent-View-Doku); `--bg` „Prints the session ID and management commands". | WhisperM8s Background-Agents laufen bereits darauf. |
| **Agent SDK** (TypeScript/Python) | Offiziell, der von Anthropic bevorzugte programmatische Weg. | Alternative zur PTY, wenn man das UI selbst rendert. |
| **`CLAUDE_CONFIG_DIR`** | Offiziell referenziert („Move storage off `~/.claude`", [Sessions-Doku](https://code.claude.com/docs/en/sessions#where-transcripts-are-stored)) — isoliert Config, Login **und** Session-Storage. Kurioserweise fehlt die Variable in der env-vars-Tabelle selbst; sie ist aber quer durch die Doku verankert. | Standard-Mechanik aller Multi-Account-Tools. |
| **`CLAUDECODE=1` / `CLAUDE_CODE_CHILD_SESSION=1`** ([env-vars](https://code.claude.com/docs/en/env-vars)) | Offiziell: markiert von Claude Code gespawnte Subprozesse; nested Sessions werden automatisch aus `--resume`/Picker ausgeschlossen. | Bestätigt WhisperM8s Env-Bereinigung in `LoginShellEnvironment` als notwendig und korrekt. |

### Fragil (Reverse-Engineering, kann mit jedem Release brechen)

1. **Session-JSONL direkt parsen** (`~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`): Pfadschema (cwd mit `-` ersetzt) und Zeilenformat (`type`, `uuid`, `parentUuid`, `sessionId`, `cwd`, `gitBranch`, `version`, `message.content`-Blöcke, `message.usage`) sind zwar de facto seit langem stabil und von Dutzenden Tools ([claude-code-log](https://github.com/daaain/claude-code-log), claudecodeui, opcode, …) implementiert — aber **explizit als „internal, changes between versions" deklariert**. Bekannte Stolperfallen aus der Doku: `/cd` **verschiebt** eine Session in ein anderes Projektverzeichnis (seit v2.1.169), `--fork-session`/`/branch` erzeugen neue IDs, zwei Terminals auf derselben Session interleaven in **eine** Datei.
2. **Terminal-Output-Pattern-Matching** (CCManager, claude-squad): Status aus dem gerenderten TUI-Output ableiten (Spinner-Zeichen, Prompt-Muster, Content-Hashing). Maximal fragil — jedes TUI-Redesign bricht die Detektion; CCManager pflegt deshalb pro CLI-Tool eine eigene „state detection strategy" und shippt laufend Fixes dafür (153 Releases).
3. **Interne State-Dateien** (`~/.claude/jobs/<id>/state.json` der Background-Agents, `~/.claude.json`): nirgends als Vertrag dokumentiert.

## 3. Wie lösen die Projekte die Kernprobleme?

### 3.1 Session-Bindung (welche externe Session gehört zu meinem UI-Objekt?)

- **Crystal / Vibe Kanban (Headless-Fraktion)**: umgehen das Problem, indem sie nie eine fremde Session „finden" müssen — sie starten `claude -p --output-format stream-json`, lesen die Session-ID aus dem ersten JSON-Event und persistieren sie in ihrer eigenen SQLite-DB. Follow-ups laufen als `--resume <id>`-Aufruf. Nachteil: kein echtes TUI, das UI muss alles selbst rendern (Crystals CLAUDE.md: eigene `conversation_messages`- und `session_outputs`-Tabellen pro Panel).
- **claudecodeui**: hybrider Ansatz — die Chat-Historie kommt aus dem direkten Lesen von `~/.claude/projects/*.jsonl` (per File-Watcher + `ClaudeSessionSynchronizer` in eine lokale SQLite gespiegelt), neue Prompts werden headless gespawnt und per WebSocket gestreamt. Ein „Session Protection System" verhindert, dass der Projekt-Watcher während eines aktiven Chats die UI-Session überschreibt (Race zwischen Discovery und laufendem Stream — exakt das Problem, das WhisperM8 mit der Trennung Workspace-Store vs. Runtime-Status löst).
- **happy**: radikalster Ansatz — `happy claude` **wrappt** den CLI-Start komplett, besitzt die Session also von Geburt an; für Remote-Steuerung wird die Session „in remote mode neu gestartet" (SDK-getrieben), lokal läuft ein PTY. Bindung ist trivial, weil es nie eine fremdgestartete Session gibt. Dafür: ohne den Wrapper gestartete Sessions sind unsichtbar.
- **CCManager / claude-squad**: besitzen ihre Sessions ebenfalls selbst (PTY bzw. tmux-Session pro Instanz), Bindung = Prozess-Ownership. Extern gestartete Sessions: nicht abgedeckt.
- **Niemand** in der Stichprobe nutzt konsequent die sauberste offizielle Variante: **`--session-id <selbstgewählte-UUID>`** beim Start vergeben und damit die Bindung deterministisch machen, oder die Hook-Felder `session_id` + `transcript_path` als Bindungsquelle (WhisperM8s `ClaudeHookBridge` tut genau letzteres).

### 3.2 Status-Erkennung (working / awaiting input / idle)

Drei Schulen, aufsteigend nach Robustheit:

1. **Output-Polling + Pattern-Matching** (claude-squad: 500-ms-Poll über tmux-Output + Content-Hashing; CCManager: per-Tool-Regex auf PTY-Output für busy/waiting_input/idle). Funktioniert für jedes CLI-Tool ohne dessen Mitwirkung, bricht aber bei jedem UI-Update — CCManagers Release-Historie ist voll von Detection-Fixes (z. B. „detect MCP tool permission prompts as waiting_input").
2. **Stream-Events konsumieren** (Crystal, Vibe Kanban, claudecodeui im Chat-Modus): Im Headless-Modus liefert `stream-json` harte Ereignisse (Turn-Ende, Tool-Use, Result) — Status ist ein Nebenprodukt des Protokolls. Robust, aber nur für selbst gestartete Headless-Runs.
3. **Hooks als Ereignisquelle** (tmux-agent-status; WhisperM8): `Stop`, `Notification`, `PermissionRequest`, `SessionStart/End` feuern exakt bei den relevanten Übergängen, mit dokumentiertem Schema. tmux-agent-status wirbt explizit damit, Zustände „from agent lifecycle events rather than fragile process polling" zu beziehen. Einzige Lücke: Hooks brauchen Injektion beim Start (via `--settings` oder User-Settings) — für extern gestartete Sessions greift nur Transcript-Beobachtung als Fallback.

CCManager hat zusätzlich „status change hooks" — aber in umgekehrter Richtung (eigene Commands ausführen, wenn CCManager einen Statuswechsel *detektiert*), nicht Claude-Hooks als Quelle.

### 3.3 Transcript-/History-Zugriff

- **JSONL-Direktleser**: claudecodeui (mit Normalisierungsschicht `NormalizedMessage` über Claude/Cursor/Codex/Gemini — die pro Provider JSONL, SQLite oder andere Formate abstrahiert), opcode (Session-Browser über `~/.claude/projects/`), claude-code-log. Alle akzeptieren still das Bruchrisiko.
- **Eigene Persistenz**: Crystal schreibt jede Konversation zusätzlich in die eigene DB — doppelte Wahrheit, dafür unabhängig vom internen Format.
- **Offiziell wäre**: `/export`, `claude -p --resume <id> --output-format json` für nachträgliche Abfragen, oder `transcript_path` aus Hook-Payloads (immerhin ein offizieller *Pfad*-Lieferant, auch wenn das *Format* dahinter intern bleibt).

### 3.4 Multi-Account-Isolation

Der gesamte Markt konvergiert auf **`CLAUDE_CONFIG_DIR`**: ein Verzeichnis pro Account (Login/OAuth-Token, Settings, History, Session-Storage komplett getrennt), umgeschaltet per Shell-Alias, direnv, oder Wrapper wie [claude-code-profiles](https://github.com/quinnjr/claude-code-profiles) („Each profile is a complete, isolated Claude Code configuration directory") und ccs (`~/.ccs/instances/<n>` + exec). Kein Projekt der Stichprobe hat einen anderen Mechanismus gefunden — es gibt schlicht keinen. Trade-off, den alle teilen: getrennte Config-Dirs heißt auch getrennte Settings/Plugins/History; wer teilen will, muss symlinken oder synchronisieren.

## 4. Direkter Vergleich zu WhisperM8

### Was WhisperM8 besser macht

- **Hooks als Status-SoT statt Output-Parsing**: `ClaudeHookSettingsBuilder` + `--settings`-Injection + `ClaudeHookBridge` (Event-Datei + `DispatchSourceFileSystemObject`) nutzt die *offiziellste* verfügbare Schnittstelle. Bewusste Detail-Entscheidungen wie der Ausschluss von `Notification` wegen `idle_prompt`-Rauschen (Kommentar in `ClaudeHookSettingsBuilder.swift`) sind reifer als alles, was die Stichprobe zeigt. CCManager/claude-squad stehen mit Pattern-Matching eine Robustheitsklasse darunter.
- **Echtes TUI statt nachgebautem Chat**: Die Headless-Fraktion (Crystal, Vibe Kanban) muss jedes UI-Feature von Claude Code (Plan-Mode, Permission-Dialoge, Checkpoints, Slash-Commands) selbst nachbauen oder verlieren. WhisperM8s SwiftTerm-PTY + `AgentCommandBuilder` behält das Original-TUI und ergänzt nur außen herum — deutlich update-resistenter gegenüber neuen Claude-Code-Features.
- **Extern gestartete Sessions**: `AgentDirectoryEventMonitor` (FSEvents auf `~/.claude/projects`) + `AgentSessionIndexer` decken Sessions ab, die *nicht* aus der App gestartet wurden. happy, CCManager, claude-squad und Crystal sehen nur, was sie selbst gestartet haben.
- **Hybrid-Statusmodell**: hook-live-Gating mit Transcript-Fallback (stat-first-Eskalation, vnode-Events) kombiniert Schule 3 und die Beobachtung der JSONL-Dateien — keines der untersuchten Tools hat beide Pfade.
- **Multi-Account bereits integriert**: `ClaudeAccountProfiles` (`~/.claude-profiles/<name>/` als `CLAUDE_CONFIG_DIR`, injiziert via `AgentCommandBuilder`) entspricht dem Stand der Technik der dedizierten Switcher-Tools — aber in die Session-UI integriert statt als Shell-Alias.
- **Env-Hygiene**: das Entfernen geerbter `CLAUDE_CODE_*`-/`CLAUDECODE`-Variablen in `LoginShellEnvironment` ist durch die offizielle Doku bestätigt kritisch (nested Sessions werden sonst aus `--resume`/Picker/agents-Liste ausgeschlossen) — dieser Gotcha ist in der Stichprobe nirgends explizit behandelt.

### Was andere besser machen / wo WhisperM8 schlechter dasteht

- **Kein Struktur-Stream für Programmatisches**: Wo WhisperM8 Inhalte braucht (Auto-Naming, Summaries, Kontext-Tail), parst es die als „internal" deklarierten JSONL-Dateien (`ClaudeTranscriptReader`). Crystal/Vibe Kanban beziehen dieselben Daten aus dem stabilen `stream-json`-Vertrag. WhisperM8 trägt hier dasselbe Bruchrisiko wie claudecodeui/opcode — gemildert nur dadurch, dass Parsing-Fehler degradieren statt crashen.
- **Provider-Normalisierung**: claudecodeuis `NormalizedMessage`-Adapter-Pattern über 5 Provider ist sauberer verallgemeinert als WhisperM8s zwei getrennte Reader (`ClaudeTranscriptReader`/`CodexTranscriptReader`) → `AgentChatTranscript`. WhisperM8 ist funktional gleichwertig, aber ein dritter Provider wäre dort billiger.
- **Session-Schutz explizit benannt**: claudecodeuis „Session Protection System" adressiert dieselbe Race (Discovery-Refresh vs. aktive Session) wie WhisperM8s Store/Runtime-Trennung — hat sie aber als eigenständiges, getestetes Subsystem formalisiert. Bei WhisperM8 ist der Schutz über Store-Konventionen verteilt („nie `loadWorkspace()` zum Refreshen").
- **Checkpoint-/Timeline-UX**: opcodes Snapshot/Restore-Timeline pro Session hat WhisperM8 nicht (Claude Code bringt inzwischen natives Checkpointing mit — im TUI nutzbar, aber nicht in WhisperM8s Transcript-UI reflektiert).
- **Remote-Zugriff**: happys E2E-verschlüsselte Mobile-Brücke inklusive Push bei Permission-Requests ist eine Dimension, die WhisperM8 (bewusst) nicht besetzt — die `AgentSessionNotifier`-Notifications sind lokal.

## 5. Übertragbare Muster für WhisperM8 (priorisiert)

1. **`--session-id` für selbst gestartete Sessions vergeben (hoch, geringer Aufwand)**: Statt die externe Session-ID nachträglich über Hook-Events zu binden, kann WhisperM8 beim Start eine eigene UUID via `--session-id` mitgeben — die Bindung wird deterministisch, der SessionStart-Hook zur reinen Bestätigung, und Race-Fenster zwischen Spawn und erstem Hook-Event verschwinden. (Offiziell dokumentiert; kein anderes Tool der Stichprobe nutzt das konsequent — echter Vorsprung möglich.) Zu prüfen: Zusammenspiel mit `--fork-session`-Semantik beim Resume.
2. **JSONL-Parser als „tolerant by contract" härten (hoch)**: Anthropic sagt explizit, das Format darf jederzeit brechen. Konsequenz: (a) Schema-Drift-Telemetrie — unbekannte `type`-Werte/fehlende Felder zählen und einmalig loggen statt still ignorieren; (b) ein kleiner Golden-File-Testkorpus mit JSONL-Fixtures mehrerer Claude-Versionen, damit ein `claude`-Update sofort in `swift test` sichtbar wird; (c) dokumentierte Degradations-Matrix (was funktioniert noch, wenn nur `sessionId`+`timestamp` lesbar sind — Status ja, Summary nein, …).
3. **Doku-Versionsanker beobachten (mittel)**: Die offizielle Doku annotiert Verhaltensänderungen mit Min-Versionen (z. B. v2.1.169 `/cd` verschiebt Sessions ins neue Projektverzeichnis — bricht cwd-basierte Discovery-Annahmen; v2.1.196 Default-Display-Names; `--bg`-Einschränkungen). Ein kurzer Audit-Check pro Claude-Release gegen `sessions`/`hooks`-Doku ist billiger als Bug-Reports von Usern. Konkret prüfenswert heute: behandelt `AgentSessionIndexer` den Fall, dass eine bekannte Session-Datei per `/cd` in einen **anderen** Projektordner wandert?
4. **`claude agents --json` als zusätzliche Statusquelle (mittel)**: Offiziell dokumentiert, liefert laufende Sessions inkl. Default-Display-Names. Als Cross-Check gegen die eigene Runtime-Watcher-Sicht (verwaiste „working"-Stati erkennen) deutlich robuster als weitere JSONL-Heuristiken.
5. **Transcript-Normalisierungsschicht formalisieren (mittel, nur bei Provider-Ausbau)**: Falls je ein dritter Agent (Gemini CLI, Cursor, …) dazukommt, claudecodeuis Adapter-Pattern übernehmen: pro Provider ein Reader gegen ein explizites `NormalizedMessage`-Protokoll statt zwei parallel gewachsener Reader.
6. **Headless-Kanal für programmatische Abfragen (niedrig)**: Für Auto-Naming/Summaries wäre `claude -p --resume <id> --output-format json "fasse zusammen"` der vertraglich stabile Weg statt JSONL-Lesen — kostet aber Tokens und Latenz; nur als Fallback erwägen, wenn Muster 2 zu oft anschlägt.
7. **Nicht übernehmen**: Terminal-Output-Pattern-Matching (CCManager/claude-squad) — WhisperM8s Hook-Ansatz ist strikt überlegen; eigene Konversations-Persistenz à la Crystal — doppelte Wahrheit ohne Not; Session-Wrapping à la happy — würde extern gestartete Sessions ausschließen, die WhisperM8 heute abdeckt.

## Quellen

- Offiziell: [Hooks-Referenz](https://code.claude.com/docs/en/hooks) · [CLI-Referenz](https://code.claude.com/docs/en/cli-reference) · [Sessions](https://code.claude.com/docs/en/sessions) · [Env-Vars](https://code.claude.com/docs/en/env-vars)
- Projekte: [stravu/crystal](https://github.com/stravu/crystal) (+ [CLAUDE.md](https://github.com/stravu/crystal/blob/main/CLAUDE.md)) · [siteboon/claudecodeui](https://github.com/siteboon/claudecodeui) (+ [DeepWiki-Architektur](https://deepwiki.com/siteboon/claudecodeui/2-architecture-overview)) · [slopus/happy](https://github.com/slopus/happy) · [slopus/happy-cli](https://github.com/slopus/happy-cli) (archiviert) · [getAsterisk/opcode](https://github.com/getAsterisk/opcode) · [kbwo/ccmanager](https://github.com/kbwo/ccmanager) · [smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad) (+ [DeepWiki](https://deepwiki.com/smtg-ai/claude-squad)) · [BloopAI/vibe-kanban](https://github.com/BloopAI/vibe-kanban) · [quinnjr/claude-code-profiles](https://github.com/quinnjr/claude-code-profiles) · [daaain/claude-code-log](https://github.com/daaain/claude-code-log) · [samleeney/tmux-agent-status](https://github.com/samleeney/tmux-agent-status)
- JSONL-Format (Community-Analysen): [claude-dev.tools/docs/jsonl-format](https://claude-dev.tools/docs/jsonl-format) · [Medium: Inside Claude Code — Session File Format](https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b)
