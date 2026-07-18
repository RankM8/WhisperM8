---
status: aktiv
updated: 2026-07-18
description: Runde-3-Audit des Terminal-Snapshot-Features mit Fokus auf Capture- und Quit-Races, Klartext-Secrets, Lösch- und Persistenzfehler, Datenretention sowie den Fallback auf provider-spezifische Transcripts.
---

# Runde 3: Terminal-Snapshots — Lifecycle, Persistenz und Privacy

## Gegenstand und Methode

Statisch geprüft wurden die Snapshot-Commits `f448e02` und `a26d29f`, insbesondere
`TerminalSnapshotStore`, der Capture-Pfad in `AgentTerminalController` und
`AgentTerminalRegistry`, App-Quit, die Offline-Anzeige in
`AgentSessionDetailView`/`AgentTranscriptContainerView` sowie Session-/Projekt-
Löschung und Workspace-Pruning. Zur Verifikation der Buffer-Extraktion wurde die
im Repository ausgecheckte SwiftTerm-Quelle gelesen. Es wurden keine Builds,
Tests oder Prozesse ausgeführt.

**Bilanz:** fünf Findings — drei hoch, zwei mittel. Ein Snapshot wird bei
explizitem Terminal-Stop, natürlichem Prozessende oder App-Quit erzeugt
(`WhisperM8/Views/AgentTerminalView.swift:775-819,969-979,385-400`). Da der
Dateiname ausschließlich aus der lokalen Session-UUID besteht, überschreibt ein
späterer Lauf derselben Session den vorherigen Snapshot atomar
(`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:65-68,77-88`). Eine
explizite Session-/Projekt-Löschung plant die Sidecar-Löschung nur asynchron ein
(`WhisperM8/Services/AgentChats/AgentSessionStore.swift:458-499`). Pro Datei gibt
es einen 2.000-Zeilen-Deckel, aber weder globale Rotation noch Ablaufdatum
(`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:27-29,52-60,65-119`).

## G01 — App-Quit blockiert genau den Main-Thread, der den letzten PTY-Output verarbeiten muss

**Schweregrad:** hoch

### Beleg

- Sämtlicher von SwiftTerm eintreffender Output läuft durch
  `QuietableTerminalView.dataReceived`; der Code verlangt dort ausdrücklich den
  Main-Thread (`WhisperM8/Views/AgentTerminalView.swift:112-117`).
- `applicationShouldTerminate` ruft den Snapshot-Quit-Pfad MainActor-isoliert auf
  und antwortet danach sofort mit `.terminateNow`
  (`WhisperM8/WhisperM8App.swift:336-351`).
- Dieser Quit-Pfad sendet zweimal Ctrl+C, blockiert dazwischen jedoch denselben
  Thread mit insgesamt 260 ms `usleep` und liest unmittelbar danach alle Buffer
  (`WhisperM8/Views/AgentTerminalView.swift:385-400`).
- Die Extraktion liest ausschließlich den Normal-Buffer; der reguläre
  `processTerminated`-Pfad würde erst nach Flush und Capture den Owner informieren
  (`WhisperM8/Views/AgentTerminalView.swift:799-819,969-980`).

### Szenario

Der User beendet WhisperM8 per Cmd+Q, während Claude Code oder Codex noch läuft.
Die beiden Interrupts lösen im Kindprozess Exit-Text und den Resume-Hinweis aus.
Während der festen 260-ms-Wartezeit kann der Main-Thread die dazu eintreffenden
PTY-Bytes aber nicht durch `dataReceived` in SwiftTerms Buffer einspeisen. Danach
liest WhisperM8 den alten Normal-Buffer und beendet den App-Prozess sofort. Bleibt
die TUI nach 260 ms noch im Alternate Buffer, ist zusätzlich gerade der einzig
gelesene Normal-Buffer leer oder veraltet. Der Snapshot fehlt dann oder enthält
nicht den Terminal-Stand, den der User unmittelbar vor dem Quit gesehen hat.

### Fix-Skizze

App-Quit als asynchronen, generationstreuen Teardown implementieren:
`.terminateLater` zurückgeben, Interrupts ohne Main-Thread-Schlaf senden und pro
Controller auf `processTerminated` beziehungsweise eine Deadline warten. Erst
nach dem letzten MainActor-Flush und erfolgreicher Persistenz
`reply(toApplicationShouldTerminate:)` aufrufen. Bei Deadline den **aktiven**
Buffer als klar markierten Abrupt-Snapshot sichern, statt ungeprüft den
Normal-Buffer zu verwenden. Einen deterministischen Test mit steuerbarer
PTY-Output-Barriere zwischen Interrupt und Capture ergänzen.

## G02 — Vollständiger Terminal-Scrollback wird unverschlüsselt und ohne Retention als Secret-Sidecar gespeichert

**Schweregrad:** hoch

### Beleg

- Der Capture-Pfad exportiert den vollständigen Normal-Buffer der Session und
  übergibt ihn ohne Inhaltsklassifizierung oder Redaction an den Store
  (`WhisperM8/Views/AgentTerminalView.swift:808-819`).
- `prepared` entfernt nur Leerzeilen und schneidet auf die letzten 2.000 Zeilen;
  sensible Muster werden nicht behandelt
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:48-60`).
- Gespeichert wird als direktes UTF-8-Plaintext-Payload unter
  `~/Library/Application Support/WhisperM8/TerminalSnapshots/<uuid>.terminal-snapshot`;
  der Write setzt weder Verschlüsselung noch explizit restriktive Dateiattribute
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14-21,39-44,77-88`).
- Der Store bietet nur Einzel-/Mehrfachlöschung nach bekannter Session-ID. Eine
  TTL, Gesamtgrößen-Grenze, Verzeichnis-Reconciliation oder Rotation existiert
  nicht (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:65-119`).
- Beim App-Quit werden alle laufenden Controller gesichert
  (`WhisperM8/Views/AgentTerminalView.swift:393-400`), obwohl die Offline-Anzeige
  reine Terminal-Sessions separat behandelt und Snapshots für Agent-View/
  Subagent-Jobs ausdrücklich nicht lädt
  (`WhisperM8/Views/AgentSessionDetailView.swift:102-109,201-207`). Damit entstehen
  auch Sidecars, die diese UI nie verwendet.

### Szenario

Ein User gibt in einer Shell oder Agent-TUI `env` aus, kopiert einen API-Key in
einen Prompt oder erhält einen OAuth-/Login-Code im Terminal. Beim normalen Stop
oder App-Quit landet dieser Wert im Klartext-Snapshot. Auch für eine reine
Terminal- oder Agent-View-Session kann die Datei erzeugt werden, obwohl sie in
der Offline-Ansicht nicht genutzt wird. Ohne explizite Löschung bleibt pro
Session eine solche Datei unbegrenzt bestehen; viele kurzlebige Sessions lassen
das Verzeichnis dauerhaft wachsen.

### Fix-Skizze

Snapshots nur für tatsächlich unterstützte Chat-Kinds erzeugen und die
Persistenz als privacy-relevante Option sichtbar machen. Für persistierte Daten
mindestens restriktive Dateiattribute und eine klar dokumentierte
At-Rest-Strategie vorsehen; robuste Secret-Redaction allein nicht als
Sicherheitsgrenze behandeln. Eine konfigurierbare TTL/Gesamtgrößen-Grenze sowie
einen Startup-Sweep für abgelaufene oder nicht mehr referenzierte Sidecars
einführen. Privacy-Tests mit Token-/OAuth-artigen Terminalzeilen und Tests für
nicht unterstützte Session-Kinds ergänzen.

## G03 — Chat-Löschung garantiert die Löschung des sensitiven Sidecars nicht

**Schweregrad:** hoch

### Beleg

- Nach der sofort geflushten Workspace-Löschung wird das Entfernen des
  Snapshots nur als ungebundener globaler Utility-Queue-Block eingeplant — für
  Sessions wie für Projekte (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:458-499`).
- `TerminalSnapshotStore.delete` verwirft jeden Dateisystemfehler mit `try?` und
  meldet weder Erfolg noch Fehler zurück
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:109-119`).
- App-Quit wartet nicht auf diese Queue, sondern liefert `.terminateNow`
  (`WhisperM8/WhisperM8App.swift:343-351`).
- Zusätzlich entfernen die bei der Workspace-Normalisierung laufenden Prunes
  Worktree-, unresumierbare und verwaiste/importierte Sessions direkt aus dem
  Workspace; ihre IDs werden nicht an den Snapshot-Store weitergereicht
  (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1103-1151,1163-1186`).

### Szenario

Der User löscht einen Chat mit einem secret-haltigen Snapshot und beendet die App
unmittelbar danach. Die Workspace-Datei enthält den Chat dank synchronem Flush
nicht mehr, der Utility-Block kann aber mit dem Prozess sterben, bevor er die
Sidecar-Datei entfernt. Dasselbe Resultat entsteht bei einem transienten
Dateisystemfehler; wegen `try?` bleibt es unsichtbar. Bei einem automatischen
Workspace-Prune entsteht ein verwaister Snapshot sogar ohne irgendeinen
Löschversuch. Da anschließend die Session-ID aus dem Workspace fehlt, existiert
kein normaler UI-Pfad mehr, der die Datei später aufräumt.

### Fix-Skizze

Privacy-Löschungen nach der Store-Mutation synchron oder über eine durable,
beim Quit geflushte Delete-Queue ausführen; Fehler loggen und als ausstehende
Tombstones persistieren. Jede Prune-Funktion muss die entfernten Session-IDs
zurückgeben, damit Sidecars im selben Cleanup-Protokoll landen. Beim Start das
Snapshot-Verzeichnis gegen die gültigen Workspace-Session-IDs reconciliieren.
Tests müssen „delete → sofortiger Quit“, injizierte Remove-Fehler und sämtliche
Prune-Pfade abdecken.

## G04 — Eine kaputte oder neuere Snapshot-Datei verhindert den versprochenen Transcript-Fallback

**Schweregrad:** mittel

### Beleg

- `hasSnapshot` prüft ausschließlich die Dateiexistenz
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:70-73`).
- `load` liefert bei kaputtem Header, ungültigem UTF-8 oder unbekannter Version
  dagegen `nil`; laut Kommentar soll der Aufrufer dann auf das Transcript
  zurückfallen (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:94-106`).
- Beim Mount ruft die Detail-View zwar Snapshot- und Transcript-Load direkt
  nacheinander auf (`WhisperM8/Views/AgentSessionDetailView.swift:129-142`), der
  Transcript-Load wird im globalen Terminal-Modus aber bereits durch die bloße
  Dateiexistenz abgebrochen
  (`WhisperM8/Views/AgentSessionDetailView.swift:219-225,255-260`).
- Der spätere asynchrone `nil`-Snapshot setzt nur den View-State; ein erneuter
  Transcript-Load ist lediglich an einen manuellen Moduswechsel gebunden
  (`WhisperM8/Views/AgentSessionDetailView.swift:201-216,164-167`).
- Die Store-Tests prüfen zwar, dass unbekannte und kaputte Header `nil` liefern,
  testen aber nicht die Integrationsweiche der Detail-View
  (`Tests/WhisperM8Tests/TerminalSnapshotStoreTests.swift:65-85`).

### Szenario

Nach Dateikorruption oder einem späteren Format-Upgrade liegt weiterhin eine
Datei mit unbekannter Header-Version am erwarteten Pfad. `hasSnapshot == true`
verhindert beim Öffnen den JSONL-Load; `load == nil` entfernt nur den angebotenen
Terminal-Modus. Die View löst intern auf Chat auf, besitzt aber weiterhin kein
geladenes Transcript. Erst ein manueller Wechsel des globalen Modus stößt den
Load erneut an — genau der im Store-Kommentar zugesagte automatische Fallback
findet nicht statt.

### Fix-Skizze

Existenz und Validität nicht als zwei konkurrierende Wahrheiten verwenden. Den
asynchronen Load als einen Zustandsautomaten modellieren (`loading`, `valid`,
`absentOrInvalid`); bei `absentOrInvalid` sofort `loadTranscriptIfNeeded`
auslösen und die kaputte/zu neue Datei quarantänisieren oder aus der Defer-
Entscheidung ausschließen. Einen Integrations-Test für fehlende, kaputte und
zukünftige Header-Versionen ergänzen.

## G05 — „Bereits gesichert“ wird vor erfolgreicher Persistenz gesetzt; ein Write-Fehler ist endgültig

**Schweregrad:** mittel

### Beleg

- `captureTerminalSnapshot` setzt `didCaptureSnapshot = true`, bevor Buffer-
  Konvertierung und Dateischreibvorgang erfolgreich sind
  (`WhisperM8/Views/AgentTerminalView.swift:806-819`).
- `save` fängt alle Fehler intern ab und liefert keinen Erfolgswert zurück
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:75-91`).
- Der explizite Stop capturt vor `terminal.terminate`; der spätere
  `processTerminated`-Callback ist wegen desselben Flags nur noch ein No-op
  (`WhisperM8/Views/AgentTerminalView.swift:775-819,969-979`).
- Der Kommentar behauptet, der Datei-Write gehe off-main, tatsächlich erfolgt
  der direkte synchrone `save`-Aufruf aus dem MainActor-isolierten Controller
  (`WhisperM8/Views/AgentTerminalView.swift:613-614,808-819`).

### Szenario

Beim ersten Capture scheitert der atomare Write, etwa wegen vollem Datenträger,
fehlender Berechtigung oder eines transienten I/O-Fehlers. Der Fehler wird nur
als Debug-Log konsumiert, der Controller gilt trotzdem als „captured“. Wenn der
Prozess anschließend real terminiert, kann der natürliche Callback nicht erneut
speichern. Existiert aus einem früheren Lauf derselben Session bereits ein
Snapshot, bleibt dieser alte Stand sogar unter derselben Session-ID liegen und
kann später als aktueller Terminal-Stand erscheinen. Ein langsamer atomarer
Write blockiert zusätzlich den Main-Thread im Teardown.

### Fix-Skizze

`save` als `throws` oder `Bool` modellieren und `didCaptureSnapshot` erst nach
erfolgreicher Persistenz setzen. Buffer-Extraktion auf dem MainActor, I/O auf
einer seriellen Snapshot-Queue ausführen; Stop/App-Quit müssen deren konkreten
Write bis zu einer Deadline abwarten. Bei Fehler einen Retry im
`processTerminated`-Pfad erlauben und einen alten Snapshot entweder eindeutig als
alt kennzeichnen oder vor dem neuen Lauf invalidieren. Tests mit injizierbarem
Writer für Fehler, Retry und Write-Reihenfolge ergänzen.

## Positive Befunde

- Das Dateiformat ist versioniert und der eigentliche Write atomar
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:31-34,77-88`).
- Der per-Datei-Zeilen-Deckel bewahrt den jüngsten Tail einschließlich Resume-
  Hinweis (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:48-60`).
- Normaler Selbst-Exit flusht den Feed-Batcher vor dem Capture; die
  UI-Detailansicht lädt erst nach synchroner Persistenz nach
  (`WhisperM8/Views/AgentTerminalView.swift:969-979`;
  `WhisperM8/Views/AgentSessionDetailView.swift:188-197`).
- Session- und Projekt-Löschung haben grundsätzlich einen Snapshot-Cleanup-
  Pfad; der Defekt ist dessen fehlende Durability und Fehlerwahrheit, nicht ein
  vollständig vergessenes Feature
  (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:458-499`).

## Priorität

1. **Sofort:** G01 beheben, damit App-Quit den tatsächlichen letzten Terminal-
   Stand statt eines durch Main-Thread-Blocking erzeugten Zufalls-Snapshots
   sichert.
2. **Sofort:** G02/G03 als Privacy-Paket behandeln: Capture-Scope begrenzen,
   klare At-Rest-/Retention-Policy definieren und Löschung durable machen.
3. **Kurzfristig:** G04 reparieren, damit Formatmigration und Dateikorruption
   nicht den Offline-Chat scheinbar leeren.
4. **Kurzfristig:** G05 mit expliziter Write-Erfolgswahrheit und serieller,
   quit-fähiger I/O-Pipeline absichern.
