# Claude Code CLI: Session-Persistenz & Resume — Verhalten, Diagnose, Fix

Stand: 2026-06-24 · Referenz-Dokument (Recherche + autoritative Doku + Fix)

Dieses Dokument hält fest, **wie Claude Code CLI Sessions persistiert und resumed**, **warum
WhisperM8-Chats „verschwanden"** (Symptom: „No conversation found" / „noch keine Konversation",
Fork unmöglich) und **welcher Fix** implementiert wurde.

## ⚠️ DIE WURZEL (verifiziert 2026-06-24) — `CLAUDE_CODE_*`-Env-Leakage

Nach langer Suche durch Inspektion der **echten Prozess-Umgebung** (`ps eww <pid>`) gefunden:
WhisperM8 wird oft aus einem **Claude-Code-Kontext** gestartet (`make dev`/`open` aus einer
laufenden Claude-Session, oder ein Terminal mit aktivem `claude`). Dabei **erbt** es die
Variablen, die Claude Code in sein Prozess-Environment schreibt — u. a.:

```
CLAUDE_CODE_CHILD_SESSION=1
CLAUDE_CODE_SESSION_ID=<parent-session>
CLAUDE_CODE_ENTRYPOINT=claude-desktop
```

`LoginShellEnvironment.processEnvironment` nutzte `ProcessInfo.processInfo.environment` als Basis
und reichte **alles** an gespawnte `claude`-Prozesse weiter. Claude sah `CLAUDE_CODE_CHILD_SESSION=1`
+ eine fremde `SESSION_ID` und behandelte sich als **verschachtelte Child-Session** → schrieb
**bewusst kein eigenes Transkript** nach `~/.claude/projects/<cwd>/<id>.jsonl`. Ergebnis: voller
Turn (SessionStart→UserPromptSubmit→Stop), aber **keine `.jsonl`** → später „No conversation
found" / „kein Name" / nicht forkbar — **egal welche Session-ID**. Das erklärt restlos, warum auch
**lange** Chats von Anfang an nichts persistierten.

**Fix (`LoginShellEnvironment.processEnvironment`):** alle geerbten `CLAUDE_CODE_*`- (und
`CLAUDECODE`-) Variablen entfernen, bevor das ENV an einen Agenten geht. Jeder gespawnte `claude`
ist damit eine **saubere Top-Level-Session**. Alle Spawn-Pfade (PTY-Terminal, BackgroundAgent,
AutoNamer, PostProcessing) laufen über diese Funktion → ein zentraler Fix.

**Live verifiziert:** nach dem Fix haben neu gespawnte `claude`-Prozesse 0 `CLAUDE_CODE_*`-Treffer;
ein „hallo"-Testchat in marketing-rankm8 schrieb sofort ein frisches `<id>.jsonl` (mit „hallo"),
bekam einen Auto-Namen und ist resumebar.

> Einordnung: Das Vorab-`--session-id` (→ Weg B) und die fehlende Transkript-Prüfung vor `--resume`
> (→ §6-Garantie) waren **verschärfende Faktoren / fehlende Netze**, aber **nicht** die Wurzel.
> Die Wurzel ist diese Env-Leakage. Alle drei Fixes zusammen machen das Resume robust.

## Quellen
- Offizielle Claude-Code-Doku: [CLI-Reference](https://code.claude.com/docs/en/cli-reference),
  [Sessions](https://code.claude.com/docs/en/sessions)
- Vergleichs-Wrapper (funktioniert mit langen Sessions): [Superset](https://github.com/superset-sh/superset)
- Empirische Forensik am lokalen `~/.claude/projects/` + `log`-Telemetrie (siehe unten)

## 1. Ist Claude Code open-source? Nein.
Claude Code wird als **minifiziertes npm-Paket** (`@anthropic-ai/claude-code`) ausgeliefert — kein
lesbarer Quellcode. Man kann den minifizierten JS-Blob inspizieren, aber autoritativ ist die Doku.
Konsequenz: Wir dürfen uns **nicht** auf Implementierungs-Annahmen verlassen, sondern auf
dokumentiertes Verhalten + Beobachtung der real geschriebenen Dateien.

## 2. Wo & wann persistiert Claude eine Session
- **Pfad:** `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` (append-only Transkript).
  `<encoded-cwd>` = absoluter cwd, jedes Nicht-Alphanumerische → `-` (führender `/` → führendes `-`).
- **Zeitpunkt:** Das Transkript wird **beim ersten echten Turn** angelegt und **kontinuierlich**
  fortgeschrieben — **nicht** beim bloßen interaktiven Start. Eine gestartete, aber nie benutzte
  Session schreibt **keine** JSONL → ist **nicht** resumebar.
- **Begleit-Verzeichnis:** Zusätzlich legt Claude bei subagent-/workflow-lastigen Sessions ein
  **`<session-id>/`-Verzeichnis** an (`subagents/`, `workflows/`, `journal.jsonl`, …). **Wichtig:**
  Dieses Verzeichnis ist **nicht** das resumebare Transkript — `claude --resume` braucht die
  `<id>.jsonl`-DATEI.
- **Resume-Scope:** `claude --resume <id>` sucht **nur im aktuellen cwd + dessen Git-Worktrees**
  (laut Doku). Falscher cwd → „No conversation found".
- **Cleanup:** `cleanupPeriodDays` (Default **30 Tage**) löscht alte Transkripte. Bei uns nicht
  gesetzt → nicht ursächlich für frische Verluste.

## 3. Relevante Flags (Doku-Auszug)
| Flag | Bedeutung | Relevanz |
|---|---|---|
| `--session-id <uuid>` | Nutzt eine **vorgegebene** UUID für die Session (muss valide UUID sein) | WhisperM8s bisheriger Ansatz |
| `--resume`, `-r <id>` | Resumed per ID/Name; ID-Lookup **nur im aktuellen Projekt + Worktrees** | schlägt fehl ohne Transkript |
| `--continue`, `-c` | Lädt die **neueste** Konversation im cwd (ID-frei) | robuste Alternative |
| `--fork-session` | Bei Resume eine **neue** ID statt der originalen | Fork braucht gültige Quelle |
| `--no-session-persistence` | Keine Persistenz — **nur Print-Mode** (`-p`) | bei uns NICHT genutzt |
| `--bg` | Startet als Background-Agent, gibt Session-ID aus | Background-Pfad |

## 4. Die Wurzel: WhisperM8 vertraut einer vorgegebenen ID — Superset bindet an die reale Datei

| | Superset (funktioniert) | WhisperM8 (failte) |
|---|---|---|
| Session-ID | lässt **Claude** die ID vergeben, **liest** sie aus der `.jsonl` auf Platte | **generiert UUID vorab**, erzwingt sie via `--session-id` |
| Bindung | bindet an das **real existierende** Transkript | committet **optimistisch** auf die Vorab-ID |
| Resume | `claude --resume <reale-id>` | `claude --resume <vorab-id>` — evtl. **nie geschrieben** |

WhisperM8 markierte einen Chat als „resumebar" (`hasLaunchedInitialPrompt=true`) **sofort beim
PTY-Start** und committete auf die Vorab-`externalSessionID`, **ohne** zu prüfen, ob Claude je ein
Transkript dort schrieb. Brach die Bindung an Claudes reale ID (per SessionStart-Hook) ab oder
schrieb Claude unter einer anderen ID/gar nicht, blieb ein **toter Zeiger**.

## 5. Empirische Belege (marketing-rankm8 / headless-woo)
- **Korrelation (lückenlos):** Jeder Chat **mit** Auto-Namen hatte ein Transkript und war
  resumebar; jeder generische „Claude Chat" hatte **kein** Transkript und failte. Beides folgt aus
  derselben Wurzel: *gibt es ein reales Transkript?*
- **`f218f1bd` (langer Chat, headless-woo):** komplettes Begleit-Verzeichnis
  (`subagents/`, `workflows/wf_…`, `journal.jsonl` — der Chat lief lange!), aber **keine
  `f218f1bd.jsonl`** und in keinem Zeitfenster ein Haupt-Transkript. → Persistenz beim Start
  umgelenkt/ausgeblieben, **nicht** „kein Turn".
- **`318fb6d4`:** **0** SessionStart-Hook-Events in 12 h → nie an Claudes reale ID gebunden.
- **Ausgeschlossen:** `cleanupPeriodDays` (Default 30 d), MCP-Hang (`listm8` antwortet in 0,28 s),
  Symlinks, persistenz-feindliche Flags (nur `--dangerously-skip-permissions` gesetzt), Pruning
  (manuelle Chats sind durch `createdManually` + `externalSessionID` doppelt geschützt).

## 6. Der Fix (implementiert)
**Prinzip (Superset-konform): Nie `--resume <id>` ohne real existierendes Transkript.**

- **`ClaudeTranscriptReader.transcriptExists(forCwd:sessionID:)`** — prüft die `<id>.jsonl`-**Datei**
  (ein gleichnamiges `<id>/`-Verzeichnis zählt bewusst **nicht**).
- **`AgentSessionDetailView.repairedSessionForLaunch()`** — Final-Garantie nach dem Repair:
  Wenn die Session resumen würde (`hasLaunchedInitialPrompt` + `externalSessionID`), das Transkript
  aber **nicht real existiert** (auch wenn der Indexer es per **Cache** noch meldet → Outcome
  `.unchanged`), wird stattdessen eine **frische** Session im selben Tab gestartet
  (`externalSessionID=nil`, `hasLaunchedInitialPrompt=false`). Claude vergibt eine neue ID, die
  `bindExternalSessionIDWhenAvailable()` danach an das **real geschriebene** Transkript bindet.
- **Telemetrie** (`category == "claude.binding"`): `resume_rebound`, `resume_reset_invalid`,
  `resume_guard_fresh_start` (`.notice`) machen jede Entscheidung sichtbar.

Damit kann „No conversation found" beim Öffnen eines Chats nicht mehr auftreten — im schlimmsten
Fall startet der Tab frisch (statt in eine Sackgasse zu laufen).

**Wichtig / ehrlich:** Bereits verlorene Chats hatten **nie** ein persistiertes Transkript — es
gibt dort **nichts wiederherzustellen**. Der Fix verhindert es ab sofort.

## 7. Diagnose-Befehle
```bash
# Welche Resume-Entscheidung trifft WhisperM8?
/usr/bin/log show --last 1h --predicate 'subsystem == "com.whisperm8.app" AND category == "claude.binding"' --info | grep resume_

# Hat eine Session ein reales Transkript?
ls -la ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl

# Persistenz der Chat-Liste selbst (Datenverlust-Telemetrie)
/usr/bin/log show --last 1h --predicate 'subsystem == "com.whisperm8.app" AND category == "agent.store"'
```

## 8. Superset-Tiefenanalyse (code-verifiziert, Clone @ 28245a0, 2026-06-24)

Vollständige Code-Analyse des Superset-Monorepos (TypeScript/Electron). **Kernbefund: Superset
verwendet `--resume`, `--session-id`, `--continue`, `--fork-session` NIRGENDS — 0 Treffer.**

**Wie Superset Claude startet** (`packages/shared/src/builtin-terminal-agents.ts`):
`command: "claude --dangerously-skip-permissions"` — ohne ID, als `initialCommand` in eine
**Login-Shell** (PTY spawnt die Shell, nicht `claude` direkt). Prompt per Heredoc, voll
interaktive TUI (kein `-p`/`stream-json`).

**Persistenz = Prozess-Überleben, nicht Resume:** Die ganze Wiederaufnahme steckt im
**detached PTY-Daemon** (`packages/pty-daemon/`, `DaemonSupervisor.ts`). Der Daemon wird
detached + `unref()`'d gespawnt und überlebt App-/host-service-Neustarts. Beim Start wird der
**lebende Prozess adoptiert** (`terminal.ts` adopt-or-respawn: `adoptOnly:true` → bei Erfolg
lebende Shell + Ringpuffer behalten; sonst frische Shell respawnen — **nie** `claude --resume`).
64-KB-Ringpuffer-Replay zeichnet den Screen neu.

**Persistiert wird** (SQLite, `schema.ts`): nur `terminalId` (Supersets eigene UUID) +
`workspaceId` + `status`. **Weder Agent-Typ noch Kommando noch Claudes Session-ID.** Durable
Handle = `terminalId` + lebender OS-Prozess. Claudes echte ID wird nur **ephemer** aus dem
Hook-Payload (`session_id`) gelesen (für Status/Notify), nie auf Platte geschrieben.

**Hooks:** Merge in `~/.claude/settings.json` (nicht `--settings`), nur für
Completion-Sounds/Status (SessionStart/Stop/PostToolUse/…). Identität über Env
`SUPERSET_TERMINAL_ID`, nicht über Claudes ID.

**cwd:** roher git-Worktree-Pfad, keine Symlink-Auflösung.

### Konsequenz / die eigentliche Wurzel
WhisperM8 stirbt der PTY-Prozess beim App-Quit (SwiftTerm im App-Prozess) → Wiederaufnahme NUR
über `claude --resume <id>` möglich → hängt zwingend daran, dass Claude unter der **erzwungenen**
ID ein Transkript schreibt → fragil. **Superset hat diese Fehlerklasse gar nicht**, weil es den
Prozess am Leben hält und nie resumed.

## 9. Zwei Wege nach vorn

**Weg A — Prozess-Persistenz (Superset-Modell, große Änderung):** langlebiger Helper/Daemon, der
die PTYs (claude/codex) detached über App-Neustarts hält; Wiederaufnahme = reattach an den
lebenden Prozess + Ringpuffer-Replay. `claude --resume` wird überflüssig. Beseitigt die ganze
Fehlerklasse, ist aber ein Architektur-Umbau (Daemon, Adoption, IPC) und ändert nichts an
Force-Quit-Datenverlust *innerhalb* einer Session.

**Weg B — Korrektes Resume (gezielt, kleiner):** Claude die ID **selbst vergeben** lassen (kein
Vorab-`--session-id`), die **hook-bestätigte** reale `session_id` als maßgeblich binden, und einen
Chat erst als „resumebar" markieren, **wenn `<id>.jsonl` real existiert** (nicht beim PTY-Start).
`--resume` nur mit dieser verifizierten ID; sonst frischer Start (bereits via Garantie aus §6
abgesichert). Bleibt im aktuellen SwiftTerm-Modell.

**Empfehlung:** Weg B als nächster Schritt (behebt die Resume-Wurzel ohne Architektur-Umbau);
Weg A als optionale spätere „Killer-Feature"-Investition (Sessions überleben App-Neustart wie bei
Superset).

### Konkrete B-Schritte
1. ✅ **Vorab-`--session-id` entfernt** — `createSession` setzt `externalSessionID=nil`,
   `claude` startet ohne ID (`AgentChatsView.createSession`).
2. ✅ **`--session-id`-Zweig + Throw entfernt** (`AgentCommandBuilder.claudeCommand`): Resume nur
   noch mit real gebundener ID, sonst frischer Start. Die reale ID bindet der SessionStart-Hook
   (`handleClaudeHookEvent`) bzw. der Indexer-Merge nach.
3. ✅ **§6-Garantie bleibt das Netz:** nie `--resume` ohne real existierendes `<id>.jsonl`.
4. ⬜ `--continue`-Fallback im richtigen cwd erwägen (optional).
5. ⬜ Tote „Claude Chat ohne Transkript"-Einträge automatisch aufräumen/markieren (optional).
6. ⬜ Offen für später: `hasLaunchedInitialPrompt` erst setzen, wenn ein Transkript existiert
   (würde „resumebar"-False-Positives an der Wurzel beseitigen; bewusst klein gehalten, da das
   Flag an mehreren Stellen load-bearing ist).

### Weg A (Prozess-Daemon) — bewusst auf später verschoben
Vom User priorisiert: erst B (umgesetzt), A als separate spätere Investition.
