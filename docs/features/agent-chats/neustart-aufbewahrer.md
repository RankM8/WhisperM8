# Aufbewahrer (Neustart ohne Chatverlust, Paket 2)

**Stand:** 12.11.2026 · **Plan:** [docs/plans/neustart-ohne-chatverlust.md](../../plans/neustart-ohne-chatverlust.md)

Der Aufbewahrer hält die PTY-Leitungen laufender Chats, während die App neu startet. Die alte App gibt ab, er liest weiter und beantwortet die Rückfragen der TUIs, und die neue App holt alles zurück. Dieses Paket baut nur den Aufbewahrer. Die App ruft ihn erst mit Paket 4 auf; bis dahin ändert sich am Verhalten der App nichts.

## Bausteine

| Datei | Inhalt |
|---|---|
| `Services/AgentChats/Handover/HandoverProtocol.swift` | Versionen, Telegramme, Manifest, Status, Pfade, Einmal-Geheimnis |
| `Services/AgentChats/Handover/HandoverConnection.swift` | Rahmung, `SCM_RIGHTS`, Fristen, Prüfung der Gegenseite |
| `Services/AgentChats/Handover/HandoverScreen.swift` | Schnittstelle zum Serialisierer (Paket 1) mit Platzhalter, Terminal ohne Fenster, Prozessende per `kqueue` |
| `Services/AgentChats/Handover/HandoverKeeper.swift` | Zustand, Lock, Socket, Fristen, Beenden, Schreiben und Lesen je Chat |
| `Services/AgentChats/Handover/HandoverKeeper+Session.swift` | Ablauf je Verbindung (Abgabe, Übernahme, Freigabe, Status) |
| `Services/AgentChats/Handover/HandoverClient.swift` | Gegenstück für App und CLI, Starter |
| `CLI/HandoverCommands.swift` | interner Modus `handover-keeper`, `whisperm8 app handover-status` |

## Aufruf

```
WhisperM8 handover-keeper --root <ordner> --run <id> [--hold-seconds N] [--deposit-seconds N] [--app-binary <pfad>]…   (Geheimnis als erste Zeile auf stdin)
whisperm8 app handover-status [--json]
```

- **Geheimnis:** Die App erzeugt je Start ein Einmal-Geheimnis (`HandoverSecret.make()`, 32 Byte hex) und gibt es dem Aufbewahrer als erste Zeile auf stdin (`HandoverKeeperLauncher.launch(…, secret:)`). Ohne gültiges Geheimnis startet er nicht (Exit 64). Als Argument geht es nie mit, weil es dann in `ps` stünde, und auf die Platte kommt es nicht. Wer abgibt, muss es im `HELLO` nennen.
- `--root`: Standard `Application Support/WhisperM8/handover/` der Instanz (die Test-Instanz hat ihren eigenen). Darin liegen `keeper.lock` (`flock`, höchstens ein Aufbewahrer je Instanz), `keeper.sock` (0600 in einem 0700-Ordner), `keeper.log` (rotiert ab 1 MB) und `socket-path`. Ist der Socket-Pfad zu lang für `sun_path`, weicht er nach `/private/tmp/whisperm8-<uid>-h<hash>/keeper.sock` aus, und `socket-path` nennt den echten Pfad.
- `--hold-seconds`: Haltefrist, höchstens 600 (Entscheidung 2), auch per Argument nicht mehr.
- `--deposit-seconds`: Abgabefrist, Standard 30. Sie läuft vom Start bis zum `HELLO` und danach jeweils ab dem letzten `HELLO` oder `DEPOSIT` bis zum `COMMIT`.
- `--app-binary`: Wer abgeben, übernehmen und freigeben darf. Ohne Angabe gilt das Binary, aus dem der Aufbewahrer selbst läuft. Nach `rsync` liegt die neue App unter demselben Pfad. Zusätzlich gilt das Designated Requirement des eigenen Codes, wenn der Aufbewahrer mit einem Zertifikat signiert ist. `make dev` signiert mit „WhisperM8 Local Dev“, die Anforderung „Kennung plus Zertifikat“ bleibt über Neubauten gleich. Ad hoc signierte Builds prüfen nur den Pfad.
- Exit-Code 75: Ein anderer Aufbewahrer hält den Lock.

## Wer darf was

`STATUS` darf jeder Prozess desselben Nutzers. Die Antwort enthält weder Tokens noch Terminal-Inhalte. Alles andere prüft der Aufbewahrer bei **jedem einzelnen Telegramm** (`HandoverKeeper.receiveChecked`): gleiche UID, ein Audit-Token per `LOCAL_PEERTOKEN`, dazu Pfad und Code-Anforderung des Codes hinter diesem Token.

Warum bei jedem Telegramm (gemessen am 12.11.2026): `LOCAL_PEERTOKEN` und `LOCAL_PEERPID` nennen den Prozess, der den Socket zuletzt benutzt hat, und zwar in seinem jetzigen Zustand, nicht den vom `connect`. Verbindet sich ein Kind und lädt danach per `exec` das App-Binary, sähe eine Prüfung beim `accept` „die App“. Der Elternprozess, der danach über dieselbe Verbindung spricht, fällt erst bei seinem eigenen Telegramm auf (`HandoverKeeperHardeningTests.testPeerThatExecsAllowedBinaryAfterConnectIsNotTrusted`, `testParentSpeakingAfterChildHelloIsRefused`).

Umgekehrt prüft die App den Aufbewahrer: bei der Abgabe PID (`LOCAL_PEERTOKEN` des Servers) und `runID`, bei der Übernahme auf Wunsch Pfad und Code-Anforderung (`HandoverClient.verifyServer`).

## Protokoll v1

Rahmung: 4 Byte Länge (big-endian), dann JSON, dann `payloadBytes` rohe Bytes (das Bild). Ein Deskriptor hängt per `SCM_RIGHTS` am ersten `sendmsg` des Telegramms. Der Empfänger setzt sofort close-on-exec. Leitungen nimmt nur an, wer es ausdrücklich will (`receive(…, acceptDescriptor: true)`): der Aufbewahrer an `DEPOSIT` in der Abgabe, die App an `CHAT`. Jede andere mitgeschickte Leitung wird sofort geschlossen, damit niemand den Empfänger mit Deskriptoren fluten kann.

| Phase | Ablauf |
|---|---|
| Abgabe | `HELLO {role: deposit, protocolVersion, secret}` → `OK {runID}`; je Chat `DEPOSIT {manifest}` + Leitung + Bild → `ACK {chatID}`; `COMMIT` → `OK` oder `ABORT` → `OK` |
| Übernahme | `HELLO {role: take, protocolRange}` → `OK {protocolVersion}` oder `INCOMPATIBLE`; `LIST` → `CHATS`; je Chat `TAKE {chatID}` → `CHAT {manifest, exited, exitStatus, gapBytes}` + Leitung (nicht bei beendeten Chats) + Bild → `ACK {chatID}` → `OK {chatID}`; `DONE` |
| Freigabe | `RELEASE` → `OK`, dann geordnet beenden; auch direkt nach `INCOMPATIBLE` und ohne `HELLO` |
| Status | `STATUS` → `STATUS_RESULT` |

Versionsunabhängig sind die Rahmung, `type`, `HELLO`, `INCOMPATIBLE`, `RELEASE` und `STATUS`. Telegrammnamen und Manifestfelder werden nur ergänzt, nie umbenannt (`HandoverProtocolTests.testMessageTypesKeepTheirWireNames`).

### Wann gehört eine Leitung wem

Für jede Seite gilt: Wer eine Leitung schickt, schließt sie erst nach der Bestätigung. Daraus folgen zwei Regeln für die App.

- **Abgabe:** Die App hält ihre Originale, bis `commit()` ohne Fehler zurückkam (`COMMIT` → `OK`). Das `ACK` nach einem `DEPOSIT` reicht dafür nicht. Bricht vorher etwas ab (Verbindung weg, Abgabefrist, SIGTERM, `ABORT`), schließt der Aufbewahrer seine Kopien still. Die Originale der App halten die Chats, und sie beendet sich auf dem heutigen Weg.
- **Übernahme:** Die App benutzt eine Leitung erst nach `OK {chatID}`. Dieses `OK` schickt der Aufbewahrer, nachdem er seine eigene Kopie geschlossen hat. Kommt ihr `ACK` zu spät (nach `ackTimeout`), liest der Aufbewahrer weiter, und auf das späte `ACK` folgt kein `OK`. Die App schließt ihre Kopie dann nur, ohne Ctrl+C (`HandoverClient.take` erledigt das selbst). So lesen nie zwei Prozesse dieselbe Leitung. Die App wartet doppelt so lange auf das `OK` wie der Aufbewahrer auf das `ACK`.

**Manifest:** Die Felder stehen im Plan. Neu in diesem Paket ist das optionale Feld `terminalColors {foreground, background}` (`#rrggbb`), damit der Aufbewahrer auf OSC 10/11 dieselben Farben meldet wie die App. Fehlt es, gelten SwiftTerms Standardfarben. `launchCommand` und `pendingAccountSwitch` sind für den Aufbewahrer undurchsichtiges JSON, ihren Inhalt legt Paket 4 fest. Ist `pidStartTime` gesetzt, lehnt der Aufbewahrer eine Abgabe ab, wenn die Startzeit des Prozesses nicht passt (wiederverwendete PID).

## Terminal ohne Fenster

Je Chat ein SwiftTerm-`Terminal`. Es wird erst mit dem Bild gefüttert, dann mit allem, was der Chat in der Lücke schreibt. Rückfragen wie Cursorposition, Geräteattribute und Farben beantwortet `Terminal` selbst, die Antwort geht in die Leitung.

**Das Lesen der Zwischenablage per OSC 52 wird verweigert**, dieselbe Regel wie im `AgentTerminalLinkInterceptor`. Schreibversuche per OSC 52 verwirft der Aufbewahrer in der Lücke.

- **Lesen:** mit `poll(…, 0)` statt mit `O_NONBLOCK`, höchstens 1 MB je Durchlauf. Den Rest holt der nächste Durchlauf, sonst hätte ein Chat, der ohne Pause schreibt, die Queue für sich allein, samt Fristen, `accept`, `TAKE` und SIGTERM.
- **Schreiben** (Antworten auf Rückfragen, Ctrl+C): nie wartend. Liest ein Kind seine Eingabe nicht, etwa ein angehaltener Job oder eine TUI im Raw-Modus vor einer Datei voller `ESC[6n`, ist die Leitung voll, und ein blockierendes `write` hielte den ganzen Aufbewahrer an. `O_NONBLOCK` wird nur für diesen Aufruf gesetzt und gleich zurückgenommen. Das Flag gilt für die gemeinsame Dateibeschreibung, aber solange der Aufbewahrer schreibt, benutzt niemand sonst die Leitung. Was nicht passt, wird verworfen und in `droppedBytes` gezählt. Im kanonischen Modus verwirft das Terminal selbst; blockieren kann es nur im Raw-Modus, und den benutzen alle TUIs.

**Serialisierer:** Der Aufbewahrer arbeitet gegen `HandoverScreenSerializing`. Bis Paket 1 im Pin ist, gilt `HandoverPlainTextSerializer`. Er sichert nur Text und Cursor, keine Farben und keine Schalter. Für die Tests mit `/bin/sh` reicht das, für Claude und Codex nicht. Oles `Terminal.serializeScreen()` (Fork-Commit 5eff1b83) erfüllt denselben Vertrag; nach dem Review von Paket 1 wird daraus ein Adapter von einer Zeile.

## Enden

| Anlass | Was passiert |
|---|---|
| alle übernommen, `DONE` | sofort beenden |
| `DONE` mit übrigen Chats | die übrigen geordnet beenden |
| `ABORT`, Abgabe-Verbindung verloren, Abgabefrist abgelaufen, SIGTERM vor `COMMIT` | Kopien still schließen, kein Signal; die alte App hält die Originale bis `COMMIT` → `OK` |
| Haltefrist (10 min), `RELEASE`, SIGTERM/SIGINT nach `COMMIT` | geordnet wie heute: zweimal Ctrl+C (80 ms und 180 ms Pause) an Chats mit `sendsInterruptOnStop`, also nicht an Attach-Clients; dann die Leitungen schließen, die Chats bekommen SIGHUP |
| eines davon, während ein Chat mitten in der Übergabe ist | dieser Chat bekommt kein Ctrl+C; der Aufbewahrer wartet in der Phase `closing`, bis die Übergabe entschieden ist. Mit `ACK` gehört der Chat der App, sie bekommt noch ihr `OK`; ohne `ACK` wird nur geschlossen. Erst dann endet er |
| Absturz (SIGKILL) | der Kernel schließt die Leitungen, die Chats bekommen SIGHUP |
| Chat endet in der Lücke | `kqueue` mit `NOTE_EXIT \| NOTE_EXITSTATUS` vermerkt Ende und Status; das letzte Bild bleibt, die Übernahme liefert es ohne Leitung. Aus einem Chat mitten in der Übergabe wird dabei nicht mehr gelesen |

## Tests

- `HandoverKeeperProcessTests` (Aufbewahrer als eigener Prozess, `/bin/sh`-Kinder über `forkpty`):
  - Abgabe, Übernahme, Abgabe zehnmal hintereinander: gleiche PID, kein Signal, lückenlose Ausgabe, Fortschritt in jeder Runde;
  - SIGKILL → SIGHUP an die Kinder ohne Ctrl+C;
  - unverträgliches Protokoll → `RELEASE` → geordnetes Ende;
  - zweiter Aufbewahrer → Exit 75; SIGTERM;
  - Start ohne Geheimnis → Exit 64;
  - falsches Geheimnis, falsche `runID` oder falsche PID → keine Abgabe.
- `HandoverKeeperTests` (im Testprozess): Ausgabe der Lücke kommt an, fehlendes `ACK`, Ende in der Lücke mit Exit-Code, Fristen, `ABORT`, verlorene Abgabe, falsche Startzeit, fremdes Binary, Token nie im Status, `app handover-status`.
- `HandoverKeeperHardeningTests`, je ein Test pro Review-Befund:
  - Abgabefrist ab `HELLO` und je `DEPOSIT`, Originale bis `COMMIT`;
  - volle Leitung im Raw-Modus;
  - `RELEASE` und SIGTERM mitten in der Übergabe;
  - Leitungen außerhalb der Abgabe;
  - spätes `ACK`;
  - Audit-Token und beide `exec`-Angriffe;
  - Geheimnis.
- `HandoverProtocolTests`: Rahmung mit Deskriptor und großer Nutzlast, Annahme nur auf Wunsch, Fristen, Aushandeln, Manifest, Pfade, Antworten auf Rückfragen, OSC-52-Sperre, Farben, Platzhalter-Serialisierer, CLI-Argumente.

Die Prozess-Tests brauchen das gebaute `WhisperM8`-Binary neben dem Test-Bundle. `swift test` linkt es mit; fehlt es, scheitern die Tests, statt still übersprungen zu werden.

## Offen für Paket 4

- **Start:** den Aufbewahrer per `HandoverKeeperLauncher.launch(…, secret:)` starten und Geheimnis, `runID` und PID nur im Speicher halten. Bei der Abgabe `helloDeposit(secret:expectedRunID:expectedPID:)` benutzen. Vorher per `STATUS` klären, ob schon ein Aufbewahrer mit Chats lebt, die noch niemand übernommen hat.
- **Originale:** erst nach `commit()` schließen, Leitungen erst nach dem `OK` aus `take` benutzen.
- **Prozesslisten:** `make kill` (`GUI_PIDS`, `Makefile` ~Z. 252) und `scripts/test-instance.sh` (`cmd_stop` ~Z. 97, `pids()`) treffen heute jeden Prozess des Binarys. Prozesse mit dem Argument `handover-keeper` müssen sie ausnehmen. `make clean-install` trifft ihn absichtlich.
- **Farben:** `terminalColors` aus den Farben der Terminal-View füllen.
- **close-on-exec:** Empfangene Leitungen bekommen close-on-exec erst nach `recvmsg`. Deshalb nicht übernehmen, während auf einem anderen Thread ein `forkpty` läuft; beides auf dem Main Thread löst das.
- **Signatur:** Zwischen verschieden signierten Builds, etwa von `make dev` zur Brew-Version, passt die Code-Anforderung nicht. Die Übernahme scheitert dann, und es gilt der Rückfall per `--resume`. Das ist so gewollt.
