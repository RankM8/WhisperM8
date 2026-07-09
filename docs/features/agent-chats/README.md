---
status: aktiv
updated: 2026-07-09
---

# Agent Chats — UI-Landkarte

Das Agent-Chats-Fenster ist die gemeinsame Oberfläche für interaktive Claude-
und Codex-Sessions, Terminal-Tabs, Claude-Background-Chats und headless
Codex-Jobs. Diese Seite ordnet die sichtbaren Flächen ihren Teilsystemen zu;
Lebenszyklen, Persistenzformate und Bedienungsdetails stehen in den verlinkten
Detaildokumenten.

## Was treibt welche Fläche?

| Sichtbare Fläche | Treibendes Teilsystem |
|---|---|
| **Sidebar** | Projekte und Sessions stammen aus dem Workspace- und Session-Kern unter [`sessions/`](sessions/). Rendering, Scope, Gruppierung und die Subagent-Fortschrittsgruppe gehören zu [`ui/`](ui/); eingerückte Kind-Zeilen repräsentieren die Codex-Jobs aus [`sub-agents/`](sub-agents/). |
| **Tabs und Fenster** | Offene Tabs, Selektion, Pinning und Verteilung auf mehrere Fenster werden von der UI-Schicht verwaltet. Tab-Reorder, Cross-Window-Moves und Tear-off sind in [`ui/multiwindow.md`](ui/multiwindow.md) eingeordnet. |
| **Terminal-Bereich** | Interaktive Claude-, Codex-, Background- und Shell-Sessions laufen als SwiftTerm-PTY über `AgentSessionDetailView`. Start, Resume, Registry, Tastaturprofile und Prozessbeendigung beschreibt [`ui/terminal.md`](ui/terminal.md). |
| **Detailfläche** | Normale interaktive Sessions verwenden `AgentSessionDetailView`. Ein noch nicht übernommener Codex-Job verwendet `SubagentJobDetailView` mit Auftrag, Report, Metriken, Event-Transcript, Stop, Follow-up und Übernahme; erst danach wechselt er in den normalen PTY-Pfad. |
| **Status-Ampeln** | Der ephemere Live-Status und seine State-Machine liegen in [`sessions/`](sessions/). Bei Claude-Sessions liefert die Hook-Bridge aus [`background-agents/`](background-agents/) die maßgeblichen Aktivitäts-, Eingabe- und Ende-Signale; Transcript-Beobachtung bleibt der Fallback für Codex und hook-stumme Claude-Sessions. |
| **Codex-Jobs** | [`sub-agents/`](sub-agents/) besitzt Job-Store, Supervisor, Workspace-Synchronisation und Lifecycle der über `whisperm8 agent` gestarteten Jobs. Die UI projiziert diese Jobs als Session-Zeilen und eigene Detailansichten, ohne `state.json` als Job-Wahrheit zu ersetzen. |
| **Geteilte Exec-Schicht** | [`codex-exec/`](codex-exec/) kapselt die nicht-interaktive `codex exec --json`-Integration: Prozessstart, Streaming, Resume, Sandbox und Report-Schema. Subagent-Jobs bauen darauf auf; die Schicht selbst besitzt weder Sidebar- noch Job-Persistenz. |

## Teilsysteme

### [`ui/`](ui/)

Die UI-Schicht komponiert Fenster-Chrome, Sidebar, globale Tab-Leiste,
Inspector, Terminal und Transcript-Flächen. Sie hält den Fensterzustand im
`AgentWindowStore` und projiziert Session- sowie Job-Daten in sichtbare Rows,
Fortschrittsgruppen und die passende Detailansicht. Multiwindow- und
Terminalmechanik bleiben in den spezialisierten UI-Dokumenten verortet.

### [`sessions/`](sessions/)

Der Session-Kern persistiert lokale `AgentChatSession`-Einträge, entdeckt
externe Claude- und Codex-Verläufe und stellt Transcripts bereit. Er trennt
den dauerhaften Session-Zustand vom ephemeren Runtime-Status, den Sidebar,
Tabs und Status-Ampeln konsumieren. Externe CLI-Transcripts werden dabei
read-only gelesen.

### [`sub-agents/`](sub-agents/)

Dieses Teilsystem verwaltet WhisperM8-eigene, headless Codex-Jobs samt
Job-Verzeichnis, Supervisor, Folge-Turns und Übernahme in einen interaktiven
Chat. Es liefert die Job-Wahrheit für eingerückte Sidebar-Kinder,
Fortschrittsstände und `SubagentJobDetailView`; die UI entscheidet nur über
deren Darstellung.

### [`background-agents/`](background-agents/)

WhisperM8 startet Claude-Background-Agents per `claude --bg` und öffnet sie
später per `claude attach`. Dass der laufende Agent vom externen Claude-
Supervisor gehostet wird, ist externes Claude-Code-Laufzeitverhalten; die App
liest dessen Snapshots lediglich defensiv. Die Hook-Bridge bindet externe
Claude-IDs an lokale Sessions und speist die Runtime-State-Machine mit
Live-Ereignissen. Dispatch, Lifecycle-Aktionen und Supervisor-Dateien sind in
diesem Bereich abgegrenzt.

### [`codex-exec/`](codex-exec/)

Codex-Exec ist die geteilte Prozessintegrationsschicht für nicht-interaktive
Codex-Läufe. Sie vereinheitlicht JSONL-Streaming, Thread-Resume,
Sandbox-Argumente, Status-Proben und den strukturierten Report-Vertrag. Job-
und UI-Zustand bleiben bewusst bei den aufrufenden Teilsystemen.

## Schlüsseldateien

- `WhisperM8/Views/AgentChatsView.swift` orchestriert Fensterlayout, Store-Bridges, Sidebar, Tabs, Detailauswahl, Inspector und Sheets.
- `WhisperM8/Views/AgentChatsSidebarViews.swift` rendert Projektgruppen, Session-Zeilen, Subagent-Kinder und deren Fortschritts-Footer.
- `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift` baut die reine Sidebar-Projektion aus Sessions und Subagent-Zuordnungen.
- `WhisperM8/Services/AgentChats/AgentWindowStore.swift` ist die Zustandsquelle für Fenster, offene Tabs, Selektion, Pins und ungelesene Subagent-Ergebnisse.
- `WhisperM8/Views/AgentSessionDetailView.swift` startet oder übernimmt interaktive PTY-Sessions und bindet deren Transcripts.
- `WhisperM8/Views/SubagentJobDetailView.swift` rendert noch nicht übernommene Codex-Jobs ohne PTY.
- `WhisperM8/Services/AgentChats/AgentSessionStore.swift` vermittelt Workspace- und Session-Mutationen für die sichtbare Session-Liste.
- `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift` ist der Single Writer für den ephemeren Live-Status.
- `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift` führt Claude-Hook-Ereignisse und lokale Sessions für Binding und Status zusammen.
- `WhisperM8/Services/AgentChats/AgentJobStore.swift` persistiert Zustand, Events, Prompts und Reports der Codex-Jobs.
- `WhisperM8/Services/AgentChats/CodexExecRunner.swift` startet und überwacht die gestreamten `codex exec --json`-Prozesse.

## Verwandte Bereiche

- [`../cli/`](../cli/) dokumentiert das `whisperm8`-Binary und insbesondere den öffentlichen Namespace `whisperm8 agent` für Codex-Jobs.
- [`../settings/`](../settings/) beschreibt die Settings-Navigation; die Gruppe **Agents** enthält die Seiten **Agent Chats** sowie **CLI & Skills**.

## Keywords

Agent Chats, Agent-Chat-Fenster, UI-Landkarte, Sidebar, Session-Liste,
Projektgruppen, Subagent-Kinder, Subagent-Fortschrittsgruppe, Tabs,
Multiwindow, Tab-Tear-off, Terminal, SwiftTerm, PTY, Detailfläche,
`AgentSessionDetailView`, `SubagentJobDetailView`, Status-Ampel, Live-Status,
Runtime-Status, Hook-Bridge, Claude Background Agent, Codex-Subagent,
Codex-Job, `whisperm8 agent`, Codex-Exec, `codex exec --json`,
`AgentChatsView`, `AgentWindowStore`, `AgentSessionStore`, `AgentJobStore`,
`AgentSessionStatusCoordinator`, `ClaudeHookBridge`, `CodexExecRunner`.
