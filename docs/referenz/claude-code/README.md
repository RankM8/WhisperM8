# Claude Code Dokumentation für WhisperM8

> Recherche-Stand: **2026-05-12** · Claude Code aktuelle Version-Linie ≥ 2.1.139
> Ziel dieser Doku: vollständiges, fundiertes Verständnis von Claude Code (CLI, SDK, Hooks, Agent View, Cloud-Pendants), damit wir saubere Entscheidungen für die WhisperM8-Agents-View-Integration treffen können.

## Aufbau

| Datei | Inhalt |
| :---- | :----- |
| [`00-uebersicht.md`](00-uebersicht.md) | Big Picture: Was ist Claude Code, welche Oberflächen gibt es (CLI / Agent View / Remote Control / Web), wie hängen sie zusammen |
| [`01-agent-view.md`](01-agent-view.md) | **Agent View tief** — Subcommands, Lifecycle, Supervisor, Pfade, Tastatur, Limitations |
| [`02-sessions-cli.md`](02-sessions-cli.md) | Sessions auf Disk (JSONL), `--resume` / `--continue` / `--session-id` / `--fork-session`, CLI-Referenz, Headless-Mode, JSON-Output |
| [`03-hooks-sdk.md`](03-hooks-sdk.md) | Hooks (Events, Matcher, Exit Codes, JSON-IO), Agent SDK (Python/TypeScript), Managed Agents, Skills/Plugins |
| [`session-verhalten.md`](session-verhalten.md) | Claude-Code-CLI-Session-Verhalten (Resume, JSONL-Kontinuität) — autoritative Referenz inkl. Fix-Historie |

Historisch (Integrationsstand Mai 2026, Beratung entschieden):
[`04-whisperm8-integration-stand.md`](../../archive/claude-code-integration/04-whisperm8-integration-stand.md),
[`05-beratung-optionen.md`](../../archive/claude-code-integration/05-beratung-optionen.md) —
der aktuelle Integrationsstand wird in [`features/agent-chats/`](../../features/agent-chats/) dokumentiert.

## Wichtigste offizielle Links

### Einstieg
- [Claude Code Doku-Index (llms.txt)](https://code.claude.com/docs/llms.txt)
- [Claude Code Home](https://code.claude.com/docs/en/home)
- [Quickstart](https://code.claude.com/docs/en/quickstart)
- [CLI Reference](https://code.claude.com/docs/en/cli-reference)
- [Commands](https://code.claude.com/docs/en/commands)

### Agent View / Parallelität
- [Agent View](https://code.claude.com/docs/en/agent-view) ⭐
- [Blog Post: Agent view in Claude Code](https://claude.com/blog/agent-view-in-claude-code)
- [Run agents in parallel](https://code.claude.com/docs/en/agents)
- [Subagents](https://code.claude.com/docs/en/sub-agents)
- [Agent Teams](https://code.claude.com/docs/en/agent-teams)
- [Worktrees](https://code.claude.com/docs/en/worktrees)

### Sessions & SDK
- [Work with sessions (SDK)](https://code.claude.com/docs/en/agent-sdk/sessions) ⭐
- [Agent SDK Overview](https://code.claude.com/docs/en/agent-sdk/overview)
- [Headless / programmatic](https://code.claude.com/docs/en/headless)
- [Python SDK](https://code.claude.com/docs/en/agent-sdk/python)
- [TypeScript SDK](https://code.claude.com/docs/en/agent-sdk/typescript)
- [Cookbook: Session browser](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser)

### Hooks
- [Hooks reference](https://code.claude.com/docs/en/hooks) ⭐
- [Settings](https://code.claude.com/docs/en/settings)
- [Permissions](https://code.claude.com/docs/en/permissions)
- [Permission Modes](https://code.claude.com/docs/en/permission-modes)

### Cloud / Remote
- [Remote Control](https://code.claude.com/docs/en/remote-control) — claude.ai/code als Window auf deine lokale Session
- [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) — Cloud-Sessions in Anthropic-Sandbox
- [Managed Agents (REST API)](https://platform.claude.com/docs/en/managed-agents/overview)
- [Slack](https://code.claude.com/docs/en/slack)
- [Channels](https://code.claude.com/docs/en/channels)
- [Scheduled Tasks](https://code.claude.com/docs/en/scheduled-tasks)

### Weitere relevante Seiten
- [Plugins](https://code.claude.com/docs/en/plugins)
- [MCP](https://code.claude.com/docs/en/mcp)
- [Env Vars](https://code.claude.com/docs/en/env-vars)
- [Claude Directory (`~/.claude/`)](https://code.claude.com/docs/en/claude-directory)
- [Auto-updates / Setup](https://code.claude.com/docs/en/setup)
- [Costs](https://code.claude.com/docs/en/costs)
- [Data usage](https://code.claude.com/docs/en/data-usage)

## Kerneinsichten in einem Satz

- **Agent View** (`claude agents`, ≥ v2.1.139) ist eine TUI mit eigenem **Supervisor-Daemon**, der Background-Sessions hostet — kein einzelner Chat, sondern eine Multi-Session-Verwaltung.
- **State liegt rein lokal** unter `~/.claude/` (`daemon/`, `jobs/<id>/state.json`, `projects/<encoded-cwd>/*.jsonl`). Keine Cloud-API für lokale Background-Sessions.
- **Cloud Agents** = das Cloud-Pendant: läuft auf Anthropic-Infrastruktur (`claude.ai/code`, `claude --remote`). Anderer Code-Pfad, anderes Subscription-Modell.
- WhisperM8 nutzt heute schon `claude agents` als eigenen Session-Typ in einem Tab — die Agent-View-TUI rendert im Alt-Screen-Buffer im eingebauten SwiftTerm-PTY.
