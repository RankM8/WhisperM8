# Workspace-Layout — Performance-Plan

Planungsdokument zur Frage, wie die neue Layout-Engine für Agent Chats in Swift
umgesetzt wird, **ohne dass sie langsam wird**. Kein Produktivcode, keine
Umsetzung — nur Analyse, Budgets und Reihenfolge.

## Einstieg

Öffne `index.html` im Browser. Alles andere hängt daran.

```
workspace-performance/
├── index.html                          Hub: Warum, Budgets, Pakete, Risiken, Fahrplan
├── 01-rendering/
│   └── 01-renderer-architektur.html    View-Identität, Custom-Layout, Drag bei 60 fps
├── 02-terminals/
│   └── 01-pty-durchsatz.html           Drei Feed-Stufen, Stapel-Drosselung, Messung
└── 03-state/
    └── 01-store-persistenz.html        Flüchtig vs. dauerhaft, Writer, v4→v5-Migration
```

## Lese-Reihenfolge

1. **Hub** (`index.html`) — Zielbild, Messvertrag, Risiko-Reihenfolge
2. **Paket 01 — Renderer** — der riskanteste Teil: View-Identität und PTY-Re-Mounts
3. **Paket 02 — Terminals** — Durchsatz bei neun Strömen, Verhalten gestapelter Sessions
4. **Paket 03 — State** — Persistenz, Skalierung, Schema-Migration
5. **Paket 04 — Sofort** — was unabhängig vom Feature zuerst passiert
6. **Paket 05 — Entscheidungen** — Scope, Alternativen, offene Fragen

## Woher die Aussagen stammen

Drei parallele Code-Analysen im Repo, jede mit Datei- und Zeilenbelegen:

| Thema | Wesentliche Quellen |
|---|---|
| Rendering | `AgentChatsView.swift`, `AgentChatsView+Grid.swift`, `AgentGridSplitContainer.swift`, `AgentTerminalView.swift` |
| Terminals | `AgentTerminalView.swift`, `TerminalFeedBatcher.swift`, `AgentSessionRuntimeWatcher.swift` |
| State | `AgentWindowStore.swift`, `AgentUIState.swift`, `AgentSessionStore.swift`, `AgentGridWorkspace.swift` |
| Historie | `docs/audit/2026-07-agent-chats-deep-dive/` — dokumentierte Freeze- und Render-Befunde |

Verhaltensfragen (was das Feature tun soll) sind **nicht** hier, sondern im
HTML-Zwilling entschieden: `docs/design/agent-chats-layout-engine.html`.

## Was die Recherche ergänzt hat (01.08.2026)

- **Ghostty** war ursprünglich „all-in auf SwiftUI" und hat die Split-Logik bewusst nach AppKit
  verlagert ([PR #7523](https://github.com/ghostty-org/ghostty/pull/7523)) — SwiftUI ist damit nicht
  disqualifiziert, SwiftUI *als Besitzer der Terminal-Lebensdauer* wäre es.
- **SwiftTerm koppelt Parsing und Rendering** — offenes Upstream-Issue
  [#137](https://github.com/migueldeicaza/SwiftTerm/issues/137). Das ist die Ursache von
  „viel Output → alles klebt".
- **Der Metal-Renderer ist bereits eingebaut, aber aus** (`AgentTerminalView.swift:27-41`).
  — *Nachtrag 01.08.2026: inzwischen an, siehe Status unten.*
- **SwiftUI-Drag hat diese App schon einmal eingefroren** (`AgentChatsSidebarViews.swift:199`,
  Mai-2026-Freeze, Fix 60ca683).
- **libghostty** ist die einzige Option, die das Parsing-Problem an der Wurzel löst — offizielles
  Swift-Paket aber noch nicht veröffentlicht. Bewertung in Paket 05.

## Zwei Zahlen, die den Ton setzen

- Sidecar `agent-ui-state.json`: **99.677 Bytes**, wird bei jeder Mutation **vollständig** neu geschrieben
- Domain `AgentSessions.json`: **7.771.874 Bytes** (Messung 30.07.2026)

## Status

**Pakete 01–03 und 05:** reine Planung, kein Produktivcode. Die Budgets im Hub
sind Vorschläge auf Basis der Code-Analyse — sie gehören mit Instruments
kalibriert, bevor sie als Abnahmekriterien gelten.

**Paket 04 (Sofortmaßnahmen):** A2 ist am 01.08.2026 umgesetzt — SwiftTerm steht
auf v1.15.0 (Fork-Pin `2671405`), und ein gemessener 262-ms-Hänger beim ersten
Chat ist durch Vorwärmen des Shader-Caches beseitigt. Die Reihenfolge musste
dabei getauscht werden: Metal auf v1.14 hätte die App auf fremden Macs
abgeschossen.

**A1 wurde umgesetzt und nach dem Feldtest wieder zurückgenommen** — mit Metal
litt das Schriftbild sichtbar, während der Geschwindigkeitsgewinn mangels
Messung unbelegt blieb. Der Default steht wieder auf aus. Befunde, geprüfte
Hypothesen und die Lehre daraus im Abschnitt „Warum Metal wieder aus ist" von
`04-sofort/01-sofortmassnahmen.html`.

**A4 (Messgerüst) ist am 01.08.2026 umgesetzt:** zweistufig (`PerfTier`,
Detail-Schalter `agentPerfDetailEnabled`, Default aus), Zähler statt Signposts
in heißen Pfaden, ein Stillstands-Wächter für den Main Thread, dazu
`scripts/perf-load.sh` (Lastgenerator) und `scripts/perf-report.sh`
(Auswertung). 11 neue Tests.

Die erste Auswertung war in wesentlichen Teilen **falsch** — parallele Reviews
(GPT und Opus) fanden vier Fehler im Messwerkzeug selbst: Unit-Test-Läufe
flossen in die App-Baseline, „keine Daten" wurde nie erkannt, der Lastgenerator
verbrauchte selbst CPU, und die Uhr war eine Wanduhr (Systemschlaf erschien als
Einfrieren). Alles behoben; Details im Paket 04.

**Zwei Befunde haben die Prioritäten umgeworfen:**

- `sidebar.statusPoll` war ein **Fehlalarm**. Der Messpunkt umfasste
  Einplanungs- und MainActor-Wartezeit statt Arbeit — belegt durch zehn Polls,
  die millisekundengleich endeten. Ein `stat` kostet 1,3 µs, ein Tail-Read
  18,3 µs. Korrigiert.
- **A3 ist weitgehend gegenstandslos.** Die Domain-Datei wird längst off-main
  geschrieben; auf dem Main Thread liegt nur der UI-Sidecar mit 3.497 Bytes
  (nicht 99.677). Die Domain-Datei misst nach der Retention 1,45 MB statt
  7,77 MB.

Offen bleibt: Warum brauchen einzelne Saves 122 ms, wo vergleichbare 21–29 ms
schaffen? Dafür misst `save` jetzt seine Phasen einzeln.
