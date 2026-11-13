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

- **Geheimnis:** Die App erzeugt je Start ein Einmal-Geheimnis (`HandoverSecret.make()`, 32 Byte hex) und gibt es dem Aufbewahrer als erste Zeile auf stdin (`HandoverKeeperLauncher.launch(…, secret:)`). Ohne gültiges Geheimnis startet er nicht (Exit 64). Als Argument geht es nie mit, weil es dann in `ps` stünde. Jedes `HELLO` (Abgabe und Übernahme) und ein `RELEASE` ohne vorheriges `HELLO` muss es nennen. Die neue App bekommt es von der alten über eine Datei `take-secret` (0600) im 0700-Ordner des Aufbewahrers (Option A, `HandoverFileSecretStore`): Die alte App legt sie exklusiv an, die neue löscht sie nach dem Lesen, der Aufbewahrer bei seinem Ende. Kein Schlüsselbund-Aufruf im Übergabe-Weg: Ohne Team-ID band macOS den Eintrag an den cdhash des Builds, über zwei Builds (`make dev`, Brew-Update) ging die Übernahme so nie, und ein Dialog war nicht sicher zu verhindern. Der Schlüsselbund-Weg (`HandoverSecretStore`) bleibt für eine Signatur mit Team-ID (Option C) im Code; gewählt wird in `HandoverSecretStores.live`.
- `--root`: Standard `Application Support/WhisperM8/handover/` der Instanz (die Test-Instanz hat ihren eigenen). Darin liegen `keeper.lock` (`flock`, höchstens ein Aufbewahrer je Instanz), `keeper.sock` (0600 in einem 0700-Ordner), `keeper.log` (rotiert ab 1 MB) und `socket-path`. Ist der Socket-Pfad zu lang für `sun_path`, weicht er nach `/private/tmp/whisperm8-<uid>-h<hash>/keeper.sock` aus, und `socket-path` nennt den echten Pfad.
- `--hold-seconds`: Haltefrist, höchstens 600 (Entscheidung 2), auch per Argument nicht mehr.
- `--deposit-seconds`: Abgabefrist, Standard 30. Sie läuft vom Start bis zum `HELLO` und danach jeweils ab dem letzten `HELLO` oder `DEPOSIT` bis zum `COMMIT`.
- `--app-binary`: Wer abgeben, übernehmen und freigeben darf. Ohne Angabe gilt das Binary, aus dem der Aufbewahrer selbst läuft. Nach `rsync` liegt die neue App unter demselben Pfad. Zusätzlich gilt das Designated Requirement des eigenen Codes, wenn der Aufbewahrer mit einem Zertifikat signiert ist. `make dev` signiert mit „WhisperM8 Local Dev“, die Anforderung „Kennung plus Zertifikat“ bleibt über Neubauten gleich. Ad hoc signierte Builds prüfen nur den Pfad.
- Exit-Code 75: Ein anderer Aufbewahrer hält den Lock.

## Wovor schützen wir, wovor nicht

Maßstab für jede Review dieses Features (Beschluss 13.11.2026, zweite Meinung):

- **Schutzziel:** Andere Benutzer des Macs bekommen keine Terminal-Leitung, kein Bild, kein Control-Token und keinen lauschenden Router-Socket. Instanzen werden nicht verwechselt (Test-Instanz, alter Aufbewahrer, falscher Lauf), und zufällige oder ungezielte Zugriffe scheitern.
- **Kein Schutzziel (Urteil Vic, 13.11.2026):** Ein gezieltes Programm desselben Benutzers. Es kann die Datei mit dem Geheimnis lesen, solange sie liegt. Das galt auch mit Schlüsselbund: Ohne gehärtete Laufzeit kann ein Programm desselben Benutzers eigenen Code in das App-Programm laden lassen (`DYLD_INSERT_LIBRARIES`) und den Eintrag mit der Identität der App lesen. Eine echte Grenze bräuchte eine Signatur mit Team-ID samt gehärteter Laufzeit (Option C) oder eine geerbte Verbindung (Option B). Die Übergabe öffnet einem solchen Programm keine neue Art von Zugriff, nur einen zweiten Weg zu dem, was über den Steuer-Socket ohnehin geht.
- **Kein Schutzziel:** Stören oder Beenden durch denselben Nutzer. Wer Signale schicken oder den Aufbewahrer belegen kann, kann auch die App beenden. Dann gilt der Rückfall per `--resume`.
- **Kein Schutzziel:** Was über den vorhandenen Control-Socket der App ohnehin geht. `whisperm8 chats send` nimmt Aufrufe jedes Prozesses desselben Nutzers an, Aufrufe ohne Sitzungs-Kennung gelten als „extern“ (`AgentControlServer`, `AgentControlRequestHandler.rejectsUnverifiedActor`). Dieser Socket ist schwächer gesichert als der Aufbewahrer. Das ist bekannt und ein eigener, späterer Punkt, kein Auftrag für dieses Feature.
- **Folge:** Weitere Härtung am Aufbewahrer nur, wenn sie ein Schutzziel oben trifft. Sie kostet sonst Zuverlässigkeit (Schlüsselbund, Fristen) ohne echten Gewinn.

Welche Schicht was trägt (Urteil zur Absender-Bindung, 13.11.2026):

| Schicht | Was sie leistet |
|---|---|
| Einmal-Geheimnis | **Grenze gegen andere Benutzer und Verwechslungen, Hürde gegen ein gezieltes Programm desselben Benutzers** (es kann die Datei lesen, solange sie liegt). Ohne das Geheimnis gibt es keine Abgabe, keine Übernahme und keine Freigabe. |
| Kein Kind erbt den Socket | **Grenze.** Ein Kind, das die Verbindung der App erbt, könnte die Telegramme des Aufbewahrers mitlesen, samt Leitung, Bild und Token. Dagegen hilft keine Prüfung des Absenders, nur dass niemand erbt: Die App setzt close-on-exec sofort nach dem Anlegen, legt Socket und Leitungen nur auf dem Main Thread an (dort laufen auch die `forkpty`) und prüft das im Code; das Kind schließt vor `execve` alle Leitungen, die beim Start offen waren (Paket 1). |
| Code-Prüfung je Telegramm | **Hürde, keine Garantie.** Der Kernel nennt den Prozess, der den Socket zuletzt angefasst hat, nicht den, der diese Bytes geschrieben hat. Bei ad hoc signierten Builds (alle Brew-Releases) prüft sie nur den Pfad. |
| Absender-Bindung | **Hürde, keine Garantie,** aus demselben Grund. Beide bleiben, weil sie billig sind und Fälle aufhalten, in denen der gebundene Prozess gerade nicht am Socket ist. |

## Wer darf was

`STATUS` darf jeder Prozess desselben Nutzers. Die Antwort enthält weder Tokens noch Terminal-Inhalte. Für alles andere gelten drei Prüfungen.

1. **Geheimnis** im `HELLO` bzw. im ersten `RELEASE` (siehe oben). Das ist der eigentliche Schutz: Den *Inhalt* eines Telegramms kann sich ein fremder Prozess nicht vom App-Binary schreiben lassen.
2. **Code des Absenders** bei jedem einzelnen Telegramm (`HandoverKeeper.receiveChecked`): gleiche UID, ein Audit-Token per `LOCAL_PEERTOKEN`, dazu Pfad und Code-Anforderung des Codes hinter diesem Token.
3. **Absender-Bindung:** Der erste geprüfte Absender einer Verbindung (PID und PID-Version aus dem Audit-Token) wird festgehalten. Jedes weitere Telegramm muss von genau ihm kommen.

Dazu nimmt der Aufbewahrer Nutzlast und Leitungen nur an `DEPOSIT` an. Bei jedem anderen Telegramm bricht er schon nach dem Kopf ab, bevor er die Nutzlast liest.

Warum so viel (gemessen am 12.11.2026, Review): `LOCAL_PEERTOKEN` und `LOCAL_PEERPID` nennen den Prozess, der den Socket zuletzt benutzt hat, in seinem jetzigen Zustand, nicht den vom `connect`. Eine Prüfung nur beim `accept` lässt sich mit „verbinden, dann `exec` des App-Binarys“ umgehen. Auch eine Prüfung je Telegramm allein reicht nicht: Ein fremder Prozess kann den Anfang eines Telegramms schreiben und den Rest vom App-Binary schreiben lassen, etwa über die Ausgabe von `whisperm8 chats tail` aus einem Verlauf, den er selbst bestimmt. Dann gilt das App-Binary als letzter Absender. Dagegen hilft das Geheimnis; die Bindung hält einen Teil der Fälle auf, ist aber nur eine Hürde (siehe Tabelle oben; Tests: `HandoverKeeperHardeningTests`: `testPeerThatExecsAllowedBinaryAfterConnectIsNotTrusted`, `testParentSpeakingAfterChildHelloIsRefused`, `testInheritorIsRejectedWhileBoundProcessIsIdle`, `testTakeAndReleaseRequireSecret`).

Umgekehrt prüft die App den Aufbewahrer: bei der Abgabe PID (`LOCAL_PEERTOKEN` des Servers) und `runID`, bei der Übernahme auf Wunsch Pfad und Code-Anforderung (`HandoverClient.verifyServer`).

## Protokoll v1

Rahmung: 4 Byte Länge (big-endian), dann JSON, dann `payloadBytes` rohe Bytes (das Bild). Ein Deskriptor hängt per `SCM_RIGHTS` am ersten `sendmsg` des Telegramms. Der Empfänger setzt sofort close-on-exec. Leitungen nimmt nur an, wer es ausdrücklich will (`receive(…, acceptDescriptor: true)`): der Aufbewahrer an `DEPOSIT` in der Abgabe, die App an `CHAT`. Jede andere mitgeschickte Leitung wird sofort geschlossen, damit niemand den Empfänger mit Deskriptoren fluten kann.

| Phase | Ablauf |
|---|---|
| Abgabe | `HELLO {role: deposit, protocolVersion, secret}` → `OK {runID}`; je Chat `DEPOSIT {manifest}` + Leitung + Bild → `ACK {chatID}`; `COMMIT` → `OK` oder `ABORT` → `OK` |
| Übernahme | `HELLO {role: take, protocolRange, secret}` → `OK {protocolVersion}` oder `INCOMPATIBLE`; `LIST` → `CHATS`; je Chat `TAKE {chatID}` → `CHAT {manifest, exited, exitStatus, gapBytes}` + Leitung (nicht bei beendeten Chats) + Bild → `ACK {chatID}` → `OK {chatID}`; `DONE` |
| Freigabe | `RELEASE {secret}` → `OK`, dann geordnet beenden; auch direkt nach `INCOMPATIBLE` und ohne `HELLO` |
| Status | `STATUS` → `STATUS_RESULT` |

Versionsunabhängig sind die Rahmung, `type`, `secret`, `HELLO`, `INCOMPATIBLE`, `RELEASE` und `STATUS`. Telegrammnamen und Manifestfelder werden nur ergänzt, nie umbenannt (`HandoverProtocolTests.testMessageTypesKeepTheirWireNames`).

### Wann gehört eine Leitung wem

Für jede Seite gilt: Wer eine Leitung schickt, schließt sie erst nach der Bestätigung. Daraus folgen zwei Regeln für die App.

- **Abgabe:** Die App hält ihre Originale, bis `commit()` ohne Fehler zurückkam (`COMMIT` → `OK`). Das `ACK` nach einem `DEPOSIT` reicht dafür nicht. Bricht vorher etwas ab (Verbindung weg, Abgabefrist, SIGTERM, `ABORT`), schließt der Aufbewahrer seine Kopien still. Die Originale der App halten die Chats, und sie beendet sich auf dem heutigen Weg. Lässt sich das `OK` auf `COMMIT` nicht zustellen, gibt der Aufbewahrer ebenfalls still frei. Kommt es bei der App nicht an, schickt `commit()` dem Aufbewahrer SIGTERM, bevor es den Fehler meldet: Vor `COMMIT` schließt er dann still, danach geordnet. Das Signal geht nur hinaus, wenn unter der PID noch derselbe Prozess läuft (Startzeit aus `helloDeposit(expectedPID:)`). Eine Übernahme lässt der Aufbewahrer erst zu, wenn die Abgabe-Verbindung beendet ist; ein `HELLO take`, das kurz vorher ankommt, wartet bis zu 2 s. So hält nie eine Kopie Chats weiter, während die App auf dem heutigen Weg endet.
- **Übernahme:** Die App benutzt eine Leitung erst nach `OK {chatID}`. Der Aufbewahrer schickt dieses `OK`, solange seine Kopie noch offen ist, und schließt sie erst danach. Geht das `OK` nicht hinaus, behält er den Chat und liest weiter. Kommt das `ACK` der App zu spät (nach `ackTimeout`), liest der Aufbewahrer ebenfalls weiter, und auf das späte `ACK` folgt kein `OK`. Ohne `OK` schließt die App ihre Kopie nur, ohne Ctrl+C (`HandoverClient.take` erledigt das selbst). So lesen nie zwei Prozesse dieselbe Leitung. Die App wartet doppelt so lange auf das `OK` wie der Aufbewahrer auf das `ACK`. Geht das `OK` hinaus und stirbt die App direkt danach, endet der Chat; das ist der Rückfall per `--resume`.

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
  - falsches Geheimnis, falsche `runID` oder falsche PID → keine Abgabe;
  - Übernahme ohne Geheimnis → abgelehnt.
- `HandoverKeeperTests` (im Testprozess): Ausgabe der Lücke kommt an, fehlendes `ACK`, Ende in der Lücke mit Exit-Code, Fristen, `ABORT`, verlorene Abgabe, falsche Startzeit, fremdes Binary, Token nie im Status, `app handover-status`.
- `HandoverKeeperHardeningTests`, je ein Test pro Review-Befund:
  - Abgabefrist ab `HELLO` und je `DEPOSIT`, Originale bis `COMMIT`;
  - volle Leitung im Raw-Modus;
  - `RELEASE` und SIGTERM mitten in der Übergabe;
  - Leitungen außerhalb der Abgabe;
  - spätes `ACK`;
  - Audit-Token, beide `exec`-Angriffe und Absender-Bindung;
  - Geheimnis bei Abgabe, Übernahme und Freigabe;
  - SIGTERM nach gescheitertem `COMMIT`;
  - leere Verbindungen blockieren nichts.
- `HandoverProtocolTests`: Rahmung mit Deskriptor und großer Nutzlast, Annahme nur auf Wunsch, Fristen, Aushandeln, Manifest, Pfade, Antworten auf Rückfragen, OSC-52-Sperre, Farben, Platzhalter-Serialisierer, CLI-Argumente.

Die Prozess-Tests brauchen das gebaute `WhisperM8`-Binary neben dem Test-Bundle. `swift test` linkt es mit; fehlt es, scheitern die Tests, statt still übersprungen zu werden.

## Umsetzung in der App (Paket 4)

Stand 13.11.2026, Branch `feat/handover-app`. Was aus der früheren Liste „Offen für Paket 4“ wo erledigt ist:

| Punkt | Umsetzung |
|---|---|
| Start mit Geheimnis, `STATUS` vorher | `HandoverRestartService` (Plan per `HandoverPlanning.quitPlan`), `HandoverDepositCoordinator`. Hält ein Aufbewahrer noch Chats, gibt die App nicht ab. |
| Geheimnis weiterreichen | `HandoverSecretStore`: ein Eintrag je Instanz **und Signatur**, gelesen ohne Dialog mit 2 s Frist. Ein anders signierter Build findet keinen Eintrag. Gelöscht wird erst nach dem Ende der Übernahme. Ohne Geheimnis beendet die neue App den Aufbewahrer per SIGTERM (PID aus `STATUS`). |
| Originale erst nach `COMMIT` schließen | `AgentTerminalController.completeHandover` läuft erst nach `commit()`; davor holt `reattachAfterFailedHandover` jede Leitung zurück. |
| Prozesslisten | `GUI_PIDS` im Makefile und `pids()` in `scripts/test-instance.sh` nehmen `handover-keeper` aus. |
| Farben | `terminalColors` aus Vorder- und Hintergrundfarbe der Terminal-View. |
| close-on-exec, Main Thread | Abgabe, Übernahme und der Socket zum Aufbewahrer nur auf dem Main Thread, mit Prüfung zur Laufzeit; sonst keine Übergabe bzw. Rückfall. |
| Signatur dev ↔ Brew | Rückfall per `--resume`, ohne Dialog (siehe Geheimnis). Die echte Prüfung mit zwei Builds steht noch aus. |
| Startzeit | Vor jeder Übernahme prüft die App, ob unter der PID noch derselbe Prozess läuft. |

Bedienung: `make dev` fragt vor dem Beenden `whisperm8 app handover`; Test-Instanz `restart --keep-chats` und `handover`; Labs-Schalter „Neustart ohne Chatverlust“. Offen: Pflichttests mit echtem `make dev`, Abnahme Dev auf Dev und ad hoc auf ad hoc mit der Datei-Ablage, Bild im echten Fenster, Ansicht hängt sich an übernommene Chats an (Rückweg nach gescheitertem Andocken, Fehlertext).
