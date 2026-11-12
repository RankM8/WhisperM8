# Aufbewahrer (Neustart ohne Chatverlust, Paket 2)

**Stand:** 12.11.2026 · **Plan:** [docs/plans/neustart-ohne-chatverlust.md](../../plans/neustart-ohne-chatverlust.md)

Der Aufbewahrer hält die PTY-Leitungen laufender Chats, während die App neu startet. Die alte App gibt ab, er liest weiter und beantwortet die Rückfragen der TUIs, und die neue App holt alles zurück. Dieses Paket baut nur den Aufbewahrer. Die App ruft ihn erst mit Paket 4 auf; bis dahin ändert sich am Verhalten der App nichts.

## Bausteine

| Datei | Inhalt |
|---|---|
| `Services/AgentChats/Handover/HandoverProtocol.swift` | Versionen, Telegramme, Manifest, Status, Pfade |
| `Services/AgentChats/Handover/HandoverConnection.swift` | Rahmung, `SCM_RIGHTS`, Fristen, Prüfung der Gegenseite |
| `Services/AgentChats/Handover/HandoverScreen.swift` | Schnittstelle zum Serialisierer (Paket 1) mit Platzhalter, Terminal ohne Fenster, Prozessende per `kqueue` |
| `Services/AgentChats/Handover/HandoverKeeper.swift` | Zustand, Lock, Socket, Fristen, Beenden |
| `Services/AgentChats/Handover/HandoverKeeper+Session.swift` | Ablauf je Verbindung (Abgabe, Übernahme, Freigabe, Status) |
| `Services/AgentChats/Handover/HandoverClient.swift` | Gegenstück für App und CLI, Starter |
| `CLI/HandoverCommands.swift` | interner Modus `handover-keeper`, `whisperm8 app handover-status` |

## Aufruf

```
WhisperM8 handover-keeper --root <ordner> --run <id> [--hold-seconds N] [--deposit-seconds N] [--app-binary <pfad>]…
whisperm8 app handover-status [--json]
```

- `--root`: Standard `Application Support/WhisperM8/handover/` der Instanz (die Test-Instanz hat ihren eigenen). Darin liegen `keeper.lock` (`flock`, höchstens ein Aufbewahrer je Instanz), `keeper.sock` (0600 in einem 0700-Ordner), `keeper.log` (rotiert ab 1 MB) und `socket-path`. Ist der Socket-Pfad zu lang für `sun_path`, weicht er nach `/private/tmp/whisperm8-<uid>-h<hash>/keeper.sock` aus, und `socket-path` nennt den echten Pfad.
- `--hold-seconds`: Haltefrist, höchstens 600 (Entscheidung 2), auch per Argument nicht mehr.
- `--deposit-seconds`: Frist bis `COMMIT`, Standard 30.
- `--app-binary`: Wer abgeben, übernehmen und freigeben darf. Ohne Angabe gilt das Binary, aus dem der Aufbewahrer selbst läuft. Nach `rsync` liegt die neue App unter demselben Pfad. `STATUS` darf jeder Prozess desselben Nutzers, die Antwort enthält weder Tokens noch Terminal-Inhalte.
- Exit-Code 75: Ein anderer Aufbewahrer hält den Lock.

## Protokoll v1

Rahmung: 4 Byte Länge (big-endian), dann JSON, dann `payloadBytes` rohe Bytes (das Bild). Ein Deskriptor hängt per `SCM_RIGHTS` am ersten `sendmsg` des Telegramms. Der Empfänger setzt sofort close-on-exec und ordnet ihn über `hasDescriptor` zu; Deskriptoren ohne Ankündigung werden geschlossen.

| Phase | Ablauf |
|---|---|
| Abgabe | `HELLO {role: deposit, protocolVersion}` → `OK {runID}`; je Chat `DEPOSIT {manifest}` + Leitung + Bild → `ACK {chatID}`; `COMMIT` → `OK` oder `ABORT` → `OK` |
| Übernahme | `HELLO {role: take, protocolRange}` → `OK {protocolVersion}` oder `INCOMPATIBLE`; `LIST` → `CHATS`; je Chat `TAKE {chatID}` → `CHAT {manifest, exited, exitStatus, gapBytes}` + Leitung (nicht bei beendeten Chats) + Bild → `ACK {chatID}`; `DONE` |
| Freigabe | `RELEASE` → `OK`, dann geordnet beenden; auch direkt nach `INCOMPATIBLE` und ohne `HELLO` |
| Status | `STATUS` → `STATUS_RESULT` |

Versionsunabhängig sind die Rahmung, `type`, `HELLO`, `INCOMPATIBLE`, `RELEASE` und `STATUS`. Telegrammnamen und Manifestfelder werden nur ergänzt, nie umbenannt (`HandoverProtocolTests.testMessageTypesKeepTheirWireNames`).

**ACK-Regel:** Wer eine Leitung schickt, schließt sie erst nach dem `ACK`. Der Aufbewahrer hält sich daran, und die App muss es auch: Erst wenn `HandoverClient.deposit` ohne Fehler zurückkommt, darf sie ihre eigene Kopie schließen. Kommt kein `ACK` (die neue App stürzt nach dem Empfang ab), behält der Aufbewahrer den Chat und liest weiter. Eine spätere App kann ihn erneut holen.

**Manifest:** Die Felder stehen im Plan. Neu in diesem Paket ist das optionale Feld `terminalColors {foreground, background}` (`#rrggbb`), damit der Aufbewahrer auf OSC 10/11 dieselben Farben meldet wie die App. Fehlt es, gelten SwiftTerms Standardfarben. `launchCommand` und `pendingAccountSwitch` sind für den Aufbewahrer undurchsichtiges JSON, ihren Inhalt legt Paket 4 fest. Ist `pidStartTime` gesetzt, lehnt der Aufbewahrer eine Abgabe ab, wenn die Startzeit des Prozesses nicht passt (wiederverwendete PID).

## Terminal ohne Fenster

Je Chat ein SwiftTerm-`Terminal`. Es wird erst mit dem Bild gefüttert, dann mit allem, was der Chat in der Lücke schreibt. Rückfragen wie Cursorposition, Geräteattribute und Farben beantwortet `Terminal` selbst, die Antwort geht in die Leitung.

**Das Lesen der Zwischenablage per OSC 52 wird verweigert**, dieselbe Regel wie im `AgentTerminalLinkInterceptor`. Schreibversuche per OSC 52 verwirft der Aufbewahrer in der Lücke.

Er liest mit `poll(…, 0)` statt mit `O_NONBLOCK`. Das Flag gilt für die gemeinsame Dateibeschreibung und hätte damit auch die Leitung der App verändert.

**Serialisierer:** Der Aufbewahrer arbeitet gegen `HandoverScreenSerializing`. Bis Paket 1 liefert, gilt `HandoverPlainTextSerializer`. Er sichert nur Text und Cursor, keine Farben und keine Schalter. Für die Tests mit `/bin/sh` reicht das, für Claude und Codex nicht. Ist die Funktion im Fork da, wird ein Adapter von einer Zeile daraus.

## Enden

| Anlass | Was passiert |
|---|---|
| alle übernommen, `DONE` | sofort beenden |
| `DONE` mit übrigen Chats | die übrigen geordnet beenden |
| `ABORT`, Abgabe-Verbindung verloren, Abgabefrist abgelaufen | Kopien still schließen, kein Signal; die alte App hält die Originale und beendet sich auf dem heutigen Weg |
| Haltefrist (10 min), `RELEASE`, SIGTERM/SIGINT | geordnet wie heute: zweimal Ctrl+C (80 ms und 180 ms Pause) an Chats mit `sendsInterruptOnStop`, also nicht an Attach-Clients; dann die Leitungen schließen, die Chats bekommen SIGHUP |
| Absturz (SIGKILL) | der Kernel schließt die Leitungen, die Chats bekommen SIGHUP |
| Chat endet in der Lücke | `kqueue` mit `NOTE_EXIT \| NOTE_EXITSTATUS` vermerkt Ende und Status; das letzte Bild bleibt, die Übernahme liefert es ohne Leitung |

Die Haltefrist endet nie mitten in einer Übergabe: Fehlt zu einem gesendeten Chat noch das `ACK`, prüft der Aufbewahrer eine Sekunde später noch einmal.

## Tests

- `HandoverKeeperProcessTests` (Aufbewahrer als eigener Prozess, `/bin/sh`-Kinder über `forkpty`): Abgabe, Übernahme, Abgabe zehnmal hintereinander mit derselben PID, ohne Signal und mit lückenloser Ausgabe; SIGKILL → SIGHUP an die Kinder ohne Ctrl+C; unverträgliches Protokoll → `RELEASE` → geordnetes Ende; zweiter Aufbewahrer → Exit 75; SIGTERM.
- `HandoverKeeperTests` (im Testprozess): Ausgabe der Lücke kommt an, fehlendes `ACK`, Ende in der Lücke mit Exit-Code, Fristen, `ABORT`, verlorene Abgabe, falsche Startzeit, fremdes Binary, Token nie im Status, `app handover-status`.
- `HandoverProtocolTests`: Rahmung mit Deskriptor und großer Nutzlast, Fristen, Aushandeln, Manifest, Pfade, Antworten auf Rückfragen, OSC-52-Sperre, Farben, Platzhalter-Serialisierer, CLI-Argumente.

Die Prozess-Tests brauchen das gebaute `WhisperM8`-Binary neben dem Test-Bundle. `swift test` linkt es mit.

## Offen für Paket 4

- Den Aufbewahrer per `HandoverKeeperLauncher` starten. Vorher klären, ob ein Aufbewahrer mit Chats lebt, die noch niemand übernommen hat (`STATUS`).
- `make kill` und `test-instance.sh` müssen Prozesse mit dem Argument `handover-keeper` ausnehmen. `make clean-install` trifft ihn absichtlich.
- `terminalColors` aus den Farben der Terminal-View füllen.
- Empfangene Leitungen bekommen close-on-exec erst nach `recvmsg`. Startet die App in genau diesem Moment auf einem anderen Thread einen Chat, könnte dieser die Leitung erben. Deshalb in der App nicht übernehmen, während ein `forkpty` läuft (beides auf dem Main Thread erledigt das).
