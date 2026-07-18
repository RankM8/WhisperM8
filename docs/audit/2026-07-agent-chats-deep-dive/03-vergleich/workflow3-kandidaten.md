---
status: aktiv
updated: 2026-07-18
description: Kandidaten, Claude-Code-Interna und Edge-Cases für die Workflow-3-Codeanalyse
---

# Workflow 3: Kandidaten und Claude-Code-Session-Verhalten

## Ziel und Abgrenzung

Diese Recherche vertieft die beiden Runde-1-Berichte
[`claude-session-manager.md`](claude-session-manager.md) und
[`claude-cli-oekosystem.md`](claude-cli-oekosystem.md). Im Mittelpunkt stehen
nicht weitere Feature-Listen, sondern drei konkrete Risiken in WhisperM8:

1. Ein vorhandener Chat wird nicht mehr gefunden oder fälschlich als verloren
   behandelt.
2. Nach einem Fork bleibt die UI an der Eltern-Session gebunden und ein späteres
   Resume öffnet deshalb den alten Zweig.
3. Prozessstatus, Projektpfad und Claude-Session-Identität laufen auseinander.

Alle Popularitäts- und Aktivitätsangaben sind eine Momentaufnahme vom
**18. Juli 2026**. GitHub rundet Star-Zahlen in der Weboberfläche; die Rangfolge
ist deshalb bei nah beieinanderliegenden Projekten nur näherungsweise exakt.
„Aktiv“ bedeutet hier ein Release, Tag oder sichtbare Repository-Aktivität in
den letzten Monaten, nicht automatisch Produktreife.

## 1. Ranking der Integrations- und Referenzprojekte

Die Tabelle sortiert nach GitHub-Stars. Sie unterscheidet bewusst zwischen
echter Claude-Code-Integration und Projekten, die nur als Terminal- oder
Orchestrierungsreferenz dienen. Projekte mit problematischem Wartungs- oder
Lizenzstatus sind markiert.

| Rang | Repository | Stars / letzte Aktivität | Stack | Claude-Code-Integrationstiefe |
|---:|---|---|---|---|
| 1 | [`anomalyco/opencode`](https://github.com/anomalyco/opencode) | ca. **187k**; Release **v1.18.3, 16.07.2026** | TypeScript, TUI/Client-Server | **Keine Claude-Code-CLI-Integration.** Eigener Agent mit eigener Session- und Terminalarchitektur; wertvolle TUI-/Persistenzreferenz, aber kein Beleg für Claude-JSONL- oder Fork-Semantik. |
| 2 | [`musistudio/claude-code-router`](https://github.com/musistudio/claude-code-router) | ca. **35,9k**; 2026 aktiv | TypeScript/Node | Startet bzw. umhüllt die Claude-Code-CLI und routet deren Anthropic-kompatible Requests auf andere Modelle. Tief im Request-Routing, aber **kein** eigentlicher Session-Manager; Claude verwaltet JSONL und Resume weiterhin selbst. |
| 3 | [`BloopAI/vibe-kanban`](https://github.com/BloopAI/vibe-kanban) | ca. **27,4k**; letztes Release **24.04.2026** | Rust, TypeScript/React | Headless Agent-Executor mit Worktrees und Claude-Adapter. Das README erklärt das Projekt inzwischen ausdrücklich für **sunsetting**; nur noch historische Codequelle, kein Zukunftskandidat. |
| 4 | [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux) | ca. **24,7k**; Release **v0.64.19, 14.07.2026** | Swift, TypeScript, Rust; native macOS-App auf Ghostty | Echte PTY-Integration, persistente Surface-/Workspace-Bindung, Claude-Wrapper und Resume-Aktionen; Agent-Benachrichtigungen werden über Hooks/OSC in Terminalzustand übersetzt. Sehr starke macOS-/Terminalreferenz, ohne Claude-JSONL als primären Store zu übernehmen. |
| 5 | [`slopus/happy`](https://github.com/slopus/happy) | ca. **22,7k**; CLI-Release **1.1.10, 23.06.2026** | TypeScript, React Native, Node | Wrapper und Remote-Client für Claude Code; startet die CLI lokal und nutzt inzwischen das offizielle Agent SDK. Die [Release-Historie](https://github.com/slopus/happy/releases) nennt Resume per RPC sowie mehrere Lifecycle-Fixes. Tief bei Remote-Lifecycle, Synchronisierung und Berechtigungen. |
| 6 | [`winfunc/opcode`](https://github.com/winfunc/opcode) (früher `getAsterisk/opcode`) | ca. **22,2k**; letztes Release **v0.2.0, 31.08.2025** | Rust/Tauri, React/TypeScript | Startet Claude headless, liest lokale Claude-Historie und stellt Sessions als GUI dar. Kein belastbarer Hinweis auf das aktuelle Agent SDK; nach fast elf Monaten ohne Release **stagnierend** und gegenüber aktuellen Session-APIs mit Vorsicht zu lesen. |
| 7 | [`siteboon/claudecodeui`](https://github.com/siteboon/claudecodeui) | ca. **12,7k**; Release **v1.36.3, 15.07.2026** | TypeScript/JavaScript, React, Node | Tiefe Integration über das offizielle Claude Agent SDK, lokale Session-Erkennung und eigener PTY-Shell-Kanal. Relevanter aktiver GUI-Kandidat für Streaming, Berechtigungen und Wiederaufnahme. |
| 8 | [`superset-sh/superset`](https://github.com/superset-sh/superset) | ca. **12,5k**; Release **v1.15.1, 16.07.2026** | Electron, TypeScript/React | Robuster generischer Terminal-/Worktree-Host mit PTYs, Notifications und Agent-Workspaces; Claude bleibt weitgehend ein Terminalprozess. Daher stark für Prozess- und Workspace-Lifecycle, schwächer für semantisches Resume/Fork. Lizenz: **Elastic License 2.0, source-available statt OSI-Open-Source**. Bereits lokal vorhanden. |
| 9 | [`AgentWrapper/agent-orchestrator`](https://github.com/AgentWrapper/agent-orchestrator) (früher `ComposioHQ/agent-orchestrator`) | ca. **8,3k**; Release **v0.10.3, 12.07.2026** | Go, TypeScript; tmux | Agent-Pluginarchitektur für Claude, Codex und weitere CLIs, mit Worktrees und tmux-Sessions. Spawnt CLI-Prozesse, behandelt aber Claude-JSONL/Forks nicht als zentrales Domänenmodell. |
| 10 | [`smtg-ai/claude-squad`](https://github.com/smtg-ai/claude-squad) | ca. **8,1k**; Release **v1.0.19, 17.06.2026** | Go, tmux | Mehrere Claude-/Agent-Terminals in getrennten Worktrees; Prozess-, Diff- und tmux-Orchestrierung. Session-Wiederaufnahme ist terminalzentriert, nicht SDK- oder JSONL-zentriert. |
| 11 | [`amantus-ai/vibetunnel`](https://github.com/amantus-ai/vibetunnel) | ca. **4,6k**; Juli 2026 aktiv | TypeScript, Swift | Spiegelung echter PTYs zwischen Mac und Browser. Claude Code läuft unverändert im Terminal; keine eigene Interpretation von Claude-Sessiondateien. Sehr gute Referenz für PTY-Reconnect und Ownership, nicht für Fork-Semantik. |
| 12 | [`stravu/crystal`](https://github.com/stravu/crystal) | ca. **3,1k**; letztes Release **0.3.5, 26.02.2026** | Electron, TypeScript/React, SQLite | Startete Claude headless und normalisierte Stream-Events in einen eigenen Store. Das Repository ist zugunsten von Nimbalyst **deprecated**; nur noch als historische Architekturquelle geeignet. |
| 13 | [`Nimbalyst/nimbalyst`](https://github.com/Nimbalyst/nimbalyst) | ca. **1,3k**; Release **v0.68.1, 10.07.2026** | Electron, TypeScript/React | Aktiver Crystal-Nachfolger mit echtem `@anthropic-ai/claude-agent-sdk`, Sessionimport und eigenem UI-/Datenmodell. Die [Releases](https://github.com/Nimbalyst/nimbalyst/releases) dokumentieren konkrete Fixes für Pfade mit Leerzeichen/Akzenten, Resume mit Custom Hooks, falsche „session expired“-Diagnosen und Cross-Window-Sessionvermischung. **Bester aktiver GUI-Kandidat für Workflow 3.** |
| 14 | [`kbwo/ccmanager`](https://github.com/kbwo/ccmanager) | ca. **1,2k**; Release **v4.2.1, 11.07.2026** | TypeScript, Ink/React; PTY | Selbständiger TUI-/PTY-Sessionmanager. Behandelt Worktree-Wechsel explizit, indem Claude-Sessiondateien zwischen encoded-cwd-Verzeichnissen kopiert werden; dadurch besonders interessant für Pfadbindung, auch wenn diese Strategie auf dem inoffiziellen Dateiformat beruht. |
| 15 | [`asheshgoplani/agent-deck`](https://github.com/asheshgoplani/agent-deck) | ca. **530**; Release **v1.10.9, 18.07.2026** | Go, Bubble Tea, tmux, SQLite | Weniger Stars, aber sehr aktiv und fachlich besonders passend: First-Class-Session-Forks, tmux-Lifecycle, persistente Sessionmetadaten und gruppenspezifisches `CLAUDE_CONFIG_DIR`. **Stärkste Fork-/Resume-Codequelle im Feld.** |

### Einordnung des Rankings

- **Popularität und fachliche Eignung divergieren.** OpenCode ist die größte
  Referenz, integriert aber nicht die Claude-Code-CLI. Agent Deck ist klein,
  bildet den problematischen Fork dagegen ausdrücklich als eigene Operation ab.
- **Nimbalyst ersetzt Crystal.** Neue Codeanalyse sollte deshalb Nimbalyst
  priorisieren; Crystal dient höchstens zum Nachvollziehen früherer
  Designentscheidungen.
- **Nicht als aktiv einplanen:** Vibe Kanban wird eingestellt, Crystal ist
  deprecated, Opcode wirkt gegenüber dem schnell veränderten Claude-Ökosystem
  veraltet. Auch [`sugyan/claude-code-webui`](https://github.com/sugyan/claude-code-webui)
  (ca. 1,1k Stars) wurde am **29.05.2026 archiviert**.
- [`ccusage/ccusage`](https://github.com/ccusage/ccusage) ist mit ca. **17,3k**
  Stars populärer als viele Hosts, wurde aber nicht in die Host-Rangliste
  aufgenommen: Es analysiert Claude-JSONL, startet keine interaktive
  Claude-Session. Als Parserreferenz ist es trotzdem zentral.

## 2. Claude-Code-Interna: Wo liegt tatsächlich orientierbarer Code?

### 2.1 Das Repository `anthropics/claude-code` ist nicht die CLI-Quelle

[`anthropics/claude-code`](https://github.com/anthropics/claude-code) hat ca.
**138k Stars**, enthält aber hauptsächlich README, Changelog, Dokumentation,
Plugins, Beispiele und Hilfsskripte. Ein Quellbaum der eigentlichen CLI und ihr
Buildsystem fehlen. Das Repository ist deshalb hervorragend für
[Releases](https://github.com/anthropics/claude-code/releases),
[Changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md),
Issues und Hook-Beispiele, aber **nicht** für eine Implementationsanalyse des
Session-Stores.

Die Community-Anfrage
[#22002 „Open-source Claude Code“](https://github.com/anthropics/claude-code/issues/22002)
bestätigt diese Lücke aus Nutzersicht. Das ältere npm-Paket
[`@anthropic-ai/claude-code`](https://www.npmjs.com/package/@anthropic-ai/claude-code?activeTab=code)
lieferte einen gebündelten/minifizierten JavaScript-Entrypoint, nicht den
wartbaren Originalquelltext; der npm-Installationsweg ist inzwischen zugunsten
des nativen Installers als deprecated markiert. Aussagen, die aus der
minifizierten Datei rekonstruiert wurden, sollten daher nicht gegen die aktuelle
offizielle Session-Dokumentation ausgespielt werden.

### 2.2 Die Agent SDKs sind der offizielle programmatische Zugang

| Quelle | Was wirklich offen einsehbar ist | Nutzen für WhisperM8 |
|---|---|---|
| [`anthropics/claude-agent-sdk-python`](https://github.com/anthropics/claude-agent-sdk-python) | Ca. **7,7k Stars**; echter Python-Quellcode unter `src/claude_agent_sdk`, Tests, Beispiele und E2E-Infrastruktur. Das [Changelog](https://github.com/anthropics/claude-agent-sdk-python/blob/main/CHANGELOG.md) dokumentiert SessionStore-Protokoll, Hilfs-APIs und Referenzadapter. | Beste offizielle lesbare Quelle für Host-Lifecycle, Optionen, Transport und SessionStore-Vertrag. Die gebündelte geschlossene Claude-CLI selbst wird dadurch nicht offen. |
| [`anthropics/claude-agent-sdk-typescript`](https://github.com/anthropics/claude-agent-sdk-typescript) | Ca. **1,6k Stars**; öffentliches Repo vor allem mit README, Beispielen, Skripten und Changelog, aber ohne vollständigen TypeScript-Implementationsquellbaum. Das npm-Artefakt liefert deklarierte APIs und kompilierten Runtime-Code. | Verbindliche Typnamen und JavaScript-Verwendung, aber deutlich weniger ergiebig für interne Codeanalyse als Python. |
| [Offizielle Session-Dokumentation](https://code.claude.com/docs/en/agent-sdk/sessions) | Sprachübergreifender Vertrag für Continue, Resume, Fork, Listing und Metadaten. | Primäre Quelle für erwartetes Verhalten; Community-Code nur daran messen. |
| [Session Storage](https://code.claude.com/docs/en/agent-sdk/session-storage) | Vertrag für lokale Persistenz, externen `SessionStore`, Dual-Write, Deduplizierung, Rekonstruktion und Fork. | Direktes Vorbild für robuste Metadaten-/Mirror-Strategien, ohne Claude-JSONL selbst zur schreibbaren Datenbank zu erklären. |

Die aktuelle API-Oberfläche ist klarer als ältere Wrapper-Experimente:

| Operation | Python | TypeScript | Semantik |
|---|---|---|---|
| Resume | `ClaudeAgentOptions(resume=session_id)` | `options: { resume: sessionId }` | Vorhandene Session wird mit **derselben** ID fortgeschrieben. |
| Fork beim Resume | `resume=session_id, fork_session=True` | `resume: sessionId, forkSession: true` | Neue Session-ID, Eltern-Session bleibt unverändert. Die tatsächliche neue ID kommt aus Result-/Init-Nachrichten. |
| Letzte Session fortsetzen | `continue_conversation=True` | `continue: true` | Zuletzt verwendete Session für das Arbeitsverzeichnis; weniger deterministisch als explizites Resume. |
| Sessions auflisten | `list_sessions()` | `listSessions()` | Index-/Metadatenzugriff ohne vollständiges Parsen aller Transkripte. |
| Nachrichten lesen | `get_session_messages()` | `getSessionMessages()` | Read-only und paginierbar; liefert bei Kompaktierung die rekonstruierte aktive Kette, nicht zwingend jede rohe JSONL-Zeile. |
| Offline-Fork | `fork_session(...)` | `forkSession(...)` | Reine Store-Operation: Transkript kopieren, neue Session-ID vergeben und Message-UUIDs neu abbilden; startet keinen Agenten. |

Die APIs und Beispiele sind in der
[SDK-Session-Dokumentation](https://code.claude.com/docs/en/agent-sdk/sessions)
und im offiziellen Cookbook
[„Building a session browser“](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser)
belegt. Wichtig für neue TypeScript-Analyse: Die ältere V2-API
`createSession()` wurde laut aktueller Doku mit SDK **0.3.142** entfernt; der
unterstützte Weg ist wieder `query()`.

Der externe [SessionStore-Vertrag](https://code.claude.com/docs/en/agent-sdk/session-storage)
liefert weitere Robustheitsregeln:

- Claude schreibt immer zuerst lokal und spiegelt danach in den Store.
- Mirror-Fehler werden bis zu dreimal erneut versucht und anschließend als
  `mirror_error` gemeldet; die lokale Session läuft weiter.
- Eintrags-UUIDs dienen der Deduplizierung.
- Ein Fork ist keine Byte-Kopie: Session- und Message-IDs werden konsistent
  neu geschrieben.
- Für externe Stores gibt es keine automatische Retention; die lokale
  Bereinigung bleibt davon unabhängig.

Für WhisperM8 ist das stärker als ein eigener ad-hoc JSONL-Mirror: Session-ID,
Transkriptpfad und Fork-Lineage sind explizite Domänenwerte, während der
Terminalprozess nur eine Instanz ist, die auf diese Werte zeigt.

### 2.3 Community-Code zum JSONL-Format

Das lokale Format ist absichtlich leicht zugänglich, aber nicht als
versioniertes öffentliches Schema garantiert:

- [`ccusage/ccusage`](https://github.com/ccusage/ccusage) (ca. **17,3k Stars**,
  Release am **10.07.2026**) lädt große Mengen aus
  `~/.claude/projects/<project>/<sessionId>.jsonl` und trennt Report-Gruppierung
  von der tatsächlichen `sessionId`. Die eigene
  [Architekturdokumentation](https://github.com/ccusage/ccusage/blob/main/CLAUDE.md)
  ist eine gute Quelle für skalierbares Discovery und tolerant geparste
  Usage-Daten.
- [`daaain/claude-code-log`](https://github.com/daaain/claude-code-log)
  (ca. **1,2k Stars**) konvertiert Transkripte nach HTML/Markdown und bietet eine
  TUI zum Auflisten und Resumen per Session-ID. Quellcode, Tests und
  Entwicklerdokumentation machen es zur besseren Referenz für vollständige
  Message-/Tool-Result-Rekonstruktion.
- [`coo-labs/tjsonl`](https://github.com/coo-labs/tjsonl) versucht, das
  beobachtete JSONL als Community-Spezifikation und Validator zu fassen. Das ist
  nützlich für Test-Fixtures, bleibt aber **inoffiziell**.
- Issue
  [#53516 „Publish a stable, versioned JSONL transcript schema“](https://github.com/anthropics/claude-code/issues/53516)
  dokumentiert die von mehreren Tools konsumierten Felder (`type`,
  `message.role`, `message.content`, `sessionId`, `cwd`, `timestamp`) und gerade
  deshalb das Risiko: Mehrere verbreitete Parser hängen an einem nicht stabil
  zugesagten Schema.

Konsequenz: WhisperM8 darf JSONL lesen, sollte unbekannte Record-Typen und
unvollständige Tail-Zeilen aber tolerieren. Schreiben, Umordnen oder reparieren
sollte es die externen Dateien nicht; ein eigener Index verweist auf die
autoritative Datei.

### 2.4 Offizielle Dokumente, die Workflow 3 als Vertrag verwenden sollte

| Thema | Primärquelle | Relevanter Vertrag |
|---|---|---|
| Resume, Continue, Branch/Fork, Speicherort, Retention | [Sessions](https://code.claude.com/docs/en/sessions) | Resume schreibt dieselbe ID fort; Fork erzeugt eine neue; paralleles Resume interleaved; Standardbereinigung nach 30 Tagen. |
| Mentales Modell | [How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works) | Explizite Trennung von Resume und Fork. |
| CLI-Flags | [CLI reference](https://code.claude.com/docs/en/cli-reference) | `--resume`, `--continue`, `--fork-session`, `--no-session-persistence`. |
| Rewind/Checkpointing | [Checkpointing](https://code.claude.com/docs/en/checkpointing) | Checkpoints pro User-Prompt; Gespräch und Dateien können getrennt zurückgesetzt werden; Branch für alternative Zukunft. |
| Hook-Payloads | [Hooks reference](https://code.claude.com/docs/en/hooks) und [Hooks guide](https://code.claude.com/docs/en/hooks-guide) | Gemeinsame Felder `session_id`, `transcript_path`, `cwd`; `SessionStart.source` unterscheidet `startup`, `resume`, `clear`, `compact`. |
| Konfigurationswurzel | [Environment variables](https://code.claude.com/docs/en/env-vars) | `CLAUDE_CONFIG_DIR` verschiebt Einstellungen, Credentials, History und Plugins. |
| Dateilayout und Datenschutz | [Claude directory](https://code.claude.com/docs/en/claude-directory) | JSONL, Tool-Ergebnisse und File-History liegen lokal im Klartext; `cleanupPeriodDays`/Purge können Daten entfernen. |
| Worktrees | [Worktrees](https://code.claude.com/docs/en/worktrees) | Resume-Picker filtert standardmäßig nach Worktree; projektübergreifende Suche ist ein eigener Modus. |

## 3. Edge-Case-Landkarte: Fork, Resume und vermeintlicher Verlust

### 3.1 Die zentrale Identitätsregel

Nach heutigem offiziellem Vertrag gilt:

```text
Resume(S)             -> Session S, Datei S.jsonl wird fortgeschrieben
Resume(S) + Fork      -> neue Session F, neue F.jsonl, S bleibt unverändert
/branch oder /rewind  -> neuer Zweig F mit eigener ID, S bleibt als Elternzweig
```

Die [Session-Doku](https://code.claude.com/docs/en/sessions) und die
[Funktionsbeschreibung](https://code.claude.com/docs/en/how-claude-code-works)
sind hier eindeutig. Ältere Beobachtungen aus Happy, nach denen ein normales
`--resume` eine neue ID erzeugte, sind damit höchstens historisches
Wrapper-/Versionsverhalten und **nicht** der aktuelle Claude-Code-Vertrag.

Der kritische Designfehler für WhisperM8 wäre, die beim Start übergebene
Resume-ID dauerhaft als aktuelle ID zu behalten. Beim Fork ist sie nur die
**Quell-ID**. Die neue Ziel-ID und ihr `transcript_path` müssen aus der ersten
autoritativen SDK-/Hook-Nachricht übernommen und zusammen atomar gespeichert
werden.

### 3.2 Fälle, beobachtetes Verhalten und Konsequenz

| Fall | Dokumentiertes bzw. beobachtetes Verhalten | Explizite Behandlung / Evidenz | Bedeutung für WhisperM8 |
|---|---|---|---|
| Resume ohne Fork | Claude verwendet dieselbe Session-ID und hängt neue Records an dieselbe JSONL-Datei an. Ein Resume über exakte ID ist deterministischer als `--continue`. | [Sessions](https://code.claude.com/docs/en/sessions), [SDK Sessions](https://code.claude.com/docs/en/agent-sdk/sessions) | Binding bleibt auf derselben ID. `--continue` nicht als verlässlichen Ersatz für eine gespeicherte ID nutzen. |
| Resume mit `--fork-session` | Claude erzeugt eine neue ID und Datei; der alte Zweig bleibt unverändert. SDK-`forkSession` remappt zusätzlich Message-UUIDs statt nur Bytes zu kopieren. Session-only-Permissions werden laut Doku nicht vererbt. | [Sessions](https://code.claude.com/docs/en/sessions), [Session Storage](https://code.claude.com/docs/en/agent-sdk/session-storage), [Agent Deck](https://github.com/asheshgoplani/agent-deck) mit First-Class-Forks | Nach Start **atomar auf die neue ID umhängen**, `parentSessionID`/`rootSessionID` behalten und im UI klar „Fork von …“ zeigen. Ein späteres Resume muss die aktive Fork-ID verwenden, nicht die Start-ID. |
| `/branch` oder `/rewind` | `/branch` kopiert die Unterhaltung und wechselt sofort zum neuen Zweig; die Bestätigung nennt neue und alte ID. `/rewind` kann Gespräch, Code oder beides zurücksetzen bzw. zusammenfassen und dabei einen neuen Zweig erzeugen. | [Sessions](https://code.claude.com/docs/en/sessions), [Checkpointing](https://code.claude.com/docs/en/checkpointing) | Ein Fork kann **innerhalb** einer laufenden PTY-Session entstehen. Nicht nur Startflags beobachten; Hook-/Transcript-Identität während der Laufzeit neu abgleichen. |
| `/compact` | Bleibt in derselben Session und erzeugt keine neue Sessiondatei. Der aktive Kontext wird durch eine Zusammenfassung ersetzt; die rohe Historie bleibt im Transkript, während `getSessionMessages` nur die rekonstruierte Post-Compact-Kette liefern kann. | [Sessions](https://code.claude.com/docs/en/sessions), [Session Storage](https://code.claude.com/docs/en/agent-sdk/session-storage), [Issue #24304](https://github.com/anthropics/claude-code/issues/24304) zu vorhandener JSONL, aber verkürzter Resume-Historie | Sinkende Message-Zahl oder `SessionStart.source=compact` nie als neuer/verlorener Chat werten. Rohdatei, aktive Kette und UI-Zusammenfassung als drei verschiedene Ebenen behandeln. |
| Crash oder hartes Kill | Sessions werden kontinuierlich geschrieben; abgeschlossene Records sind normalerweise vorhanden. Für den gerade geschriebenen Tail gibt es aber keine dokumentierte Transaktionsgarantie. Issues zeigen unvollständige/verknüpfte History, Abstürze und extrem große JSONL als reale Fehlerklassen. | [Issue #9745](https://github.com/anthropics/claude-code/issues/9745), [#24304](https://github.com/anthropics/claude-code/issues/24304), [#22365](https://github.com/anthropics/claude-code/issues/22365) | Parser muss unvollständigen letzten Record ignorieren und später erneut lesen. Prozessende ist nicht Sessionlöschung; letzten guten Indexeintrag mit MTime/Größe behalten und als „Recovery nötig“ markieren. |
| Gleichzeitiges Resume derselben ID | Offizielle Doku warnt: Zwei Terminals schreiben dann in **dieselbe** Session; Nachrichten werden interleaved. Ein Lock-/Isolation-Vertrag wird nicht versprochen. | [Sessions: parallel sessions](https://code.claude.com/docs/en/sessions) | Pro `(CLAUDE_CONFIG_DIR, sessionID)` nur einen Writer erlauben oder beim zweiten Attach zwingend forken. Prozess-ID und Session-ID dürfen nicht dasselbe Statusfeld sein. |
| Projekt umbenannt oder verschoben | Sessions sind an den Projektpfad gebunden. SDK-Doku beschreibt encoded cwd: jedes nicht-alphanumerische Zeichen wird `-`. Ein falsches cwd ist eine häufige Ursache für scheinbar frisches Resume. Die Kodierung ist verlustbehaftet; verschiedene Pfade können kollidieren, und ein OS-seitig verschobener Ordner migriert alte Sessions nicht automatisch. | [SDK Sessions: cwd troubleshooting](https://code.claude.com/docs/en/agent-sdk/sessions), [Issue #30244](https://github.com/anthropics/claude-code/issues/30244) zu Kollisionen und verwaisten Sessions | Encoded cwd nur als Discovery-Hinweis verwenden. `session_id`, autoritatives `transcript_path`, `cwd` und Config-Root gemeinsam speichern; bei Move einen expliziten Relink/Migrationsfall anzeigen und Records nach ihrem tatsächlichen `cwd` prüfen. |
| `/cd` während aktiver Session | Claude Code **v2.1.169** führte `/cd` ein, um die aktive Session ohne Verlust des Prompt-Caches in ein anderes Arbeitsverzeichnis zu bewegen. Das ist nicht dasselbe wie ein inaktives Projekt im Finder umzubenennen. | [Claude Code Releases](https://github.com/anthropics/claude-code/releases) | Laufende `cwd`-Änderung als Sessionereignis übernehmen; Workspace-Bindung darf nicht unveränderlich aus dem Startpfad abgeleitet sein. |
| Custom Hooks beim Resume/Fork | Hook-Payloads enthalten ID, Transcriptpfad und cwd, hatten aber reale Versionsfehler. Das Changelog nennt unter anderem einen falschen `transcript_path` für resumte/geforkte Sessions sowie Rename/Tag-Probleme bei Resume aus anderem cwd. Nimbalyst musste Resume mit Custom Hooks gesondert reparieren. | [Claude Code Changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md), [Nimbalyst Releases](https://github.com/Nimbalyst/nimbalyst/releases) | Hooks sind die beste Live-Bestätigung, aber nicht unfehlbar. Payload gegen existierende Datei/Session-ID plausibilisieren, versionsbedingte Abweichung protokollieren und periodisch mit dem Store versöhnen. |
| Resume auf anderem Host oder Config-Root | Exakte ID allein reicht nicht: Das Transkript muss unter demselben encoded cwd verfügbar sein. `CLAUDE_CONFIG_DIR` verschiebt die gesamte Datenwurzel. Ein externer SessionStore kann hostübergreifend spiegeln, lokale Retention bleibt separat. | [SDK Sessions](https://code.claude.com/docs/en/agent-sdk/sessions), [Session Storage](https://code.claude.com/docs/en/agent-sdk/session-storage), [Environment variables](https://code.claude.com/docs/en/env-vars) | Die Identität ist mindestens `(configRoot, sessionID)`, Discovery zusätzlich pfadgebunden. Niemals nur `~/.claude` scannen; den tatsächlich gestarteten Environment-Snapshot speichern. |
| Session fehlt im Picker | Headless/SDK-Sessions werden laut Doku nicht im interaktiven Picker gezeigt, sind per exakter ID aber resumierbar. Picker filtert außerdem zunächst nach aktuellem Worktree/Projekt. | [Sessions](https://code.claude.com/docs/en/sessions) | „Nicht im Picker“ ist kein Beweis für Verlust. WhisperM8 braucht direkte ID-/Dateiprüfung und getrennte Zustände für verborgen, verwaist, beschädigt und gelöscht. |
| Retention oder echte Löschung | Lokale Sessions werden standardmäßig nach **30 Tagen** Inaktivität bereinigt; `cleanupPeriodDays`, `claude project purge`, `--no-session-persistence` und `CLAUDE_CODE_SKIP_PROMPT_HISTORY` verändern die Persistenz. Es existieren außerdem Berichte über unbeabsichtigte Bereinigung. | [Sessions](https://code.claude.com/docs/en/sessions), [Claude directory](https://code.claude.com/docs/en/claude-directory), [Issue #48334](https://github.com/anthropics/claude-code/issues/48334) | Vor „verloren“ den Persistenzmodus und Retention prüfen. Eigener Index darf einen fehlenden externen Chat nicht still löschen; Zustand und letzte bekannte Metadaten erhalten, aber externe `~/.claude`-Dateien read-only lassen. |
| UI/Remote-Client hat anderen Stand | Wrapper können zusätzlich zur Claude-Session eine eigene Synchronisationsidentität führen. Happy dokumentiert einen Fall, in dem eine am Desktop resumte Session mobil nicht erschien und mobil stattdessen ein neuer Chat entstand. | [Happy Issue #875](https://github.com/slopus/happy/issues/875), [Happy Releases](https://github.com/slopus/happy/releases) | Lokale Claude-ID und UI-Thread-ID getrennt modellieren und explizit mappen. Fallback auf „neue Conversation“ darf nie still erfolgen; Nutzer muss den Bruch sehen. |

### 3.3 „Chat verloren“ ist kein einzelner Zustand

Für die drei Schmerzpunkte sollte WhisperM8 mindestens diese Fälle auseinanderhalten:

1. **Vorhanden und gebunden:** ID und Datei stimmen mit der laufenden Instanz.
2. **Vorhanden, aber verborgen:** Picker-/Worktree-/Headless-Filter blendet die
   Session aus.
3. **Vorhanden, aber verwaist:** cwd oder `CLAUDE_CONFIG_DIR` hat sich geändert.
4. **Vorhanden, aber logisch unvollständig:** Parent-Chain oder Compact-Grenze
   rekonstruiert weniger Nachrichten, obwohl rohe JSONL noch existiert.
5. **Fork-Bindung veraltet:** Eltern-ID steht noch am UI-Chat, obwohl der Prozess
   bereits auf einer Kind-ID arbeitet.
6. **Temporär nicht lesbar:** unvollständiger Tail, laufender Write oder
   kurzzeitiger Discovery-Fehler.
7. **Physisch gelöscht bzw. nie persistiert:** Retention, Purge,
   `--no-session-persistence` oder tatsächlicher Defekt.

Issue [#24304](https://github.com/anthropics/claude-code/issues/24304) ist dafür
besonders lehrreich: „Resume zeigt nur den letzten Teil“ kann bei weiterhin
vorhandener JSONL auftreten. Nimbalysts
[Release-Fixes](https://github.com/Nimbalyst/nimbalyst/releases) zeigen das
komplementäre Host-Problem: Ein allgemeiner SDK-Fehler wurde als abgelaufene
Session missverstanden und führte still in einen neuen Chat. WhisperM8 sollte
deshalb niemals aus einem unspezifischen Start-/Resume-Fehler automatisch eine
neue Session erzeugen.

### 3.4 Abgeleitete Robustheitsregeln für WhisperM8

Die Codeanalyse in Workflow 3 sollte folgende Zielstruktur prüfen:

- Ein langlebiger Binding-Datensatz enthält mindestens Provider,
  `CLAUDE_CONFIG_DIR`, Session-ID, Eltern-/Root-ID, autoritativen
  `transcript_path`, aktuelles cwd, Workspace-ID, letzte Dateigröße/MTime und
  Lifecycle-Zustand.
- Launch-Argumente beschreiben **Absicht**. Die tatsächliche Session-ID aus
  `SessionStart`, SDK-Init/Result oder validierter JSONL beschreibt **Identität**.
- Ein Fork aktualisiert Ziel-ID, Transkriptpfad und Lineage in einer atomaren
  Store-Operation. Der alte Chat bleibt auffindbar; die UI markiert klar, welcher
  Zweig aktiv ist.
- Ein Session-Writer-Lease verhindert paralleles Resume derselben ID. Der Nutzer
  kann stattdessen bewusst forken.
- Discovery liest Claude-Dateien tolerant und read-only, versöhnt Hooks mit
  periodischem Scan und löscht eigene Metadaten nicht aufgrund eines einzelnen
  negativen Scans.
- Fehlermeldungen unterscheiden „nicht gefunden“, „falscher Pfad“, „nicht im
  Picker“, „Tail unvollständig“, „Resume fehlgeschlagen“ und „extern gelöscht“.
- Retention und persistenzabschaltende Flags werden beim Start sichtbar gemacht;
  sonst kann WhisperM8 eine Haltbarkeit suggerieren, die Claude nicht garantiert.

## 4. Klon-Empfehlung für Workflow 3

Superset liegt bereits lokal. Für eine fokussierte Codeanalyse sollten insgesamt
sechs Repositories betrachtet werden, davon fünf neu zu klonen:

| Priorität | Repository | Was konkret analysiert werden soll |
|---:|---|---|
| 1 | [`Nimbalyst/nimbalyst`](https://github.com/Nimbalyst/nimbalyst) | Aktuelle Agent-SDK-Anbindung, Sessionimport, Wechsel der aktiven Session-ID, Resume-Fehlerklassifikation, Custom-Hook-Kompatibilität sowie Schutz gegen Cross-Window-Vermischung. Das trifft alle drei WhisperM8-Schmerzpunkte direkt. |
| 2 | [`asheshgoplani/agent-deck`](https://github.com/asheshgoplani/agent-deck) | First-Class-Fork-Datenmodell, Eltern-/Kind-Beziehungen, persistenter Sessionstatus, tmux-Reattach und getrennte `CLAUDE_CONFIG_DIR`-Gruppen. Beste Quelle speziell für Schmerzpunkt (b). |
| 3 | [`siteboon/claudecodeui`](https://github.com/siteboon/claudecodeui) | Zusammenspiel von Agent SDK, Streaming, Berechtigungsrückfragen, lokaler Session-Discovery und PTY-Shell. Prüfen, wann SDK-ID und UI-Thread-ID gesetzt bzw. gewechselt werden. |
| 4 | [`anthropics/claude-agent-sdk-python`](https://github.com/anthropics/claude-agent-sdk-python) | Offizieller lesbarer Referenzcode für Optionen, Transport, SessionStore, Fehlerwege und Conformance-Tests. Als Norm verwenden, nicht als GUI-Vorbild. |
| 5 | [`daaain/claude-code-log`](https://github.com/daaain/claude-code-log) | Tolerante JSONL-Rekonstruktion, Compact-/Parent-Chain, Tool-Result-Zuordnung, große Dateien und Resume-Auswahl. Daraus Parser-Fixtures und Defektfälle ableiten. |
| 6 | [`superset-sh/superset`](https://github.com/superset-sh/superset) — **bereits lokal** | PTY-Ownership, Prozess-Reconnect, Workspace-/Worktree-Lifecycle und Statusentkopplung. Bewusst als Terminalreferenz lesen; Claude-Sessionsemantik muss WhisperM8 darüber ergänzen. |

Falls die Terminalschicht nach Superset noch ungeklärte macOS-spezifische Fragen
offenlässt, ist [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux) der
erste Nachrücker. Nicht priorisiert werden Crystal (deprecated), Vibe Kanban
(sunsetting), Opcode (stagnierend) und OpenCode (keine Claude-Code-CLI).

## 5. Ergebnis für Workflow 3

Der stärkste aktive Vergleichskandidat ist **Nimbalyst**, weil seine jüngsten
Fixes genau die gefährliche Zone aus Sessionimport, Resume, Hooks und
Cross-Window-Bindung betreffen. Die beste Quelle für den offiziellen
programmatischen Vertrag ist die Kombination aus
[`claude-agent-sdk-python`](https://github.com/anthropics/claude-agent-sdk-python),
[SDK-Session-Doku](https://code.claude.com/docs/en/agent-sdk/sessions) und
[SessionStore-Doku](https://code.claude.com/docs/en/agent-sdk/session-storage),
nicht das `claude-code`-Repository.

Die wichtigste Edge-Case-Erkenntnis lautet: **Resume und Fork müssen als zwei
verschiedene Identitätsübergänge modelliert werden.** Resume behält die ID;
Fork erzeugt eine neue ID, die erst aus dem laufenden Claude-/SDK-Ereignis
autoritativ bekannt wird. Solange WhisperM8 Prozess, Workspace und Session in
einem einzigen „Chat“-Status vermischt, bleiben verlorene Chats und Resume in
den falschen Zweig strukturell möglich.
