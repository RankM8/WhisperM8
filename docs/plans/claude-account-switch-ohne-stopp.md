# Plan: Claude-Konto per Klick wechseln — ohne Stoppen, gemeinsames Gedächtnis

**Stand:** 2026-10-10 · **Status:** Entwurf, nicht freigegeben · **Scope:** Agent Chats (Claude), Settings-Seite „Accounts“, CLI `whisperm8 chats move-account`
**Vorgänger:** `claude-account-switcher.md` (Profile via `CLAUDE_CONFIG_DIR`), `claude-account-routing.md` (Slice 5–6: Default-Profil, Umzug mit Journal). Dieser Plan baut darauf auf und ersetzt nichts davon.

## Ziel

Ein oder alle Claude-Chats jederzeit per Klick auf ein anderes Abo umstellen, **ohne dass der
User etwas stoppen muss** — und alle Konten arbeiten mit **demselben Gedächtnis** pro Projekt.

Harte Leitplanke (Vorgabe des Users): **nichts an Claude Code selbst verändern, nur dokumentierte
Wege nutzen.** Kein Keychain-Tausch, keine Symlinks in Claude-Interna, kein Proxy, der Logins
austauscht, keine Schreibzugriffe auf Claudes `.claude.json`.

## Ausgangslage

1. **Kontowechsel heißt heute: Chat von Hand stoppen.** Der Planner überspringt laufende Chats
   (`AccountMovePlanner`); nur die CLI kennt `--stop-and-resume`
   (`AgentControlRequestHandler+AccountMove.swift:186-241`). In der GUI muss der User den Chat
   beenden, umziehen und neu öffnen.
2. **Das Gedächtnis ist pro Konto zerstückelt.** Claude legt Auto-Memory unter
   `<config-dir>/projects/<projekt>/memory/` ab. Bestand am 10.10.2026: **94 Memory-Ordner**, allein
   für whisperm8 sieben Stück (42 Dateien in main, 17 in PowerUser, 4 in PowerUser2, 3 in Claude2,
   2 in ai3, je 0 in ai2/RankM8). Ein Chat unter ai3 kennt nicht, was ein Chat unter main gelernt hat.
3. **Die Konten-Seite zeigt nicht, was der User braucht:** wie viele Chats auf welchem Konto laufen,
   und eine Aktion „alle hierher“. Fremde Ordner erschienen als Konto (Vorfall `PowerUser.lock`,
   behoben in `fae67d3`).

## Recherche-Ergebnis (10.10.2026) — was nativ geht und was nicht

| Frage | Befund | Quelle |
|---|---|---|
| Offizieller Weg für mehrere Konten | Ein `CLAUDE_CONFIG_DIR` pro Konto; „each directory has its own settings, session history, and login“. Geteilte Verläufe sind nicht vorgesehen. | [authentication](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts) |
| Konto einer laufenden Session wechseln | Nicht dokumentiert. `/login` in der Session wirkt unzuverlässig (#98437). Keychain-Tausch (claude-swap) wirkt global und gefährdet Logins. | Issues #98437, claude-swap #383 |
| Transcripts per Symlink teilen | **Nein.** `/resume`-Liste leer (#46342, „not planned“), `--resume` bricht bei Symlinks (#98899), Memory-Writes fragen ständig nach Freigabe (#98044), das Konto mit dem kleinsten `cleanupPeriodDays` löscht für alle. | Issues #46342, #98899, #98044 |
| Eigener Transcript-Pfad | Gibt es nicht. | [sessions](https://code.claude.com/docs/en/sessions#where-transcripts-are-stored) |
| Memory-Ort verlegen | **Ja, offiziell:** Setting `autoMemoryDirectory` („Custom directory path for auto-memory storage. Supports ~/ prefix … When unset, defaults to ~/.claude/projects/<sanitized-cwd>/memory/“). Fester Pfad, keine Platzhalter. Wird aus `policySettings`, **`flagSettings` (`--settings`)**, Local/Project (nur bei Trust, eingecheckte `.claude/settings.json` ignoriert) und `userSettings` gelesen. | [settings-reference](https://code.claude.com/docs/en/settings-reference), Binary 2.1.296 |
| Chat unter anderem Konto fortsetzen | **Geht.** JSONL im `projects/` des Zielkontos + `--resume` ist der dokumentierte Weg. Thinking-Blöcke von Sonnet/Haiku 5.5 aus fremdem Konto verwirft die API **still, ohne Fehler**; ältere Modelle nicht betroffen. | [preserved-thinking](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking#account-bound-thinking) |
| Eigener Feldbeleg | 36 Chats bisher per App umgezogen, 35 danach weitergelaufen, **0 Signatur- oder Kontofehler** (nur 502, „Prompt is too long“, Abbrüche, 1× abgelaufener Token, 1× Team-Konto ohne Claude-Code-Freigabe). | `account-moves.jsonl` gegen Transcripts |
| Vergleich Open Source | T3 Code (~27k ⭐) kann Claude-Threads laut eigener Doku nicht über Config-Ordner hinweg wechseln (nur Codex, per Neustart). Kein großes Projekt wechselt Claude-Abos pro Chat ohne Proxy. | [t3code providers-claude](https://github.com/pingdotgg/t3code/blob/main/docs/user/providers-claude.md) |

**Folgerung:** Transcripts bleiben pro Konto und werden beim Wechsel verschoben (heutige, bewährte
Mechanik). Das Gedächtnis wird über `autoMemoryDirectory` per `--settings` geteilt — das Flag, mit
dem WhisperM8 jeden Chat ohnehin startet (Hook-Bridge, Datei pro Session unter
`claude-hooks/<session-id>.json`). Neu ist vor allem die **Automatik**: Die App wartet den richtigen
Moment ab und macht Stoppen → Umziehen → Fortsetzen selbst.

## Zielbild

- **Kontextmenü „Konto wechseln ▸“** an Tab und Sidebar, für einen oder mehrere markierte Chats.
  Auf der Konten-Seite pro Konto **„Alle Chats hierher“**.
- **Ruhender Chat** (kein PTY oder Turn beendet): wechselt sofort, im selben Tab.
- **Arbeitender Chat:** bekommt ein Kennzeichen „→ ai2“ und wechselt automatisch, sobald der Turn
  endet. Vormerkung jederzeit zurücknehmbar.
- **Gemeinsames Gedächtnis:** Jeder Chat eines Projekts schreibt und liest
  `~/.claude/projects/<projekt>/memory/` (Ort von main), egal unter welchem Konto er läuft.
- **Konten-Seite:** pro Konto Limits, „N laufen · M offen“, „Alle Chats hierher“, Warnung bei doppelt
  angemeldetem Konto. Im Tab/in der Sidebar ist das Konto eines Chats erkennbar.
- **Limit-Hinweis:** Bei ≥ 90 % (5 h oder Woche) eines Kontos mit laufenden Chats: „ai3 fast voll —
  4 Chats auf ai2 (7 %) umziehen?“ mit einem Klick. Kein automatischer Wechsel.

**Bewusst nicht erreichbar in dieser Stufe:** Wechsel mitten im Turn; das Terminal baut sich beim
Wechsel neu auf (Neustart mit `--resume`); die erste Antwort danach kostet mehr (Prompt-Cache wird
neu aufgebaut — gilt für jeden Weg); Background-Agents bleiben auf main (`claude-account-routing.md`,
Slice 7.5); Chats, die der User im Terminal außerhalb der App unter einem Profil startet, nutzen
weiter das Memory ihres Profils.

## Vorab-Entscheidungen

### E1 — Transcripts teilen? (Entscheidung: nein, verschieben)

Ursprünglich gewählt war „projects + file-history teilen“. Nach der Recherche verworfen: Es gibt
dafür keinen dokumentierten Weg, und alle Symlink-Varianten haben offene Claude-Code-Bugs (siehe
Tabelle). Das Verschieben beim Wechsel ist der dokumentierte Weg und im Feld belegt.

### E2 — Wie wird das Memory geteilt? (Empfehlung: `--settings` pro Launch)

| Option | Für | Gegen |
|---|---|---|
| **A: `autoMemoryDirectory` im Settings-Fragment pro Launch** | offiziell; pro Projekt korrekt; keine Dateien in Repos; wirkt sofort für alle App-Chats; abschaltbar | nur für App-Chats; App muss den Projektpfad so berechnen wie Claude |
| B: in der geteilten `~/.claude/settings.json` | ein Eintrag | fester Pfad → **alle Projekte in einem Topf**; unbrauchbar |
| C: pro Repo `.claude/settings.local.json` | offiziell | schreibt in jedes Repo, erscheint im Trust-Dialog als Warnung |
| D: Symlink auf `memory/` | — | Issue #98044 (Freigabe-Prompt bei jedem Write) |

**Empfehlung: A.** Zielordner = der Ordner, den Claude unter main für dieses Projekt nimmt
(`~/.claude/projects/<sanitized-git-root>/memory/`). Main bleibt damit die Heimat des Gedächtnisses;
das Terminal-`claude` unter main sieht dasselbe.

### E3 — Wann wechselt ein arbeitender Chat? (Entscheidung: nach dem Turn)

Vom User gewählt. „Turn beendet“ = Runtime-Status `idle` (nicht `awaitingInput` — ein offener
Permission-Dialog ist noch Teil des Turns). Liegt vermutlich ein Entwurf im Eingabefeld
(`TerminalComposerDraftTracker`), wartet die Vormerkung weiter und der Chat zeigt „Entwurf im
Eingabefeld — wechselt danach“ mit Knopf „Jetzt trotzdem wechseln“.

### E4 — Vormerkung persistieren? (Empfehlung: nein, ephemer)

Eine Vormerkung lebt nur im Speicher. Stirbt die App, setzt die Crash-Recovery den Chat unter dem
alten Konto fort und der User klickt erneut. Persistieren hieße, dass ein Neustart einen Wechsel
auslöst, den der User nicht mehr vor Augen hat. Nachrüstbar.

### E5 — Was umfasst „Alle Chats hierher“? (Empfehlung: offen + laufend)

Alle nicht archivierten Claude-Chats mit offenem Tab oder laufendem PTY, ohne Background-Agents und
Terminal-Tabs. Geschlossene Chats behalten ihren Stempel (sie kosten nichts, und ein Massen-Umzug
alter Transcripts erzeugt nur Scan-Last).

---

## Slice 0 — Prototyp (vor jeder Codeänderung)

Manuell in einem Wegwerf-Repo, Claude Code 2.1.296. Ergebnis kommt als Abschnitt
„Prototyp-Befunde“ in diesen Plan.

| # | Prüfung | Erwartung / Abbruchkriterium |
|---|---|---|
| P1 | `claude --settings x.json` mit `autoMemoryDirectory` unter einem Zusatzprofil; Claude soll sich etwas merken | Datei landet im angegebenen Ordner; **kein** Freigabe-Prompt pro Write; Memory wird in neuer Session gelesen. Sonst E2 neu entscheiden. |
| P2 | Pfadberechnung: für 3 Projekte (normales Repo, Unterordner eines Repos, Worktree) den Ordner bestimmen, den Claude unter main nimmt | App-Berechnung trifft exakt; Worktree teilt den Ordner des Hauptrepos. Abweichung → Regeln aus dem Binary nachziehen oder `CLAUDE_CODE_PROJECT_DIR_NAME` prüfen. |
| P3 | Chat unter Konto A mit Opus und Fable, Turn beenden, Datei nach B verschieben, `--resume` unter B | Läuft weiter; notieren: Trust-Dialog ja/nein, fehlende MCP-Server, Verhalten bei Modell ohne Berechtigung im Zielplan. |
| P4 | Ablauf messen: Turn-Ende → Ctrl+C ×2 → Prozessende → Umzug → `--resume` bereit | Zeit in Sekunden notieren (Zielwert < 5 s). |
| P5 | `--settings` mit `autoMemoryDirectory` + bestehende Hook-Settings zusammen | Hooks feuern weiter (Hook-Bridge, Prompt-Guard). |

## Slice 1 — Gemeinsames Gedächtnis

**Ziel:** Alle App-Chats eines Projekts nutzen das Memory von main.

### Änderungen

1. **Neu: `Services/AgentChats/ClaudeSharedMemoryPath.swift`** — pur: `cwd` → Memory-Ordner unter
   `~/.claude/projects/` nach Claudes Regel (Git-Root, Worktrees teilen, Sanitizing wie
   `AgentProjectPath`). Git-Lookup **vor** jedem Store-`mutate` (Store-Lock-Regel aus CLAUDE.md).
2. **`ClaudeHookSettingsBuilder` / `AgentCommandBuilder`** — Settings-Fragment
   `{"autoMemoryDirectory": "<pfad>"}` über das bestehende `merged(_:)` in die Session-Datei
   `claude-hooks/<session-id>.json`; nur Claude-PTY-Chats, nur wenn der Kill-Switch an ist.
3. **Neu: `Services/AgentChats/ClaudeMemoryMigration.swift`** — einmalig beim App-Start (Flag
   `claudeSharedMemoryMigrationDone`): pro Profil und Projekt den Inhalt von
   `projects/<projekt>/memory/` nach main mischen.
   - Backup aller Quell-Ordner nach `Application Support/WhisperM8/memory-migration/<zeit>/<profil>/`.
   - Nie überschreiben. Gleicher Name, gleicher Inhalt → überspringen. Gleicher Name, anderer
     Inhalt → als `<name>.<profil>.md` ablegen und eine Zeile im `MEMORY.md`-Index ergänzen.
   - `MEMORY.md` selbst: fehlende Index-Zeilen anhängen, doppelte Zeilen auslassen.
   - Quell-Ordner bleiben unverändert stehen (Terminal-Chats unter dem Profil nutzen sie weiter).
   - Wiederverwendbar: die Misch-Logik aus `ClaudeAccountProfiles+Promote.swift` (`mergeContents`,
     „gleichnamige Dateien nie überschreiben“).
4. **Kill-Switch:** `defaults write com.whisperm8.app claudeSharedMemoryEnabled -bool NO` →
   kein Fragment, Claude nutzt wieder das Memory des Profils (der Bestand dort ist unberührt).

### Tests

| Datei | Fall |
|---|---|
| `ClaudeSharedMemoryPathTests` (neu) | Repo-Root, Unterordner, Worktree, Pfad mit Leerzeichen/Umlauten, Nicht-Git-Ordner |
| `ClaudeMemoryMigrationTests` (neu) | Konflikt → Suffix + Index-Zeile; identische Datei → übersprungen; Index-Merge ohne Duplikate; zweiter Lauf ist No-op; Backup vollständig |
| `ClaudeHookSettingsBuilderTests` | Fragment enthalten bzw. fehlt bei Kill-Switch; Hooks bleiben unverändert |

### Abnahme

- Neuer Chat unter ai3 im whisperm8-Repo sieht die 42 Memories von main plus die migrierten.
- Ein `/memory`-Eintrag aus einem PowerUser-Chat erscheint im nächsten ai2-Chat.
- Nach Kill-Switch fällt alles auf den Zustand vor Slice 1 zurück, ohne Datenverlust.

## Slice 2 — Wechsel nach dem Turn, ohne Stoppen

**Ziel:** „Konto wechseln“ funktioniert für jeden Chat-Zustand; die App stoppt und setzt selbst fort.

### Änderungen

1. **Neu: `Services/AgentChats/AccountSwitchCoordinator.swift`** (MainActor)
   - Hält ephemer `pending: [sessionID: targetProfile]` (E4) als kleines `@Observable`, das nur
     Tab-/Sidebar-Kennzeichen lesen (Sidebar-Performance-Regel: nicht den ganzen Baum beobachten).
   - Ruhender Chat → sofort ausführen. Laufender Chat → vormerken; ausführen, sobald der
     `AgentSessionRuntimeStatusStore` `idle` meldet und kein Entwurf vermutet wird (E3).
   - Ausführen = die bestehende Kette, aus dem Control-Handler herausgelöst: graceful terminate
     (`registry.terminate`, 2× Ctrl+C + SIGTERM) → `ProcessExitWaiter` → `AccountMoveService.perform`
     (Umzug + Stempel + Journal, also weiterhin rückgängig machbar) → `shouldLaunchOnOpen` und
     Relaunch im selben Tab.
   - Fehler (Timeout beim Beenden, Ziel ausgeloggt) → Vormerkung entfällt, Hinweis am Chat, alter
     Zustand bleibt.
2. **`AccountMovePlanner`** — `running` ist kein Überspring-Grund mehr, sondern
   `afterTurn`; Überspringen nur noch bei `backgroundAgent`, `notAChat`, `targetNotLoggedIn`,
   `targetTranscriptExists`.
3. **Vorab-Prüfung im Bestätigungsdialog** (nur lesend): fehlende User-MCP-Server im Zielkonto
   (Vergleich der `mcpServers` aus beiden `.claude.json`), Ziel nicht eingeloggt (blockiert),
   Hinweis auf Prompt-Cache-Neuaufbau. Je nach Befund aus P3 auch Trust- oder Modell-Hinweis.
4. **CLI:** `whisperm8 chats move-account --to X` nutzt den Coordinator; Standard ist „nach dem
   Turn“. `--stop-and-resume` bleibt als Alias, `--force` (sofort, auch bei Entwurf) bleibt. Die
   eigene Session wird nie gestoppt. Skill `whisperm8-chats` anpassen.
5. **Kill-Switch:** `defaults write com.whisperm8.app accountSwitchAfterTurnEnabled -bool NO` →
   Verhalten wie heute (laufende Chats werden übersprungen).

### Tests

| Datei | Fall |
|---|---|
| `AccountSwitchCoordinatorTests` (neu) | ruhend → sofort; working → wartet, `idle` → führt aus; `awaitingInput` → wartet; Entwurf → wartet, „trotzdem“ → führt aus; Zurücknehmen; Timeout → Vormerkung weg, Stempel unverändert |
| `AccountMovePlannerTests` | `running` → `afterTurn`; übrige Gründe unverändert |
| `AgentControlRequestHandler`-Tests | CLI-Standard „nach dem Turn“, Alias, eigene Session nie |

Abhängigkeiten per Closure injiziert (Statusquelle, Terminate, Exit-Waiter, Move-Service), wie im
Projekt üblich. Drag/Menü/Kennzeichen → manuelle QA.

### Abnahme

- 3 Chats, davon einer mitten im Turn → „Konto wechseln → ai2“: zwei wechseln sofort, der dritte
  zeigt „→ ai2“ und wechselt selbst nach dem Turn. Kein manueller Stopp.
- Nach dem Wechsel liegt jede JSONL genau einmal (im Zielkonto), `log stream` ohne
  `claude_profile_stamp_mismatch`.
- „Rückgängig“ stellt Stempel und Ablageort wieder her.

## Slice 3 — Konten-Seite und Sichtbarkeit

1. **`AgentChatsClaudeAccountsTab`**
   - Pro Konto „N laufen · M offen“ (Snapshot beim Rendern der Seite, kein Dauer-Polling).
   - Knopf „Alle Chats hierher“ (E5) → Bestätigungsdialog aus Slice 2.
   - Warnung, wenn zwei Profile dieselbe E-Mail haben („doppelt angemeldet — eines entfernen“).
   - Veraltete Texte ersetzen („Running sessions keep the account they were started with …“).
2. **Tab und Sidebar:** Konto-Kürzel am Chat (aus dem Stempel, statisch) und Vormerkung „→ ai2“
   aus dem Coordinator-State. Kein `.contextMenu`-Umbau in Hot-Paths; Kennzeichen nur dort lesen,
   wo es angezeigt wird.
3. **Snapshot-Fixture** in `UISnapshotGallery` für die neue Konten-Seite (hell + dunkel).

## Slice 4 — Limit-Hinweis mit Vorschlag

1. Datenquelle: `ClaudeAccountUsageFetcher` (liest den Access-Token nur, refresht nie) bzw. dessen
   Cache. **Im Prototyp klären**, wie frisch die Werte ohne Klick auf „Update“ sind; ggf.
   periodischer Abruf nur für Konten mit laufenden Chats (Intervall ≥ 5 min).
2. Regel (pur, testbar): Konto mit ≥ 1 laufendem Chat und 5 h- oder Wochenwert ≥ 90 % → Vorschlag
   = eingeloggtes Konto mit dem meisten Spielraum (beide Werte < 70 %). Pro Konto und Fenster nur
   einmal; „Später“ blendet bis zum nächsten Reset aus.
3. Anzeige als Banner im Agent-Chats-Fenster: „ai3 bei 92 % — 4 Chats auf ai2 (7 %) umziehen?“ →
   Slice 2 mit allen laufenden Chats des Kontos. Kein automatischer Wechsel.
4. Kill-Switch: `claudeAccountLimitHintEnabled`.

## Slice 5 — Doku

CLAUDE.md (Abschnitt Agent Chats: Kontowechsel nach dem Turn, gemeinsames Memory, Kill-Switches),
`docs/features/agent-chats-cli.md` (`move-account`), Skill `whisperm8-chats`, Status-Zeile in
`claude-account-routing.md`.

---

## Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| Claude ändert Sanitizing oder Git-Root-Regel des Memory-Pfads | P2 als Unit-Test-Fixtures festhalten; Kill-Switch; Abweichung fällt nur als „Memory leer“ auf, nichts geht verloren |
| `autoMemoryDirectory` über `--settings` löst Freigabe-Prompts aus | P1 prüft das vor jedem Code; sonst E2 neu entscheiden |
| Ziel-Konto ohne MCP-Server oder ohne Trust für das Projekt | Vorab-Prüfung im Dialog (Slice 2.3); Trust-Dialog erscheint höchstens einmal je Projekt und Konto |
| Modell im Zielplan nicht verfügbar (z. B. Fable) | P3 klärt das Verhalten; dann Hinweis im Dialog |
| Wechsel beendet einen Turn, der gar nicht fertig war (Status falsch `idle`) | nur bei `idle` und ohne Entwurf; Prompt-Guard verhindert Wiedervorlage; Fehlerfall = Chat setzt per `--resume` fort, nichts geht verloren |
| Gleichzeitige Memory-Writes zweier Chats auf verschiedenen Konten | wie heute bei zwei Chats unter einem Konto; Claude schreibt Einzeldateien |
| Thinking-Blöcke (Sonnet/Haiku 5.5) gehen nach Wechsel still verloren | dokumentiertes API-Verhalten; im Dialog als „Reasoning des alten Kontos wird nicht mitgenommen“ erwähnen |

## Nicht Teil dieses Plans (bewusst offen)

- **Echter Wechsel ohne Neustart über den Router** (`ClaudeGPTMixRouter` tauscht pro Session den
  `Authorization`-Header). Technisch nah, weil alle Claude-Chats bei aktivem GPT-Backend schon über
  den Router laufen. Aber: Anthropics Bedingungen verbieten, Claude.ai-Credentials zu
  „intermediate“; das widerspricht der Leitplanke dieses Plans. Nur nach ausdrücklicher Entscheidung.
- Background-Agents pro Konto (`claude-account-routing.md`, Slice 7.5).
- Standard-Konto pro Projekt; Limit-Prognose („voll um 21:40“).

## Reihenfolge

```
Slice 0 (Prototyp) ──> Slice 1 (Memory) ──┐
                  └──> Slice 2 (Wechsel) ─┴──> Slice 3 (UI) ──> Slice 4 (Limit-Hinweis) ──> Slice 5 (Doku)
```

Slice 1 und 2 sind unabhängig voneinander und jeweils einzeln nützlich.
