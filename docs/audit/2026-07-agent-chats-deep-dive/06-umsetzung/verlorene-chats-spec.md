---
status: spezifikation-g0-g2
updated: 2026-07-20
description: Recovery-Spezifikation mit demselben capability-gegatteten Identitäts-, Claim- und Laufzeit-Transitionsvertrag wie das kanonische Identitätsmodell.
description_long: Verknüpft C04/C05/C07/C09 mit dem kanonischen G0–G2-Vertrag, fail-closed Recovery, read-only Relink, per-Launch Korrelation und capability-gegatteter Provider-ID-Vergabe im echten CLI-Host-Modell.
---

# Verlorene Chats verhindern — Ursachen- und Fix-Spezifikation

> **Status:** Revision nach G0–G2, Entscheidungen E1/E2/E5 eingearbeitet. Live-Probe (Paket B) blockiert — Capability bleibt fail-closed `hostAssignedUnsupported` (siehe [fork-hook-live-probe.md](../04-verifikation/fork-hook-live-probe.md)).

## 0. Entscheidung in einem Satz

WhisperM8 führt zuerst einen persistenten Launch-Intent, per-Launch Hook-Kanäle, atomare Claims samt `transcript_path`, eine globale ID-Lease und einen sichtbaren `recoveryRequired`-Zustand ein. **Weg B ist die Baseline** (`hostAssignedUnsupported`): Claude vergibt Fresh-/Fork-Ziel-IDs, WhisperM8 bindet streng geprüft nachträglich. Vorab reservierte `--session-id`-Ziele sind ausschließlich im Zustand `hostAssignedVerified` zulässig, nachdem die installierte CLI Fresh, Resume und Fork in einer isolierten Live-Probe vollständig bestätigt hat. Diese Reihenfolge entspricht der bereits verifizierten Roadmap
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
2. Pro `(provider, canonicalConfigRoot, externalSessionID)` existiert höchstens eine aktive
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
5. Encoded cwd ist nur ein Discovery-Hinweis. Autoritative Anker sind der `ProviderSessionKey(provider, canonicalConfigRoot, externalSessionID)` plus `transcriptPath`; Projektpfad und Worktree sind veränderliche Zuordnungen
   (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:216-220`).


## 2. Gemeinsamer Soll-Vertrag

### 2.2 Gemeinsamer normativer Vertrag G0–G2

Dieser Abschnitt ist wortgleich in `identitaetsmodell-spec.md` und `verlorene-chats-spec.md` zu führen. Bei Abweichungen ist dieses Dokument kanonisch; eine abweichende Implementierung ist nicht freigegeben.

#### Gescope Provider-Identität und Datenhoheit

Der kanonische Provider-Key lautet mindestens:

```text
ProviderSessionKey(provider, canonicalConfigRoot, externalSessionID)
```

Eine nackte Provider-UUID ist nie global eindeutig. `canonicalConfigRoot` wird aus dem beim Launch gespeicherten erwarteten Root gebildet: absolute standardisierte Pfadkomponenten, Auflösung vorhandener Symlinks und Entfernen redundanter `.`-/`..`-Komponenten. Ein Hook-`transcript_path` bestätigt den Root nur, wenn sein ebenfalls standardisierter und symlink-aufgelöster Pfad komponentenweise exakt unter `<canonicalConfigRoot>/projects/<encoded-cwd>/` liegt und auf `<externalSessionID>.jsonl` endet. Es wird nicht per String-Präfix verglichen. Passt der Pfad zu keinem oder zu mehreren bekannten Roots, lautet das Claim-Ergebnis `ambiguous`; der Root wird nie allein aus dem String des Transcriptpfads geraten. Bei noch nicht existierenden Pfadkomponenten wird der längste existierende Vorfahr aufgelöst und der Rest komponentenweise angehängt.

`~/.claude` und `~/.codex` sind für Identitäts-, Recovery- und Relink-Flows strikt read-only. Korrekturen, Aliase, Claims, Lineage und Recovery-Entscheidungen werden ausschließlich in WhisperM8-eigenen Daten persistiert. Die bestehenden Account-Umzugs- und Theme-Sync-Pfade sind keine allgemeine Ausnahme: Sie bleiben separat autorisierte, eng begrenzte User-Aktionen mit eigener Sicherung beziehungsweise eigenem Settings-Vertrag und dürfen von diesem Recovery-Vertrag nicht auf weitere Schreiboperationen in Provider-Daten ausgeweitet werden.

#### Capability-gegattete Launch-State-Machine

Der Capability-Zustand wird installationsbezogen in WhisperM8-eigenen Daten zusammen mit CLI-Pfad, CLI-Version, Probezeitpunkt und Probeergebnis persistiert. Unbekannt, veraltet, fehlgeschlagen oder per Rollback deaktiviert bedeutet `hostAssignedUnsupported`. Nur eine vollständig bestandene isolierte Live-Probe für Fresh, Resume **und** Fork darf `hostAssignedVerified` setzen. Ein Upgrade oder Wechsel des aufgelösten CLI-Binaries invalidiert die Verifikation.

| Capability-Zustand | Fall | Vor Spawn persistiert | Launch-Intent und CLI-Aufruf | Erwartete Provider-ID | Fehlerzustand |
|---|---|---|---|---|---|
| `hostAssignedUnsupported` | Fresh | `intent=fresh`, `expectedProviderKey=nil`, neue `launchID`/Generation, erwarteter Config-Root, cwd, `launchedAt` | Fresh ohne `--session-id`; Claude vergibt die ID | Genau ein neuer, ungeclaimter Key im erwarteten Root; Bindung erst durch aktuellen Hook oder schwächere eindeutige JSONL-Recovery | Kein oder mehr als ein Kandidat, belegter Key, Root-/Zeit-Mismatch oder Altgeneration → `recoveryRequired`; keine Row-Mutation |
| `hostAssignedUnsupported` | Resume | `intent=resume(sourceKey)`, `expectedProviderKey=sourceKey`, neue `launchID`/Generation, erwarteter Config-Root, cwd, `launchedAt` | `--resume <sourceKey.externalSessionID>` im Root des Source-Keys | Exakt `sourceKey` | Abweichende ID, falscher Root/Pfad oder Mehrdeutigkeit → `recoveryRequired`; kein stilles Rebind/Fresh |
| `hostAssignedUnsupported` | Fork | neuer lokaler Chat mit `intent=fork(parentKey)`, `expectedProviderKey=nil`, Parent-/Root-Lineage, neue `launchID`/Generation, Root, cwd, `launchedAt` | `--resume <parentKey.externalSessionID> --fork-session` ohne `--session-id` | Genau ein neuer, ungeclaimter Child-Key im Root des Parents; niemals `parentKey` | Parent-ID, kein/ein mehrfacher Child-Kandidat, Kollision, Root-/Zeit-Mismatch oder Altgeneration → `recoveryRequired`; keine Row-Mutation |
| `hostAssignedVerified` | Fresh | wie oben, zusätzlich vorab reservierter `expectedProviderKey=targetKey` | `--session-id <targetKey.externalSessionID>` im erwarteten Root | Exakt `targetKey` in Hook und Transcriptpfad | Mismatch/fehlende Bestätigung → `recoveryRequired`, Verifikation für dieses CLI-Binary deaktivieren; kein automatischer Retry als Fresh |
| `hostAssignedVerified` | Resume | `intent=resume(sourceKey)`, `expectedProviderKey=sourceKey`, neue `launchID`/Generation, Root, cwd, `launchedAt` | `--resume <sourceKey.externalSessionID>`; keine erneute Vorvergabe | Exakt `sourceKey` | Abweichung, Kollision, Root-/Pfad-Mismatch oder Altgeneration → `recoveryRequired`; keine Row-Mutation |
| `hostAssignedVerified` | Fork | neuer lokaler Chat mit `intent=fork(parentKey)`, vorab reserviertem `expectedProviderKey=childKey`, Parent-/Root-Lineage, neuer `launchID`/Generation, Root, cwd, `launchedAt` | Nur nach positiver Fork-Probe: `--session-id <childKey.externalSessionID> --resume <parentKey.externalSessionID> --fork-session` | Exakt `childKey`; Hook und Transcriptpfad müssen übereinstimmen | Parent-/andere ID, fehlende Datei, Kollision oder Altgeneration → `recoveryRequired`, Verifikation deaktivieren; Parent bleibt unverändert |

Die Launch-Transition lautet in beiden Capability-Zuständen `prepared → spawned → bindingPending → healthy | recoveryRequired`. `prepared` wird vor jedem Spawn synchron persistiert; `healthy` ist nur über `claimed` oder `alreadyOwnedBySameRow` erreichbar.

`hostAssignedVerified` ist damit kein zukünftiger Default, sondern ein reversibler, evidenzgebundener Capability-Zustand. Die Live-Probe aus Paket B entscheidet, ob er für die installierte CLI überhaupt erreichbar ist.

#### Per-Launch-Korrelation und Bridge-Envelope

Für jeden Spawn werden App-eigene, nicht wiederverwendete Pfade erzeugt:

```text
<WhisperM8-AppSupport>/ClaudeHooks/<chatID>/<launchID>/settings.json
<WhisperM8-AppSupport>/ClaudeHooks/<chatID>/<launchID>/events.jsonl
```

Vor Aktivierung einer neuen Generation muss die Bridge den FD/File-Watcher der vorherigen Generation schließen, deren Pfade als `superseded` markieren und die neue Generation samt Launch-Intent synchron persistieren. Erst danach werden Settings geschrieben und der PTY gestartet. Alte Dateien dürfen diagnostisch aufbewahrt werden, aber nie erneut aktive Eingangsquelle werden.

Jedes gelesene Provider-Ereignis wird vor der Auswertung in folgendes App-eigenes Envelope gelegt:

```text
BridgeEnvelope(
  chatID, launchID, generation, expectedConfigRoot, launchedAt,
  eventPath, observedAt, providerPayload
)
```

`SessionStart.source` wird aus dem Payload als typisierte Eingangsgröße `startup | resume | branch | rewind | clear | compact | unknown(rawValue)` geparst und zusammen mit dem Envelope weitergereicht; es darf nicht mehr verworfen werden. Nur `(chatID, launchID, generation)` der aktuell persistierten Generation darf claimen. Ein später Event einer alten Datei erhält Diagnose `staleGeneration` mit Pfad und beobachteter Provider-ID, verändert aber weder Binding, Recovery-State noch UI-Auswahl.

#### Atomare Claim-API

Hook, Indexer-Recovery und Control-CLI verwenden dieselbe Store-Operation unter demselben Workspace-Lock:

```text
claimProviderSession(
  chatID, launchID, generation, intent, candidateKey,
  transcriptPath, currentCwd, source, evidence
) -> ClaimOutcome
```

| `ClaimOutcome` | Bedeutung | Darf mutieren? |
|---|---|---|
| `claimed` | Kandidat erfüllt Generation, Intent, Root/Pfad, Zeitfenster, Erwartungs-ID und globale Eindeutigkeit | Ja: Key, Transcriptpfad, cwd, Source, Lineage und Recovery-State atomar committen |
| `alreadyOwnedBySameRow` | Derselbe kanonische Key gehört bereits derselben Row; das Event ist idempotent | Ja: ausschließlich neuere bestätigte Metadaten derselben Generation aktualisieren |
| `collision` | Der kanonische Key gehört einer anderen kanonischen Row oder Writer-Lease | Nein |
| `ambiguous` | Mehrere plausible Rows/Kandidaten/Roots oder widersprüchliche Evidenz | Nein |
| `staleGeneration` | `launchID`/Generation ist nicht mehr aktuell | Nein |

Nur `claimed` und `alreadyOwnedBySameRow` dürfen eine Row verändern. `collision` und `ambiguous` lassen Binding, Lineage, Transcriptpfad und sämtliche Chat-Row-Felder unverändert; der Aufrufer persistiert stattdessen einen separaten App-eigenen `RecoveryCase` und zeigt „prüfen“ an. `staleGeneration` bleibt reine Diagnose. Die User-Entscheidung im Recovery-Flow ruft anschließend dieselbe Claim-API mit einem explizit ausgewählten Kandidaten und neuer Revision auf, statt Felder direkt zu überschreiben.

Indexer-/JSONL-Evidenz ist gegenüber einem passenden aktuellen Hook schwächer. Sie darf keine Parent-Lineage erfinden: Nachrichtenfelder wie `parentUuid` sind ohne bestätigten Provider-Vertrag kein Branch-Parent-Beleg. Zulässig sind nur kanonischer Root, neue Dateiidentität, beidseitiges Fenster um `launchedAt`, cwd-Kompatibilität, gescopte Neuheit und globale Unbelegtheit. Diese Evidenz wird als `recoveryEvidence` persistiert und darf nur bei genau einem Kandidaten claimen; sonst folgt `ambiguous`.

#### Recovery-State-Machine

Recovery wird als eigener, App-eigener Sidecar `RecoveryCase(chatID, state, reason, candidateKeys, owningLaunchID, revision)` persistiert. Er verändert bei fehlgeschlagenen Claims keine Chat-Row. Unbekannte spätere Enum-Werte werden als `recoveryRequired(reason=unknownState)` erhalten, nicht verworfen. `healthy` bedeutet, dass kein aktiver RecoveryCase besteht; abgeschlossene Fälle dürfen als Diagnosehistorie erhalten bleiben.

| Zustand | Persistenz und zulässige Übergänge | UI-/Retry-Vertrag |
|---|---|---|
| `healthy` | kein aktiver `RecoveryCase`; bestätigtes Row-Binding bleibt unverändert. Vor Spawn entsteht ein separater LaunchRecord mit `bindingPending`; negativer Locator kann einen Case `missing` oder `worktreeDetached` erzeugen | normal sichtbar und startbar |
| `bindingPending` | im LaunchRecord mit aktueller `launchID`/Generation und Intent persistiert; nur `claimed`/`alreadyOwnedBySameRow` schließt den Case zu `healthy`, Unsicherheit/Crash/Timeout erzeugt `recoveryRequired` | sichtbar als „wird verbunden“; kein zweiter Fresh-Start |
| `recoveryRequired(reason, candidates)` | eigener Sidecar bleibt bis explizitem erfolgreichen Rescan/Relink/User-Claim bestehen; Archivieren der Chat-Row ändert den Case nicht | Sidebar und Archiv zeigen dauerhaft „prüfen“; Retry-Owner ist genau ein Recovery-Coordinator pro Chat, User wählt bei Mehrdeutigkeit |
| `missing(lastKnownKey, transcriptPath)` | separater Case nur nach bestätigtem Nichtfund; negative Scans löschen und verändern kein Row-Binding | sichtbar „Verlauf fehlt“; Rescan/Relink möglich, Launch gesperrt |
| `worktreeDetached(lastKnownKey, worktreeCwd)` | separater Case bei nicht auflösbarem Worktree/Basisrepo; Provider-History und Row bleiben unverändert | sichtbar „Worktree getrennt“; Ordnerwahl/Relink in App-Daten, kein Provider-Schreibzugriff |

„Neuen Chat bewusst anlegen“ erzeugt eine **neue lokale Row mit neuer Launchgeneration**; es setzt eine problematische Row nicht still auf Fresh zurück. Archivierte problematische Rows und ihre RecoveryCases bleiben auffindbar. Automatische Retries dürfen nur den RecoveryCase und seine Evidenzrevision aktualisieren, aber weder User-Auswahl simulieren noch einen mehrdeutigen Kandidaten claimen.

#### Chats-CLI-Revisionsvertrag

`whisperm8 chats new` darf sofort die lokale `chatID` als `--ref` zurückgeben. `wait --ref` hält jedoch keinen Workspace-Snapshot über mehrere Polls: Jeder Poll liest mindestens die aktuelle Workspace-Revision und löst die Row anhand der lokalen Referenz neu auf. Sobald Binding oder Recovery-State persistiert wird, erhöht der Single-Writer die Revision. Eine geänderte Revision erzwingt Re-Load von `externalSessionID`, `transcriptPath`, Generation und Recovery-State; erst die neu geladene Row wird an den Status-Probe übergeben. Datei-/Socket-Events dürfen Polls aufwecken, ersetzen aber nicht den Re-Load. So kann `new → wait --ref` ein nach dem Start eintreffendes Binding beobachten.

### 2.3 Vollständige Laufzeit-Übergangsmatrix

`activeBranchChange` ist eine Identitätstransition innerhalb derselben PTY-Inkarnation. Sie ist ausdrücklich verschieden von `inPlaceCompact`, das den Key nicht ändert, und von `processEnded`, das nur die Launchgeneration beendet. Die Row bleibt lokale UI-Identität; Provider-Branches werden separat über Binding-Historie auffindbar gehalten.

| Operation | Alter → neuer Provider-Key | `SessionStart.source` und Evidenz | Transcriptpfad / cwd / Lineage | Row, Tab, Unread, Auto-Naming | Negativ-/Mehrdeutigkeitsfall |
|---|---|---|---|---|---|
| `/branch` | `oldKey → newKey`, `newKey != oldKey`, gleicher Provider/Root | `branch` muss geparst sein und aus aktueller Generation kommen; neuer Key wird atomar geclaimt | neuer kanonischer Pfad passend zu `newKey`; cwd als Metadatum; `parentKey=oldKey`, `rootKey` geerbt | dieselbe lokale Row und derselbe Tab werden aktiv umgebunden; alter Key bleibt in Binding-Historie, kein Auto-Tab; Unread erst bei neuem Inhalt im nicht sichtbaren Tab; manueller Name bleibt, automatischer Name darf nach erstem neuen Inhalt einmal neu bewertet werden | fehlende Source, gleiche ID trotz Branch, mehrere Kandidaten oder Kollision → `recoveryRequired`; alter Key bleibt aktiv |
| `/rewind` | `oldKey → newKey`, `newKey != oldKey`, gleicher Provider/Root | `rewind` muss geparst sein; Branchpunkt ist nur aus autoritativem Hook/Provider-Feld oder expliziter User-Aktion ableitbar | neuer Pfad passend zu `newKey`; cwd aktualisierbar; `parentKey=oldKey` als erzeugende Branch-Lineage, optionaler Branchpunkt nur bei autoritativem Beleg | gleiche Row/Tab-Regeln wie `/branch`; kein Unread nur durch Transition; manuelle Namen bleiben | JSONL-Nachrichtenverkettung allein darf keinen Branchpunkt/Parent beweisen; fehlender eindeutiger neuer Key → `recoveryRequired` |
| `/clear` | `oldKey → oldKey` | `clear` wird geparst; Ereignis derselben Generation und exakt desselben Keys | derselbe kanonische Binding-Pfad; cwd darf aktualisiert werden; Lineage unverändert | `inPlaceClear`, gleiche Row/Tab; kein Transition-Unread; kein Auto-Rename, manuelle und automatische Titel bleiben | abweichende ID oder Root/Pfad → nicht als Clear akzeptieren, sondern `recoveryRequired`; kein Rebind |
| `/resume` | `oldKey → targetKey`; gleich bedeutet In-Place-Bestätigung, verschieden bedeutet `activeBranchChange` | `resume` wird geparst; `targetKey` muss explizit vom Provider-Ereignis derselben Generation und dem kanonischen Pfad bestätigt sein | Pfad/cwd des Targets; kein Parent-/Child-Verhältnis zwischen `oldKey` und `targetKey`, sondern Navigationshistorie | dieselbe Row/Tab wird auf Target umgebunden; alter Key bleibt auffindbar; Unread erst bei neuem Hintergrundinhalt; manueller Name bleibt, automatischer Titel darf nach erstem Target-Inhalt neu bewertet werden | nackte UUID ohne eindeutigen Root, belegter Target-Key oder mehrere Targets → `recoveryRequired`; alter Key bleibt aktiv |
| `/compact` | `oldKey → oldKey` | `compact` wird geparst; `SessionEnd(reason=compact)` plus folgender Start ist `inPlaceCompact`, kein Prozessende | Binding und Lineage unverändert; Pfad nur als Metadatenbestätigung desselben Keys, cwd aktualisierbar | gleiche Row/Tab; kein Unread und kein Auto-Rename durch Compact; Status darf kurz wechseln | abweichende ID, Root oder konkurrierende Generation → `recoveryRequired`; niemals `activeBranchChange` daraus raten |
| Prozessende/Crash | `oldKey → oldKey` | kein `SessionStart`; Terminierungsgrund schließt die aktuelle Generation | letzter bestätigter Pfad/cwd/Lineage bleiben erhalten | Row/Tab bleiben; kein Auto-Rename; laufender Status endet, Recovery richtet sich nach `bindingPending` vs. `healthy` | späte Events der geschlossenen Generation → `staleGeneration`; Crash in `bindingPending` → `recoveryRequired`, nicht Fresh |

Bei `/branch`, `/rewind` oder abweichendem `/resume` wird der bisherige Provider-Branch nicht gelöscht. Er bleibt als Branch-/Binding-Historie in WhisperM8-eigenen Daten auffindbar und kann bei explizitem Öffnen eine eigene Discovery-Row erhalten; die Transition selbst öffnet keinen zusätzlichen Tab. Auto-Naming arbeitet nie auf einem bloßen Transition-Event, sondern erst auf bestätigtem inhaltlichem Output des neuen Keys.

#### Testverträge `source`/Transitionen

Die folgenden IDs sind normative Oracle-Platzhalter; jeder Test kontrolliert zusätzlich, dass Binding, Lineage, Transcriptpfad und Chat-Row im Negativfall unverändert bleiben.

| Test-ID | Positiv-Oracle | Negativ-Oracle |
|---|---|---|
| `S-01` | Der Parser bildet `startup | resume | branch | rewind | clear | compact` jeweils auf den gleichnamigen typisierten Wert ab. | Jeder andere String bleibt verlustfrei als `unknown(rawValue)` erhalten; kein Default auf `startup`. |
| `S-02` | Ein Event der aktuellen `(chatID, launchID, generation)` erreicht Claim-/Transitionslogik. | Ein Event einer alten Generation liefert `staleGeneration`, erzeugt nur Diagnose und erreicht keine Row-Mutation. |
| `S-03` | `/branch` mit `source=branch`, eindeutigem neuem Key und passendem Pfad führt zu `activeBranchChange`. | Fehlende/falsche Source, gleicher Key, Kollision oder mehrere Kandidaten führt zum separaten `RecoveryCase`; alter Key bleibt aktiv. |
| `S-04` | `/rewind` mit `source=rewind` und eindeutigem neuem Key übernimmt nur autoritativ belegte Lineage. | Aus JSONL-Nachrichtenverkettung abgeleitete Lineage oder uneindeutiger neuer Key führt zu Recovery ohne Claim. |
| `S-05` | `/clear` mit `source=clear` bestätigt denselben Key als `inPlaceClear`. | Abweichender Key, Root oder Transcriptpfad wird nicht als Clear/Rebind akzeptiert. |
| `S-06` | `/resume` bestätigt exakt den expliziten Target-Key; bei abweichendem Target entsteht der definierte `activeBranchChange`. | Nackte UUID ohne eindeutigen Root, belegter Target-Key oder mehrere Targets führt zu Recovery; alter Key bleibt aktiv. |
| `S-07` | `/compact` mit `source=compact` und gleichem Key bleibt `inPlaceCompact`, ohne Unread oder Auto-Rename. | Abweichende ID, Root oder konkurrierende Generation wird weder als Compact noch als Branchwechsel geraten. |
| `S-08` | Reguläres Prozessende schließt ausschließlich die aktuelle Launchgeneration und erhält das letzte bestätigte Binding. | Spätes Event der geschlossenen Generation ist `staleGeneration`; Crash in `bindingPending` führt zu Recovery statt Fresh. |

Diese Oracles sind in der G4-Revision der `test-specs-welle0-1.md` als `A02-S01` bis `A02-S08` materialisiert; die alte A02-Direktbindung ist dort durch capability-/claim-spezifische Oracles ersetzt.

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

Die repo-eigene Analyse des lokalen agent-deck-Klons beschreibt eine konservative Rebinding-Hierarchie: terminale Hook-Phasen binden nicht, Kandidaten ohne passende Konversationsdaten werden abgelehnt und der vorherige Zustand bleibt erhalten. Persistierte Instanzen und Provider-/Prozessidentität bleiben getrennt (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:49-61,148-194`).

Für Start/Restart ist die persistierte Claude-ID der Anker. Existiert belastbare Konversationshistorie, verwendet agent-deck `--resume <id>`; andernfalls startet es dieselbe vorbereitete ID über `--session-id`, statt für den Restart eine neue UUID aus „neueste Datei“ abzuleiten (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:115-142`). Das ist genau der Schutz gegen „neueste Datei gewinnt“, den U3 heute verletzt.

Für einen Projekt-Move besitzt der Klon eine explizite Migration von
`~/.claude/projects/<oldSlug>` nach `<newSlug>`, verweigert vorhandene Ziele und
fällt dateisystemübergreifend von Rename auf Copy+Remove zurück
(`/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/agent-deck/internal/session/claude_project_dir.go:27-80`).
Für Accountwechsel ist die neuere Referenz noch konservativer: Quelle auflösen,
copy-only migrieren, Ziel verifizieren und erst dann Metadaten umstellen
(`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:265-283,412-423`).

**Übernahme nach E2:** autoritative persistierte ID, Hook-Korrelation, append-only Bindungsdiagnose und expliziter **logischer** Relink in WhisperM8-eigenen Daten. **Entfällt nach E2 / nicht freigegeben:** Copy+Verify, Rename, Copy+Remove oder andere Schreibzugriffe in `~/.claude`/`~/.codex` als Identitäts-, Recovery- oder Relink-Maßnahme. Die Vergleichsimplementierung bleibt Evidenz, aber kein Produktvertrag. Die bestehenden Account-Umzugs- und Theme-Sync-Ausnahmen bleiben davon getrennt und dürfen nicht verallgemeinert werden (`AGENTS.md:40-49`, `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/README.md:48-56`).

### 3.3 Lehre für WhisperM8

ccmanager löst Pfadbindung physisch, agent-deck löst Identitätsbindung primär logisch und migriert Pfade explizit. Für WhisperM8s natives CLI-Host-Modell gilt nach E2 ausschließlich der logische Anteil: exakten Hook-`transcript_path` im eigenen Store persistieren und CWD-/Worktree-Moves als Alias/Relink in WhisperM8-eigenen Daten modellieren. **Entfällt nach E2 / nicht freigegeben:** Claude-Dateien per Copy+Verify, Rename oder Move zu migrieren. Provider-History bleibt read-only (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:250-269`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:203-220`).

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

Vor dem Spawn wird synchron und crash-sicher exakt der in Abschnitt 2.2 definierte Launchdatensatz persistiert:

```text
chatID, launchID, generation, provider, expectedConfigRoot,
intent(fresh|resume(sourceKey)|fork(parentKey)), expectedProviderKey?,
launchCwd, launchedAt, settingsPath, eventPath,
recoveryState=bindingPending
```

`createdAt` der UI-Zeile darf nicht mehr als Launch-Zeitpunkt dienen; der heutige Fallback tut genau das (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:623-633`). Settings und Eventdatei sind pro `(chatID, launchID)` eindeutig. Die Bridge schließt vor dem Spawn alte FDs/Watcher, envelopt jedes Event mit Generation, `expectedConfigRoot` und `launchedAt` und protokolliert spätere Alt-Events als `staleGeneration`.

Die Payloadfelder existieren bereits (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`), werden heute aber auf `externalSessionID` reduziert (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`). Künftig parst der Eingang zusätzlich `SessionStart.source` und ruft ausschließlich `claimProviderSession(...)` auf. Nur `claimed` und `alreadyOwnedBySameRow` committen in **einer** Store-Mutation:

```text
ProviderSessionKey + transcriptPath + currentCwd + source + lineage
+ recoveryState=healthy
```

`collision`, `ambiguous` und `staleGeneration` verändern keine Row. Abgewiesene Kandidaten werden mit Grund append-only protokolliert; Kollision/Mehrdeutigkeit werden sichtbar als „prüfen“ markiert. Dieses Autoritätsmodell folgt der konservativen Hook-/Rebinding-Hierarchie aus der agent-deck-Analyse (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:170-194`).

**JSONL-Recovery:** Nur für alte CLI-Versionen oder wirklich stumme Hooks. Sie nutzt kanonischen Root, neue Dateiidentität, ein beidseitiges Fenster um `launchedAt`, cwd-Kompatibilität, gescopte Neuheit und globale Unbelegtheit. Sie bindet nur bei exakt einem Kandidaten und persistiert die schwächere Evidenzart; sie erfindet keine Parent-Lineage aus Nachrichtenrecords. Mehrere Kandidaten ergeben `ambiguous` und `recoveryRequired`, wie es der vorhandene Resolver bereits modelliert (`WhisperM8/Services/AgentChats/ClaudeActiveSessionTracker.swift:13-60`).

### P0.4 — Globale ID-Invariante und Dubletten-Reparatur

1. Store-Operation `claimProviderSession` prüft und schreibt unter demselben Workspace-Lock. Der kanonische Schlüssel ist `(provider, canonicalConfigRoot, externalSessionID)`. Ihre vollständigen Outcomes sind `claimed`, `alreadyOwnedBySameRow`, `collision`, `ambiguous` und `staleGeneration`; nur die ersten beiden mutieren. Ein zweiter aktiver Claim desselben Keys wird als `collision` abgelehnt, der heutige Hook-Pfad hat diesen Check nicht (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-366`).
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
4. Recovery und Relink bleiben **rein logisch**: WhisperM8 speichert neue Projektzuordnung, `pathAliases`, kanonischen Config-Root und Transcriptpfad nur in App-eigenen Daten; Provider-History unter `~/.claude`/`~/.codex` wird weder verschoben noch kopiert. Die bestehenden Account-Umzugs- und Theme-Sync-Funktionen sind separat autorisierte, eng begrenzte Ausnahmen mit eigener Sicherungs-/Settings-Semantik und begründen keine Schreibbefugnis für diesen Flow. Vergleichsprojekte mit Copy+Verify bleiben Architektur-Evidenz, nicht Produktvertrag (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:265-283`).

### P1.3 — Bestehenden Junk sicher bereinigen

Nach P0.1 wird eine signaturbasierte, wiederholbare **App-Daten-Migration** spezifiziert: Dry-Run, Backup der WhisperM8-Workspace-/Indexdaten, Quarantäne ausschließlich in WhisperM8-eigenen Daten, Referenzprüfung gegen Workspace-Bindings und explizite Wiederherstellung. Provider-History unter `~/.claude`/`~/.codex` wird dabei nur gelesen und weder gelöscht, kopiert, verschoben noch quarantänisiert. **Eine physische Provider-History-Bereinigung entfällt nach E2 und ist nicht freigegeben.** Weder der Ordner `projects/-` noch cwd `/` allein sind Löschbelege; die Plan-Verifikation stuft pauschales Löschen der 495 Zeilen selbst als Datenrisiko ein (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/plan-review.md:59-60,106-110`).

### P2 — Soll WhisperM8 `--session-id` selbst vergeben?

**Entscheidung: Weg B bleibt die Baseline (`hostAssignedUnsupported`).** Weg A ist weder allgemeines Zielbild noch vorgelagerter Sofortfix, sondern ausschließlich der optionale Capability-Zustand `hostAssignedVerified`. Er darf nur nach vollständig bestandener Live-Probe des konkreten CLI-Binaries und mit Rollback-Schalter aktiv werden; bis zum Ergebnis von Paket B wird keine Gültigkeit der Fresh-/Fork-Flagkombination behauptet (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/plan-review.md:114-118,313-324`).

#### Potenzielle Vorteile nur bei `hostAssignedVerified`

- Falls die Live-Probe die Vorvergabe bestätigt, wäre die Claude-ID vor dem PTY-Spawn bekannt; Crash zwischen Spawn und Hook könnte dann keinen anonymen Chat mehr hinterlassen. agent-deck dient dafür nur als Vergleichsevidenz, nicht als Beleg für die installierte Claude-CLI (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:84-115,336-361`).
- Zwei parallele Tabs könnten bei positiver Fresh-Probe verschiedene vorab reservierte UUIDs erhalten und bräuchten für frische Starts keinen „latest indexed session“-Fallback. Nimbalyst belegt lediglich einen Vergleichspfad (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/nimbalyst.md:105-110`).
- Forks könnten bei positiver Fork-Probe vor dem Spawn eine Child-ID persistieren. Die bei agent-deck beobachtete Flagfolge `--session-id <child> --resume <parent> --fork-session` wird bis Paket B ausdrücklich nicht als gültiger Vertrag der installierten Claude-CLI vorausgesetzt (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:334-364`).
- Das native TUI-Hosting bleibt unverändert: WhisperM8 setzt nur ein offizielles
  CLI-Flag, statt Claude durch SDK oder Eigen-UI zu ersetzen
  (`docs/audit/2026-07-agent-chats-deep-dive/02-findings/claude-integration-codex.md:7-12`).

#### Nachteile und Grenzen

- WhisperM8 hat die Vorvergabe nach realen „No conversation found“-Fehlern
  bewusst entfernt; die aktuelle Testsuite fixiert Weg B ausdrücklich
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:355-360`,
  `Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:67-87`).
- Eine deterministisch vorgegebene ID löst weder falschen Config-Root noch verschobenes cwd: Claude-Resume bleibt an den vollständigen `ProviderSessionKey(provider, canonicalConfigRoot, externalSessionID)` und die lokale Pfadablage gebunden
  (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/workflow3-kandidaten.md:216-220`).
- Existiert bereits eine JSONL, muss der Launcher `--resume`, nicht erneut
  `--session-id`, verwenden; die agent-deck-Analyse trennt genau diese Fälle
  (`docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md:115-142`).
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

- Fresh-Start ohne `--session-id` ist das Regression-Oracle für `hostAssignedUnsupported`; für `hostAssignedVerified` muss es durch capability-spezifische Oracles ergänzt, nicht pauschal entfernt werden (`Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:67-87`).
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
6. **P2** kann deterministische `--session-id`-Starts ausschließlich im Zustand `hostAssignedVerified` nach erfolgreicher Capability-Probe und mit Rollback-Flag aktivieren; andernfalls bleibt `hostAssignedUnsupported` verbindlich.

„Done“ bedeutet: Kein negativer Scan löscht Metadaten, kein Nil-/Mismatch-Zustand
startet fresh, keine externe ID kann zwei aktive Wrapper besitzen, und jeder
vorhandene Transcriptfund ist über persistierten `transcript_path` oder einen
sichtbaren Relink wieder erreichbar. Diese Zielrichtung entspricht der
verifizierten Roadmap
(`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:203-220`).
