# 01 · Agent View — alles, was wir wissen müssen

> Offizielle Quelle: <https://code.claude.com/docs/en/agent-view> · Launch-Post: <https://claude.com/blog/agent-view-in-claude-code> (11.05.2026) · Min-Version: **Claude Code 2.1.139**, Research Preview, verfügbar auf Pro, Max, Team, Enterprise und API-Plans.

## 1. Konzept in einem Satz

> *"Agent view, opened with `claude agents`, is one screen for all your background sessions: what's running, what needs your input, and what's done."* — offizielle Doku.

Damit ist Agent View **eine TUI** (Text-UI im Terminal) — *kein* eigener Chat. Es zeigt ein **Dashboard** über alle Background-Sessions des aktuellen Users (genau: alle Sessions unter dem aktiven `CLAUDE_CONFIG_DIR` bzw. `~/.claude`) und erlaubt dir, Sessions zu dispatchen, peeken, beantworten oder attachen.

## 2. So sieht Agent View aus

Aus der offiziellen Doku gespiegelt:

```
Pinned
  ✽ clawd walk cycle          Write assets/sprites/clawd-walk.png           3m

Ready for review
  ∙ jump physics              github.com/anthropics/example/pull/2048       2h

Needs input
  ✻ power-up design           needs input: double jump or wall climb?       1m

Working
  ✽ collision detection       Edit src/physics/CollisionSystem.ts           2m
  ✢ playtest level 3          run 12 · all checkpoints cleared           in 4m

Completed
  ✻ title screen              result: menu, options, and credits done       9m
  ∙ sound effects             result: 14 SFX exported to assets/audio       4h
```

Pro Row: **State-Indikator (Farbe)** + **Shape-Icon** (Prozess lebt/exited) + Session-Name + One-Line-Summary + Relative-Zeit.

## 3. Zustands-Map

| Indikator | Bedeutung |
| :-------- | :-------- |
| Animiertes `✽` | **Working** — Claude generiert oder ruft Tools |
| Gelb | **Needs input** — Permission-Prompt oder Multiple-Choice |
| Gedimmt | **Idle** — wartet auf Prompt, nicht blockiert |
| Grün | **Completed** |
| Rot | **Failed** |
| Grau | **Stopped** (durch `Ctrl+X` oder `claude stop`) |

Form-Icon:
- `✻` / animiert `✽` → Prozess lebt, du kannst direkt antworten.
- `∙` → Prozess exited, aber **Conversation lebt**: peek/reply/attach respawnt automatisch.
- `✢` → eine `/loop`-Session schläft zwischen Iterationen; Row zeigt Run-Count + Countdown.

## 4. One-Line-Summary

Der zweite Spalten-Wert ist eine **Haiku-Class-Zusammenfassung** der aktuellen Aktivität. Sie wird vom konfigurierten Haiku-Modell erstellt — **max. alle 15 s aktualisiert**, plus einmal pro Turn-Ende. Jede Refresh-Anfrage ist ein zusätzlicher Haiku-Request, der via deine normale Subscription bezahlt wird.

> Source: Agent View Doc, Abschnitt "Monitor sessions with agent view".

## 5. Wie du eine Session dispatchst

Drei Wege:

1. **Aus Agent View selbst** — unten ist ein Input. Enter → neue Background-Session entsteht.
2. **Aus einer laufenden Session** — `/background` (Alias `/bg`), optional mit weiterem Prompt (`/bg run tests and fix`).
3. **Direkt aus der Shell** — `claude --bg "<prompt>"`, optional mit `--agent <name>` um einen bestimmten Sub-Agent als Main zu fahren.

Prefix-/Mention-Conventions im Agent-View-Input:

| Eingabe | Effekt |
| :------ | :----- |
| `<subagent-name> <prompt>` | Erstes Wort matcht Sub-Agent → der Sub-Agent ist Main |
| `@<subagent>` | Same — explizit |
| `@<repo>` | Session läuft in diesem Sibling-Repo |
| `/<skill>` | Skill als Prompt dispatchen |
| `#<num>` oder PR-URL | Wenn schon Session an PR arbeitet → selektieren statt neue spawnen |
| `Shift+Enter` | Dispatchen *und* sofort attachen |

## 6. Filter

Du kannst im Input filtern statt dispatchen:

| Filter | Zeigt |
| :----- | :---- |
| `a:<name>` | Sessions, die einen bestimmten (Sub-)Agent fahren |
| `s:<state>` | Sessions in einem State, z. B. `s:blocked` |
| `#<num>` oder PR-URL | Session, die an dem PR arbeitet |

## 7. Keyboard-Shortcuts (komplett)

| Shortcut | Aktion |
| :------- | :----- |
| `↑` / `↓` | Zwischen Rows navigieren |
| `Enter` | Selected Session attachen (oder dispatchen, wenn Input nicht leer) |
| `Space` | Peek-Panel für die Row öffnen/schließen |
| `Shift+Enter` | Dispatchen + sofort attachen |
| `→` | An die selektierte Session attachen |
| `Alt+1` … `Alt+9` | An die N-te Session der fokussierten Gruppe attachen |
| `Tab` | Browse Subagents, oder Suggestion übernehmen |
| `Ctrl+S` | Grouping zwischen *State* und *Directory* toggeln |
| `Ctrl+T` | Selected Session pinnen/unpinnen |
| `Ctrl+R` | Selected Session umbenennen |
| `Ctrl+G` | Dispatch-Prompt in `$EDITOR` öffnen |
| `Ctrl+X` | Stop; nochmal innerhalb 2 s → Delete |
| `Shift+↑` / `Shift+↓` | Reordering |
| `Esc` | Peek schließen / Input clearen / verlassen |
| `Ctrl+C` | Input clearen (zweimal → Exit) |
| `?` | Help (alle Shortcuts) |
| `←` (auf leerem Input) | Detach + zurück zur Tabelle (oder Background-Toggle einer aktuellen Session) |
| `Ctrl+Z` (im Dialog) | Sofort detachen |

## 8. Peek-Panel

`Space` öffnet Peek. Es zeigt:
- Worauf die Session wartet,
- den letzten Output,
- offene Pull Requests.

Du kannst **direkt im Peek antworten** (Enter sendet Reply an die Session). Bei Multiple-Choice-Fragen → Zahlentasten. `Tab` befüllt den Input mit einer Suggested-Reply. Prefix `!` → Bash-Command statt Text.

## 9. Hosting — der Supervisor-Daemon (zentral wichtig!)

Jede Background-Session ist ein **eigener Claude-Code-Process**, **parented zum Supervisor-Daemon**, nicht zu deinem Terminal. Das bedeutet:

- Du kannst dein Terminal schließen — Sessions laufen weiter.
- Eine Session, die finished + ~1 Stunde unattached + nichts macht → wird vom Supervisor *gestopped* (Process exited), Transcript bleibt aber auf Disk. Nächstes Attach/Peek/Reply startet automatisch einen frischen Prozess "wo es aufgehört hat".
- Wenn **alle** Sessions fertig sind + kein Terminal mehr connected → Supervisor exitiert auch. Beim nächsten `--bg` / `claude agents` startet er neu.
- Supervisor **watcht das Claude-Binary auf der Disk**: nach Auto-Update wird in die neue Version respawnt — die Sessions überleben den Restart als detachierte Prozesse, der neue Supervisor reconnected sie.

Auth: Supervisor und Sessions nutzen dieselben Credentials wie deine interaktiven Sessions. Keine zusätzlichen Netzverbindungen außer Model-API.

## 10. State auf Disk — diese Pfade sind die wichtigsten

| Pfad | Inhalt |
| :--- | :----- |
| `~/.claude/daemon.log` | Supervisor-Log |
| `~/.claude/daemon/roster.json` | Liste der aktuell registrierten Background-Sessions (zum Reconnect nach Restart) |
| `~/.claude/jobs/<short-id>/state.json` | **Pro Session: genau der State, den Agent View rendert** (Name, State-Indicator, One-Line-Summary, Last-Activity, PR-Link, Indicator-Shape, Pinned/Sortierung) |
| `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` | Conversation-Transcript dieser Session — *gleiches Format* wie interaktive Sessions |

Beachte: Es gibt **zwei IDs**:
- **Short-ID** (z. B. `7c5dcf5d`) → für `claude attach/logs/stop/respawn/rm`. Diese identifiziert die Background-Job-Hülle (`~/.claude/jobs/<short-id>/`).
- **Session-UUID** → identifiziert das Conversation-Transcript (`~/.claude/projects/.../<uuid>.jsonl`).

> Daraus folgt: Ein externes UI, das Agent-View-Status lesen will, müsste `~/.claude/daemon/roster.json` + `~/.claude/jobs/*/state.json` parsen. Dieses Format ist **nicht offiziell stabil dokumentiert** (es ist ein Implementation-Detail des Supervisors), kann sich also brechen.

## 11. File-Edit-Isolation (relevanter Implikations-Punkt)

Jede Background-Session startet im cwd, ist aber **vom Schreiben dort blockiert**, bis sie sich automatisch in eine isolierte git-worktree unter `.claude/worktrees/` verschiebt — sobald sie editieren will. Ausnahme: man ist schon in einer Worktree, der cwd ist kein Git-Repo, oder Writes außerhalb des cwds.

Die Worktree wird gelöscht, wenn die Session gelöscht wird → **vorher mergen oder pushen**.

`isolation: worktree` im Frontmatter eines Sub-Agents zwingt diesen, immer in eigener Worktree zu laufen.

## 12. Permission-Mode beim Dispatch

Dispatching aus dem Agent-View-Input übergibt **kein** Permission-Mode → Session nutzt `defaultMode` aus den Settings ihres cwds, oder `permissionMode` aus dem Frontmatter des dispatchten Sub-Agents.

Aus der Shell mit `claude --bg --permission-mode bypassPermissions "…"` setzen — aber Claude verlangt vorher mindestens *einmal* interaktiv `claude --permission-mode bypassPermissions` anzunehmen.

## 13. Shell-Commands für Background-Sessions

Identisch zum Agent-View-State; nützlich für Scripts, oder wenn man Agent View nicht öffnen will:

| Command | Funktion |
| :------ | :------- |
| `claude agents` | Agent View öffnen |
| `claude attach <short-id>` | Attachen |
| `claude logs <short-id>` | Output ausgeben |
| `claude stop <short-id>` | Stoppen (Alias: `claude kill`) |
| `claude respawn <id>` / `--all` | Gestoppte wieder hochfahren |
| `claude rm <short-id>` | Entfernen |

Wenn `claude agents` per **Pipe** läuft (`claude agents | cat`), listet es **statt der Agent View** alle konfigurierten Sub-Agents als Plain-Output → maschinenlesbar.

## 14. Was zwischen Sleep/Shutdown passiert

Background-Sessions sind **lokale Prozesse** → Sleep + Shutdown stoppt sie. Beim Aufwecken sind sie als "Stopped" markiert.

- **Attach/Peek/Reply** → Auto-Respawn von wo aufgehört.
- `claude respawn --all` → alle stopped Sessions auf einmal wiederbeleben.

## 15. Administrator-Schalter

Per Managed-Settings oder Env:
- `disableAgentView: true` → komplett ausschalten.
- `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` → Env-Variante.

Beides verhindert `claude agents`, `--bg`, `/background` und den Supervisor.

## 16. Limitations (Research Preview)

- **Rate-Limits gelten** — 10 parallele Agents = 10× Quote-Verbrauch.
- **Lokale Sessions stoppen bei Sleep/Shutdown** → wieder hochfahren per Respawn.
- **Worktrees verschwinden mit der Session** — Änderungen davor mergen.

## 17. Drei Vergleichspunkte zu anderen Parallelitäts-Mechanismen

| Approach | Charakter |
| :------- | :-------- |
| **Sub-Agents** | Worker *innerhalb* einer Session — eigener Context-Window, returnt Summary |
| **Agent View** | Mehrere unabhängige Hauptsessions parallel, du behältst die Übersicht |
| **Agent Teams** (experimental) | Ein Lead-Agent koordiniert mehrere Worker; sie teilen Task-List + Inter-Agent-Messaging |
| **Worktrees** | Reine FS-Isolation für parallele Editoren-Sessions |
| **`/batch`** | Geplanter Split eines großen Changes in 5–30 Sub-Agent-Worktree-Tasks, jeder mit eigenem PR |

> Source: <https://code.claude.com/docs/en/agents>

## 18. Wichtige Beobachtungen für eine UI-Integration

1. **Agent View ist ein TUI**, kein REST/Websocket-Server. Es gibt keine offizielle Status-API. Wer den State braucht, muss entweder:
   - Die TUI im PTY rendern (was wir heute schon tun), oder
   - `~/.claude/jobs/*/state.json` + `roster.json` lesen (inoffiziell, kann brechen), oder
   - `claude agents | cat` als Pipe nutzen (gibt aber nur Sub-Agents zurück, **nicht** die Background-Sessions!), oder
   - Über die Session-JSONL den Live-Status aus Tool-Events selber ableiten.

2. **Background-Sessions sind reguläre Claude-Code-Sessions** mit einer Standard-`session_id`-UUID und einer JSONL unter `~/.claude/projects/<cwd>/<id>.jsonl`. Heißt: **WhisperM8 könnte sie attachen, indexieren, anzeigen wie jede andere Session.** Die "Background-Hülle" ist nur ein Supervisor-Wrapper.

3. **`claude --bg` druckt die `short-id` und Management-Commands** ins stdout:
   ```
   backgrounded · 7c5dcf5d
     claude agents             list sessions
     claude attach 7c5dcf5d    open in this terminal
     claude logs 7c5dcf5d      show recent output
     claude stop 7c5dcf5d      stop this session
   ```
   → Ein WhisperM8-Subprocess kann diese ID parsen und sich merken.

4. **Es gibt keine offizielle Möglichkeit, eine Background-Session "von außerhalb" headless zu erzeugen** und sie dann der bestehenden Agent-View hinzuzufügen — `claude --bg` *ist* genau dieser Weg.

5. **`/bg` aus laufender Session** ist der zweite offizielle Weg → wir könnten in unseren Tabs einen "In Background schicken"-Button bauen, der das Kommando ins PTY schickt.

## 19. Konkrete Skript-Snippets aus der Doku

**Eine Background-Session aus der Shell starten und die Short-ID festhalten:**
```bash
short_id=$(claude --bg "investigate the flaky SettingsChangeDetector test" \
  | grep -oE '· [0-9a-f]{8}' | tr -d '· ')
```

**Mit einem spezifischen Sub-Agent fahren:**
```bash
claude --agent code-reviewer --bg "address review comments on PR 1234"
```

**Logs einer Background-Session pollen:**
```bash
claude logs 7c5dcf5d
```

**Spezifische Session direkt attachen:**
```bash
claude attach 7c5dcf5d
```

**Alle stopped Sessions auf einmal wiederbeleben:**
```bash
claude respawn --all
```

## 20. Was Agent View *nicht* kann (Stand 05/2026)

- Keine eingebaute Möglichkeit, Sessions zwischen Maschinen zu syncen (Sessions sind streng lokal). Für Cross-Machine: [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) oder eigene `SessionStore`-Adapter im SDK.
- Kein offizielles JSON-Event-Stream-Format für den Agent-View-State.
- Keine Custom-Spalten oder eigenes Theming.
- Kein eingebauter Push an externe Tools — dafür braucht es Hooks oder Channels.
