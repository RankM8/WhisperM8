# Plan: Claude-Account-Routing — aktives Profil als Default + kontrollierter Kontowechsel

**Stand:** 2026-08-22 · **Status:** Entwurf, wartet auf Freigabe · **Scope:** Agent Chats (Claude), CLI `whisperm8 chats`, Workspace-Store
**Vorgänger:** `claude-account-switcher.md` (Slice 1–4 umgesetzt 2026-07-12) — dieser Plan ist dessen Slice 5–7.

## Ausgangslage

Slice 4 des Vorgängerplans hat zugesagt: *„Session-Stempel `claudeProfileName` … beim Erstellen aus dem
aktiven Profil gesetzt."* Diese Zusage gilt heute nur für den GUI-Weg. Der später entstandene
CLI-Namespace `whisperm8 chats` (2026-08) hat einen zweiten Erstellungspfad eingeführt, der den
Stempel nicht setzt — eine stille Regression durch Feature-Entwicklung, kein Fehler im
Account-Konzept selbst.

### Befund 1 — der CLI-Pfad landet immer auf main

`AgentChatLaunchService.openChatViaControl` (Zeilen 88–91) ruft `store.createSession` ohne
`claudeProfileName` auf. Der Parameter-Default ist `nil` (`AgentSessionStore.swift:545`), und `nil`
bedeutet per Definition main. Beim Launch liefert `ClaudeAccountProfiles.environmentOverrides(nil)`
ein leeres Dictionary (Zeile 181) → kein `CLAUDE_CONFIG_DIR` → `claude` nimmt `~/.claude`.

`activeProfileNameOrNil()` wird workspace-weit an **genau einer** Stelle als Stempel verwendet:
`AgentChatsView+SessionLifecycle.swift:68`.

Verschärfend: `LoginShellEnvironment.processEnvironment()` löscht ein geerbtes `CLAUDE_CONFIG_DIR`
bewusst und korrekt (Zeile 118). Es gibt daher **keinerlei** Fallback — auch das Profil des
aufrufenden Jarvis-Chats vererbt sich nicht.

**Beleg aus dem Feld** (Audit-Log `chats-audit.jsonl`, `method: "new"` gegen den Workspace-Stempel):

| Zeit | Audit-Eintrag | Stempel |
|---|---|---|
| 22.08. 13:21 | `ListM8/Handbuch-Videos ListM8: Delta-Analyse…` | **main** |
| 22.08. 14:35 | `ListM8/Shadcn-Migration: Entscheidungsvorlage…` | **main** |
| 19.08. 15:25 | `whisperm8/Neue Session` (Doc System) | **main** |

`.active` steht auf `ai3`. Seit 19.08. entstanden 22 Claude-Sessions: 13× ai3 (GUI), 5× PowerUser2,
4× main — und die vier main-Sessions decken sich exakt mit CLI-`new`-Aufrufen.

### Befund 2 — die Adoption ist profilblind

`AgentSessionStore.swift:947` baut den Adoptions-Pool über `AdoptionKey(provider, projectID)` ohne
Profilbezug. Eine ungebundene Session kann nach reiner Zeitnähe ein Transcript aus *irgendeinem*
Profil-Root adoptieren (`takeAdoptionCandidate`, Zeile 854) und übernimmt dessen Stempel (Zeile
1090). Das erklärt, warum die Fehlzuordnung nicht deterministisch wirkt.

### Befund 3 — Background-Agenten sind strukturell auf main

`SupervisorJobReader` liest hart `~/.claude/jobs` (Zeile 36); `BackgroundAgentLifecycle` spawnt
`logs`/`stop` mit leerem Environment (Zeilen 140, 172); `dispatchBackgroundAgent`
(`+BackgroundAgents.swift:47`) setzt keinen Stempel. Ein Profil-Env allein beim Spawn erzeugt einen
zweiten Supervisor-Daemon, dessen Jobs die App weder lesen noch stoppen könnte. Bleibt bewusst
außerhalb dieses Plans (siehe Slice 7).

## Zielverhalten

1. Wird beim Erstellen eines Claude-Chats **kein** Profil angegeben, gilt der in den WhisperM8-
   Settings gewählte aktive Account — für GUI, CLI und Jarvis gleichermaßen.
2. Eine **ausdrückliche** Profilangabe schlägt den Default, wird aber hart validiert: unbekanntes
   oder nicht eingeloggtes Profil bricht die Erstellung ab, statt still auf main zu fallen.
3. Der Default wird **zur Startzeit eingefroren**. Ein späterer Wechsel des aktiven Accounts hängt
   bestehende Chats nicht um — sonst bräche deren Resume.
4. Bestehende Chats lassen sich einzeln oder in Auswahl **kontrolliert** auf einen anderen Account
   umstellen und dort fortsetzen.

## Vorab-Entscheidungen

### E1 — Wo lebt der Default? (Empfehlung: im Store)

| Option | Für | Gegen |
|---|---|---|
| **A: nur Call-Site fixen** (`openChatViaControl`) | zwei Zeilen, minimales Risiko | reproduziert die Ursache — der nächste Erstellungspfad vergisst es wieder |
| **B: Default im Store** (`createSession`), Auswahl als Enum | strukturell unmöglich zu vergessen; eine Wahrheit für alle Pfade | Signaturänderung an allen Call-Sites; Store liest Datei |

**Empfehlung: B.** Genau das Vergessen *ist* die Ursache. Konkret ein
`ClaudeProfileSelection { case activeDefault, explicit(String?) }` mit Default `.activeDefault`
statt des heutigen `claudeProfileName: String? = nil` — `nil` kann sonst nicht zwischen „nicht
angegeben" und „ausdrücklich main" unterscheiden. Auflösung passiert **vor** dem `mutate`-Aufruf
(Store-Lock verträgt kein Datei-I/O, siehe CLAUDE.md) über einen injizierbaren Resolver
(`var activeClaudeProfileResolver: () -> String?`) — Projektkonvention: DI per Closure.

### E2 — Wandern `file-history` / `session-env` mit? (Empfehlung: nein, vorerst)

Verifiziert in `~/.claude-profiles/ai3/`: pro Session-UUID existieren `file-history/<uuid>/`
(versionierte Datei-Snapshots, z. B. `1da267364cd5e7ce@v1`) und `session-env/<uuid>/` — beide
**außerhalb** von `projects/`, beide bleiben beim heutigen `moveTranscript` zurück.

Der Gesprächsverlauf ist davon nicht betroffen (die JSONL ist alleinige Quelle). Verloren geht die
Rücksprung-/Checkpoint-Fähigkeit der bewegten Session. Beide Verzeichnisse sind undokumentierte
Claude-Code-Interna mit versionsabhängigem Format. **Empfehlung: zurücklassen und den Verlust im
Bestätigungsdialog benennen**, statt auf Verdacht Verzeichnisse zu verschieben, deren Semantik wir
nicht kennen. Nachrüstbar (Slice 7) nach Verifikation.

### E3 — Bulk-Atomarität (Empfehlung: Journal statt Auto-Rollback)

Dateisystem-Moves über mehrere Verzeichnisse kennen keine Transaktion. Ein Auto-Rollback nach halber
Strecke kann selbst scheitern und hinterlässt einen schlechteren Zustand als ein sauber berichteter
Teilerfolg. **Empfehlung: Teilerfolge stehen lassen**, jede bewegte Session mit Quell-/Zielprofil
journalisieren und daraus eine explizite „Rückgängig"-Aktion anbieten. Weil `moveTranscript`
symmetrisch ist, ist das Zurückrollen derselbe Aufruf mit vertauschten Argumenten — kein Sonderpfad.

---

## Slice 5 — Aktives Profil als Default für neue Chats

**Ziel:** Befund 1 schließen. Kleinster Schnitt mit unmittelbarem Nutzen.

### Änderungen (in dieser Reihenfolge)

1. **`Services/AgentChats/AgentSessionStore.swift`** — `ClaudeProfileSelection` einführen,
   `createSession` löst `.activeDefault` vor der Mutation über den injizierbaren Resolver auf;
   `provider == .codex` bleibt immer `nil`.
2. **`Views/AgentChatsView+SessionLifecycle.swift`** — Call-Sites auf das Enum umstellen
   (`createSession` Zeile 57 → `.activeDefault`; `forkSession` Zeile 95 → `.explicit(source.claudeProfileName)`).
3. **`Views/AgentChatsView+BackgroundAgents.swift`** — Zeile 47 explizit auf `.explicit(nil)` mit
   Kommentar auf Befund 3. Verhalten unverändert, aber die Absicht steht im Code statt im Zufall.
4. **`Services/AgentChats/AgentChatLaunchService.swift`** — `openChatViaControl` bekommt einen
   `account: String?`-Parameter; leer/`nil` → `.activeDefault`, sonst Validierung
   (`ClaudeAccountProfiles().profile(named:)`: existiert + `isLoggedIn`) → bei Fehlschlag
   `ControlLaunchError`, **kein** Fallback. Rückgabewert um `profileName` erweitern.
5. **`Services/AgentChats/AgentControlRequestHandler.swift`** — `sessionNew` liest
   `params["account"]`, reicht durch, gibt das Profil in der Antwort zurück; Audit-Eintrag um das
   Profil erweitern.
6. **`CLI/ChatsLiveCommands.swift`** — `ChatsNewCommand`: `--account <name>`. Argument-Parsing in
   eine pure `ChatsNewArguments`-Struktur ziehen (heute in `run` eingebettet und dadurch nicht
   isoliert testbar). Erfolgsmeldung nennt das Profil.
7. **Doku** — `docs/features/agent-chats-cli.md` (kennt den Begriff „Account" derzeit mit keinem
   Wort) und `WhisperM8/Resources/whisperm8-chats-skill.md`: Default-Regel + `--account`.

### Tests

| Datei | Fall |
|---|---|
| `AgentSessionStoreTests` | `.activeDefault` + Resolver `"ai3"` → Stempel `ai3`; `.explicit(nil)` → `nil` trotz aktivem Profil; Codex → immer `nil`; Fork erbt Quelle |
| `ChatsControlTests` | `session.new` mit `account` = unbekanntes Profil → `notFound`, **keine** Session angelegt; mit gültigem Profil → Stempel korrekt, Profil in der Antwort |
| `ChatsCLITests` | `ChatsNewArguments`-Parsing: `--account` mit/ohne Wert, unbekannte Flags |
| `ClaudeAccountProfilesTests` | bestehende 14 müssen grün bleiben |

### Abnahmekriterien

- `whisperm8 chats new --project whisperm8 --title "ZZ-Profiltest"` bei aktivem `ai3` erzeugt eine
  Session, deren `chats show … --json` `claudeProfileName: "ai3"` meldet.
- Nach dem ersten Turn liegt die JSONL unter `~/.claude-profiles/ai3/projects/<encoded-cwd>/` und
  **nicht** unter `~/.claude/projects/`. (Platte schlägt Stempel — dies ist das eigentliche Kriterium.)
- `/status` im neuen Chat zeigt die E-Mail des ai3-Accounts.
- `--account nichtexistent` bricht mit klarer Meldung ab; kein Tab, keine Session, kein Prozess.
- Schließen und erneut öffnen erzeugt **keine** `claude_profile_stamp_mismatch`-Warnung im
  `log stream` (`AgentCommandBuilder.swift:599`).
- Bei aktivem `main` ist das Verhalten bitgleich zu heute.

### Risiko & Rollback

- **Risiko:** Ein defektes aktives Profil (Verzeichnis gelöscht, ausgeloggt) könnte neue Chats
  blockieren. **Gegenmaßnahme:** `activeProfileName()` validiert die Verzeichnisexistenz bereits und
  fällt auf main zurück; nur die *explizite* Angabe bricht hart ab.
- **Kill-Switch:** `defaults write com.whisperm8.app chatsNewProfileDefaultEnabled -bool NO` stellt
  das alte Verhalten (immer main) her, ohne Deployment.
- **Rollback:** Ein Commit, revertierbar. Bereits erzeugte Sessions behalten ihren Stempel — der ist
  korrekt und braucht keine Migration.

---

## Slice 6 — Kontrollierter Kontowechsel bestehender Chats

**Ziel:** Auswahl von Chats auf einen anderen Account umstellen und dort fortsetzen.
**Voraussetzung: Slice 5.** Ohne den Default legt Jarvis parallel neue main-Chats nach.

Die Mechanik existiert bereits: `ClaudeAccountProfiles.moveTranscript` (Zeile 407) sucht die Quelle
über alle Roots, prüft Kollisionen vor jeder Bewegung, nimmt den Subagent-Ordner mit und rollt den
Haupt-Move zurück, wenn dessen Verschiebung scheitert. `moveSession`
(`+SessionLifecycle.swift:194`) nutzt das für Einzel-Chats inklusive Running-Guard. Die
Mehrfachauswahl-Infrastruktur (`AgentChatsView+BulkActions`, `actionGroup`/`bulkLabel`) ist da.
**Neu ist nur die Orchestrierung.**

### Semantik nach Chat-Zustand

| Zustand | Verhalten | Begründung |
|---|---|---|
| **läuft** | blockieren, nicht stoppen | Der Prozess hält seine Registry unter `sessions/<pid>.json` im alten Config-Dir und schreibt weiter in die alte JSONL |
| **offen, nicht laufend** | erlauben, Tab bleibt offen | kein Prozess, kein Risiko |
| **geschlossen** | erlauben | Regelfall |
| **archiviert** | auf ausdrückliche Auswahl ja; **nicht** in „alle" einschließen | erzeugt sonst Scan-Last ohne Nutzen |
| **Background-Agent** | ausschließen | `jobs/` ist hart auf main (Befund 3); `canMoveToAccount` filtert bereits über `effectiveKind == .chat` |
| **Terminal / Agent View** | ausschließen | kein Claude-Transcript |
| **ohne `externalSessionID`** | nur umstempeln | `moveTranscript` gibt `false` zurück; bereits korrekt gelöst |

### Änderungen (in dieser Reihenfolge)

1. **Neu: `Services/AgentChats/AccountMovePlanner.swift`** — pur und unit-testbar. Nimmt Sessions +
   Zielprofil, liefert `movable` / `skipped(reason)`. Gründe: `running`, `backgroundAgent`,
   `notAChat`, `targetNotLoggedIn`, `targetTranscriptExists`. Kein I/O außer den bereits geladenen
   Profilen. *Dieser Baustein ist der Kern des Slices — alles andere ist Verdrahtung.*
2. **Neu: `Services/AgentChats/AccountMoveJournal.swift`** — schreibt pro bewegter Session
   `(sessionID, from, to, timestamp)` nach `Application Support/WhisperM8/account-moves.jsonl`;
   liefert den letzten Batch für „Rückgängig".
3. **`Services/AgentChats/AgentScanCoordinator.swift`** — `pauseScans()`/`resumeScans()` (der
   30s-Cooldown liefert den Hebel). **Zwingend:** Der `AgentDirectoryEventMonitor` feuert bei jeder
   bewegten Datei einen Scan; läuft der mitten in der Schleife, sieht der Merge Sessions in
   wechselnden Roots und `applyIndexedScan(closingStaleExcluding:)` könnte nicht-aktive Sessions als
   verwaist schließen.
4. **`Views/AgentChatsView+SessionLifecycle.swift`** — `moveSelection(forID:toProfileNamed:)` neben
   dem bestehenden `moveSession`; `moveToAccountMenu` auf `actionGroup` verallgemeinern (Label über
   `bulkLabel`, wie die übrigen Bulk-Aktionen).
5. **Neu: Bestätigungsdialog** — zeigt die Aufteilung aus dem Planner (N verschiebbar, M
   übersprungen **mit Grund je Session**), benennt den Kontingentwechsel und den Verlust von
   Checkpoints/Datei-Historie (E2). Das ist die Stelle, an der die Entscheidung wirklich fällt.
6. **Ausführung** — Scan pausiert, Fortschritt, Abbruch möglich (beendet **nach** der aktuellen
   Session, nie mitten im zweistufigen Move), Ergebnisbericht, genau ein Scan danach.

### Tests

| Datei | Fall |
|---|---|
| `AccountMovePlannerTests` (neu) | gemischte Auswahl → exakte Aufteilung je Grund; leere Auswahl; Ziel == Quelle → No-op |
| `ClaudeAccountProfilesTests` | Kollision im Ziel bewegt **nichts**; Subagent-Ordner-Fehler rollt die JSONL zurück (Temp-Root + `FileManager`) |
| `AccountMoveJournalTests` (neu) | Batch schreiben/lesen; Rückgängig erzeugt die exakt inverse Bewegungsliste |
| `AgentSessionStoreTests` | `setClaudeSessionProfile` über mehrere Sessions bleibt eine Mutation/Publikation |

Nicht unit-testbar (SwiftUI/Dialog/Fortschritt) → manuelle QA, wie beim Tab-Drag dokumentiert.

### Abnahmekriterien

- Auswahl aus 5 Chats (davon 1 laufend, 1 Background) → Dialog zeigt „3 verschiebbar, 2
  übersprungen" mit Gründen; nach Bestätigung sind exakt 3 umgezogen.
- `find` über **alle** Roots nach einer bewegten Session-ID liefert genau **einen** Treffer (schließt
  die Doppel-Adoption aus, vor der `moveTranscript` im Kommentar warnt).
- Bewegter Chat startet im Zielaccount, `log stream` zeigt keine `claude_profile_stamp_mismatch`.
- Nach einem Bulk über ≥20 Chats steht **keine** Session unerwartet auf `closed` (Symptom eines
  durchgerutschten Stale-Scans).
- „Rückgängig" direkt nach einem Bulk stellt Stempel und Ablageorte exakt wieder her.
- Laufender Chat wird nie stillschweigend gestoppt.

### Risiko & Rollback

| Risiko | Gegenmaßnahme |
|---|---|
| Scan-Race während des Bulk schließt Sessions | Scan-Pause (Punkt 3) — der einzige zwingende Baustein neben dem Planner |
| Session-ID-Kollision im Ziel | Planner prüft **vorab**, `moveTranscript` prüft nochmals vor der Bewegung; nichts wird halb bewegt |
| Teilerfolg nach Abbruch/Fehler | Journal + „Rückgängig"; Teilerfolge bleiben bewusst stehen (E3) |
| Ziel ausgeloggt → Sackgasse | Planner filtert über `isLoggedIn`; Menüeintrag bleibt disabled |
| Reindizierungskosten | Index-Cache-Key ist pfadbasiert (`AgentSessionIndexer.cacheKey`) → jede bewegte Datei wird neu geparst. Bei >50 MB-Transcripts und dreistelligen Zahlen spürbar → Fortschritt anzeigen, UI nicht stumm blockieren |
| Verlust von Checkpoints überrascht | im Bestätigungsdialog benannt (E2) |

- **Kill-Switch:** `defaults write com.whisperm8.app accountBulkMoveEnabled -bool NO` blendet die
  Bulk-Aktion aus; der Einzel-Move bleibt unberührt.
- **Rollback:** Journal-basiertes „Rückgängig" im laufenden Betrieb; im Notfall manuell per `mv`
  zwischen den `projects/`-Roots, danach ein Scan — die Selbstheilung
  (`AgentSessionStore.swift:1057`) zieht die Stempel nach.

---

## Slice 7 — Ausbaustufen (nicht Teil der Freigabe)

Nach Nutzen sortiert, jede Stufe einzeln entscheidbar:

1. **CLI-Zugang** `whisperm8 chats move --ref … --account X` bzw. `--project Y --all` — macht den
   Wechsel für Jarvis selbst verfügbar. Muss **dieselben** Guards nutzen; ein CLI-Weg an den
   Prüfungen vorbei wäre Befund 1 in neuer Form.
2. **Profilbewusste Adoption** (Befund 2): `AdoptionKey` um das Profil erweitern bzw. Kandidaten mit
   abweichendem Stempel ausschließen. Unabhängig von Slice 5/6 testbar in `AgentSessionStoreTests`.
3. **„Alle Chats eines Projekts umstellen"** als eigener Einstieg mit Vorschau — erst wenn Slice 6
   im Alltag getragen hat.
4. **`file-history`/`session-env` mitverschieben** — nur nach empirischer Verifikation, dass die
   Verzeichnisse rein UUID-adressiert und account-neutral sind (E2).
5. **Background-Agenten profilbewusst** — `SupervisorJobReader` + `BackgroundAgentLifecycle` +
   `SupervisorRosterReader` **gemeinsam**, sonst zerreißt der Job-Bezug. Eigenes Paket, auch
   unabhängig vom Kontowechsel wertvoll.
6. **Automatischer Wechsel bei Limit-Erschöpfung** — `ClaudeAccountLimitPinger` hat die Daten, aber
   ein automatischer Move kollidiert frontal mit dem Running-Guard. Frühestens ganz zuletzt, und
   dann als Vorschlag an den Nutzer statt als Automatik.

## Reihenfolge und Freigabe

```
Slice 5 (Default)  ──┬──> Slice 6 (Bulk-Wechsel) ──> Slice 7.1 (CLI move)
                     └──> Slice 7.2 (Adoption)   [unabhängig, jederzeit]
```

Slice 5 ist eigenständig nützlich und sollte auch dann umgesetzt werden, wenn Slice 6 nicht kommt.
Slice 6 ohne Slice 5 wäre Sisyphusarbeit.
