# 02 · Sessions, CLI & Headless-Mode

> Quellen: <https://code.claude.com/docs/en/agent-sdk/sessions>, <https://code.claude.com/docs/en/headless>, <https://code.claude.com/docs/en/cli-reference>, <https://code.claude.com/docs/en/agent-sdk/overview>.

## 1. Anatomie einer Session

Eine **Session** ist die Konversations-Historie + alle Tool-Calls + alle Tool-Results, akkumuliert während Claude arbeitet. Das SDK / die CLI schreiben sie **automatisch auf Disk**, du kannst sie später jederzeit fortsetzen.

> Wichtige Trennung: *Sessions persistieren die Konversation, nicht das Filesystem.* File-Snapshots laufen separat über **File-Checkpointing**.

## 2. Wo Sessions liegen

```
~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
```

- `<encoded-cwd>` = absoluter Working-Directory-Pfad, jedes Nicht-Alphanumerische → `-`.
  - `/Users/me/proj` → `-Users-me-proj`.
- `<session-uuid>` = standard UUID, z. B. `550e8400-e29b-41d4-a716-446655440000`.
- Datei ist **JSON-Lines**: jede Zeile ein Message-Event (User, Assistant, Tool-Use, Tool-Result, System-Meta).

WhisperM8 liest diese JSONLs für die Live-Transcripts (`ClaudeTranscriptReader`) und für den `AgentSessionIndexer`.

## 3. Continue, Resume, Fork — die Unterscheidung

| Modus | CLI-Flag | SDK-Option | Findet die Session über … |
| :---- | :------- | :--------- | :------------------------ |
| **Continue** | `-c` / `--continue` | `continue: true` (TS) / `continue_conversation=True` (Py) | **Letzte** Session im aktuellen cwd |
| **Resume** | `-r <id\|name>` / `--resume <id>` | `resume: <id>` | Spezifische Session per UUID oder Name |
| **Fork** | `--fork-session` (mit `--resume` oder `--continue`) | `forkSession: true` mit `resume: …` | Kopiert History → neue UUID, Original bleibt unverändert |

> Default: Resume *modifiziert* die existierende Session. Fork *kopiert* die Historie und macht eine neue Session-ID — gut um Alternativen durchzuspielen, ohne den Original-Pfad zu zerstören.

## 4. Welche Option WhisperM8 schon benutzt

Aus `AgentCommandBuilder.swift` (Repo):

```swift
if session.hasLaunchedInitialPrompt {
    arguments.append(contentsOf: ["--resume", externalSessionID])
} else if let externalSessionID = session.externalSessionID {
    arguments.append(contentsOf: ["--session-id", externalSessionID])
}
```

→ **Erster Start**: `--session-id <uuid>` (UUID vorgegeben, JSONL-Pfad deterministisch).
→ **Resume**: `--resume <uuid>`.

Das ist der "präzise Pfad" — wir wissen genau, welche JSONL zu welcher WhisperM8-Tab gehört. Eine *Background-Session* (Agent View) hat **keine** vom Caller vorgegebene UUID — sie wird vom Supervisor erzeugt.

## 5. Volle CLI-Subcommand-Liste

(aus [`cli-reference`](https://code.claude.com/docs/en/cli-reference))

| Command | Funktion |
| :------ | :------- |
| `claude` | Interactive |
| `claude "query"` | Interactive + initial Prompt |
| `claude -p "query"` | Headless / SDK CLI |
| `cat … \| claude -p "…"` | Piped Headless |
| `claude -c` | Continue (cwd-spezifisch) |
| `claude -c -p "…"` | Continue Headless |
| `claude -r "<id\|name>" "…"` | Resume |
| `claude update` | Update |
| `claude install [version]` | Native Binary installieren |
| `claude auth login\|logout\|status` | Auth |
| `claude agents` | Agent View |
| `claude attach <id>` | Background-Session attachen |
| `claude logs <id>` | Background-Session Output |
| `claude stop <id>` / `kill` | Background-Session stoppen |
| `claude respawn <id>` / `--all` | Restart |
| `claude rm <id>` | Background-Session entfernen |
| `claude auto-mode defaults` | Built-in Auto-Mode-Classifier-Rules als JSON |
| `claude mcp` | MCP-Server konfigurieren |
| `claude plugin` | Plugins (Alias: `claude plugins`) |
| `claude project purge [path]` | Projekt-State löschen |
| `claude remote-control` | Remote-Control Server-Mode |
| `claude setup-token` | Long-lived OAuth-Token (CI) |
| `claude ultrareview [target]` | Multi-Agent-Code-Review (non-interactive) |

## 6. Die wichtigsten Flags fürs Embedding

| Flag | Bedeutung |
| :--- | :-------- |
| `--print`, `-p` | Headless / non-interactive |
| `--output-format text\|json\|stream-json` | Output-Modus |
| `--include-hook-events` | Hook-Events in den Stream packen (nur `stream-json`) |
| `--include-partial-messages` | Token-Streaming für UI |
| `--input-format text\|stream-json` | Stdin als Stream-JSON |
| `--bare` | Schneller Start ohne Auto-Discovery |
| `--allowedTools "Bash,Edit,…"` | Auto-Approve-Set |
| `--disallowedTools "…"` | Tools komplett aus Context entfernen |
| `--tools "…"` | Built-in-Tools einschränken (`""` = none) |
| `--permission-mode <mode>` | Default, acceptEdits, plan, auto, dontAsk, bypassPermissions |
| `--permission-prompt-tool` | MCP-Tool als Permission-Handler |
| `--add-dir <path>` | Weitere working dirs erlauben |
| `--max-turns N` / `--max-budget-usd X` | Limits (nur Print-Mode) |
| `--fallback-model` | Fallback bei Overload (Print-Mode) |
| `--model <alias\|name>` | Modell wählen |
| `--effort low\|medium\|high\|xhigh\|max` | Reasoning-Effort |
| `--agent <name>` | Sub-Agent als Main-Agent fahren |
| `--agents '<json>'` | Sub-Agents dynamisch via JSON |
| `--bg "<prompt>"` | Direkt als Background dispatchen |
| `--worktree [name]` / `-w` | Im worktree starten |
| `--tmux` | Mit tmux (benötigt `--worktree`) |
| `--name "label"` / `-n` | Display-Name für die Session |
| `--session-id <uuid>` | Eigene UUID vorgeben |
| `--resume <id\|name>` | Resume |
| `--continue` / `-c` | Letzte Session im cwd |
| `--fork-session` | Fork |
| `--no-session-persistence` | Stateless (Print-Mode) |
| `--from-pr <num\|url>` | Sessions, die zu PR linked sind |
| `--settings <path\|json>` | Settings überschreiben |
| `--setting-sources user,project,local` | Welche Settings-Files |
| `--system-prompt` / `--system-prompt-file` | Default-System-Prompt ersetzen |
| `--append-system-prompt[-file]` | Anhängen |
| `--mcp-config <path\|json>` | MCP-Server hinzufügen |
| `--strict-mcp-config` | Nur die, sonst keine |
| `--plugin-dir <path>` / `--plugin-url <url>` | Plugins ad-hoc |
| `--ide` | Mit IDE verbinden |
| `--debug` / `--debug-file <path>` | Debug |
| `--verbose` | Turn-für-Turn |
| `--remote-control` / `--rc` | Mit Remote Control |
| `--remote "task"` | Cloud-Session auf claude.ai/code |
| `--teleport` | Cloud-Session lokal weiterführen |
| `--chrome` / `--no-chrome` | Chrome-Integration |
| `--channels` | MCP-Channel-Notifications (Research Preview) |
| `--init-only` | Nur Setup + SessionStart-Hooks, dann beenden |
| `--init` / `--maintenance` | Setup-Hooks mit jeweiligem Matcher |
| `--json-schema '<schema>'` | Validated JSON-Output |
| `--exclude-dynamic-system-prompt-sections` | Cache-friendlier System-Prompt |
| `--replay-user-messages` | Stream-JSON-Echo |
| `--max-budget-usd` | Hard-Cap auf Budget |

## 7. Headless-Mode in einem Beispiel

```bash
claude -p "Find and fix the bug in auth.py" \
  --allowedTools "Read,Edit,Bash" \
  --output-format stream-json \
  --include-partial-messages \
  --verbose
```

Stream-JSON-Format: Eine Zeile = ein Event. Wichtigste Event-Types:

| Event | Bedeutung |
| :---- | :-------- |
| `system/init` | Erster Event: Session-Metadata, Modell, Tools, geladene Plugins/MCP-Server (`plugins[]`, `plugin_errors[]`). Enthält **`session_id`** schon direkt. |
| `system/plugin_install` | Plugin-Install-Fortschritt (wenn `CLAUDE_CODE_SYNC_PLUGIN_INSTALL=1`) |
| `system/api_retry` | API-Retry mit `attempt`, `max_retries`, `retry_delay_ms`, `error_status`, `error` (z. B. `rate_limit`) |
| `user` / `assistant` | Konversations-Messages |
| `tool_use` / `tool_result` | Tool-Aufrufe |
| `stream_event` | Token-Deltas (`event.delta.text`) bei `--include-partial-messages` |
| `result` | Letztes Event: Final Result, Cost, Session-ID, Subtype (`success` / `error_max_turns` / `error_max_budget_usd` / …) |

In Python:
```python
from claude_agent_sdk import query, ClaudeAgentOptions, ResultMessage

async for message in query(
    prompt="Analyze the auth module",
    options=ClaudeAgentOptions(allowed_tools=["Read","Glob","Grep"]),
):
    if isinstance(message, ResultMessage):
        session_id = message.session_id
```

In TypeScript:
```ts
for await (const message of query({
  prompt: "Analyze the auth module",
  options: { allowedTools: ["Read","Glob","Grep"] }
})) {
  if (message.type === "result") sessionId = message.session_id;
}
```

## 8. `ClaudeSDKClient` vs `query()`

| Bibliothek | Was sie macht |
| :--------- | :------------ |
| `claude_agent_sdk.query()` (Python) / `query()` (TS) | Standalone-Call. Selbst Session-IDs tracken, wenn du multi-turn willst. |
| `ClaudeSDKClient` (Python) | Async Context Manager — hält die Session-ID intern. Mehrere `client.query()`-Calls = derselbe Multi-Turn-Chat. |
| TS V1 `continue: true` | Pattern für Multi-Turn: Sub-Sequent `query()`-Calls mit `continue: true` resumed automatisch. |
| TS V2 Session API | **Deprecated** — V1-Pattern nutzen. |

## 9. Sessions auflisten + verwalten programmatisch

| Funktion | Zweck |
| :------- | :---- |
| `listSessions()` (TS) / `list_sessions()` (Py) | Alle Sessions auf Disk enumerieren |
| `getSessionMessages()` / `get_session_messages()` | Alle Messages einer Session lesen |
| `getSessionInfo()` / `get_session_info()` | Metadata einer Session |
| `renameSession()` / `rename_session()` | Display-Name setzen |
| `tagSession()` / `tag_session()` | Tags setzen |

Damit ließe sich z. B. ein eigener "Session Browser" bauen (siehe [Cookbook](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser)).

## 10. Cross-Host-Sessions

Sessions sind streng lokal. Zwei Optionen für Server-/Cross-Machine-Setups:

1. **Session-File spiegeln**: `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` auf einen Storage syncen, auf dem neuen Host restorieren, dann `resume` aufrufen. cwd muss matchen.
2. **`SessionStore`-Adapter** im SDK schreiben — siehe <https://code.claude.com/docs/en/agent-sdk/session-storage>.
3. **Alternative**: Statt Transcript syncen, nur die *Ergebnisse* (Output, Diffs, Entscheidungen) als App-State persistieren und in einen frischen Prompt füttern.

## 11. JSON-Schema-Output für strukturierte Daten

```bash
claude -p "Extract function names from auth.py" \
  --output-format json \
  --json-schema '{"type":"object","properties":{"functions":{"type":"array","items":{"type":"string"}}},"required":["functions"]}'
```

→ Antwort enthält `structured_output` mit garantiert valider Struktur.

## 12. `--bare`-Mode — wichtig für Embedding

`--bare` skipped: Auto-Discovery von Hooks, Skills, Plugins, MCP, Auto-Memory, CLAUDE.md.
- Tools die Claude trotzdem hat: Bash, File Read, File Edit.
- Auth: nur via `ANTHROPIC_API_KEY` oder `apiKeyHelper` in `--settings`. Keychain & OAuth werden geskipped.
- Lädt nichts aus `~/.claude` oder `.claude/`, was der User vielleicht lokal hat — gut für reproduzierbares CI.
- Wird in einer zukünftigen Version **default** für `-p` werden.

Was du im Bare-Mode brauchst, gibst du explizit:
```bash
claude --bare -p "Summarize this file" \
  --allowedTools "Read" \
  --settings ./my-settings.json \
  --mcp-config ./mcp.json \
  --plugin-dir ./my-plugin
```

## 13. `--bg` und Background-Stream

`claude --bg "<prompt>"` startet eine Background-Session (Agent-View-Welt). Print auf stdout:
```
backgrounded · 7c5dcf5d
  claude agents             list sessions
  claude attach 7c5dcf5d    open in this terminal
  claude logs 7c5dcf5d      show recent output
  claude stop 7c5dcf5d      stop this session
```

`--bg` + `--agent <name>` kombiniert → die Background-Session fährt den angegebenen Sub-Agent als Main.

## 14. Wichtigste SDK-Optionen (auszugsweise)

Python `ClaudeAgentOptions` / TS `Options` haben u. a.:

- `allowed_tools` / `allowedTools`
- `permission_mode` / `permissionMode`
- `resume`, `continue` (TS) / `continue_conversation` (Py), `fork_session` / `forkSession`
- `session_store` / `sessionStore` — eigener Speicher-Adapter
- `system_prompt`, `append_system_prompt`
- `mcp_servers` / `mcpServers`
- `agents` (für dynamische Sub-Agents)
- `hooks` (mit `HookMatcher` in Python)
- `setting_sources` / `settingSources`
- `cwd`
- `model`, `effort`
- `permission_prompt_tool`
- `include_partial_messages`, `include_hook_events`
- `json_schema`

> Vollständige Doku: <https://code.claude.com/docs/en/agent-sdk/python> · <https://code.claude.com/docs/en/agent-sdk/typescript>

## 15. Skills, Slash-Commands, Plugins — die wichtigsten relevanten Slash-Commands

Aus [`commands`](https://code.claude.com/docs/en/commands):

| Command | Funktion |
| :------ | :------- |
| `/init`, `/memory` | Setup |
| `/mcp`, `/agents`, `/permissions` | Konfigurieren |
| `/plan`, `/model`, `/effort` | Während Task |
| `/context`, `/compact`, `/btw` | Context-Management |
| `/agents` | **In-Session Manager** für Sub-Agents (Running-Tab + Library) — *nicht* zu verwechseln mit `claude agents` |
| `/tasks` | Was läuft im Background der *aktuellen* Session |
| `/background` (`/bg`) | Aktuelle Session in Background detachen |
| `/batch` | Großer Change → 5–30 Worktree-Sub-Agent-Tasks |
| `/remote-control` (`/rc`) | Remote-Control aktivieren |
| `/rename`, `/resume`, `/exit` | Session-Verwaltung |
| `/loop` | Wiederkehrendes Prompt auf Intervall |
| `/stop`, `/clear` | Beenden / Kontext leeren |
| `/config`, `/status`, `/usage`, `/recap` | Diagnose |
| `/mobile` | Download-QR für Mobile-App |

## 16. Take-aways für eine Integration

- WhisperM8 nutzt **interaktive Sessions** mit deterministischen UUIDs — sauber.
- Für **headless Programmsteuerung** ist `claude -p --output-format stream-json --include-hook-events` der einzige offizielle Weg, Events aus Claude in einer eigenen App zu konsumieren.
- Für **Background-Agents** ist `claude --bg` der Weg, eine Session zu erzeugen, die wir später per `attach`/`logs` selber rendern könnten — oder per `claude agents` als TUI hosten lassen.
- Das **Session-Repository auf Disk** (`~/.claude/projects/.../*.jsonl`) ist die einzige stabile Wahrheit, die wir parsen können.
- **SDK-Library-Verwendung** ist nur sinnvoll, wenn wir auf Python/TS-Tooling setzen — Swift/macOS-App heißt: wir bleiben beim **CLI-Subprocess-Pattern**, das wir schon haben.
