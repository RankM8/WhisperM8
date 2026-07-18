---
status: abgeschlossen
updated: 2026-07-18
description: Adversariale Schluss-Verifikation der sieben Feldvergleichs-Analysen (Workflow 3) — Belegprüfung gegen die Klone, Constraint-Prüfung gegen WhisperM8s CLI-Host-Modell
---

# Schluss-Verifikation (Fable) — Feldvergleichs-Analysen Workflow 3

## Auftrag und Methode

Geprüft wurden die sieben Analysen in diesem Verzeichnis (`agent-deck.md`, `superset.md`, `cmux.md`, `nimbalyst.md`, `claudecodeui.md`, `claude-code-log.md`, `claude-agent-sdk-python.md`) auf zwei adversariale Fragen:

1. **Constraint-Treue:** Sind die als übertragbar empfohlenen Muster mit WhisperM8s CLI-Host-Modell vereinbar (echte Claude-CLI in SwiftTerm-PTYs, kein verkappter SDK-/Eigen-Chat-UI-Umbau)?
2. **Belegtreue:** Ist jede Empfehlung durch echten Code im jeweiligen Klon belegt oder nur plausibel behauptet?

Methode: Stichproben-Verifikation der zitierten `Pfad:Zeile`-Belege direkt in den Klonen unter `scratchpad/vergleich/` (u. a. agent-deck `instance.go:7323-7366`, superset `terminal.ts:1058-1106,1179-1181` + `schema.ts:16-37` + `terminal.adoption.node-test.ts`, cmux `cmux.swift:24018-24045` + `AgentForkArgv.swift:70-86`, sdk-python `types.py:259-271` + `session_mutations.py:429-445` + `subprocess_cli.py:349-361`, claude-code-log `dag.py`, claudecodeui `sessions-watcher.service.ts`). Zusätzlich wurden die Constraint-relevanten Empfehlungen gegen den echten WhisperM8-Code gehalten (`AgentCommandBuilder.swift`, `AgentSessionStatusCoordinator.swift`), was die Analysten auftragsgemäß nicht durften.

**Prozesshinweis:** Die sieben Analysten-Jobs hatten ihre Analysen fertig, konnten die Dateien aber wegen read-only-Sandbox nicht schreiben (`status: partial`). Die vollständigen Reports wurden per Folge-Turn aus den Codex-Threads geborgen und hier abgelegt. Die Datei zum SDK heißt `claude-agent-sdk-python.md` (der Report selbst nennt intern `agent-sdk-python.md` — Kosmetik, kein Inhaltseffekt).

**Gesamturteil vorab:** Die Zitat-Fidelität ist ungewöhnlich hoch — jede Stichprobe (12 von 12) traf wortwörtlich den behaupteten Code, inklusive Kommentartexten. Alle sieben Reports deklarieren „nicht auffindbar" sauber, statt zu erfinden. Kein Report empfiehlt einen SDK-/Eigen-UI-Umbau; die drei SDK-nahen Quellen (nimbalyst SDK-Pfad, claudecodeui, sdk-python) werden korrekt als **Invarianten-Norm**, nicht als Mechanik-Vorlage behandelt. Die Hauptrisiken liegen nicht in erfundenen Belegen, sondern in zwei Empfehlungen, die mit WhisperM8s dokumentierter Betriebserfahrung kollidieren (siehe Querschnitt).

---

## Pro Repo

### agent-deck — tragfähig, mit einem Flag-Vorbehalt

**Trägt (verifiziert):**
- Fork-Erstkommando `exec claude --session-id "<child>" --resume <parent> --fork-session` mit vorab generierter Child-UUID — wörtlich in `internal/session/instance.go:7355-7360` bestätigt, samt `IsForkAwaitingStart`-Sentinel und Fork-Guard im Startpfad (`instance.go:3339-3354`).
- Drei getrennte Identitäten (Instance-ID / ClaudeSessionID / tmux-Socket) inkl. SQLite-Schema — Struktur bestätigt.
- UPSERT statt Snapshot-Löschung, konservative Recovery-Leiter, Accountwechsel als copy-only-Migration, `CLAUDE_CONFIG_DIR`-Hierarchie — Dateien und Testabdeckung (`fork_integration_test.go`, `verify-per-group-claude-config.sh`) existieren.
- Der Report benennt die eigenen Schwächen des Klons ehrlich (keine persistente Fork-Lineage, Account-Lücke im Fork-Kopierpfad, globale JSONL-Restpfade) — das sind echte Negativ-Lektionen, keine Schönfärberei.

**Fragwürdig:**
- Das P0-Fork-Muster setzt die **Vorvergabe der Child-ID per `--session-id`** voraus. Genau diese Vorvergabe hat WhisperM8 nachweislich abgeschafft: `AgentCommandBuilder.swift:353-358` dokumentiert `--session-id` als „Wurzel der No-conversation-found-Fehler" (Weg B: Claude vergibt die ID, Hook/Indexer binden nach). Der Analyst konnte das nicht wissen (durfte WhisperM8 nicht lesen). Das **zweiphasige, persistierte Fork-Datenmodell** (prepared → spawned → identityVerified → committed) trägt trotzdem — nur die konkrete Flag-Kombination darf nicht ungeprüft übernommen werden. Falls WhisperM8 die Child-ID vorab kennen will, muss die `--session-id`-Zuverlässigkeit der aktuellen CLI-Version erst neu verifiziert werden; sonst gilt die cmux-Variante (Child-ID nachträglich binden, siehe unten).

**Constraint:** kein Verstoß. tmux wird ausdrücklich als *nicht* zu übertragende Schicht markiert.

### superset — stärkste Terminalreferenz, teuerste Empfehlung

**Trägt (verifiziert):**
- Adoption statt Doppel-Spawn nach Host-Neustart (`terminal.ts:1058-1106`, wörtlich) und „Initialkommando nach Adoption nie erneut senden" (`initialCommandQueued: isAdopted`, `terminal.ts:1179-1181`, wörtlich). End-to-End-Test existiert (`terminal.adoption.node-test.ts`: gleicher Shell-PID nach simuliertem Host-Restart).
- Persistente `terminalId`-Zeile in SQLite (`schema.ts:16-37`, wörtlich), Zwei-Pass-Reaper mit Schonfrist, `null`-vs-`[]`-Semantik beim Daemon-Listing.
- Statusentkopplung „SessionStart ≠ working", Hook-Workspace serverseitig herleiten — deckt sich mit WhisperM8s bereits umgesetzter Hook-SoT-Entscheidung und bestätigt sie extern.
- Sehr sauberer Scope-Schnitt: Supersets ACP-Chat-Pfad wird explizit als Constraint-Verletzung ausgegrenzt und nicht als Beleg verwendet. Ebenso ehrlich: kein Claude-JSONL-Reader, kein Fork-Modell, keine Claude-Account-Isolation im Klon gefunden.

**Fragwürdig:**
- **P1 „Langlebiger PTY-Broker als separater macOS-Prozess":** belegt und constraint-konform (die echte CLI bleibt die Runtime), aber de facto ein Neubau des Terminal-Stacks — SwiftTerms `LocalProcessTerminalView` besitzt Prozess und PTY heute in-process; ein Broker hieße eigenen Daemon, Socket-Protokoll, Replay, Backpressure und eine Feed-basierte TerminalView. Das ist kein „Muster übernehmen", sondern ein Architekturprojekt und steht in Spannung zur gerade bewusst gewählten leichteren Terminal-Snapshot-Strategie (Commits f448e02/a26d29f). Als Fernziel legitim, als P1 zu hoch gegriffen.
- P2 (FD-Handoff) stuft der Report selbst korrekt als nachrangig ein.

**Constraint:** kein Verstoß; vorbildliche Abgrenzung.

### cmux — wertvollster Einzelbefund des gesamten Feldes

**Trägt (verifiziert):**
- **Fork-SessionStart-Guard:** Der Code-Kommentar in `CLI/cmux.swift:24018-24038` ist wörtlich bestätigt: „`claude --resume <parent> --fork-session` fires SessionStart with the PARENT session id — the forked session id is only minted at the first UserPromptSubmit" (inkl. Issue-Referenz #5908); der Guard (`isForkSessionLaunch` → Store bleibt unangetastet) ist implementiert. Fork-Argv `["claude", "--resume", <id>, "--fork-session"]` in `AgentForkArgv.swift:80-86` wörtlich bestätigt — **ohne** `--session-id`-Vorvergabe, also kompatibel mit WhisperM8s Weg B.
- **Direkte WhisperM8-Relevanz (eigener Verifikationsbefund):** WhisperM8s `bindExternalSessionID` (`AgentSessionStatusCoordinator.swift:345-367`) bindet beim `SessionStart`-Hook jede gemeldete ID ohne Fork-Guard. Trifft cmuxs CLI-Verhaltensbeschreibung zu, bindet ein WhisperM8-Fork die **Eltern-ID** an den Fork-Chat; jeder spätere Resume öffnet dann den Elternzweig — exakt Workflow-3-Risiko 2. Das ist der konkreteste verwertbare Befund aller sieben Analysen.
- Hook-first/OSC-Fallback, PID+Prozessstartzeit gegen PID-Reuse, Teardown-Reihenfolge, „nur eindeutiger JSONL-Kandidat" bei Recovery — Dateien und Strukturen existieren.

**Fragwürdig:**
- Die Verhaltensbehauptung „SessionStart meldet die Parent-ID" ist im Klon nur durch Kommentar, Guard-Implementierung und Issue-Link belegt — nicht durch eine hier reproduzierbare CLI-Beobachtung. Vor einem WhisperM8-Fix einmal real gegen die installierte CLI-Version reproduzieren (Fork starten, Hook-Event-File ansehen). Die Kohärenz von Guard + Issue + separatem `forkParentFallback`-Downgrade macht die Behauptung aber sehr glaubwürdig.
- Das Ghostty-Submodul ist im Klon leer; die OSC-Parser-Aussagen sind darum nur bis zur libghostty-Grenze belegt (der Report deklariert das selbst).
- Die Portal-/Lease-/Reparenting-Architektur ist als Ganzes nicht kopierenswert (der Report sagt das selbst: „nicht 1:1 zu kopieren") — übertragbar ist nur das Prinzip Surface-ID ≠ Runtime-Generation ≠ SwiftUI-Host.

**Constraint:** kein Verstoß — cmux ist selbst CLI-Host, die nächste Verwandtschaft zum WhisperM8-Modell im Feld.

### nimbalyst — korrekt als Doppel-Referenz behandelt, ein Flag-Vorbehalt

**Trägt:**
- Resume-Mismatch als harter Abbruch statt stillem Neuanfang; „session expired" **nur** bei autoritativem Provider-Fehler (`no conversation found` u. ä.), `history.jsonl`-Miss ausdrücklich nur Soft-Signal (dokumentierte Korrektur einer früheren Fehldiagnose) — genau die Fehlerklassifikation, die WhisperM8s eigene „No conversation found"-Geschichte gebraucht hätte. Die vorgeschlagene Zustandstabelle (`resume_target_missing_local` ≠ `session_not_found_authoritative` ≠ `auth_mismatch` …) ist die beste Einzeltabelle des Feldes.
- Import-Lücke „Scan kennt das App↔Provider-Mapping, Sync upsertet nur nach App-ID → Dublette" inklusive TODO-Beleg — starke **Negativ**referenz für WhisperM8s Indexer-Merge.
- Fokus-Gating gegen Restart-Stampedes (alle wiederhergestellten Fenster starteten gleichzeitig CLI-Prozesse) — für WhisperM8s Multi-Window-Architektur unmittelbar relevant.
- Subscribe-before-restore mit Sequenznummern, TUI-Snapshot statt Raw-Replay — passt zur Terminal-Snapshot-Roadmap.

**Fragwürdig:**
- Die stärksten Identitäts-Muster stammen aus dem **SDK-Pfad** (`ProviderSessionManager`, `forkSession=true` via Agent SDK). Der Report kennzeichnet das durchgehend korrekt als Invarianten-Quelle und empfiehlt keinen SDK-Einsatz — aber jeder Weiterverwender muss wissen: Für den echten CLI-Pfad hat Nimbalyst selbst **kein** Fork-Muster (kein `--fork-session` im Spawn-Builder, bestätigt), d. h. der „beste aktive GUI-Kandidat" liefert für das Kernproblem Fork/CLI gerade *keinen* Beleg.
- P0 „Fresh: Start mit `--session-id <cliSessionId>`" kollidiert — wie bei agent-deck — mit WhisperM8s dokumentierter Weg-B-Entscheidung. Nimbalyst pinnt frische Sessions per `--session-id`; WhisperM8 hat genau das als Fehlerquelle entfernt. Nicht ungeprüft übernehmen.

**Constraint:** kein Verstoß; die Trennung „SDK = Norm, CLI-Pfad = Mechanik" ist sauber durchgehalten.

### claudecodeui — schmal, aber die drei Muster tragen

**Trägt (verifiziert):**
- Zwei-Spalten-Identität `session_id` / `provider_session_id` mit dokumentiertem Schema; transaktionales Dubletten-Merge (`assignProviderSessionId` löscht die watcher-erzeugte native Zeile und übernimmt Pfad/Name in die App-Zeile) — genau das Race „JSONL-Watcher zuerst, Hook-Bindung danach", das WhisperM8 zwischen `AgentSessionIndexer` und Hook-Bridge ebenfalls hat.
- Subagent-Filter beim Scan (`subagents/`-Pfadsegment ausschließen, sonst überschreibt die Subagent-JSONL den `jsonl_path` der Hauptsession) — Watcher-Datei und Pfade bestätigt; direkt prüfenswert für WhisperM8s Indexer.
- `birthtime`-statt-`mtime`-Falle beim inkrementellen Startscan als Warnung.

**Fragwürdig:**
- Bewusst schmaler Scope (kein Fork, kein PTY, kein Multi-Account) — der Report deklariert das im ersten Absatz; als Einzelquelle wäre er zu dünn, als Ergänzung ist er präzise.
- CloudCLI ist eine SDK-Runtime mit Eigen-Chat-UI; der Report sagt ausdrücklich „nicht WhisperM8s Zielarchitektur" und überträgt nur Identitäts-/Discovery-Muster. Korrekt.

**Constraint:** kein Verstoß dank expliziter Abgrenzung.

### claude-code-log — solide Parser-Referenz, Empfehlungen teils Eigenleistung

**Trägt (verifiziert):**
- `uuid`/`parentUuid`-DAG mit Reparatur (fehlender Parent → Kind wird Root; Zyklen inkl. Self-Loops werden gebrochen; Dedup mit `dropped→survivor`-Umschreibung) — `dag.py` bestätigt inklusive der Kommentare zu `_SPAWN_TOOL_NAMES` und Passthrough-Strukturknoten.
- `compact_boundary` als Multi-Root **derselben** `sessionId` — wichtige Semantik für WhisperM8s `ClaudeTranscriptReader` (Compact ist kein Sessionwechsel).
- Tool-Korrelation über `(session_id, tool_use_id)` statt Nachbarschaft; Last-Write-Wins als benannte Defektkante.
- Regressionstest gegen zyklische Parent-Ketten (früher Endlosschleifen/Speicherexplosion) existiert.

**Fragwürdig:**
- Die P0/P1-Fixture-Kataloge und der Vorschlag „inkrementelles Einlesen ab Byte-Offset + UUID-Metadatenindex" sind **Analysten-Eigenleistung**, nicht Klon-Beleg — als Empfehlung brauchbar, aber nicht mit „so macht es die Referenz" verwechseln (der Klon hält den DAG vollständig im Speicher, was der Report selbst als Grenze nennt).
- Kein Bezug zu Prozess/PTY/Accounts — der Report grenzt das korrekt aus.

**Constraint:** irrelevant (reiner Parser), kein Konflikt.

### claude-agent-sdk-python — beste Norm-Quelle, ein sofort umsetzbarer Quick-Win

**Trägt (verifiziert):**
- Normative Übergangstabelle Neu/Resume/Continue/Fork; `fork_session`-Semantik wörtlich bestätigt (`types.py:1943-1945`).
- **Flag-Injection-Schutz:** `--resume=<uuid>` in equals-Form statt zwei Tokens, mit begründendem Kommentar (CLI deklariert `--resume` mit optionalem Wert; dash-führender Wert würde als eigenes Flag geparst) — wörtlich bestätigt (`subprocess_cli.py:352-361`). **Eigener Verifikationsbefund:** WhisperM8 übergibt heute `["--resume", resumeSessionID]` als zwei Tokens, und `bindExternalSessionID` UUID-validiert die aus Hook-Events übernommene ID nicht. Beides zusammen ist ein kleiner, sofort umsetzbarer Härtungs-Fix (equals-Form + UUID-Validierung beim Binden).
- Offline-Fork mit vollständiger UUID-Neuschreibung und `forkedFrom.sessionId/messageUuid`-Herkunft — wörtlich bestätigt (`session_mutations.py:429-445`). Vorsicht bei Übernahme: Das ist eine *schreibende* Operation auf Transcript-Daten; für WhisperM8 gilt `~/.claude/` als read-only — nur das `forkedFrom`-**Lesen** ist direkt übertragbar.
- Branch-bewusstes Lesen (Haupt-Blatt ohne `isSidechain`/`teamName`/`isMeta`, dann `parentUuid` rückwärts) statt „letzte Zeile gewinnt".
- Die Lücke „`SessionStart` fehlt in der öffentlichen `HookEvent`-Union" ist wörtlich bestätigt (`types.py:259-271`) — der Schluss, dass sich Resume-vs-Fork nicht aus SDK-Hook-Typen ableiten lässt und WhisperM8 den Übergang aus eigenem Spawn-Intent + bestätigter ID bestimmen muss, ist korrekt gezogen.

**Fragwürdig:**
- „Lokale JSONL als Primärkopie mit reparierbarem Mirror" beschreibt den SessionStore-Mechanismus des SDK — für WhisperM8 nur als **Analogie** tragfähig (eigener Katalog/`agent-index-cache` = Sekundärindex mit Repair-Pfad), nicht als zu bauende Store-Schnittstelle.
- Pipes/`stream-json` statt PTY: Der Report grenzt selbst präzise ab, was *nicht* als PTY-Beleg gilt — diese Liste sollte jeder Leser ernst nehmen, bevor er Transport-Muster überträgt.

**Constraint:** kein Verstoß — das SDK wird als Norm für Identität/Übergänge zitiert, ausdrücklich nicht als Runtime-Empfehlung.

---

## Querschnitts-Spannungen (adversarial)

1. **`--session-id`-Vorvergabe (agent-deck-Fork, nimbalyst-Fresh) vs. WhisperM8s Weg B.** Zwei Reports empfehlen Muster, die auf `--session-id`-Pinning beruhen. WhisperM8 hat Pinning nach realen „No conversation found"-Fehlern bewusst entfernt (`AgentCommandBuilder.swift:353-358`). cmux und sdk-python zeigen, dass Fork auch **ohne** Vorvergabe sauber geht (`--resume <parent> --fork-session` + nachträgliche, verifizierte Child-Bindung). Empfehlung der Verifikation: Fork-Datenmodell aus agent-deck übernehmen, Flag-Mechanik aus cmux — nicht umgekehrt.
2. **SessionStart ist beim Fork nicht vertrauenswürdig.** cmux (Guard + Issue), sdk-python (SessionStart fehlt in der Hook-Union) und WhisperM8s eigener Code (`bindExternalSessionID` ohne Fork-Guard) ergeben zusammen den konkretesten Handlungsbedarf des gesamten Vergleichs. Vor dem Fix: Verhalten einmal gegen die installierte CLI reproduzieren.
3. **Broker-Architekturen sind constraint-konform, aber kein „Muster".** Superset (Daemon) und agent-deck (tmux) beziehen ihre Neustart-Robustheit aus einer externen Prozess-Schicht. Beide Reports markieren das korrekt als nicht zwingend übertragbar. Wer daraus ein WhisperM8-Arbeitspaket macht, plant einen Terminal-Stack-Neubau — das ist eine Grundsatzentscheidung, keine Übernahme.
4. **Konvergenz als Qualitätssignal:** Alle sieben Quellen landen unabhängig bei derselben Kernstruktur (Wrapper-ID ≠ Claude-UUID ≠ Prozessinkarnation, + Account-Scope; Übergänge geplant → bestätigt). Diese Konvergenz ist selbst der stärkste Beleg dafür, dass das Muster trägt.

---

## Abschluss

### Die 3 tragfähigsten Muster

1. **Fork als zweiphasiger, verifizierter Identitätsübergang mit Parent-ID-Guard.** Belegt in cmux (Guard-Code + dokumentiertes CLI-Verhalten), agent-deck (persistierte Child-ID + Fork-Erstkommando) und sdk-python (Übergangstabelle, `forkedFrom`). Deckt einen wahrscheinlichen realen WhisperM8-Bug auf: `bindExternalSessionID` würde beim Fork die Eltern-ID binden. Höchste Priorität, kleinster Fix: SessionStart-Events während eines Fork-Launches nicht binden; Child-ID erst über UserPromptSubmit/JSONL bestätigen.
2. **Drei getrennte Identitäten plus Account-Scope** (Wrapper-/Chat-ID, Claude-UUID, PTY-/Prozessinkarnation; Lookups nie ohne Account-/Config-Root-Filter). In allen sieben Quellen unabhängig belegt (agent-deck-Schema, superset-`terminalId`, cmux-Surface-Generation, claudecodeui-Zwei-Spalten-Modell, sdk-python-`SessionKey`). WhisperM8 hat die Grundtrennung bereits, aber ohne durchgängigen Account-Scope und ohne Prozessgenerations-Bindung von Hook-Events.
3. **Autoritative Fehlerklassifikation und Reconciliation statt Heuristik:** „session expired" nur bei eindeutigem CLI-Fehler (nimbalyst, verifizierte Selbstkorrektur), Zwei-Pass-Schonfrist vor destruktivem Aufräumen (superset-Reaper), nur eindeutige JSONL-Kandidaten binden (cmux, agent-deck), Katalog beim Start gegen die read-only-JSONL-Wahrheit reconciliieren mit `missing`/`discovered` statt Löschen (sdk-python). — Dazu als Quick-Win aus sdk-python: `--resume=<uuid>` in equals-Form plus UUID-Validierung gebundener IDs.

### Die fragwürdigsten Muster

1. **`--session-id`-Vorvergabe** (agent-deck-Fork-Kommando, nimbalyst-Fresh-Start): im jeweiligen Klon sauber belegt, aber frontal gegen WhisperM8s dokumentierte Betriebserfahrung; Übernahme nur nach erneuter Verifikation gegen die aktuelle CLI-Version, sonst cmux-Variante ohne Pinning.
2. **Externer PTY-Broker als P1** (superset): belegt, constraint-konform, aber faktisch ein Terminal-Stack-Neubau in Spannung zur gewählten Terminal-Snapshot-Strategie — als Grundsatzentscheidung behandeln, nicht als übertragbares Muster.
3. **Verhaltens- statt Code-Belege:** cmuxs „Fork-SessionStart meldet die Parent-ID" ist nur über Fremdcode-Kommentar/Issue belegt (vor Fix reproduzieren); die SDK-Pfad-Mechaniken aus nimbalyst/claudecodeui sind ausschließlich als Invarianten übertragbar; claude-code-logs Fixture-/Inkremental-Empfehlungen sind Analysten-Eigenleistung ohne Klon-Beleg.
