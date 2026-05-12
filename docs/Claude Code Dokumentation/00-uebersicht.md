# 00 · Claude Code — Big Picture

Claude Code ist Anthropics agentisches Coding-System. Es gibt **eine zugrundeliegende Agent-Engine** und mehrere Oberflächen, die alle auf dieselben Konzepte (Sessions, Tools, Hooks, Permissions, Skills, Plugins, MCP) zugreifen.

## 1. Die fünf Oberflächen

| Oberfläche | Wo läuft Claude? | Ausgelöst durch | Wofür gut |
| :--------- | :---------------- | :-------------- | :-------- |
| **CLI / `claude`** (interaktiv) | Lokal, im aktuellen Terminal | `claude` in deinem Shell | Tägliches Coden, vollständige Kontrolle |
| **Headless / `-p`** (Agent SDK CLI) | Lokal, ohne TUI | `claude -p "…"` oder Python/TS-SDK | Skripte, CI/CD, Embed in eigene Apps |
| **Agent View** (`claude agents`) | Lokal — Supervisor-Daemon + Background-Processes | `claude agents` (TUI) oder `claude --bg` / `/bg` | Mehrere unabhängige Background-Sessions parallel hosten + überwachen |
| **Remote Control** | Lokal (Client) ↔ [claude.ai/code](https://claude.ai/code) (Steuerung) | `claude remote-control` oder `--rc` | Laufende lokale Session vom Phone/Browser weitersteuern |
| **Claude Code on the web** | Anthropic-Cloud-Sandbox | `claude --remote` oder claude.ai/code | Aufgaben ohne lokales Setup, parallel ausführen lassen |

> Source: [CLI Reference](https://code.claude.com/docs/en/cli-reference), [Agent View](https://code.claude.com/docs/en/agent-view), [Remote Control](https://code.claude.com/docs/en/remote-control), [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web).

## 2. Was *unterhalb* aller Oberflächen gleich ist

Jede Oberfläche startet letztlich eine **Claude-Code-Session**. Sessions haben:

- **Eine `session_id` (UUID)**, die alle Messages, Tool-Calls und Results in einer JSONL aggregiert.
- **Ein cwd (working directory)** — bestimmt, wo die JSONL liegt: `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
- **Settings**, gemerged aus User (`~/.claude/settings.json`) → Project (`.claude/settings.json`) → Local (`.claude/settings.local.json`) → CLI-Flags (`--settings`, `--setting-sources`). Managed-Settings (vom Admin) gewinnen am Ende.
- **Permissions / Permission-Mode** (`default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`).
- **Tools** (Read, Edit, Write, Bash, Glob, Grep, Agent, WebSearch, WebFetch, Monitor, AskUserQuestion … plus MCP-Tools).
- **Hooks** (siehe [`03-hooks-sdk.md`](03-hooks-sdk.md)) — Lifecycle-Hooks die zu jedem Event auslösen können.
- **Plugins / Skills / Sub-Agents / Commands** — alles File-basierte Erweiterungen im `.claude/`-Layout.

## 3. Wie sich die Oberflächen unterscheiden — entscheidende Tabelle

| Aspekt | CLI | `-p` Headless | Agent View | Remote Control | Claude Code on the web |
| :----- | :-: | :------------: | :--------: | :------------: | :--------------------: |
| Eigene TUI | ✅ | ❌ | ✅ (Multi-Session-Dashboard) | Nutzt Browser/Mobile | Browser |
| Persistente Session-JSONL | ✅ | ✅ (default; `--no-session-persistence` opt-out) | ✅ | ✅ | Cloud-Hosted |
| Mehrere parallele Sessions im selben Tool | ❌ (1 pro Terminal) | n/a (jeder Call ist eigen) | ✅ (das ist sein USP) | ❌ pro Process | ✅ Cloud |
| Supervisor-Daemon | ❌ | ❌ | ✅ (`~/.claude/daemon/`) | ❌ | n/a |
| Resumable per `session_id` | ✅ | ✅ | ✅ (per `claude attach <short-id>`) | ✅ | ✅ |
| Subscription / API-Key | Beides | Beides | Sub (research preview) | Sub-only | Sub-only |
| Geeignet als "Window" in eigener GUI | ✅ (PTY) | ✅ (stdin/stdout JSON) | ⚠️ (PTY, aber TUI-typisch) | ❌ direkt — UI ist Anthropic | ❌ direkt |

## 4. Die wichtigsten CLI-Subcommands

Aus der offiziellen [CLI Reference](https://code.claude.com/docs/en/cli-reference) (Stand 2026-05):

| Command | Funktion |
| :------ | :------- |
| `claude` | Interaktive Session starten |
| `claude "query"` | Mit initialem Prompt |
| `claude -p "query"` | Headless / via SDK, dann beenden |
| `claude -c` / `--continue` | Letzte Konversation im cwd fortsetzen |
| `claude -r <id\|name> "query"` / `--resume` | Session per ID/Name fortsetzen |
| `claude --session-id <uuid>` | Mit *vorgegebener* Session-ID starten (WhisperM8 nutzt das!) |
| `claude --fork-session` | Beim Resume ein neues Branch-Session anlegen |
| `claude agents` | Agent View (TUI) öffnen |
| `claude --bg "<prompt>"` | Neue Background-Session aus der Shell |
| `claude attach <id>` | An laufende Background-Session anhängen |
| `claude logs <id>` | Output einer Background-Session ausgeben |
| `claude stop <id>` / `claude kill` | Background-Session beenden |
| `claude respawn <id>` / `--all` | Gestoppte Session(en) wieder hochfahren |
| `claude rm <id>` | Background-Session aus Liste entfernen |
| `claude remote-control` | Server-Mode für Remote-Steuerung von claude.ai |
| `claude --remote "task"` | Neue Cloud-Session auf claude.ai/code starten |
| `claude --teleport` | Cloud-Session lokal weiterführen |
| `claude --worktree <name>` / `-w` | Im isolierten git-worktree starten |
| `claude auth login \| logout \| status` | Auth |
| `claude setup-token` | Lang-lebiges OAuth-Token für CI |
| `claude mcp` | MCP-Server verwalten |
| `claude plugin` | Plugins verwalten |
| `claude project purge [path]` | Lokalen Projekt-State löschen |
| `claude install [version]` | Native Binary installieren/upgraden |
| `claude ultrareview [target]` | Multi-Agent-Code-Review (non-interactive möglich) |

## 5. CLI-Flags, die für eine Integration wirklich wichtig sind

| Flag | Warum für uns interessant |
| :--- | :----------------------- |
| `--settings <path\|json>` | Settings inline / per File überschreiben — wir nutzen das schon für die `ClaudeHookBridge` |
| `--setting-sources user,project,local` | Festlegen, welche Settings-Files geladen werden |
| `--add-dir <dir>` | Weitere Working-Directories freischalten |
| `--allowedTools "Read,Edit,…"` | Auto-Approve-Set für Tools |
| `--permission-mode <mode>` | Default-Mode festlegen |
| `--output-format text\|json\|stream-json` | Für headless: maschinenlesbarer Output |
| `--include-hook-events` | Hook-Events in den Stream packen (nur mit stream-json) |
| `--include-partial-messages` | Token-Streaming für UI |
| `--bare` | Schneller Start, *kein* Auto-Discovery von Plugins/Hooks/Skills/MCP/Memory |
| `--bg` | Direkt als Background-Agent starten |
| `--name <n>` / `-n` | Display-Name für die Session (in Agent View sichtbar) |
| `--session-id <uuid>` | Wir geben die ID vor → JSONL-Pfad ist deterministisch (`~/.claude/projects/<cwd>/<uuid>.jsonl`) |
| `--no-session-persistence` | Stateless-Modus (nur -p) |

## 6. Wichtigste Datei-Pfade auf der Disk

| Pfad | Inhalt |
| :--- | :----- |
| `~/.claude/settings.json` | User-Settings |
| `~/.claude/agents/*.md` | User-globale Sub-Agents |
| `~/.claude/skills/*/SKILL.md` | User-globale Skills |
| `~/.claude/plugins/…` | Installierte Plugins |
| `~/.claude/projects/<encoded-cwd>/*.jsonl` | **Session-Transcripts** (eine JSONL pro Session-ID) |
| `~/.claude/daemon.log` | Supervisor-Log |
| `~/.claude/daemon/roster.json` | Liste aktiver Background-Sessions (für reconnect) |
| `~/.claude/jobs/<short-id>/state.json` | Pro-Background-Session State, wie Agent View ihn anzeigt |
| `.claude/settings.json` (im Projekt) | Project-Settings (gemerged) |
| `.claude/agents/*.md` (im Projekt) | Project-spezifische Sub-Agents |
| `.claude/worktrees/<name>/` | Default-Ort für `--worktree` |
| `CLAUDE.md` / `.claude/CLAUDE.md` | Auto-Memory / Projektregeln |

> `<encoded-cwd>` = absoluter cwd-Pfad, jedes Nicht-alphanumerische Zeichen durch `-` ersetzt. `/Users/me/proj` → `-Users-me-proj`.

## 7. Environment-Variablen

| Variable | Wirkung |
| :------- | :------ |
| `ANTHROPIC_API_KEY` | API-Key-Auth (statt claude.ai-OAuth) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Long-lived Inference-Token (CI) — *nicht* Remote-Control-fähig |
| `CLAUDE_CONFIG_DIR` | Verschiebt `~/.claude` woanders hin (Multi-Instanz möglich) |
| `CLAUDE_CODE_DISABLE_AGENT_VIEW` | Schaltet Agent View komplett ab |
| `CLAUDE_CODE_USE_BEDROCK` / `_USE_VERTEX` / `_USE_FOUNDRY` | Alternativer Backend-Provider |
| `CLAUDE_CODE_SKIP_PROMPT_HISTORY` | Wie `--no-session-persistence` |
| `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA` | Bei Hooks gesetzt |

> Vollständig: <https://code.claude.com/docs/en/env-vars>

## 8. Die schnelle Versions-Matrix relevanter Features

| Feature | Min-Version |
| :------ | :---------- |
| Agent View / `claude agents` | **2.1.139** |
| Remote Control | 2.1.51 (Mobile Push: 2.1.110) |
| VS-Code-Plugin `/remote-control` | 2.1.79 |
| Stdin-Cap (10 MB für `-p`) | 2.1.128 |
| `disableRemoteControl` Managed Setting | 2.1.128 |
| Opus 4.7 SDK-Unterstützung | Agent SDK 0.2.111+ |

## 9. Verbindung der Konzepte — wichtiger Take-away

```
                ┌────────────────────────────────────────────┐
                │            Claude-Code-Engine              │
                │  (Tools, Hooks, Permissions, Skills,       │
                │   Plugins, MCP, Memory, Auto-Discovery)    │
                └──────────────────┬─────────────────────────┘
                                   │
        ┌──────────────┬───────────┴────────────┬──────────────┐
        ▼              ▼                        ▼              ▼
    Interactive    Headless                Agent View       Cloud
    `claude`       `claude -p`             `claude agents`  `claude --remote`
    (1 Session)    (1 Session per Call)    (Supervisor +    (Anthropic-
                                            n Background-    managed
                                            Sessions, lokal)  Sandbox)
                                            │
                                            ├── `claude --bg`
                                            ├── `/bg` aus laufender Session
                                            ├── `claude attach <id>`
                                            ├── `claude stop/respawn/rm`
                                            └── State: ~/.claude/{daemon,jobs}/
```

**Agent View ist also nicht "noch ein UI" — es ist der einzige Code-Pfad in Claude Code, in dem ein lokaler Daemon mehrere autonome Sessions hostet.** Das ist der Unterschied, den WhisperM8 ausnutzen will.
