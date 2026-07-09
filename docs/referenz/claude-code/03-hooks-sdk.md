# 03 · Hooks, Sub-Agents, Skills, MCP & SDK

> Quellen: <https://code.claude.com/docs/en/hooks>, <https://code.claude.com/docs/en/sub-agents>, <https://code.claude.com/docs/en/settings>, <https://code.claude.com/docs/en/agent-sdk/overview>, <https://platform.claude.com/docs/en/managed-agents/overview>.

## 1. Hooks — die Programmable-Lifecycle-API

**Hooks sind user-definierte Side-Effects, die zu Claude-Code-Events feuern.** Sie können ein Shell-Command, ein HTTP-Endpoint, ein MCP-Tool, ein LLM-Prompt oder ein Sub-Agent sein. Sie kriegen JSON via stdin und können via Exit-Code + JSON-Output das Verhalten von Claude steuern.

WhisperM8 nutzt das aktiv für die `ClaudeHookBridge` (SessionStart/SessionEnd) — das ist die **mit Abstand zuverlässigste API**, um Claude-Code-Sessions extern zu beobachten.

### 1.1 Komplette Event-Liste

| Event | Wann |
| :---- | :--- |
| `SessionStart` | Session startet/resumed — Matchers: `startup`, `resume`, `clear`, `compact` |
| `SessionEnd` | Session endet — Matchers: `clear`, `resume`, `logout`, `other` |
| `UserPromptSubmit` | Bevor Claude den User-Prompt verarbeitet |
| `UserPromptExpansion` | Wenn ein Slash-Command expandiert wird |
| `PreToolUse` | Vor jedem Tool-Call — *kann blocken* via Exit 2 oder `permissionDecision: "deny"` |
| `PostToolUse` | Nach erfolgreichem Tool-Call |
| `PostToolUseFailure` | Nach gescheitertem Tool-Call |
| `PermissionRequest` | Wenn ein Permission-Dialog auftaucht |
| `PermissionDenied` | Wenn Auto-Mode-Classifier denied |
| `PostToolBatch` | Nach paralleler Tool-Resolution |
| `Stop` | Wenn Claude einen Turn fertig macht |
| `StopFailure` | Turn endet durch API-Error |
| `Notification` | Notifications (z. B. Permission-Prompt) |
| `SubagentStart` / `SubagentStop` | Sub-Agent gestartet/beendet |
| `PreCompact` / `PostCompact` | Vor/Nach Context-Compaction |
| `FileChanged` | Beobachtete Datei hat sich verändert |
| `CwdChanged` | cwd hat sich geändert |
| `InstructionsLoaded` | CLAUDE.md geladen |
| `ConfigChange` | Settings-Datei geändert |
| `Elicitation` / `ElicitationResult` | MCP User-Input |
| `WorktreeCreate` / `WorktreeRemove` | Worktree-Lifecycle (custom VCS-Adapter möglich) |
| `Setup` | One-time Init (`--init-only`, `--init`, `--maintenance`) |
| `TaskCreated` / `TaskCompleted` | Pro Task im Background |
| `TeammateIdle` | Agent-Team-Teammate idle |

### 1.2 Konfigurations-Schema

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/script.sh",
            "args": [],
            "timeout": 30,
            "if": "Bash(git *)",
            "statusMessage": "Validating command..."
          }
        ]
      }
    ]
  }
}
```

### 1.3 Handler-Typen

| Typ | Wofür |
| :-- | :---- |
| `command` | Shell — JSON in stdin, JSON in stdout |
| `http` | POST JSON an URL, Response wird interpretiert |
| `mcp_tool` | Tool an einem MCP-Server aufrufen |
| `prompt` | Yes/No-Decision per Modell-Aufruf |
| `agent` | Sub-Agent als Verifier spawnen (experimental) |

### 1.4 Exit-Code-Semantik (Command-Hooks)

| Exit | Effekt |
| :--- | :----- |
| `0` | Erfolg. stdout wird als JSON-Decision geparst (oder als Plain-Context für `UserPromptSubmit`/`SessionStart` injiziert) |
| `2` | Blocking-Error. stdout wird ignoriert, stderr ist die Fehlermeldung |
| Andere | Non-Blocking-Error. Erste stderr-Zeile in Transcript, volle stderr im Debug-Log |

### 1.5 Decision-Control

Universell:
```json
{
  "continue": true,
  "stopReason": "…",
  "suppressOutput": false,
  "systemMessage": "Warnung an User",
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "…",
    "permissionDecision": "allow|deny|ask|defer",
    "permissionDecisionReason": "…",
    "updatedInput": { "command": "npm run lint -- --fix" }
  }
}
```

### 1.6 Path-Placeholders

| Placeholder | Wert |
| :---------- | :--- |
| `${CLAUDE_PROJECT_DIR}` | Projekt-Root |
| `${CLAUDE_PLUGIN_ROOT}` | Plugin-Verzeichnis |
| `${CLAUDE_PLUGIN_DATA}` | Persistente Plugin-Daten |

### 1.7 Settings-Scopes & Precedence

```
Managed (Org-Policy)               ← höchste, override-fest
   └── CLI --settings
       └── .claude/settings.local.json (gitignored)
           └── .claude/settings.json
               └── ~/.claude/settings.json
                   └── Skill/Agent Frontmatter (während aktiv)
                       └── Plugin hooks.json (wenn enabled)
```

### 1.8 Wie WhisperM8 das schon nutzt

`ClaudeHookSettingsBuilder.swift` erzeugt eine temporäre Settings-JSON mit:
```json
{
  "hooks": {
    "SessionStart": [{"matcher": ".*", "hooks": [{"type": "command", "command": "(cat; echo) >> \"<event-file>\""}]}],
    "SessionEnd":   [{"matcher": ".*", "hooks": [{"type": "command", "command": "(cat; echo) >> \"<event-file>\""}]}]
  }
}
```

Per Launch-Argument `--settings <path>` injectet → Hooks schreiben jeden Event als Zeile in eine pro-Session-Event-JSONL. `ClaudeHookBridge` lauscht via `DispatchSource.makeFileSystemObjectSource` auf Writes (Idle-CPU = 0%).

**Daraus folgt direkt eine sehr mächtige Erweiterungs-Achse**: Wir könnten weitere Hook-Events (PreToolUse, PostToolUse, Stop, …) in derselben Bridge tracken, ohne ihre Architektur zu sprengen.

## 2. Sub-Agents

### 2.1 Definition

File: `~/.claude/agents/<name>.md` (User-global) oder `.claude/agents/<name>.md` (Projekt).

```yaml
---
name: code-reviewer
description: Reviews code for quality and security
tools: [Read, Glob, Grep]
isolation: worktree
model: sonnet
color: cyan
permissionMode: plan
---
You are a focused code reviewer. Analyze the diff in stages…
```

### 2.2 Wichtige Frontmatter-Felder

| Feld | Funktion |
| :--- | :------- |
| `name` | CLI-/Mention-Name (`@code-reviewer` oder `code-reviewer <prompt>`) |
| `description` | Wann Claude den Sub-Agent automatisch wählt |
| `tools` | Liste / `default` |
| `isolation: worktree` | Sub-Agent läuft immer in eigenem Worktree |
| `model` | Override |
| `permissionMode` | Override |
| `color` | UI-Hinweis |
| `hooks: { … }` | Skill-/Agent-spezifische Hooks |

### 2.3 Wie ein Sub-Agent dispatcht wird

- **In Agent View**: `@code-reviewer <prompt>` oder `code-reviewer <prompt>` als erstes Wort.
- **In Shell**: `claude --agent code-reviewer --bg "review PR 1234"`.
- **Aus laufender Session**: Claude wählt automatisch via Description, oder `/agents` UI öffnen.

→ Sub-Agents tauchen als **`a:<name>`-Filter** in Agent View auf.

## 3. Skills, Slash-Commands, Plugins

| Konzept | Ort | Zweck |
| :------ | :-- | :---- |
| **Skills** | `.claude/skills/<name>/SKILL.md` | Spezialisierte Workflows mit Beschreibung, Trigger, Body |
| **Commands** | `.claude/commands/<name>.md` | Custom Slash-Commands |
| **Plugins** | über `claude plugin install` oder `--plugin-dir` | Pakete aus Commands + Agents + Skills + Hooks + MCP |
| **MCP-Server** | `.mcp.json` / `~/.claude.json` / Plugins | Externe Tool-Provider via Model-Context-Protocol |

WhisperM8-relevant: **Wir können später eigene Skills/Plugins ausliefern**, die Hooks für die UI-Bridge enthalten — z. B. ein Skill `whisperm8-bridge`, der unsere `--settings`-Logik in einen wiederverwendbaren Container packt.

## 4. Settings — wichtigste Keys für unsere Welt

(aus [Settings-Doku](https://code.claude.com/docs/en/settings))

| Key | Wirkung |
| :-- | :------ |
| `disableAgentView` | Schaltet `claude agents`, `--bg`, `/bg`, Supervisor komplett aus |
| `disableRemoteControl` | Schaltet Remote-Control aus (≥ 2.1.128) |
| `disableAllHooks` | Hooks komplett aus |
| `allowManagedHooksOnly` | Nur Admin- + SDK-Hooks akzeptieren |
| `allowedHttpHookUrls` | URL-Allow-List für HTTP-Hooks |
| `httpHookAllowedEnvVars` | Env-Vars, die HTTP-Hooks interpolieren dürfen |
| `permissions` | `allow`, `deny`, `defaultMode`, `additionalDirectories` |
| `allowManagedPermissionRulesOnly` | Restriktion: User darf keine eigenen Rules |
| `worktree.baseRef` | `"fresh"` oder `"head"` |
| `statusLine` | Eigene Statuszeile via Command |
| `agent` | Default-Sub-Agent |
| `model`, `effortLevel`, `viewMode`, `teammateMode` | Defaults für die Session |
| `cleanupPeriodDays` | Wie alt orphaned Worktrees werden müssen, bevor sie gesweept werden |

### 4.1 Settings-Files

| Pfad | Scope |
| :--- | :---- |
| `~/.claude/settings.json` | User-global |
| `.claude/settings.json` | Projekt (checked-in) |
| `.claude/settings.local.json` | Projekt-Local (gitignored) |
| macOS: `/Library/Application Support/ClaudeCode/managed-settings.json` | Managed |
| Linux: `/etc/claude-code/managed-settings.json` | Managed |
| Windows: `C:\Program Files\ClaudeCode\managed-settings.json` oder Registry | Managed |

## 5. Agent SDK kurz

### 5.1 Was ist es

**Build agents using Claude Code as a library.** Python + TypeScript. Hat dieselbe Tool-Loop, dasselbe Context-Management, dieselben Hooks/MCP/Skills.

```bash
pip install claude-agent-sdk
# bzw.
npm install @anthropic-ai/claude-agent-sdk
```

```python
async for message in query(
  prompt="Fix the bug in auth.py",
  options=ClaudeAgentOptions(allowed_tools=["Read","Edit","Bash"]),
):
    print(message)
```

### 5.2 Wichtige Pfade fürs Wissen

| Doku | Inhalt |
| :--- | :----- |
| [Quickstart](https://code.claude.com/docs/en/agent-sdk/quickstart) | Erstes Beispiel |
| [Sessions](https://code.claude.com/docs/en/agent-sdk/sessions) | Continue/Resume/Fork |
| [Hooks](https://code.claude.com/docs/en/agent-sdk/hooks) | Programmatic Hooks |
| [Sub-Agents](https://code.claude.com/docs/en/agent-sdk/subagents) | Dynamisch erstellen |
| [Streaming](https://code.claude.com/docs/en/agent-sdk/streaming-output) | Real-time Output |
| [Permissions](https://code.claude.com/docs/en/agent-sdk/permissions) | Tool-Approval-Callbacks |
| [MCP](https://code.claude.com/docs/en/agent-sdk/mcp) | MCP-Integration |
| [Skills](https://code.claude.com/docs/en/agent-sdk/skills) | Skills filesystem-basiert |
| [Slash-Commands](https://code.claude.com/docs/en/agent-sdk/slash-commands) | Custom Commands |
| [Modifying System Prompts](https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts) | Memory/Custom |
| [File Checkpointing](https://code.claude.com/docs/en/agent-sdk/file-checkpointing) | Snapshot+Revert |
| [Session Storage](https://code.claude.com/docs/en/agent-sdk/session-storage) | Cross-Host-Adapter |
| [Migration Guide](https://code.claude.com/docs/en/agent-sdk/migration-guide) | Vom alten SDK |
| [Python Reference](https://code.claude.com/docs/en/agent-sdk/python) | API |
| [TypeScript Reference](https://code.claude.com/docs/en/agent-sdk/typescript) | API |
| [Structured Outputs](https://code.claude.com/docs/en/agent-sdk/structured-outputs) | `--json-schema` |
| [User Input / Approvals](https://code.claude.com/docs/en/agent-sdk/user-input) | AskUserQuestion + Permission-Callbacks |

### 5.3 SDK vs CLI vs Managed Agents

| Aspekt | Agent SDK | Claude Code CLI | Managed Agents |
| :----- | :-------- | :-------------- | :------------- |
| Wo läuft Code | In deinem Process | Lokal | Anthropic-managed Sandbox |
| Interface | Lib (Py/TS) | CLI / TUI | REST-API |
| Files | Auf deinem FS | Auf deinem FS | Managed Sandbox pro Session |
| Sessions | JSONL auf Disk | JSONL auf Disk | Anthropic-hosted Event-Log |
| Custom Tools | Lokale Functions | Tools/MCP | Du implementierst Tool, Anthropic ruft an |
| Best für | Lokale Prototypen | Interaktiv | Production-Agents ohne eigene Infra |

> Für **WhisperM8 als Swift/macOS-App** ist das **Agent SDK nicht direkt sinnvoll** (kein Swift-SDK). Wir bleiben beim CLI-Subprocess. Nur wenn wir eine separate Python/TS-"Tool-Bridge" als Daemon mitausliefern wollen, lohnt sich das SDK.

## 6. Managed Agents (Cloud-API) — sehr kurz, für Vollständigkeit

- REST-API: <https://platform.claude.com/docs/en/managed-agents/overview>.
- Anthropic hosted: Agent + Sandbox + Session-State alles in Anthropics Infra.
- Du sendest Events, du kriegst Results gestreamed.
- **Anderer Code-Pfad als Claude Code CLI.**
- Eigene Sub-Pages: `agent-setup`, `define-tools`, `events`, `permissions`, `billing`.
- Authentifizierung: Console-API-Key.

> **Verwechslungsgefahr**: "Cloud Agents" / "Managed Agents" / "Claude Code on the web" sind drei verschiedene Dinge:
> 1. **Managed Agents** = die generische Hosted-REST-API für eigene Agents.
> 2. **Claude Code on the web** = Cloud-gehostete Claude-Code-Sessions, gestartet von claude.ai/code.
> 3. **Agent View** = lokal, Supervisor-getriebene Multi-Session-TUI.

Für WhisperM8 mit Subscription ist **nur (3) Agent View** zu 100 % im Scope. (2) wäre nur dann interessant, wenn wir Sessions in der Cloud anstoßen wollen → das macht z. B. der `--remote` Flag, aber für die Subscription-Welt ist `--bg` der direkte Pfad.

## 7. Remote-Control / Mobile Push / Channels — Ergänzungen

Diese Features könnten WhisperM8-Hand-in-Hand interessant sein:

- **Remote Control**: Eine lokale Session via claude.ai oder Mobile-App weitersteuern. WhisperM8 könnte einen Button "In Remote Control schicken" haben → öffnet `claude --rc` und zeigt URL/QR.
- **Channels**: Plugins, die externe Events (Telegram, Discord, eigener Webhook) in laufende Sessions pushen — würde uns erlauben, WhisperM8-Transkripte als "Channel-Event" zu posten.
- **Dispatch (Desktop-App)**: Anthropic's eigene Desktop-App pairt mit der Mobile-App und kann Tasks von dort triggern. Andere App-Familie als wir.
- **Scheduled Tasks / Routines**: Cron-ähnliche Pläne im CLI / Desktop / Cloud — könnten via Hooks wieder in WhisperM8 zurücksignalisieren.
