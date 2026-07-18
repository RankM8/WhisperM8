---
status: spezifikation
updated: 2026-07-18
description: Fix-Spezifikation gegen verlorene, nicht wiedergefundene und falsch gebundene Claude-Code-Chats in WhisperM8.
description_long: Verknüpft die bestätigten Findings C04, C05, C07 und C09 mit den realen Encoder-, Indexer-, Projektpfad-, Store-, Hook- und Launch-Pfaden; bewertet ccmanager und agent-deck und legt eine priorisierte, regressionsgesicherte Zielarchitektur für das echte CLI-Host-Modell fest.
---

# Verlorene Chats verhindern — Ursachen- und Fix-Spezifikation

## 0. Entscheidung in einem Satz

WhisperM8 soll zuerst einen persistenten Launch-Intent, atomare Hook-Bindung samt
`transcript_path`, eine globale ID-Lease und einen sichtbaren
`recoveryRequired`-Zustand einführen; `--session-id` soll **nicht als isolierter
Sofortfix**, sondern erst danach capability-gegatet für frische Sessions und
Fork-Ziele aktiviert werden. Diese Reihenfolge entspricht der bereits
verifizierten Roadmap
(`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:203-220`)
und schützt vor der im heutigen Builder dokumentierten früheren
„No conversation found“-Regression
(`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:355-360`).

Der empirisch häufigste Verdrängungs-/Nichtwiederfindungs-Pfad ist derzeit C05:
interne Headless-Aufrufe erzeugten 356 JSONLs und 495 von 2161 Workspace-Zeilen
unter dem Phantomprojekt `/`
(`docs/audit/2026-07-agent-chats-deep-dive/02-findings/claude-integration-fable.md:51-75`).
Der gefährlichste direkte Verlustpfad ist jedoch die Kette „Launch-Marker gesetzt
→ Bindung bleibt leer oder wird gekapert → nächster Start ist fresh → alte
ungebundene Zeile wird später gepruned“
(`WhisperM8/Views/AgentSessionDetailView.swift:633-650`,
`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:337-391`,
`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1117-1133`).

## 1. Begriffe und Zielinvarianten

„Verloren“ umfasst hier nicht nur physisch gelöschte JSONL-Dateien, sondern auch
vorhandene, aber verborgene, verwaiste, falsch gebundene oder temporär nicht
auflösbare Chats; Workflow 3 trennt genau diese Zustände
(`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:224-248`).

Nach dem Fix gelten folgende Invarianten:

1. Eine lokale WhisperM8-Session, eine Claude-Session-ID und eine
   PTY-/Prozessinkarnation bleiben getrennte Identitäten; der persistierte
   Datensatz enthält zusätzlich Config-Root/Profil, aktuelles cwd,
   `transcript_path`, Launch-Modus und Launch-Zeitpunkt
   (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:250-269`).
2. Pro `(configRoot, provider, externalSessionID)` existiert höchstens eine aktive
   Writer-Lease und höchstens eine kanonische Workspace-Zeile; paralleles Resume
   derselben Claude-ID würde laut Workflow-3-Vertrag sonst Nachrichten in dieselbe
   Session interleaven
   (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:208-220`).
3. Disk-Scans entdecken History, entscheiden aber nie allein über Identität.
   Bindungsautorität haben der persistierte Launch-Intent und ein dazu passendes
   Hook-Ereignis; `session_id` und `transcript_path` liegen bereits im geparsten
   Hook-Event vor
   (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`).
4. Ein fehlender oder mehrdeutiger Beleg führt zu `recoveryRequired`, niemals zu
   automatischem Fresh-Start, Rebind auf „neueste Datei“ oder Löschen der lokalen
   Zeile
   (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/plan-review.md:198-204`).
5. Encoded cwd ist nur ein Discovery-Hinweis. Autoritative Anker sind mindestens
   `(configRoot, sessionID, transcriptPath)`; Projektpfad und Worktree sind
   veränderliche Zuordnungen
   (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:216-220`).

## 2. Ursachen-Landkarte: heutige Verlust- und Fehlbindungswege

Die vier Ausgangsbefunde sind adversarial bestätigt: C04, C05, C07 und C09
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:18-23,70-133`).
Die Codeprüfung zeigt zusätzlich zwei bestehende Prunes, die aus
„nicht auffindbar“ tatsächlich „aus WhisperM8 verschwunden“ machen können.

### U1 — CWD-Encoding-Drift und nicht persistierter Transcriptpfad (C04)

| Schritt | Heutiger Pfad | Wirkung | Beleg |
|---|---|---|---|
| U1.1 | `encodeClaudeCwd` lässt alle Swift-`isLetter`/`isNumber`-Zeichen durch und kürzt nicht. | Unicode- und Langpfade zeigen auf einen anderen Projektordner als Claude 2.1.214. | `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:318-332`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:70-79` |
| U1.2 | Der Runtime-Watcher ruft den Locator ausdrücklich mit `globFallback: false` auf. | Trotz bekannter externer ID bleibt der Live-Transcript unsichtbar; Status- und Turn-Ende-Ableitung fehlen. | `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:372-385` |
| U1.3 | Der normale Locator darf per ID suchen, akzeptiert dann aber nur den **ersten** `cwd`-Eintrag und kehrt sofort zurück. | Eine richtige JSONL wird abgelehnt, wenn ihr erster cwd ein Unterordner, alter Pfad oder Worktree ist und erst ein späterer Record passt. | `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:374-419`; `docs/audit/2026-07-agent-chats-deep-dive/02-findings/claude-integration-codex.md:130-167` |
| U1.4 | Hooks parsen `transcript_path`, das Sessionmodell persistiert aber nur `externalSessionID` und `claudeProfileName`. | Nach Neustart fällt WhisperM8 wieder auf cwd-Encoding und globale Suche zurück, obwohl Claude den exakten Pfad geliefert hatte. | `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`; `WhisperM8/Models/AgentChat.swift:225-303` |
| U1.5 | Der Account-Umzug berechnet Quelle und Ziel erneut mit demselben Encoder; bei Nichtfund liefert er `false`, der Caller setzt den Profilstempel trotzdem um. | Die JSONL kann im alten Root bleiben, während der nächste Resume im neuen Root sucht. | `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:423-452`; `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:197-210` |

**Verlustkette:** Encoding-Miss → Hook-/Watcher-Anker geht nach App-Neustart
verloren → Resume-Guard findet die Datei nicht → der Chat ist sichtbar, aber nicht
startbar; bleibt zusätzlich die externe ID ungebunden, greift U4 und später U7
(`WhisperM8/Views/AgentSessionDetailView.swift:545-607`,
`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1117-1133`).

### U2 — Persistente Headless-Junk-Sessions verdrängen echte Chats (C05)

| Schritt | Heutiger Pfad | Wirkung | Beleg |
|---|---|---|---|
| U2.1 | Auto-Namer und Summarizer starten `claude -p … --output-format text` ohne `--no-session-persistence`. | Jeder interne Hilfslauf wird als Claude-Session gespeichert. | `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:132-146`; `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-40` |
| U2.2 | `AgentHeadlessCLI` setzt kein `currentDirectoryURL`. | Der Kindprozess erbt das App-cwd; im belegten Bestand entstand so das Projekt `/`. | `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:28-38`; `docs/audit/2026-07-agent-chats-deep-dive/02-findings/claude-integration-codex.md:56-95` |
| U2.3 | Der Indexer nimmt jede `.jsonl` außer `/subagents/`, sortiert anschließend global nach Aktivität und schneidet auf 1000. | Junge Hilfssessions konkurrieren mit echten Chats um Discovery und Import. | `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:38-50,59-99` |
| U2.4 | Der Merge erzeugt für nicht gematchte Indexeinträge normale geschlossene Workspace-Sessions. | Hilfsläufe werden als sichtbare Chats und als Projekt `/` materialisiert. | `WhisperM8/Services/AgentChats/AgentSessionStore.swift:788-803,871-886` |

`AgentSessionIndexer.swift` selbst enthält Result-/Statistiktypen und den
mtime-/größenbasierten Cache, aber keine Claude-Junk- oder cwd-Filter; der Fix
gehört deshalb in Spawn und `ClaudeSessionIndexer`, nicht in die gemeinsame
Cache-Schicht
(`WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:3-68`).

Dieser Weg löscht eine bereits gebundene Workspace-Zeile nicht direkt, macht ältere
echte Sessions aber schwerer wiederfindbar und vergrößert die Kandidatenmenge für
heuristische Bindung; die gemessenen 495 Junk-Zeilen sind deshalb der häufigste
belegte Alltagsweg zu „mein Chat ist weg/woanders“
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:81-90`).

### U3 — Indexer-Fallback und Hook-Bindung können eine fremde Session kapern (C07)

| Schritt | Heutiger Pfad | Wirkung | Beleg |
|---|---|---|---|
| U3.1 | Nach Launch wartet jeder Tab 0,25 + 0,5 + 1 + 2 + 4 Sekunden und scannt jeweils bis zu 20 neue Sessions. | Zwei fast gleichzeitig gestartete Tabs beobachten dieselbe Kandidatenmenge. | `WhisperM8/Views/AgentSessionDetailView.swift:676-717` |
| U3.2 | `bindLatestIndexedSession` hat nur eine untere Zeitgrenze relativ zu `createdAt`, keine Obergrenze, keine Belegtheitsprüfung und nimmt den jüngsten Kandidaten. | Zwei Tabs können dieselbe externe ID erhalten; der zweite echte Verlauf bleibt verwaist. | `WhisperM8/Services/AgentChats/AgentSessionStore.swift:599-648`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:103-111` |
| U3.3 | Auch die Hook-Bindung prüft nur `old != newID`; sie prüft weder UUID-Format noch Kollision mit einer anderen Workspace-Zeile. | Ein verspätetes oder falsch korreliertes Hook-Event kann eine vorhandene Bindung überschreiben oder eine Doppelbindung erzeugen. | `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-366` |
| U3.4 | Der Merge dedupliziert Index-**Kandidaten** über mehrere Roots, aktualisiert bei vorhandener ID aber nur den ersten Workspace-Treffer und entfernt keine zweite Workspace-Zeile. | „Watcher/Scan zuerst, Hook danach“ kann dauerhaft zwei lokale Rows mit derselben Claude-ID hinterlassen. | `WhisperM8/Services/AgentChats/AgentSessionStore.swift:751-787,805-825`; `docs/audit/2026-07-agent-chats-deep-dive/02-findings/claude-integration-fable.md:115-139` |
| U3.5 | Ein separater Resolver kennt `.ambiguous`, der aktive Bind-Fallback verwendet ihn aber nicht. | Vorhandene Ambiguitätslogik schützt den kritischen Startpfad nicht. | `WhisperM8/Services/AgentChats/ClaudeActiveSessionTracker.swift:27-60`; `WhisperM8/Views/AgentSessionDetailView.swift:727-738` |

### U4 — Verlorene Bindung startet still fresh statt zu resumen (C09)

1. Der erfolgreiche Prozessstart setzt `hasLaunchedInitialPrompt = true`, leert den
   Initialprompt und startet erst danach die asynchrone ID-Bindung
   (`WhisperM8/Views/AgentSessionDetailView.swift:633-650`).
2. Enden alle fünf Bindversuche ohne Treffer, wird kein persistenter Fehler- oder
   Recovery-Zustand gesetzt
   (`WhisperM8/Views/AgentSessionDetailView.swift:684-746`).
3. Beim nächsten Start überspringt der Repair-Pfad Sessions ohne
   `externalSessionID`
   (`WhisperM8/Views/AgentSessionDetailView.swift:537-550`).
4. Der Builder fügt `--resume` nur mit vorhandener ID hinzu, unterdrückt wegen des
   Launch-Markers aber zugleich den Initialprompt; das Ergebnis ist ein leerer
   neuer Chat im alten Tab
   (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:337-391`).

Der vorhandene sichtbare „Transcript fehlt“-Fehler schützt nur **gebundene**
Sessions und schließt diesen Nil-ID-Pfad daher nicht
(`WhisperM8/Views/AgentSessionDetailView.swift:588-607`). C09 ist damit im
aktuellen Code weiterhin erreichbar
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:124-133`).

### U5 — Verschobener oder umbenannter Projektordner

Ein Projekt besitzt genau einen absoluten `path`; die Session referenziert nur die
Projekt-ID und speichert keinen autoritativen Transcriptpfad oder Pfad-Alias
(`WhisperM8/Models/AgentChat.swift:142-200,225-303`). `upsertProject` matcht nur
den kanonisierten aktuellen String und erzeugt bei einem neuen Pfad andernfalls
ein neues Projekt
(`WhisperM8/Services/AgentChats/AgentSessionStore.swift:128-160`).

Nach einem Finder-Move bleiben die Claude-JSONL und ihre frühen `cwd`-Records am
alten encoded cwd gebunden. Der Reader sucht dagegen mit dem neuen Projektpfad;
sein Fallback verwirft die gefundene ID, wenn der erste JSONL-cwd nicht exakt dem
neuen Pfad entspricht
(`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:25-75`,
`WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:403-419`). Der
offizielle Workflow-3-Vergleich klassifiziert dieses Ergebnis als „vorhanden,
aber verwaist“ und fordert explizites Relink statt Gleichsetzung mit Löschung
(`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:216-220,224-239`).

### U6 — Claude-Worktrees werden verborgen oder aktiv aus dem Katalog entfernt

`AgentProjectPath` erkennt ausschließlich Pfade mit dem Literal
`/.claude/worktrees/` und faltet sie auf das Basisrepo zurück; beliebige andere
Git-Worktree-Pfade bleiben dagegen separate Projektpfade
(`WhisperM8/Services/AgentChats/AgentProjectPath.swift:8-20`). Für erkannte
Claude-Worktrees gilt derzeit:

- Der Claude-Indexer verwirft die gesamte Session, sobald der zuerst gelesene cwd
  ein Claude-Worktree ist
  (`WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:119-150`).
- Der Merge ignoriert Worktree-Kandidaten und ruft vor und nach dem Merge einen
  Prune auf
  (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:718-740,788-790,889-890`).
- Dieser Prune löscht alle Sessions, deren Projektpfad unter
  `/.claude/worktrees/` liegt, und danach das Projekt
  (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1103-1115`).

Damit ist „Worktree-Chat wird im Basisprojekt gruppiert“ nicht die implementierte
Semantik; die aktuelle Testsuite schreibt vielmehr bewusst fest, dass solche
Indexer-Sessions übersprungen und bestehende Worktree-Zeilen entfernt werden
(`Tests/WhisperM8Tests/AgentSessionIndexerTests.swift:94-126`,
`Tests/WhisperM8Tests/AgentSessionStoreTests.swift:623-687`).

### U7 — Ungebundene Alt-Zeilen werden automatisch gelöscht

`removeUnresumableClaudeSessions` entfernt nach einer Stunde geschlossene,
automatisch erzeugte Claude-Sessions, wenn Launch-Marker gesetzt, externe ID und
Initialprompt aber leer sind
(`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1117-1133`). Diese
Normalisierung läuft beim Initial-Load und nach jeder Mutation
(`WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:32-40`,
`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1170-1186`). Die Tests
fordern die Löschung ausdrücklich
(`Tests/WhisperM8Tests/AgentSessionStoreTests.swift:690-731`).

U7 ist der endgültige Verstärker von C04/C07/C09: Genau die Zeile, deren reale
Claude-ID wegen Encoding, Hook-Ausfall oder Kaper-Race nie gebunden wurde, kann
aus WhisperM8 verschwinden, obwohl ihre JSONL weiterhin existiert.

## 3. Referenzprojekte: Umgang mit Pfadbindung und Identität

### 3.1 ccmanager

Workflow 3 beschreibt ccmanager als echten PTY-Sessionmanager, der beim
Worktree-Wechsel Claude-Sessiondateien zwischen den beiden encoded-cwd-
Verzeichnissen kopiert
(`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:49-51`).
Das löst die unmittelbare Claude-Eigenschaft, dass Resume an den Projektpfad
gebunden ist, mutiert aber ein inoffizielles Dateilayout; Workflow 3 warnt
ausdrücklich, dass JSONL tolerant und read-only gelesen, nicht als eigene
schreibbare Datenbank behandelt werden soll
(`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:137-167`).

**Übernahme:** expliziter Move-/Worktree-Relink als Produktzustand, nicht als
unsichtbarer Fehler. **Nicht übernehmen:** pauschales Kopieren anhand selbst
berechneter encoded-cwd-Namen; WhisperM8 besitzt bereits einen nachweislich
abweichenden Encoder
(`WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:318-332`).

### 3.2 agent-deck (lokaler Klon)

Der lokale Klon unter
`/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/agent-deck`
definiert Disk-Scans
als nicht autoritativ, erlaubt Bind/Rebind nur aus tmux-Environment, Hook-Payload
oder Hook-Sidecar und bewahrt bei Ablehnung die bestehende ID
(`/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/agent-deck/docs/session-id-lifecycle.md:5-15`). Bei Restart
bleibt die letzte persistierte ID bestehen; ein Disk-Scan darf sie nicht ersetzen
(`/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/agent-deck/docs/session-id-lifecycle.md:22-32`).

Für Start/Restart ist die persistierte Claude-ID die alleinige Quelle. Existiert
ihre JSONL, verwendet agent-deck `--resume <id>`; fehlt sie, verwendet es
`--session-id <dieselbe-id>` und mintet keine neue UUID
(`/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/agent-deck/docs/session-id-lifecycle.md:47-68`). Das ist
genau der Schutz gegen „neueste Datei gewinnt“, den U3 heute verletzt.

Für einen Projekt-Move besitzt der Klon eine explizite Migration von
`~/.claude/projects/<oldSlug>` nach `<newSlug>`, verweigert vorhandene Ziele und
fällt dateisystemübergreifend von Rename auf Copy+Remove zurück
(`/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/agent-deck/internal/session/claude_project_dir.go:27-80`).
Für Accountwechsel ist die neuere Referenz noch konservativer: Quelle auflösen,
copy-only migrieren, Ziel verifizieren und erst dann Metadaten umstellen
(`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:265-283,412-423`).

**Übernahme:** autoritative persistierte ID, Hook-Korrelation, append-only
Bindungsdiagnose, expliziter Relink und Copy+Verify. **Nicht übernehmen:**
Schreibzugriffe in `~/.claude/` als automatischen Standard; die Repo-Leitplanke
erklärt externe Claude-Daten für read-only, und die Umsetzungsübersicht grenzt
schreibende Offline-/Transcript-Operationen ebenfalls aus
(`AGENTS.md:40-49`,
`docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/README.md:48-56`).

### 3.3 Lehre für WhisperM8

ccmanager löst Pfadbindung physisch, agent-deck löst Identitätsbindung primär
logisch und migriert Pfade explizit. Für WhisperM8s natives CLI-Host-Modell ist
die sichere Kombination: exakten Hook-`transcript_path` im eigenen Store
persistieren, CWD-/Worktree-Moves als Alias/Relink modellieren und Claude-Dateien
nur über einen expliziten, bestätigten Copy+Verify-Workflow migrieren
(`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:250-269`,
`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:203-220`).

## 4. Priorisierte Fix-Spezifikation

### P0.1 — Neuen Junk sofort stoppen

1. Jeder interne Claude-Printlauf erhält `--no-session-persistence` und ein
   explizites Scratch-cwd; die CLI beschreibt das Flag ausdrücklich für
   `--print`, und die Roadmap trennt Prävention von Bestandsbereinigung
   (`docs/audit/2026-07-agent-chats-deep-dive/02-findings/claude-integration-codex.md:83-93`,
   `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:158-170`).
2. Auto-Namer/Summarizer reichen den aufgelösten Profilkontext durch; ihre
   heutigen Signaturen kennen nur Provider und Text
   (`WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:120-146`,
   `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:6-40`).
3. Noch kein pauschales `cwd == "/"`-Filtering und keine Bestandslöschung: `/`
   kann ein echtes Projekt sein; die bestehende Roadmap fordert deshalb eine
   getrennte, signaturbasierte Migration
   (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:158-170`).

**Akzeptanz:** Ein Titel- und ein Summary-Lauf liefern weiterhin Inhalt, erzeugen
aber keine importierbare Claude-JSONL; echte manuell gestartete `/`-Sessions
bleiben auffindbar.

### P0.2 — Silent-Fresh und destruktive Prunes schließen

1. `hasLaunchedInitialPrompt == true && externalSessionID == nil` wird vor jedem
   Claude-Launch zu `recoveryRequired`; Builder/PTY starten nicht
   (`WhisperM8/Views/AgentSessionDetailView.swift:537-550`,
   `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:337-391`).
2. Der Recovery-Dialog bietet „erneut scannen“, „per ID/Datei relinken“, „neuen
   Chat bewusst anlegen“ und „abbrechen“. Nur die explizite Neuanlage darf fresh
   starten; Workflow 3 verlangt, einen unspezifischen Resume-Fehler nie in eine
   neue Session umzudeuten
   (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:241-248`).
3. `removeUnresumableClaudeSessions` und
   `removeClaudeWorktreeProjectsAndSessions` werden aus der Normalisierung
   entfernt. Negative Discovery setzt einen Zustand (`missing`,
   `recoveryRequired`, `worktreeDetached`), löscht aber keine Zeile
   (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1103-1133`).

**Akzeptanz:** Ein Crash direkt nach PTY-Start, fünf erfolglose Bindversuche und
ein App-Neustart erhalten denselben Tab; kein Claude-Prozess startet, bis die
Bindung repariert oder ein neuer Chat ausdrücklich bestätigt wurde.

### P0.3 — Autoritativer Launch-Intent und atomare Hook-Bindung

Vor dem Spawn wird synchron und crash-sicher ein Datensatz persistiert:

```text
localSessionID, processIncarnationID, provider, configRoot/profile,
launchMode(start|resume|fork), sourceSessionID?, expectedSessionID?,
launchCwd, launchedAt, state(prepared|spawned|bound|recoveryRequired)
```

`createdAt` der UI-Zeile darf nicht mehr als Launch-Zeitpunkt dienen; der heutige
Fallback tut genau das
(`WhisperM8/Services/AgentChats/AgentSessionStore.swift:623-633`). Das erste zum
Intent passende Hook-Ereignis bindet in **einer** Store-Mutation:

```text
externalSessionID + transcriptPath + currentCwd + configRoot + state=bound
```

Die Payloadfelder existieren bereits
(`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`), werden heute
aber auf `externalSessionID` reduziert
(`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`).
Der Bindevorgang validiert UUID, Prozessinkarnation, Config-Root, Launch-Modus und
globale Belegtheit. Abgewiesene Kandidaten verändern die aktuelle ID nicht und
werden mit Grund append-only protokolliert; dieses Autoritätsmodell ist im
agent-deck-Klon festgeschrieben
(`/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/agent-deck/docs/session-id-lifecycle.md:5-15,34-45`).

**Legacy-Fallback:** Nur für alte CLI-Versionen oder wirklich stumme Hooks; er
nutzt ein beidseitiges Fenster um `launchedAt`, schließt belegte IDs und
Headless-Signaturen aus und bindet nur bei exakt einem Kandidaten. Mehrere
Kandidaten ergeben `recoveryRequired`, wie es der vorhandene Resolver bereits
modelliert
(`WhisperM8/Services/AgentChats/ClaudeActiveSessionTracker.swift:13-60`).

### P0.4 — Globale ID-Invariante und Dubletten-Reparatur

1. Store-Operation `claimExternalSessionID` prüft und schreibt unter demselben
   Workspace-Lock. Ein zweiter aktiver Claim derselben
   `(configRoot, provider, ID)` wird abgelehnt; der heutige Hook-Pfad hat diesen
   Check nicht
   (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-366`).
2. Der Merge arbeitet über einen reinen Plan: vorhandene kanonische Row
   aktualisieren, ungebundene Launch-Row adoptieren oder neue Discovery-Row
   anlegen. Bindet ein Hook später dieselbe Provider-ID, werden Metadaten in die
   lokale Launch-Row übernommen und die reine Discovery-Dublette entfernt; heute
   wird nur der erste ID-Treffer aktualisiert
   (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:805-825`).
3. Persistierte Altdubletten werden konservativ zusammengeführt: manuell
   benannte/archivierte Metadaten, Lineage und UI-Referenzen bleiben erhalten;
   bei Konflikt entsteht Recovery statt automatischer Gewinnerwahl. Workflow 3
   fordert ein transaktionales Dubletten-Merge zwischen Watcher und Hook
   (`docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/README.md:27-35`).

### P1.1 — Transcript-Locator, Encoder und `transcript_path`

1. `transcriptPath` wird Bestandteil des langlebigen Session-Bindings und ist
   der erste Read-/Watch-/Resume-Guard-Anker; die aktuelle Sessionstruktur hat
   dieses Feld nicht
   (`WhisperM8/Models/AgentChat.swift:225-303`).
2. Der schnelle cwd-Encoder wird ASCII-kompatibel und erhält Golden Tests für
   Unicode. Für Langpfade darf die unbekannte/versionsabhängige Hashregel nicht
   geraten werden; nach Miss folgt wiederholt off-main eine flache ID-Suche, deren
   positiver Fund gecacht wird
   (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:70-79`,
   `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:131-131`).
3. Kandidatenprüfung liest bounded **alle** cwd-Werte, nicht nur den ersten, und
   vergleicht Basisrepo, Worktree, reale/standardisierte Pfade und bekannte
   Aliase
   (`WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:403-419`).
4. Watcher und Reader verwenden denselben Locator; `globFallback: false` bleibt
   nur zulässig, wenn bereits ein positiver `transcriptPath`-Cache existiert
   (`WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:368-385`).

### P1.2 — Projekt-Move und Worktrees als Relink, nicht als Prune

1. Projektmetadaten erhalten `pathAliases` beziehungsweise eine explizite
   Relink-Tabelle. Bei fehlendem aktuellem Pfad zeigt die UI „Projekt verschoben?“
   und lässt den neuen Ordner wählen; der heutige `AgentProject` besitzt nur
   einen Pfad
   (`WhisperM8/Models/AgentChat.swift:142-200`).
2. Claude-Worktree-cwd wird als Sessionkontext erhalten und optional unter dem
   Basisrepo gruppiert; Gruppierung darf weder cwd noch Transcriptpfad
   überschreiben. Das heutige Canonicalizing verliert diese Unterscheidung
   (`WhisperM8/Services/AgentChats/AgentProjectPath.swift:8-20`).
3. Der Indexer überspringt Worktree-Sessions nicht mehr. Er indiziert ID,
   Transcriptpfad, ersten und letzten cwd sowie Basisrepo/Worktree-Beziehung;
   der aktuelle Early Return entfällt
   (`WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:119-169`).
4. Eine physische History-Migration ist ein expliziter User-Flow mit
   Dry-Run/Backup beziehungsweise Copy+Verify und bleibt getrennt vom normalen
   Discovery-/Resume-Pfad. Der agent-deck-Vergleich belegt die Reihenfolge
   „Quelle auflösen → kopieren → Ziel verifizieren → Metadaten umstellen“
   (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:265-283`).

### P1.3 — Bestehenden Junk sicher bereinigen

Erst nach P0.1 wird eine signaturbasierte, wiederholbare Migration spezifiziert:
Dry-Run, Backup/Quarantäne, Referenzprüfung gegen Workspace-Bindings und explizite
Wiederherstellung. Weder der Ordner `projects/-` noch cwd `/` allein sind
Löschbelege; die Plan-Verifikation stuft pauschales Löschen der 495 Zeilen selbst
als Datenrisiko ein
(`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/plan-review.md:59-60,106-110`).

### P2 — Soll WhisperM8 `--session-id` selbst vergeben?

**Entscheidung: ja als capability-gegatetes Zielbild, nein als vorgelagerter
Sofortfix.** Die Aktivierung folgt erst nach P0.2–P0.4 und besitzt einen
Rollback-Schalter; genau diese Reihenfolge ist in der Roadmap festgelegt
(`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/plan-review.md:114-118,313-324`).

#### Vorteile im echten CLI-Host-Modell

- Die Claude-ID ist vor dem PTY-Spawn bekannt; Crash zwischen Spawn und Hook kann
  keinen anonymen Chat mehr hinterlassen. agent-deck verwendet eine persistierte
  ID und mintet bei Restart nie unbemerkt eine andere
  (`/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/agent-deck/docs/session-id-lifecycle.md:47-68`).
- Zwei parallele Tabs erhalten verschiedene vorab reservierte UUIDs und brauchen
  für frische Starts keinen „latest indexed session“-Fallback. Nimbalyst setzt
  frische echte CLI-PTYs deterministisch per `--session-id` und wechselt bei
  vorhandener JSONL zu `--resume`
  (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/nimbalyst.md:105-110`).
- Forks können vor dem Spawn eine Child-ID und Lineage persistieren; agent-deck
  zeigt die Flagfolge `--session-id <child> --resume <parent> --fork-session`
  (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:334-364`).
- Das native TUI-Hosting bleibt unverändert: WhisperM8 setzt nur ein offizielles
  CLI-Flag, statt Claude durch SDK oder Eigen-UI zu ersetzen
  (`docs/audit/2026-07-agent-chats-deep-dive/02-findings/claude-integration-codex.md:7-12`).

#### Nachteile und Grenzen

- WhisperM8 hat die Vorvergabe nach realen „No conversation found“-Fehlern
  bewusst entfernt; die aktuelle Testsuite fixiert Weg B ausdrücklich
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:355-360`,
  `Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:67-87`).
- Eine deterministische ID löst weder falschen Config-Root noch verschobenes cwd:
  Claude-Resume bleibt mindestens an `(configRoot, sessionID)` und die lokale
  Pfadablage gebunden
  (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:216-220`).
- Existiert bereits eine JSONL, muss der Launcher `--resume`, nicht erneut
  `--session-id`, verwenden; agent-deck trennt genau diese Fälle
  (`/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/agent-deck/docs/session-id-lifecycle.md:54-68`).
- Fork-Event-Semantik muss weiterhin verifiziert werden. Die
  Schluss-Verifikation empfiehlt bis dahin das zweiphasige agent-deck-Datenmodell
  mit der cmux-Mechanik ohne Vorvergabe
  (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/verifikation-fable.md:26-35,127-144`).

#### Capability- und Rollout-Vertrag

1. Unterstützte Claude-Version per Capability-Probe bestimmen; nicht nur
   Versionsstring vergleichen.
2. In einem Fake-/Scratch-Config-Root testen: frischer Start mit reservierter UUID
   schreibt exakt `<uuid>.jsonl`; Restart wählt `--resume`; Fork bestätigt die
   reservierte Child-ID. Keine Probe darf echte User-History verändern.
3. Hook muss dieselbe ID und einen existierenden `transcript_path` bestätigen,
   bevor der Intent `bound` wird. Mismatch → `recoveryRequired`, Pinning für die
   Installation deaktivieren, keine automatische Fresh-Wiederholung.
4. Alt-CLI oder negative Probe → Weg B mit Launch-Intent, Lease und eindeutiger
   Hook-Bindung; nie Rückfall auf „neueste Datei“.

## 5. Feature-Regressions-Hinweis und Gates

Der Umbau hat hohes Risiko für Discovery, Resume, Import, Multi-Account,
Worktrees, Auto-Naming und Forks; die Roadmap verlangt dafür eine Golden-Matrix
und explizit „Recovery darf nie still fresh starten“
(`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:203-220`).

Besonders wichtig: Mehrere heutige Tests sind **Regression-Oracles des fehlerhaften
Ist-Zustands** und müssen bewusst ersetzt, nicht blind grün gehalten werden:

- Fresh-Start ohne `--session-id` ist festgeschrieben
  (`Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:67-87`).
- Claude-Worktree-Sessions werden absichtlich übersprungen
  (`Tests/WhisperM8Tests/AgentSessionIndexerTests.swift:94-126`).
- Worktree-Projekte/-Sessions und alte ungebundene Chats werden absichtlich
  gelöscht
  (`Tests/WhisperM8Tests/AgentSessionStoreTests.swift:623-731`).

Vor Implementierung sind folgende neue Verhaltensgates anzulegen:

| Gate | Muss beweisen | Betroffene Ist-Pfade |
|---|---|---|
| G1 Parallelstart | Zwei gleichzeitige Tabs desselben Projekts können nie dieselbe ID claimen; Hook- und Scan-Reihenfolge sind vertauschbar. | `WhisperM8/Views/AgentSessionDetailView.swift:676-746`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:599-648`; `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-366` |
| G2 Crash/Restart | Crash vor Hook, nach Hook vor Flush und nach Flush erhält dieselbe lokale/Claude-Bindung; Nil-ID wird Recovery statt Fresh. | `WhisperM8/Views/AgentSessionDetailView.swift:633-650`; `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:337-391` |
| G3 Pfadmatrix | ASCII, Unicode, >200 Zeichen, Unterordner, Finder-Move, `/cd`, interner und externer Worktree finden dieselbe ID ohne falschen Claim. | `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:318-419`; `WhisperM8/Services/AgentChats/AgentProjectPath.swift:8-20` |
| G4 Profile | Main und mehrere `CLAUDE_CONFIG_DIR` mit gleicher cwd/ID werden getrennt; Account-Move ist Copy+Verify und rollt bei Fehler zurück. | `WhisperM8/Models/AgentChat.swift:298-303`; `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:423-480` |
| G5 Junk | Auto-Naming und Summary funktionieren für Claude/Codex, erzeugen aber keine Session; echte `/`-Chats überleben Migration. | `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:132-146`; `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-40`; `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:38-50` |
| G6 Worktrees | Worktree-Chats bleiben sichtbar, resumebar und dem Basisprojekt gruppierbar; kein Normalize-/Merge-Pfad löscht sie. | `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:146-150`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1103-1115` |
| G7 Dubletten | Scan-vor-Hook, Hook-vor-Scan und persistierte Altduplikate enden in genau einer kanonischen Row ohne Verlust manueller Metadaten. | `WhisperM8/Services/AgentChats/AgentSessionStore.swift:751-887` |
| G8 CLI-Versionen | Capability positiv/negativ, `--session-id`-Mismatch und Rollback-Flag halten Start/Resume/Fork funktionsfähig. | `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:337-405`; `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/plan-review.md:247-249` |

Zusätzlich bleibt die volle Swift-Suite Pflicht; echte SwiftUI-/PTY-Interaktion
wird als manuelle Mehrtab-, Quit-/Restart-, Profil- und Worktree-QA geprüft, nicht
durch erfundene UI-Tests ersetzt (`AGENTS.md:17-38`).

## 6. Umsetzungsreihenfolge und Done-Kriterium

1. **P0.1** stoppt weiteren Junk-Zuwachs.
2. **P0.2** verhindert ab sofort Fresh-Start und Katalog-Prunes bei unsicherer
   Identität.
3. **P0.3/P0.4** machen Bindung atomar, eindeutig und diagnostizierbar.
4. **P1.1/P1.2** machen cwd, Moves und Worktrees zu Recovery-/Relink-Fällen statt
   Verlustfällen.
5. **P1.3** bereinigt vorhandenen Junk erst nach Backup/Dry-Run.
6. **P2** aktiviert deterministische `--session-id`-Starts nur hinter erfolgreicher
   Capability-Probe und Rollback-Flag.

„Done“ bedeutet: Kein negativer Scan löscht Metadaten, kein Nil-/Mismatch-Zustand
startet fresh, keine externe ID kann zwei aktive Wrapper besitzen, und jeder
vorhandene Transcriptfund ist über persistierten `transcript_path` oder einen
sichtbaren Relink wieder erreichbar. Diese Zielrichtung entspricht der
verifizierten Roadmap
(`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:203-220`).
