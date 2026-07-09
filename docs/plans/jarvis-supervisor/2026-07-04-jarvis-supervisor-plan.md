# Jarvis v1: Globaler Agent-Supervisor für WhisperM8

Stand: 2026-07-04 (Revision 2 — nach Architektur-Review)

Revision 2 ändert gegenüber dem Erstentwurf vier Kernpunkte:

1. **Kein Read-only-Tool-Loop in v1.** `codex exec` ist ein One-Shot-Prozess; ein
   Tool-Call-Loop hieße mehrere Codex-Aufrufe pro User-Turn (2+ Minuten Latenz,
   Kontext bei jedem Schritt neu bezahlt). Stattdessen: Kontext wird vollständig
   vorab in den Prompt injiziert (Snapshot immer, Digests selektiv via
   @-Mentions). Das Tool-Konzept bleibt nur für **mutierende** Actions bestehen.
2. **Zweistufige Reports.** Tier 1 (sofort, ohne LLM) aus Metadaten + Transcript-Tail;
   Tier 2 (Codex) nur on demand oder gebatcht. Sonst wird jeder Statuswechsel bei
   5+ parallelen Sessions zum Dauerbrand aus Codex-Prozessen.
3. **Board-first UX statt Chat+Postfach.** Der Kern-Use-Case ist „an mehreren
   Projekten arbeiten und immer alles im Blick haben". Das leistet ein ambientes,
   attention-sortiertes Status-Board — der Chat ist das Werkzeug darüber, nicht
   das Zentrum. Segmente reduziert auf Übersicht / Chat / Aktionen.
4. **Vertical Slices statt Infrastruktur-Pyramide.** Slice 1 beweist nach wenigen
   Tagen, ob Codex-headless als Brain taugt — bevor vier Schichten Infrastruktur
   stehen.

## Zielbild

Jarvis ist ein globales Supervisor-Panel im rechten Inspector des
Agent-Chats-Fensters. Es besteht aus zwei Hälften:

1. **Mission Control (ohne LLM):** ein permanent sichtbares Status-Board über
   alle WhisperM8-bekannten Claude-, Codex- und Background-Sessions, sortiert
   nach „braucht mich", mit sofortigen Tier-1-Reports bei Statuswechseln.
2. **Brain (Codex headless):** ein Chat über dem Board, der Zusammenfassungen
   liefert, Folgeprompts entwirft und Workspace-Aufräumaktionen als
   Action-Karten vorschlägt.

V1 arbeitet review-first:

- Alles Lesende (Board, Tier-1-Reports, Snapshot) läuft ohne Bestätigung und ohne LLM.
- Mutierende Vorschläge erzeugen Action-Karten mit Apply/Skip.
- Kein Auto-Send ohne explizite Nutzerbestätigung.
- Kein echter MCP-Server in v1; die interne Swift-Action-Schicht ist so
  geschnitten, dass sie später als MCP-Tools exportierbar ist.

## Bestehender Kontext im Repo

WhisperM8 ist bereits mehr als eine Diktier-App. Die Agent-Chats-Welt ist in der App breit angelegt:

- `WhisperM8/Views/AgentChatsView.swift`
  - Hauptfenster für Agent-Chats, Sidebar, Tabs, Runtime-Services, UI-State, Background-Agent-Flows.
  - Relevante State-Quellen: `openTabIDs`, `pinnedSessionIDs`, `selectedSessionID`, `runtimeStatusStore`, `awaitingInputSessionIDs`, `terminalRegistry`.
  - Bestehendes Inspector-Pattern: `isInspectorVisible` (`@SceneStorage`, fensterlokal) — Vorlage für das Jarvis-Panel.
- `WhisperM8/Models/AgentChat.swift`
  - Zentrale Modelle: `AgentProvider`, `AgentSessionKind`, `AgentChatStatus`, `AgentSessionRuntimeStatus`, `AgentProject`, `AgentChatSession`, `AgentWorkspace`.
  - `AgentSessionRuntimeStatus`: `working / awaitingInput / idle / stopped / errored`.
  - Background-Agent-Felder: `kind`, `backgroundShortID`, `backgroundSubAgent`, `backgroundPermissionMode`.
- `WhisperM8/Models/AgentUIState.swift`
  - Persistenter UI-State für offene Tabs, Pins, Selektion und Multi-Window-State.
  - Schema v3 kennt `AgentChatWindowState` und `primaryWindowID`.
- `WhisperM8/Services/AgentChats/AgentSessionStore.swift`
  - Facade für Workspace-Mutationen: Sessions/Projekte upserten, umbenennen, gruppieren, UI-State speichern.
- `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift`
  - Prozessweiter, debounced, observable Workspace-Kern.
  - Wichtig für Jarvis: keine parallelen direkten JSON-Writes am Workspace vorbei.
  - Gotcha: Mutation-Closures laufen unter dem prozessweiten Store-Lock — keine
    Subprozesse oder teure Arbeit darin; Validierung vor dem `mutate`-Aufruf hoisten.
- `WhisperM8/Views/AgentTerminalView.swift`
  - SwiftTerm-PTY-Integration, `AgentTerminalRegistry`, `AgentTerminalController`.
  - Bereits vorhanden: `terminal.send(...)`; für Jarvis braucht es eine kleine öffentliche Prompt-Send-Methode (mit Bracketed Paste, siehe Abschnitt 10).
- `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift`
  - Leitet live `AgentSessionRuntimeStatus` aus Transcripts ab.
  - Primäre Quelle für Tier-1-Report-Trigger.
- `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift`
  - Event-driven Claude-Code-Hook-Bridge via Settings/Event-JSONL.
  - Bereits für SessionStart/SessionEnd/Notification/PreToolUse nutzbar — kann
    Tier-1-Reports für Claude-Sessions ohne Polling füttern.
- `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift` / `CodexTranscriptReader.swift`
  - Parser für die Provider-JSONL-Transcripts (streamend, >50-MB-fähig).
- `WhisperM8/Services/AgentChats/AgentChatTailExtractor.swift`
  - Bestehende Routing-Logik für Chat-, Background- und AgentView-Kontext-Tails.
  - Vorlage für Jarvis-Digest-Routing.
- `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift`
  - `claude --bg` Spawn inkl. Short-ID-Parsing.
- `WhisperM8/Services/AgentChats/SupervisorJobReader.swift`
  - Liest Claude Supervisor Job-State und `linkScanPath` für Background-Agent-Transcripts.
- `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift`
  - Generischer Subprocess-Runner für headless LLM-Aufrufe.
  - **Lücke:** unterstützt aktuell kein stdin — muss für den Codex-Aufruf um eine
    stdin-Pipe erweitert werden (oder Prompt via Temp-Datei, siehe Abschnitt 7).
- `WhisperM8/Services/Dictation/PostProcessingService.swift`
  - `CodexInvocation.arguments(...)` ist die verlässliche, produktiv erprobte
    Vorlage für sandboxed/headless `codex exec`-Aufrufe. Flags gegen die
    installierte Codex-Version verifizieren (insb. `--ephemeral`).
- `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift`
  - Bestehendes Muster für Headless-Generierung, Inflight-State und Tests.
- `WhisperM8/Services/AgentChats/AgentSessionNotifier.swift`
  - Bestehender Pfad für macOS-Notifications — wird für Tier-1-Report-Notifications mitgenutzt.

Weitere relevante Dokumentation:

- `docs/archive/claude-code-integration/04-whisperm8-integration-stand.md (historisch, Stand Mai 2026)` — aktueller Stand der Claude/Codex-Agent-Integration.
- `docs/archive/claude-code-integration/05-beratung-optionen.md` — strategische Bewertung für Agent View, Background Agents und WhisperM8-Integration.
- `docs/referenz/claude-code/03-hooks-sdk.md` — Kontext zu Claude Hooks, MCP, SDK, Sub-Agents.
- `docs/archive/agent-chats-redesign/README.md` — UX-/Redesign-Kontext der Agent-Chats-Welt.

## Produktentscheidungen für v1

Entschiedene Defaults:

- UI: rechter Inspector im Agent-Chats-Fenster, Segmente **Übersicht / Chat / Aktionen**.
- Sichtbarkeit: **in jedem Fenster verfügbar** (fensterlokaler Toggle analog
  `isInspectorVisible`), aber ein globaler Jarvis-State. Keine Kopplung an
  `primaryWindowID` — wer das Primary-Fenster schließt, verliert Jarvis nicht.
- Engine: Codex headless — genau **ein** `codex exec`-Aufruf pro Chat-Turn.
- Autonomie: Review zuerst. Board und Tier-1-Reports sind rein lesend und laufen frei.
- Coverage: nur WhisperM8-bekannte Sessions, keine historische globale Disk-Inventur.
- Reports: zweistufig — Tier 1 sofort ohne LLM, Tier 2 (Codex) on demand/gebatcht.
- Kontext: Snapshot immer, Digests selektiv (Selektion, @-Mentions, frische Statuswechsel).
- Persistenz: eigener `jarvis-state.json` (klein) + separater Digest-Cache.
- Actions: Action Queue mit Apply/Skip; Fokus Rename/Group/Archive + Prompt-Drafts.
- Badge-Semantik: zählt Sessions, die Aufmerksamkeit brauchen — nicht Reports.

Nicht in v1 (bewusst gestrichen bzw. verschoben):

- **Read-only-Tool-Loop zur Laufzeit** (`list_sessions`, `get_session_context`,
  `get_runtime_status`, `get_open_tabs`, `summarize_workspace`,
  `draft_prompt_for_session`) — der Kontext wird vorab injiziert; „summarize"
  und „draft prompt" sind schlicht Chat-Antworten. Als echter MCP-Server v2.
- Pin/Unpin als Jarvis-Actions (Kosmetik, geringer Wert, UI-State-Sonderpfad).
- Drafts als eigenes viertes Segment (ein Prompt-Draft ist eine Aktion → Segment „Aktionen").
- Externe Browser-Tabs oder Claude-Web-Chats steuern.
- Echter MCP-Server.
- Auto-Send ohne explizite Bestätigung.
- Globale Inventur aller historischen `~/.claude` / `~/.codex` Sessions.
- Native Erkennung der aktuell selektierten Subsession in `claude agents`.

## Architektur

### 1. Jarvis Store

Neue Dateien:

- `~/Library/Application Support/WhisperM8/jarvis-state.json` — Chat, Reports, Actions, Drafts. Bewusst klein.
- Digest-Cache **nicht** in dieser Datei (siehe Abschnitt 5): in-memory, optional
  Sidecar `jarvis-digest-cache.json`. Sonst werden bei jeder Chat-Message mehrere
  MB debounced neu geschrieben.

Neuer Service:

- `JarvisStateStore`

Empfohlene Modelle:

```swift
struct JarvisState: Codable, Equatable {
    var schemaVersion: Int
    var reportModeEnabled: Bool
    var chatMessages: [JarvisChatMessage]
    var inbox: [JarvisReport]
    var actions: [JarvisActionProposal]
    var promptDrafts: [JarvisPromptDraft]
    var updatedAt: Date
}
```

Persistenz-Regeln:

- Eigenes JSON, keine Migration von `AgentWorkspace`.
- Atomic writes analog `AgentSessionStore.saveUIState`.
- Prune-Policy: letzte 200 Chat-Messages, 200 Reports, 100 Actions, 100 Drafts (Startwerte).
- Store muss in Tests mit temp-URL injizierbar sein.
- Ein globaler Store (Singleton/Registry analog `AgentWorkspaceStoreRegistry`),
  von allen Fenstern geteilt; SwiftUI observiert über eine `@Observable`-Projektion.

### 2. Jarvis-Inspector in jedem Fenster

Integration in `AgentChatsView.swift`:

- Jarvis-Panel als rechter Bereich unter dem bestehenden `isInspectorVisible`-Pattern;
  eigener `@SceneStorage`-Toggle `agentChatsJarvisVisible` pro Fenster.
- Jedes Fenster rendert dieselben globalen Jarvis-Daten — kein Primary-Window-Sonderfall,
  keine „wo ist Jarvis hin?"-Situation.

Neue View-Komponenten:

- `JarvisInspectorView` — Container mit Header + Segmenten
- `JarvisOverviewView` — Status-Board + Report-Feed (Kern des Panels)
- `JarvisChatView`
- `JarvisActionQueueView` — Actions + Prompt-Drafts

UI-Segmente:

- `Übersicht` (Default)
- `Chat`
- `Aktionen`

Header:

- Status: Ready / Thinking (mit Schritt-Text, s. u.) / Codex Error / Report Mode On.
- Toggle: Report Mode (steuert Tier-1-Erzeugung + Notifications).
- Button: Workspace aufräumen (startet einen Brain-Turn mit Cleanup-Auftrag).
- Badge: Attention-Count (s. Abschnitt 3).

### 3. Status Board und Attention-Modell (neu, LLM-frei)

Das Board ist die Antwort auf „alles im Blick" — permanent sichtbar, kein Prompt nötig.

- Gruppierung nach Projekt; innerhalb sortiert nach Attention-Priorität:
  1. `awaitingInput`
  2. `errored`
  3. frisch fertig und ungelesen (`working → idle/stopped`, Report ungelesen)
  4. `working`
  5. `idle` / Rest
- Zeile pro Session: Statuspunkt (bestehende Farben), Titel, Projekt, „seit N min",
  Tier-1-Einzeiler (letzte Assistant-Message, gekürzt).
- Klick auf Zeile: Session im Fenster selektieren/öffnen (bestehende Open-Tab-Pfade).
- Badge-Zahl im Header und an der MenuBarExtra = Anzahl Sessions in Kategorie 1–3.
  Reports „gelesen" markieren senkt den Zähler.

Neuer purer Builder (unit-testbar):

- `JarvisAttentionModelBuilder` — nimmt `JarvisWorkspaceSnapshot` + Read-Flags,
  liefert sortierte Board-Struktur. Keine View-Abhängigkeiten.

### 4. Snapshot Builder

Neuer Service:

- `JarvisWorkspaceSnapshotBuilder`

Ziel: Jarvis bekommt eine konsistente, serialisierbare Sicht auf den Workspace, ohne direkt View-Internals zu kennen.

Quellen:

- `AgentWorkspaceUIModel.shared.workspace`
- `AgentSessionStore.loadUIState()`
- `AgentSessionRuntimeStatusStore`
- `AgentTerminalRegistry.shared`
- `awaitingInputSessionIDs` aus `AgentChatsView` wird explizit an den Builder übergeben.

Achtung Concurrency: `AgentTerminalRegistry` und UI-Modelle sind MainActor-gebunden —
der Builder sammelt auf dem MainActor und liefert einen `Sendable`-Snapshot;
Digest-Erzeugung und Codex-Aufrufe laufen danach off-main.

Empfohlene Modelle:

```swift
struct JarvisWorkspaceSnapshot: Codable, Equatable, Sendable {
    var generatedAt: Date
    var selectedSessionID: UUID?
    var projects: [JarvisProjectSnapshot]
    var sessions: [JarvisSessionSnapshot]
    var openTabsByWindow: [JarvisWindowTabsSnapshot]
    var pinnedSessionIDs: [UUID]
}

struct JarvisSessionSnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var provider: AgentProvider
    var kind: AgentSessionKind
    var projectID: UUID
    var projectName: String
    var projectPath: String
    var title: String
    var groupName: String?
    var status: AgentChatStatus
    var runtimeStatus: AgentSessionRuntimeStatus?
    var isOpenInAnyWindow: Bool
    var isPinned: Bool
    var isRunningPTY: Bool
    var isAwaitingInputPulse: Bool
    var externalSessionID: String?
    var backgroundShortID: String?
    var lastActivityAt: Date
    var lastTurnAt: Date?
    var titleIsAutoGenerated: Bool?
}
```

Wichtig:

- Snapshot enthält nur Sessions aus `AgentWorkspace.sessions`.
- Keine direkten Scans über `~/.claude` oder `~/.codex` für v1.
- Multi-Window-Open-Tabs kommen aus `AgentUIState.windows`.
- Jarvis selbst ist global, nicht fensterlokal.

### 5. Transcript Digest

Neuer Service:

- `JarvisTranscriptDigestBuilder`

Bestehende Bausteine nutzen:

- `ClaudeTranscriptReader.readTail/read`
- `CodexTranscriptReader.readTail/read`
- `SupervisorJobReader.readSingle(...)` für Background `linkScanPath`
- `AgentChatTailExtractor` als Vorlage für Routing.

Empfohlene Modelle:

```swift
struct JarvisTranscriptDigest: Codable, Equatable {
    var sessionID: UUID
    var transcriptPath: String?
    var cacheKey: String
    var generatedAt: Date
    var availability: JarvisDigestAvailability
    var headline: String?
    var tail: String
    var digest: String
    var messageCountEstimate: Int?
}

enum JarvisDigestAvailability: String, Codable {
    case available
    case missingExternalSessionID
    case missingTranscript
    case unsupportedAgentView
    case parseFailed
}
```

Cache:

- Key aus `sessionID` + `transcriptPath` + file size + mtime.
- **In-memory** (LRU, ~50 Einträge); optional kleiner Disk-Sidecar
  `jarvis-digest-cache.json` für Warm-Start. Nicht Teil von `jarvis-state.json`.

Routing:

- Claude `.chat`: `ClaudeTranscriptReader` via `externalSessionID` + cwd.
- Codex `.chat`: `CodexTranscriptReader` via `externalSessionID`.
- Claude `.backgroundChat`: `SupervisorJobReader` shortID → `linkScanPath` → `ClaudeTranscriptReader`.
- `.agentView`: v1 `unsupportedAgentView`, kein opportunistischer Subsession-Digest.

Kontextbudget (pro Brain-Turn):

- Volles Digest-Budget (bis ~12k Zeichen Digest+Tail) nur für:
  - die aktuell selektierte Session,
  - explizit per @-Mention referenzierte Sessions/Projekte (Abschnitt 11),
  - Sessions mit frischem, ungelesenem Statuswechsel (bei Report-/Cleanup-Turns).
- Alle übrigen Sessions: nur Snapshot-Metadaten + Tier-1-Einzeiler (~200 Zeichen).
- Hartes Gesamtbudget pro Prompt (~60k Zeichen Startwert); bei Überschreitung
  Digests in Attention-Reihenfolge kürzen und im Prompt vermerken, was gekürzt wurde.

### 6. Reports: zweistufig

**Tier 1 — sofort, ohne LLM.** `JarvisTier1ReportBuilder` (pur, testbar) erzeugt
beim Runtime-Statuswechsel aus Snapshot + Digest-Tail einen Metadaten-Report:
Trigger, Projekt, Session, Dauer seit Turn-Start, letzte Assistant-Message als
Summary (gekürzt). Landet ohne Verzögerung in der Übersicht.

Trigger (via `AgentSessionRuntimeWatcher`-Statuswechsel; für Claude-Sessions
zusätzlich event-driven über `ClaudeHookBridge`-Notifications):

- `working → idle`
- `working → stopped`
- `working → awaitingInput`
- `working → errored`

Dedupe:

- Maximal ein Report pro Session pro Transcript-Version (Version = Digest-Cache-Key).
- Kein neuer Report, wenn sich nur UI-Selektion ändert.

**Tier 2 — Codex, on demand oder gebatcht.** Kein automatischer Codex-Aufruf pro
Statuswechsel. Stattdessen:

- Button „Analysieren" auf der Report-Karte → ein Brain-Turn mit vollem Digest
  dieser Session, Ergebnis reichert den Report an (`outcome`, `blocker`,
  `nextStep`, Prompt-Draft).
- Optional „Briefing": ein Brain-Turn fasst alle ungelesenen Tier-1-Reports
  gebatcht zusammen (manuell auslösbar; Auto-Batch mit Debounce ist v2).
- Brain-Turns laufen über eine serielle Queue — nie mehr als ein Codex-Prozess.

Report-Modell:

```swift
struct JarvisReport: Identifiable, Codable, Equatable {
    var id: UUID                    // vergibt die App, nie das Modell
    var createdAt: Date
    var sessionID: UUID
    var trigger: JarvisReportTrigger
    var tier: JarvisReportTier      // .metadata / .analyzed
    var title: String
    var summary: String
    var outcome: String?
    var blocker: String?
    var nextStep: String?
    var suggestedPromptDraftID: UUID?
    var digestCacheKey: String?
    var isRead: Bool
}
```

Darstellung — Report-Karte mit Ein-Klick-Handlung (der Magic Moment):

- **[Session öffnen]** — selektiert/öffnet die Zielsession.
- **[Folgeprompt entwerfen]** — Brain-Turn, erzeugt Prompt-Draft für diese Session.
- **[Analysieren]** — Tier-2-Anreicherung (nur bei `tier == .metadata`).
- **[Erledigt]** — markiert gelesen, senkt den Attention-Badge.
- Reports landen im Übersicht-Feed, nicht als Chat-Spam.

Notifications (Report Mode On):

- Tier-1-Reports der Kategorien `awaitingInput`/`errored`/fertig optional als
  macOS-Notification über den bestehenden `AgentSessionNotifier`-Pfad, wenn kein
  Agent-Chats-Fenster fokussiert ist. Klick → Fenster + Session öffnen.
- Attention-Count als Badge an der MenuBarExtra.

### 7. Codex Brain

Neuer Service:

- `JarvisCodexClient`

Nutzt:

- `AgentHeadlessCLI` — **erweitert um stdin-Unterstützung** (Pipe für den Prompt).
  Alternative, falls stdin unerwünscht: Prompt in Temp-Datei im Scratch-Verzeichnis
  und Pfad übergeben. Prompt **nicht** als argv-Argument (ARG_MAX, Prozessliste).
- `AgentCommandBuilder.commandPath("codex")` bzw. derselbe Resolver wie `CodexStatusProbe`.
- `LoginShellEnvironment.shared.processEnvironment()`.

Codex-Aufruf (Flags gegen installierte Version verifizieren; `CodexInvocation`
in `PostProcessingService` ist die erprobte Vorlage):

```bash
codex exec \
  --sandbox read-only \
  --skip-git-repo-check \
  --output-last-message <temp-output-path> \
  -m <model> \
  -c model_reasoning_effort=<effort> \
  -            # Prompt via stdin
```

Turn-Semantik:

- Genau **ein** Codex-Aufruf pro User-Turn. Kein Tool-Loop.
- Prompt Builder injiziert: Systemprompt, Workspace-Snapshot (kompakt),
  selektive Digests (Budget aus Abschnitt 5), letzte N Chat-Messages,
  Action-Schemas (nur die mutierenden), ggf. Auftrag (Cleanup/Analyse/Briefing).
- Brain-Turns seriell (eine Queue); UI zeigt Schritt-Status:
  „Snapshot bauen → 3 Transcripts lesen → Codex denkt…".

Modell/Effort:

- Default aus bestehenden Codex-Settings, analog PostProcessing.
- Keine neue Settings-Flut in v1.

Timeouts:

- Chat normal: 45s.
- Cleanup/Briefing mit großem Kontext: 90s.

Sofort-Antworten ohne LLM:

- Fragen, die aus dem Snapshot beantwortbar sind („was läuft gerade?",
  „welche Session wartet auf mich?"), beantwortet die App direkt aus dem
  Attention-Modell — optional als Quick-Reply-Chips über dem Chat-Eingabefeld,
  ohne Codex-Roundtrip.

### 8. Strict-JSON-Vertrag

Codex muss ein JSON-Objekt liefern (kein `toolCalls`-Feld mehr):

```json
{
  "assistantMessage": "Kurzantwort an den Nutzer.",
  "reports": [],
  "actions": [],
  "promptDrafts": []
}
```

Empfohlene Swift-Modelle:

```swift
struct JarvisBrainResponse: Codable, Equatable {
    var assistantMessage: String
    var reports: [JarvisReportDraft]
    var actions: [JarvisActionProposalDraft]
    var promptDrafts: [JarvisPromptDraftDraft]
}
```

Parser-Regeln:

- **IDs vergibt die App.** Die `…Draft`-Typen enthalten nur Inhalt (Titel,
  Begründung, Payload); `UUID`s, `createdAt`, `status` setzt der Parser beim
  Übernehmen. Modell-generierte UUIDs sind Kollisions- und Dedupe-Gift.
- **Fence-tolerant parsen:** führende/trailende ```-Fences und Prosa vor/nach dem
  JSON-Objekt strippen, dann strikt decodieren. Reines „nur top-level JSON"
  produziert in der Praxis zu viele `failed`-Antworten.
- Unbekannte Action-Kinds ignorieren und loggen.
- Mutierende Actions müssen eine gültige `sessionID` referenzieren.
- Archive ablehnen, wenn die Session aktuell `working` ist oder ein PTY läuft.
- Send ablehnen, wenn kein laufender PTY-Controller existiert.
- Rename bei manuell gesetztem Titel (`titleIsAutoGenerated != true`) nur
  zulassen, wenn die Action explizit als nutzer-angefragte Cleanup-Aktion markiert ist.
- Bei kaputtem JSON: Raw-Output als failed Chat-Event speichern, keine Actions erzeugen.

Jarvis-Systemprompt muss enthalten:

- Du bist Jarvis, Workspace-Supervisor für WhisperM8.
- Du darfst keine Mutationen behaupten — für Mutationen erzeuge Action-Proposals.
- Reports kurz, operativ, immer mit nächstem Schritt.
- Prompt-Drafts müssen direkt in Claude/Codex nutzbar sein (imperativ, mit Kontext).
- Antworte ausschließlich mit dem JSON-Objekt.

### 9. Action Queue (mutierende Actions)

Aus dem früheren Tool-Registry-Konzept bleibt der mutierende Teil: eine
`JarvisActionRegistry` mit MCP-ähnlichen Schemas (für den v2-Export), deren
Actions erst bei Apply ausgeführt werden.

Action-Kinds v1:

- `rename_session`
- `set_session_group`
- `archive_session`
- `create_prompt_draft`
- `send_prompt_draft_to_running_pty`

Mutation-Pfade:

- Workspace-Mutationen über `AgentSessionStore`:
  - rename: `renameSession(id:title:)`
  - group: `setSessionGroup(id:groupName:)`
  - archive: `updateSession(id:) { status = .archived }`
  - Validierung (Session existiert, Status kompatibel) **vor** dem `mutate`-Aufruf
    hoisten — nichts Teures unter dem Store-Lock.
- UI-nahe Actions (Tab öffnen, Session selektieren) über Host-Callbacks aus
  `AgentChatsView` — Jarvis mutiert nie eine zweite UI-State-Kopie.

Modell:

```swift
struct JarvisActionProposal: Identifiable, Codable, Equatable {
    var id: UUID                    // App-vergeben
    var createdAt: Date
    var kind: JarvisActionKind
    var targetSessionID: UUID?
    var title: String
    var rationale: String
    var before: String?
    var after: String?
    var payload: JSONValue
    var status: JarvisActionStatus
    var failureMessage: String?
}

enum JarvisActionStatus: String, Codable {
    case pending
    case applied
    case skipped
    case failed
    case reverted
}
```

UI:

- Karte pro Action: Ziel, Vorher/Nachher, Begründung, Buttons Apply/Skip.
- Batch-Apply nur für Rename/Group. Kein Batch-Apply für Archive oder Send.
- **Undo** für Rename/Group/Archive: `before`-Wert ist gespeichert; ein Klick
  „Rückgängig" auf angewendeten Karten (Status → `reverted`). Billig zu bauen,
  senkt die Review-Hemmschwelle deutlich.

Apply-Validierung (erneut beim Apply, nicht nur beim Proposal):

- Session existiert noch?
- Status noch kompatibel? (Archive nicht bei `working`/laufendem PTY)
- Vorher-Wert noch aktuell (Drift-Erkennung)?
- Wenn Drift: Action `failed` mit kurzer Fehlermeldung.

### 10. Prompt-Drafts und PTY-Send

Modell:

```swift
struct JarvisPromptDraft: Identifiable, Codable, Equatable {
    var id: UUID                    // App-vergeben
    var createdAt: Date
    var targetSessionID: UUID
    var title: String
    var prompt: String
    var rationale: String?
    var status: JarvisPromptDraftStatus
}

enum JarvisPromptDraftStatus: String, Codable {
    case draft
    case copied
    case sent
    case failed
}
```

`AgentTerminalController` erweitern:

```swift
@MainActor
func sendPrompt(_ text: String, submit: Bool)
```

Verhalten:

- **Bracketed Paste ist Pflicht:** Text in `ESC[200~ … ESC[201~` wrappen, sonst
  submitted jede Newline eines mehrzeiligen Prompts in der Claude/Codex-TUI sofort.
- Wenn `submit == true`: Return **nach** dem Paste-Block senden, mit kleinem
  Delay (~50–100 ms), damit die TUI den Paste verarbeitet hat.
- V1 sendet nur nach explizitem Button-Klick.
- Wenn Controller nicht running: Send-Button deaktiviert; stattdessen Copy / Tab öffnen.

UI (im Segment „Aktionen"):

- Prompt-Text, Zielsession, Begründung.
- Buttons: Copy, Tab öffnen, Senden (nur bei laufendem PTY).

### 11. @-Mentions im Jarvis-Chat (neu)

Explizite Referenzen lösen das Kontextbudget-Problem und machen
Multi-Projekt-Arbeit flüssig:

- `@` im Chat-Eingabefeld öffnet einen Picker über Sessions und Projekte
  (Datenquelle: Snapshot; Fuzzy-Match auf Titel/Projektname).
- Referenzierte Sessions bekommen im nächsten Brain-Turn das volle Digest-Budget;
  ein referenziertes Projekt zieht seine aktiven Sessions mit kleinem Budget nach.
- Chips über dem Eingabefeld zeigen aktive Referenzen; entfernbar.
- Beispiel-Flow: „Vergleiche @whisperm8/pill-redesign mit @rankm8/audit und
  entwirf den Folgeprompt für ersteres."

Purer, testbarer Kern: `JarvisMentionResolver` (Text + Snapshot → aufgelöste
Session-IDs); die Picker-UI ist dünn darüber.

## Failure Modes

- Codex fehlt/nicht angemeldet:
  - Board, Tier-1-Reports und Actions-Historie funktionieren vollständig weiter (LLM-frei).
  - Chat zeigt Setup-/Runtime-Fehler mit Hinweis.
- Codex liefert kaputtes JSON (auch nach Fence-Stripping):
  - Raw-Output als failed Chat-Event speichern, keine Actions erzeugen.
- Transcript fehlt:
  - Digest `missingTranscript`; Tier-1-Report nutzt Metadaten.
- Session ohne `externalSessionID`:
  - Digest `missingExternalSessionID`.
- Background-Short-ID fehlt:
  - Digest `missingTranscript` oder `missingExternalSessionID` je nach Pfad.
- PTY nicht running:
  - Send-Button deaktiviert, Copy/Open anbieten.
- Workspace driftet zwischen Proposal und Apply:
  - Apply-Revalidierung schlägt an, Action `failed` mit kurzer Meldung.
- Brain-Turn läuft, während neuer Statuswechsel eintrifft:
  - Tier-1-Report entsteht sofort unabhängig; Brain-Queue arbeitet seriell weiter.
- Mehrere Fenster offen:
  - Alle rendern denselben globalen Jarvis-State; Toggle bleibt fensterlokal.

## Implementierungsreihenfolge: Vertical Slices

Jeder Slice endet mit etwas Sichtbarem und Benutzbarem. Slice 1 validiert die
riskanteste Annahme (Codex-headless-Qualität und -Latenz) so früh wie möglich.

### Slice 1: Board + Chat-Skelett (beweist das Konzept)

- Jarvis-Modelle (State, Snapshot, BrainResponse) + `JarvisStateStore` mit temp-URL-Tests.
- `JarvisWorkspaceSnapshotBuilder`.
- `JarvisAttentionModelBuilder` + `JarvisOverviewView` (Board, noch ohne Reports).
- `JarvisCodexClient` (stdin-Erweiterung von `AgentHeadlessCLI`) + Fence-toleranter
  Strict-JSON-Parser — Kontext: nur Snapshot, keine Digests.
- `JarvisInspectorView` mit Übersicht/Chat in `AgentChatsView` integriert.
- **Go/No-Go-Check:** Antwortqualität und Latenz mit realem Workspace bewerten.

### Slice 2: Digests, Tier-1-Reports, @-Mentions

- `JarvisTranscriptDigestBuilder` + In-Memory-Cache + Invalidierung (mtime/size).
- Routing Claude/Codex/Background/AgentView inkl. Availability-Fällen.
- `JarvisTier1ReportBuilder` + Runtime-Watcher-Subscription + Dedupe.
- Report-Feed in der Übersicht, isRead/Badge-Logik.
- `JarvisMentionResolver` + Picker + Budget-Steuerung im Prompt Builder.

### Slice 3: Actions

- `JarvisActionRegistry` (rename/group/archive) + Apply/Skip/Undo-Executor.
- Apply-Revalidierung + Drift-Erkennung.
- „Workspace aufräumen"-Turn + `JarvisActionQueueView`.
- Host-Callbacks für UI-nahe Actions.

### Slice 4: Prompt-Drafts, Send, Notifications

- Tier-2-Analyse-Button + „Folgeprompt entwerfen"-Flow auf Report-Karten.
- `AgentTerminalController.sendPrompt` mit Bracketed Paste.
- Draft-UI mit Copy/Open/Send.
- Tier-1-Notifications via `AgentSessionNotifier` + MenuBarExtra-Badge.

## Testplan

Unit Tests:

- `JarvisStateStore` load/save/prune (200/200/100/100).
- Snapshot enthält alle Workspace-Sessions und alle Fenster-Tabs, aber keine historischen Disk-Sessions.
- `JarvisAttentionModelBuilder`: Sortierung awaitingInput > errored > fertig-ungelesen > working > idle; Badge zählt nur Kategorie 1–3.
- Digest-Cache invalidiert bei mtime/size-Änderung; LRU-Bound greift.
- Background-Digest liest `SupervisorJobReader.linkScanPath`.
- AgentView-Digest liefert `unsupportedAgentView`.
- `JarvisTier1ReportBuilder`: Report pro Trigger, Dedupe pro Session + Transcript-Version, kein Report bei reiner Selektionsänderung.
- Strict-JSON-Parser: akzeptiert valides JSON, strippt Fences, verwirft kaputte/unknown Actions, vergibt IDs app-seitig.
- Prompt Builder: Budget-Kürzung in Attention-Reihenfolge; @-Mention hebt Session ins volle Budget.
- `JarvisMentionResolver`: Fuzzy-Match auf Titel/Projekt, mehrdeutige Treffer.
- Action-Executor: rename/group/archive validieren Zielsession, Drift → failed, Undo stellt `before` wieder her.
- Archive abgelehnt bei `working`/laufendem PTY; Send abgelehnt ohne laufenden Controller; Rename-Schutz bei manuellem Titel.
- Bracketed-Paste-Wrapping: mehrzeiliger Prompt erzeugt genau einen Paste-Block + optionales Return.

UI/Integration Tests:

- Jeder Fenster-Inspector rendert denselben globalen Jarvis-State.
- Simulierter Statuswechsel erzeugt sofort einen Tier-1-Eintrag im Feed (ohne Codex-Prozess).
- „Workspace aufräumen" erzeugt Action-Karten.
- Apply/Skip/Undo aktualisiert Action-Status.
- Prompt-Draft kann kopiert, geöffnet und an laufende PTY gesendet werden.
- Codex nicht installiert: Board + Feed voll funktionsfähig, Chat zeigt Fehler.

Manual Acceptance:

- 5+ parallele Sessions laufen lassen; Board sortiert live nach Attention.
- Eine Claude-Session stoppen: Tier-1-Report erscheint sofort; „Analysieren" liefert brauchbaren Tier-2-Report; währenddessen entsteht **kein** ungefragter Codex-Prozess.
- Report-Karte → „Folgeprompt entwerfen" → Send an laufende PTY: mehrzeiliger Prompt kommt als ein Block an und submitted genau einmal.
- „Workspace aufräumen" erzeugt sinnvolle Rename-/Group-Vorschläge; keine Workspace-Änderung ohne Apply; Undo stellt den alten Zustand her.
- Notification bei `awaitingInput`, während die App im Hintergrund ist; Klick öffnet Fenster + Session.
- Jarvis-Chat mit @-Mention beantwortet eine Cross-Projekt-Frage mit korrektem Kontext.

## Offene v2-Kandidaten

- Read-only-Tools als echter Tool-Loop — dann direkt als lokaler MCP-Server, damit auch externe Agents die Jarvis-Sicht nutzen können.
- Auto-Batch-Briefing (debounced Tier-2-Zusammenfassung ungelesener Reports).
- Auto-Send pro Session als Opt-in.
- Auto-Apply für reversible Actions (Rename/Group) als Opt-in — Undo-Pfad existiert ab v1.
- Agent-View-Subsession-Erkennung.
- Globale Disk-Inventur historischer Claude/Codex-Sessions.
- Jarvis als eigenes Fenster oder MenuBar-Command-Center.
- Browser-/Claude-Web-Tab-Integration via Accessibility oder Browser-Automation.
