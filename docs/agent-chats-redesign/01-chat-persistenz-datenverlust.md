# Plan: Chat-Datenverlust endgültig beheben (KRITISCH)

Stand: 2026-06-24 · Priorität: **höchste**

## Umsetzungsstand
- ✅ **Phase 0 (Telemetrie):** Logger-Kategorie `agent.store`; Events `agent_store_loaded`,
  `agent_store_flushed reason=…`, `session_created`, `agent_store_pruned` (`.notice`, Debounce-
  Flushes `.info`). Live verifiziert (`/usr/bin/log show --predicate 'category == "agent.store"'`).
- ✅ **Phase 1 (Sofort-Persistenz):** `AgentSessionStore.createSession` ruft nach `upsertSession`
  `workspaceStore.flush(reason:"create")` → kein 0,5-s-Verlustfenster mehr bei Erstellung.
- ✅ **Phase 2 (Flush-Netze):** zusätzlich zu `willTerminate` jetzt `didResignActive`-Flush
  (`AgentWorkspaceStore`) gegen Force-Quit/Crash. 424 Tests grün; `testFlushWritesImmediately`
  deckt den Mechanismus.
- ⬜ **Phase 3 (Backup-Netz):** offen.
- ⬜ **Phase 4 (Resume-Symptom):** offen.
- Verifikation: nach Neustart `agent_store_loaded sessions=638`, kein `agent_store_pruned`,
  User-Chat („Jira-Chat fortsetzen…") erhalten.

---

(ursprünglicher Plan unten)

## Symptome (vom User berichtet)

1. **Chats verschwinden:** Ein neu gestarteter Agent-Chat ist nach dem Schließen der App
   beim nächsten Start **weg** — passiert *manchmal*, nicht immer.
2. **Nicht resumebar in der CLI:** Manchmal ist ein von WhisperM8 gestarteter Claude-Chat
   **nicht** in `claude --resume` auffindbar — nicht mal, während er läuft.

User-Sorge (ernst genommen): „Wir doktern mit WhisperM8 herum und machen dabei Claudes
Session-Handling kaputt." → Dieser Plan ist **evidenzbasiert**: erst messen/reproduzieren,
dann gezielt fixen, dann Sicherheitsnetz. Kein Blind-Patchen.

## Was verifiziert wurde (Code gelesen, Fakten)

**Persistenz-Pipeline** (`WhisperM8/Services/AgentWorkspaceStore.swift`):
- `mutate()` (Z. 92–120) läuft synchron unter Lock und ruft `persistLocked()`.
- Für die Produktions-Datei ist die Policy **`.debounced(0.5)`** (Registry). `persistLocked()`
  (Z. 158–171) schreibt **nicht sofort**, sondern setzt `dirty=true` und plant einen Flush in
  **0,5 s** auf einer Hintergrund-Queue. **Jede weitere Mutation canceled den pending Flush und
  startet die 0,5 s neu** (Z. 164–169) → bei schnellen Mutationsfolgen wird das Schreiben immer
  weiter rausgeschoben.
- `flush()` (Z. 128–147) schreibt synchron (atomic). Wird per `willTerminate`-Observer
  (Z. 64–73) aufgerufen.

**Termination:** `flush()` greift bei **Cmd+Q** (graceful). Es greift **nicht** bei
`make kill`/Force-Quit/Crash/System-Shutdown **innerhalb des 0,5-s-Fensters** — dann feuert
`willTerminate` nicht und der pending Flush läuft nie.

**Pruning ist NICHT die Ursache (widerlegt):** Mehrere Recherche-Hypothesen vermuteten, dass
`removeUnresumableClaudeSessions` (`AgentSessionStore.swift:681–692`) frische Chats löscht. Das
ist **falsch**: Die Bedingung verlangt u.a. `externalSessionID == nil` **und**
`createdManually != true`. Ein neuer Claude-Chat hat aber:
- `externalSessionID` = pre-generierte lowercase-UUID (`AgentChatsView.swift:2264–2266`),
- `createdManually = true` (`AgentSessionStore.swift:394`), Codable round-trippt korrekt
  (`AgentChat.swift:370`).
→ Manuelle Chats sind **doppelt** vor diesem Pruning geschützt. (Trotzdem als Härtung relevant,
siehe Phase 3.)

## Root-Cause-Analyse (nach Konfidenz)

### RC1 — Datenverlust durch nicht-persistierte Mutation (HOCH)
Eine frisch erstellte Session lebt bis zu ~0,5 s (oder länger, da rapid-mutation den Timer
zurücksetzt) **nur im Speicher** (`canonical`), bevor sie auf Platte landet. Endet die App in
diesem Fenster nicht-graceful (Crash, Force-Quit, `make kill`, Shutdown, Login-Logout), ist der
Chat **weg**. Das erklärt „manchmal" perfekt — es ist ein Timing-Fenster.

Verstärker: Der Erstell-Flow erzeugt **mehrere** schnelle Mutationen (createSession →
markLaunched → später externalSessionID-Bindung), die den Debounce-Timer wiederholt neu starten.

### RC2 — „Nicht in `claude --resume`" (MITTEL, separate Ursache)
Hypothesen, in Phase 4 zu verifizieren (nicht raten):
- **Lazy-Write:** Claude schreibt die Transkript-JSONL evtl. erst nach der ersten User-Nachricht.
  Wer den Tab öffnet, aber nichts tippt, hat (noch) keine resumebare Session — normales
  Claude-Verhalten, kein Bug, aber verwirrend.
- **`--session-id`-Handling:** WhisperM8 übergibt eine pre-gen UUID per `--session-id`
  (`AgentCommandBuilder`). Zu prüfen: legt die installierte Claude-Version damit sofort eine
  resumebare Session an?
- **cwd-Encoding:** `encodeClaudeCwd` (`AgentSessionTranscript.swift`) nutzt
  `standardizedFileURL` (löst **keine** Symlinks auf). Für normale Pfade unter `/Users/...` ist
  `/Users` **kein** Symlink → kein Mismatch erwartet. Nur relevant, wenn das Projekt selbst über
  einen Symlink liegt. **Erst messen, bevor hier etwas geändert wird.**

### RC3 — Überschreiben mit leerem Workspace (NIEDRIG, aber gefährlich)
`AgentWorkspaceRepository.load` gibt bei Parse-Fehler `.empty` zurück (nach `backup()`). Eine
nachfolgende Mutation würde dann die (gesicherte) Datei mit dem leeren Stand **überschreiben**.
Unwahrscheinlich als Hauptursache (setzt Korruption voraus), aber das Sicherheitsnetz (Phase 3)
muss das abfangen.

## Leitprinzip
Aus `ROBUST_CLAUDE_RESUME_TERMINAL_PERSISTENCE_PLAN.md` (Z. 642): **Ein lokaler Tab darf niemals
automatisch verschwinden.** Persistenz muss „crash-safe by default" sein — ein erstellter Chat ist
sofort auf Platte, und eine nicht-leere Datei wird nie ungesichert durch eine leere ersetzt.

## Umsetzungsplan (diszipliniert: messen → fixen → absichern)

### Phase 0 — Telemetrie + Reproduktion (ZUERST, bestätigt die Ursache)
- Signposts/Logs (`subsystem == "com.whisperm8.app"`, Kategorie `perf.store` erweitern) für:
  `session_created` (id), `persist_scheduled` (debounce), `persist_flushed` (bytes, count),
  `willTerminate_flush`, `workspace_loaded` (count), `prune_removed` (welche Regel, count).
- Repro-Skript/Checkliste: Chat erstellen → App per `kill -9` beenden → neu starten → in den
  Logs sehen, ob `persist_flushed` vor dem Kill kam. Damit ist RC1 **bewiesen oder widerlegt**,
  bevor wir Code-Verhalten ändern.
- Erwartetes Ergebnis: „created" ohne „flushed" vor Kill → RC1 bestätigt.

### Phase 1 — Sofort-Persistenz für strukturelle Mutationen (Kern-Fix)
Strukturelle, seltene, kritische Änderungen umgehen den Debounce und schreiben **synchron**:
- Betroffen: `createSession`, `deleteSession`, Pin/Unpin, Rename, Projekt-Anlage/-Löschung.
- Mechanik: entweder ein `mutate(flushImmediately: true)`-Pfad im `AgentWorkspaceStore` (ruft nach
  `persistLocked` direkt `flush()`), oder die Facade `AgentSessionStore` ruft nach diesen
  Operationen explizit `workspaceStore.flush()`.
- Häufige, unkritische Mutationen (z.B. `lastActivityAt`, Reihenfolge) bleiben debounced — der
  I/O-Spar-Grund bleibt erhalten.
- Datei: `WhisperM8/Services/AgentWorkspaceStore.swift`, `AgentSessionStore.swift`.

### Phase 2 — Flush-Sicherheitsnetze gegen nicht-graceful Quit
- Flush bei **`NSApplication.willResignActiveNotification`** und **`didResignActive`**
  (App verliert Fokus / wird in den Hintergrund geschickt) — fängt Force-Quit-Vorbereitung,
  App-Switch, Logout-Beginn.
- Flush bei **`scenePhase`-Wechsel** (`.inactive`/`.background`) der Agent-Chats-Szene.
- Flush bei **Fenster-Schließen** (auch wenn die App als MenuBarExtra weiterlebt).
- Datei: `WhisperM8App.swift` (AppDelegate/Scene), Anbindung an `AgentWorkspaceStore.flush()`.

### Phase 3 — Backup-/Recovery-Sicherheitsnetz (nie gute Daten verlieren)
- `AgentWorkspaceRepository` führt bereits `backup()` — nutzen/ausbauen: bei **jedem
  erfolgreichen Load** eine Rolling-Kopie (`AgentSessions.backup.json`) der **nicht-leeren**
  Datei behalten.
- **Schutzregel:** Niemals eine nicht-leere `AgentSessions.json` durch einen **leeren** Workspace
  ersetzen, ohne dass dies eine echte User-Aktion war. Beim Speichern: wenn neuer Stand 0
  Sessions hat, alter Stand aber > 0, dann zuerst sichern + warnen (Log), nicht still
  überschreiben.
- Beim Laden mit Parse-Fehler: aus Backup wiederherstellen statt `.empty` zu übernehmen.
- Datei: `WhisperM8/Services/AgentWorkspaceRepository.swift`.

### Phase 4 — Resume-Symptom verifizieren (separat, niedrigere Prio)
- Integrationscheck: neuen Claude-Chat via WhisperM8 starten, **eine** Nachricht senden, dann in
  einem normalen Terminal `claude --resume` im selben Projektpfad → erscheint die Session?
- Prüfen: schreibt Claude vor der ersten Nachricht? Akzeptiert die installierte Version
  `--session-id` so, dass sofort eine resumebare Session entsteht? cwd-Encoding 1:1 zu Claudes
  Ablageort (`~/.claude/projects/<encoded>`)?
- Nur fixen, was die Messung als echten Mismatch zeigt (z.B. ggf. `resolvingSymlinksInPath()`
  in `canonicalProjectPath`/`encodeClaudeCwd`, falls Symlink-Projekte betroffen sind).

### Phase 5 — Regressionstests
- Store-Test: `createSession` → sofortiger Flush → Datei auf Platte enthält die Session
  (kein Warten auf Debounce).
- Store-Test: nicht-leerer Workspace wird nie durch leeren überschrieben (Schutzregel).
- Repository-Test: Parse-Fehler → Recovery aus Backup statt `.empty`.
- Bestehende 424 Tests grün halten.

## Bezug zu bestehender Doku
- `docs/ROBUST_CLAUDE_RESUME_TERMINAL_PERSISTENCE_PLAN.md` (2026-05-11): behandelt Terminal-
  Snapshot + `/resume`-ID-Rebinding + Recovery-UI. **Komplementär** — dieser Plan schließt die
  darunterliegende Lücke (die Session-Einträge selbst zuverlässig persistieren). Telemetrie-
  Namespaces dort wiederverwenden (`claude.binding`, `terminal.snapshot`).

## Verifikation (End-to-End)
1. Telemetrie aktiv → Repro: Chat erstellen, sofort `kill -9 <pid>`, neu starten → Chat ist
   **da** (war vor dem Kill geflusht; Logs zeigen `persist_flushed` direkt nach `session_created`).
2. Chat erstellen → Cmd+Q → neu starten → da.
3. Chat erstellen → Fenster schließen (App lebt weiter) → neu öffnen → da.
4. `AgentSessions.json` manuell korruppieren → Start → Recovery aus Backup, keine leere Sidebar.
5. `swift test` grün inkl. neuer Regressionstests; `make dev` Smoke-Test.

## Nicht-Ziele
- Kein Versuch, einen gekillten PTY-Prozess weiterleben zu lassen (siehe ROBUST-Plan: Snapshot,
  nicht Prozess-Persistenz).
- Keine globale Änderung an `~/.claude`-Settings.
