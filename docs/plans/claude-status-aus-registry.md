# Plan: Claude-Status aus Claudes eigener Registry + Chat-Brücke über Konten

**Stand:** 2026-10-17 · **Status:** S1–S4 umgesetzt (QA nach `make dev` offen), S5 offen · **Scope:** Agent-Chats-Status (Claude-Chats), Hook-Bridge, `whisperm8 chats`, Chats-Skill
**Herkunft:** Beratung im Chat „Noa · Chat-Brücke: Konten übergreifend“ (17.10.2026), Belege aus Claude Code 2.1.302 (Binary-Analyse) und Live-Tests.
**Parallel läuft:** Chat „Mia · Jarvis-Randnotizen“ ([`jarvis-randnotizen.md`](jarvis-randnotizen.md)) — fasst Jarvis-Board, Kachelkopf, Mod `register.tsx`, Jarvis-Skill an. Siehe „Kollisionen“.

## Ziel

1. **Chats reden nativ miteinander, auch über Claude-Konten hinweg** (`SendMessage` an eine `uds:`-Adresse), WhisperM8 liefert das fehlende Adressbuch.
2. **Der Status eines Claude-Chats kommt aus Claude selbst**, nicht mehr aus Hooks + Transcript-Heuristik. Keine falschen „arbeitet“-Anzeigen mehr, an denen `chats send`/`enqueue` hängen bleiben.

## Entscheidungen (User, 17.10.2026)

| Nr | Entscheidung |
|---|---|
| E1 | Reihenfolge: **zuerst die Brücke**, dann Status-Umbau. |
| E2 | **Claudes eigener Status ist die Quelle** für Claude-Chats; die Status-Hooks fliegen raus. |
| E3 | **Keine Mod-Ereignisse fürs „Warum“** (API-Fehler, Abbruchgrund). Ein Fehler endet in `idle`, das reicht. |
| E4 | Messen ja, aber kein mehrtägiger Schattenbetrieb als Bedingung; Abweichungen werden während der Umstellung geloggt. |
| E5 | Kein `make dev` durch den umsetzenden Chat; App-Neustart und Live-QA macht der User. |

Offen, mit Empfehlung: „frei, Hintergrund-Shell läuft“ (`shell`) in der UI als normales „frei“ — **Empfehlung: ja, ohne Extra-Hinweis**.

## Belegte Fakten (Claude Code 2.1.302)

**Registry.** Jede laufende Session schreibt `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json` (Default-Profil: `~/.claude/sessions/`), Datei 0644, Ordner 0700. Felder u. a.: `pid`, `sessionId`, `cwd`, `kind` (`interactive`/`bg`), `name`, `nameSource`, `status`, `waitingFor`, `statusUpdatedAt` (ms), `messagingSocketPath`, `peerFeatures`, `version`. Beim Prozessende wird die Datei gelöscht (Exit-Handler; bei SIGKILL kann sie liegen bleiben → PID-Lebendigkeit prüfen, `procStart` vergleichen).

**Status-Regel** (Funktion im Binary, aus dem UI-Zustand der TUI berechnet, nur bei Änderung geschrieben):
- `waiting` + `waitingFor`: `input needed` (Elicitation/Permission-Dialog), `dialog open` (andere Dialoge), `worker request`, `sandbox request`.
- `busy`: Modell lädt/streamt **oder** delegierte Arbeit läuft (Subagents, Hintergrund-Tasks).
- `idle`; `shell` = idle, aber eine Hintergrund-Shell läuft.
- ESC-Abbruch und API-Fehler enden in `idle` (kein Hook nötig).
- Offizielle Lesart von außen: `claude agents --json` (gleiche Werte, pro `CLAUDE_CONFIG_DIR`). Das Dateiformat selbst ist nicht dokumentiert.

**Messaging.**
- Sockets aller Konten liegen gemeinsam in `/tmp/cc-socks/<pid>.sock` (0600, Ordner 0700).
- `ListAgents` liest nur die Registry des eigenen Profils → Konten sehen sich nicht.
- `SendMessage({to: "uds:/tmp/cc-socks/<pid>.sock"})` wird akzeptiert und zugestellt; auf macOS verlangt der Empfänger kein Token (`authRequired` nur unter Windows). **Live getestet 17.10.:** PowerUser → ai2 zugestellt, Antwort ai2 → PowerUser kam an, `notify_when_idle` kam ebenfalls an (verzögert, weil der Empfänger selbst im Turn war).
- Peer-Nachrichten stehen im Ziel-Transcript als `user`-Zeile mit `origin.kind == "peer"`, `from`, `verifiedPeerPid` (vom Kernel bestätigt), `fromMode`.
- Rechte-Modus-Parität: Bypass-Sessions und alle anderen sind zwei Klassen; über die Klassengrenze wird eine Nachricht im Ziel-Terminal zur Freigabe gehalten (Verfall nach 5 min). Steuerung im Ziel: Setting `crossSessionInbound` (`accept`/`hold`/`refuse`).
- Namen: ohne Vorgabe `<ordner>-<2 hex>`; offiziell setzbar per `claude -n <name>`.

**Risiko bei Updates:** Erzwingt Anthropic das Socket-Token auch auf macOS, bricht das Senden über Konten (der Absender sucht den Schlüssel nur im eigenen Profil). Ändert sich das Registry-Format, fällt der Leser auf `claude agents --json` zurück bzw. der Kill-Switch auf den Hook-Pfad. `chats send`/`enqueue` bleiben deshalb vollwertig.

**Live-Messung 17.10.2026** (Test-Chat Konto ai2, Registry-Datei alle 0,5 s gelesen, Claude 2.1.302):

| Fall | Registry-Verlauf |
|---|---|
| Prompt mit langem Vordergrund-Befehl (`python3 … sleep(45)`) | `idle` → `busy` (1 s nach dem Senden) |
| ESC (`chats interrupt`) mitten im Befehl | `busy` → `shell` → `idle` in derselben Sekunde |
| `AskUserQuestion` | `busy` → `waiting` / `waitingFor: "input needed"` |
| `ExitPlanMode` (Plan-Freigabe) | `busy` → `waiting` / `waitingFor: "permission prompt"` |
| ESC auf offenem Dialog | `waiting` → `idle` |
| Bash mit `run_in_background` | `busy` → `shell` (Turn fertig, Shell läuft) |
| Hintergrund-Shell endet | `shell` → `busy` (Claude startet selbst einen Turn mit der Meldung) → `idle` |

`procStart` steht in **UTC** (`13:05:05` bei lokal `16:05:05` EEST). Ein echter Permission-Dialog ließ sich in
Bypass-Chats nicht auslösen; laut Binary-Tabelle meldet er wie die Plan-Freigabe `waiting` (QA-Punkt 5).
`waitingFor` unterscheidet Frage und Freigabe also grob, Plan-Freigabe und Tool-Freigabe aber nicht.

**Entscheidung S3.3 (Warte-Art):** Die Warte-Art kommt aus Registry + dem ohnehin gelesenen Transcript-Tail
(`AgentSessionActivity.detail`, gleicher Extractor wie die Stand-Zeile): offene Frage im Tail → `question`;
letzter Tool-Aufruf `ExitPlanMode` → `planApproval`; sonst `waitingFor == "input needed"` → `question`, alles
andere → `permission` (Tool-Name für „Freigabe: Bash …“ aus dem Tail). Kommt der Tail nach dem Registry-Wechsel,
wird die Art nachgezogen.

**Entscheidung ESC:** Registry kann „Turn fertig“ und „abgebrochen“ nicht unterscheiden (beides `idle`). Damit ein
ESC wie bisher keine Fertig-Meldung und keine Queue-Zustellung auslöst, merkt sich der Coordinator einen
beobachteten Abbruch (ESC im Terminal, `chats interrupt`) 10 s lang; ein `idle` in diesem Fenster gilt als Abbruch.
Das ist keine Status-Heuristik mehr, nur die Einordnung eines von Claude gemeldeten Wechsels.

## Ausgangslage im Code

- `ClaudeHookSettingsBuilder.trackedEventNames`: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `Stop` → je ein `(cat ; echo) >> eventfile`-Shell-Aufruf. Pre/PostToolUse feuern bei **jedem** Werkzeug-Aufruf (zwei Prozess-Starts pro Tool).
- Zusätzlicher `UserPromptSubmit`-Eintrag: Send-Guard (`whisperm8 chats _prompt-guard`) — **bleibt**.
- `ClaudeHookBridge` → `AgentSessionStatusCoordinator.handleHookEvent` → `AgentSessionSignal` → `AgentSessionStateMachine.reduce` → `AgentSessionRuntimeStatusStore` + Effekte (`turnCompleted`: Ton, Notification, `AgentPromptQueueDelivery.deliverNext`; `inputRequested`: Notification). Statuswechsel landen im `ChatsStatusJournal` (Quelle für `chats since/watch`, Board-Wecken).
- `hookLiveSessions` sperrt Transcript-Meinungen; Heilungen: Abort-Verdacht (`suspectTurnAborted`/`verifyAbortSuspicion`, 5 s, ESC-Beobachtung im Terminal) und stilles Netz (`shouldHealSilentHookWorking`, 180 s).
- `AwaitingInputKind` (`permission`/`question`/`planApproval`) kommt heute aus `PreToolUse` (`AskUserQuestion`, `ExitPlanMode`) bzw. `PermissionRequest` (+ Tool-Name für „Freigabe: Bash …“).
- SessionStart bindet die externe Session-ID (`externalIDBindingDecision`, Fork-/bg-Sonderfälle, Vorfall 30.09.).
- CLI ohne App: `ChatsStatusProbe` schätzt Status aus Transcripts.

## Umsetzung

### S1 — Registry-Leser + Chat-Brücke

1. **`ClaudeSessionRegistry`** (Services/AgentChats/, pur + getestet): liest alle Registry-Ordner (Default `~/.claude/sessions` + jedes Profil aus `ClaudeAccountProfiles`), parst tolerant (unbekannte Felder ignorieren, fehlende = nil), prüft PID-Lebendigkeit (`kill(pid,0)`, optional `procStart`), liefert `[ClaudeSessionRecord]` mit Profil. Mapping-Funktion `runtimeStatus(for:)`: `busy`→working, `waiting`→awaitingInput, `idle`/`shell`→idle, unbekannter Wert → nil (= keine Meinung).
2. **`whisperm8 chats address <ref|name> [--json]`** (Lese-Befehl, app-unabhängig): sucht zum Chat (über `externalSessionID` = `sessionId`) den Record und gibt `uds:<messagingSocketPath>`, nativen Namen, Profil, Status aus. Läuft der Chat nicht oder ist er kein Claude-Chat → Exit ≠ 0 mit Klartext („nicht erreichbar, nimm `chats send`“). Hilfe-Text + `docs/features/agent-chats-cli.md` ergänzen.
3. **Chats-Skill** (`WhisperM8/Resources/whisperm8-chats-skill.md`, Abschnitt „Zwei Wege“) korrigieren: Finden pro Konto, Zustellung über alle Konten per `chats address` → `SendMessage({to: "uds:…"})`; Antwort per `from`; `notify_when_idle` geht auch über Konten. Weiter `chats send/enqueue` für Codex, geschlossene Chats, Arbeitsaufträge, Warten bis Turn-Ende. Hinweis auf Rechte-Modus-Parität. Danach `make skills` **nicht** nötig für Tests; Sync macht die App beim Start.

### S2 — App liest Claudes Status mit

1. **`ClaudeRegistryStatusSource`** (MainActor-Fassade, Logik pur): beobachtet die Registry-Ordner per `FileEventSource`/FSEvents (Muster `AgentDirectoryEventMonitor`), entprellt (~100 ms), liest nur geänderte Dateien (≈0,5 KB). Kein I/O im Body/Render-Pfad, nichts unter dem Store-Lock. Fallback-Timer nur, wenn Events fehlen (z. B. 5 s, stat-first).
2. Zuordnung Record → lokale Session: primär `sessionId == externalSessionID`; vor der Bindung über die PID des PTY-Prozesses (bzw. seines `claude`-Nachfahren). bg-Agents (`kind: bg`) zunächst **nicht** umstellen (eigener Pfad über Supervisor), nur loggen.
3. Abweichungen gegenüber dem bisherigen Status loggen (`Logger`, `.info`, `registry_status_diff sessionID=… registry=… current=… ageMs=…`), damit QA nach `make dev` Zahlen hat.
4. Kill-Switch: `defaults write com.whisperm8.app claudeRegistryStatusEnabled -bool NO` (Default an).

### S3 — Umschalten

1. Neues Signal im Reducer, z. B. `.registryStatus(ClaudeRegistryStatus)`; Übergänge: → `working`; → `awaitingInput(kind)`; working/awaiting → idle erzeugt **dieselben Effekte wie heute `turnStopped`** (`turnCompleted`: Ton, Notification, Queue-Zustellung). Erst-Sicht eines Records ohne vorherigen Turn erzeugt **kein** `turnCompleted`.
2. `registryLiveSessions` (analog `hookLiveSessions`): Für sie zählen Hook-Status-Signale und Transcript-Meinungen nicht mehr; Heilungen (5-s-Abort-Verdacht, 180-s-Netz) sind für sie aus. Journal-`source: "registry"`.
3. `AwaitingInputKind`: aus `waitingFor` allein nicht unterscheidbar → **live verifizieren**, was Registry bei `AskUserQuestion` und `ExitPlanMode` zeigt; Feinunterscheidung (question/planApproval) aus dem ohnehin gelesenen Transcript-Tail (letzter offener `tool_use`-Name, `AgentTranscriptActivityExtractor`) statt aus PreToolUse. Ohne Beleg: `permission` als Default-Text „wartet auf dich“.
4. `ChatsStatusProbe` (CLI ohne App) nutzt zuerst die Registry, Transcript nur als Fallback.
5. Prozess endet ohne Registry-Update → bestehender `processTerminated`-Pfad bleibt maßgeblich.

### S4 — Hooks reduzieren (nur neue Launches, hinter dem Kill-Switch)

- Bei aktivem Kill-Switch-Default schreibt `ClaudeHookSettingsBuilder` nur noch `SessionStart`, `SessionEnd` (ID-Bindung, Lebenszyklus) und den Send-Guard (`UserPromptSubmit`). Entfallen: generisches `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `Stop`.
- Kill-Switch aus → alter vollständiger Hook-Satz und alter Status-Pfad (für neu gestartete Chats).
- Laufende Chats behalten ihre alte Settings-Datei bis zum Neustart; ihre Hook-Events schaden nicht, weil Registry-live Vorrang hat.
- Prompt-Guard-Block: Composer-Clear bleibt; das `turnAborted` darf bleiben (harmlos), Status korrigiert Claude selbst.

### S5 — Altcode löschen (später, nach QA des Users)

Heuristiken (Abort-Verdacht, ESC-Beobachtung, stilles Netz), `hookLiveSessions`-Statuszweig und die alten Hook-Signale entfernen, sobald der User nach `make dev` einige Tage ohne Auffälligkeiten bestätigt. Optional danach: ID-Bindung über Registry (`sessionId` je PID), nur mit Lösung für den Fork-/bg-Fall vom 30.09.

**Codex-Chats bleiben unverändert** (Transcript-Pfad).

## Tests

- Unit (pur): Registry-Parser (alle Felder, fehlende/unbekannte, kaputtes JSON, tote PID), Mapping, Zuordnung, Reducer-Übergänge inkl. „Erst-Sicht ohne turnCompleted“, Gating gegenüber Hooks/Transcript, Hook-Settings mit/ohne Kill-Switch, `chats address`-Ausgabe/Exit-Codes, `ChatsStatusProbe`-Vorrang.
- Live (ohne `make dev`, nur eigene Test-Chats via `whisperm8 chats new --account …`, danach `chats close <ref> --stop`):
  - neu gebaute CLI (`<build>/release/WhisperM8 chats address <ref>`) gegen Test-Chats in zwei Konten; `SendMessage` Hin- und Rückweg über die Kontogrenze; `notify_when_idle`.
  - Registry-Werte beobachten bei: langer `sleep` per Bash (busy), danach idle, `chats interrupt` (ESC → idle), `AskUserQuestion`, Plan-Modus/`ExitPlanMode` falls auslösbar, Hintergrund-Shell (`shell`).
- Perf: Leser-Kosten pro Event messen (Budget: < 1 ms pro Datei), keine Arbeit im SwiftUI-Body.

## QA durch den User nach `make dev`

1. Neue Chats in zwei Konten starten; Sidebar-Status bei Arbeit/Frage/Abbruch (ESC)/fertig prüfen.
2. `log stream --predicate 'subsystem == "com.whisperm8.app"' | grep registry_status` — Abweichungen sichten.
3. `enqueue` an einen arbeitenden Chat: wird nach Turn-Ende zugestellt.
4. Jarvis fragt einen Chat in anderem Konto per `chats address` + `SendMessage`.
5. Permission-Dialog (Chat ohne Bypass) zeigt „wartet auf dich“.

## Kollisionen mit parallelen Chats

- **Mia (Jarvis-Randnotizen)** arbeitet an `JarvisBoard*`, `AgentControlRequestHandler+Board.swift`, `ChatsBoardCommand.swift`, Grid-Kachelkopf, `Resources/claude-plugin/hooks/register.tsx`, Jarvis-Skill, `docs/design/…`, `docs/plans/jarvis-randnotizen.md`, `docs/plans/README.md`. Diese Dateien **nicht anfassen**; nie fremde Änderungen stagen.
- Gemeinsam berührte Dateien (z. B. `CLAUDE.md`, `AgentCLICommand.swift`-Hilfe, Chats-Skill, `docs/plans/README.md`): vor jedem Edit `git diff <datei>` prüfen; nur eigene Hunks committen (`git diff` → eigenen Patch → `git apply --cached`), sonst Datei uncommittet lassen und melden.
- Eigener Build-Ordner (`swift build/test --scratch-path "$TMPDIR/wm8-statusreg-build"`), damit kein `.build`-Lock anderer Chats blockiert.

## Offen für das Review (Übergabe 17.10.2026)

- **Volle Suite nicht gelaufen** (auf Wunsch des Users nur gezielt): grün waren `AgentSessionStatusCoordinatorTests`,
  `AgentSessionStateMachineTests`, `ClaudeHookBridgeTests`, `ChatsWaitEngineTests`, `CodexStatusProbeTests`, CLI-Tests,
  `ClaudeSessionRegistryTests`, `ClaudeRegistryStatusTests`. Vor dem Release einmal `swift test` komplett.
- **Release-Build nicht gebaut**; der Live-Test von `chats address` lief mit dem Debug-Binary.
- **Scan-Budget:** im Debug-Build 1,6 ms pro Registry-Datei ohne, < 1 ms mit `procStart`-Cache (Test grün).
- **Prüfen im Review:** Wettlauf Voll-Scan ↔ FSEvents (`eventTouchedAt`), Abbruch-Merker (10 s) bei ESC im Leerlauf,
  Wiederbelebung `stopped` → Registry-Eintrag (5-s-Sperre nach Prozessende), `registrySessionID` lädt den Workspace je Event.
- **Live erst nach `make dev`:** QA-Liste oben; dazu im Log `registry_live`, `registry_status_diff`, `claude_registry_scan_slow`.

## Messung

Lese-Skript (17.10., 16:34–18:34, alle 15 s, 381 Messungen): WhisperM8-Laufzeitstatus gegen Registry-Status aller
laufenden Claude-Chats, Abweichungen ≥ 20 s. **22 Abweichungen**, davon 18 × „WhisperM8 idle, Claude busy“
(20–263 s; typisch lange Befehle/Builds ohne Hook-Event, die das 180-s-Netz fälschlich beendet), 2 × „WhisperM8 working,
Claude wartet auf Eingabe/Dialog“ (44–61 s), 1 × „WhisperM8 working, Claude idle“ (33 s), 1 × Testchat-Anlauf.
Zwei Messungen fielen aus (`chats list` > 30 s, CLI-Lauf hing — gesondert anzusehen).

## Umsetzung (17.10.2026) — Abweichungen vom Plan

- Zuordnung nur über `sessionId` (keine PID-Zuordnung vor der Bindung): Die ID-Bindung per `SessionStart` bleibt, und
  `externalSessionIDBound`/`setExternalSessionID` übernehmen den schon bekannten Eintrag sofort.
- ESC-Beobachtung bleibt als **Abbruch-Merker** (siehe „Entscheidung ESC“), nicht mehr als Status-Heilung.
- Mit reduziertem Hook-Satz macht ein `SessionStart` die Session nicht hook-live — fehlt die Registry (alte Claude-Version),
  trägt der Transcript-Pfad den Status wie bei Codex.
- Neue Kill-Switch-Stelle: `AppPreferences.isClaudeRegistryStatusEnabled`, wirkt nach Neustart.
