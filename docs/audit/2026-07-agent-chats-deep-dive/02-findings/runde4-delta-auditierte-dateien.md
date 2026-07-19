---
status: abgeschlossen
updated: 2026-07-19
description: Delta-Audit bereits auditierter Agent-Chats-Dateien für e8b7661..HEAD mit Fokus auf neue Fehler, Race Conditions, Security-Grenzen und die Verschiebung bestätigter Alt-Findings.
---

# Runde 4: Delta-Audit bereits auditierter Dateien

## Umfang und Methode

Geprüft wurde ausschließlich das Delta `e8b7661..HEAD` der vorgegebenen Dateien:

- `ClaudeHookBridge.swift`
- `ClaudeHookSettingsBuilder.swift`
- `AgentSessionStatusCoordinator.swift`
- `AgentSessionStore.swift`
- `AgentHeadlessCLI.swift`
- `AgentCommandBuilder.swift`
- `AgentWorkspaceRepository.swift`
- `Models/AgentChat.swift`
- `Views/AgentTerminalView.swift`
- `Views/AgentChatsView+SessionLifecycle.swift`
- `Views/AgentSessionDetailView.swift`
- `WhisperM8App.swift`
- `AppPreferences.swift`

Für jede Datei wurden die neuen Hunk-Bereiche, ihre direkten Aufrufer und die zugehörigen Tests gelesen. Maßstab waren die bestätigten Klassen `C01–C16`, `N01–N16` und die Runde-3-`G`-Findings. Es wurden weder Produktcode geändert noch Builds oder Tests ausgeführt.

## Ergebnis

- kritisch: 0
- hoch: 8
- mittel: 2
- niedrig: 0

Die wichtigsten neuen Risiken sind:

1. Der neue Headless-Timeout sendet `SIGKILL` anhand einer nicht erneut validierten PID und kann nach PID-Reuse einen fremden Prozess treffen (`R4-HCLI-01`).
2. Derselbe Timeout gibt nach zehn Sekunden trotz weiterlebender Nachkommen frei und widerlegt damit seine eigene Serialisierungs-/„Prozess wirklich tot“-Garantie (`R4-HCLI-02`).
3. `session.send` übergibt ungefilterte Terminal-Steuerbytes und quittiert „delivered“, bevor der verzögerte Submit tatsächlich passiert ist; parallele Sends können sich im Composer vermischen (`R4-CTRL-01`, `R4-CTRL-02`).
4. Context-Profile werden bei Settings-I/O-Fehlern still fallengelassen und der Prozess startet mit breiteren/defaultmäßigen Fähigkeiten weiter (`R4-PROFILE-01`).
5. Zwei neue persistierte Referenzfelder wurden ohne Schema-Bump oder Future-Schema-Guard eingeführt; ein Downgrade kann sie sofort wieder entfernen (`R4-SCHEMA-01`, konkrete Fortsetzung von `N05`).

## Findings

### R4-HCLI-01 — Unvalidiertes `SIGKILL` kann nach PID-Reuse einen fremden Prozess treffen

**Schweregrad:** hoch
**Klasse / Alt-Finding:** Prozessidentität; neue Ausprägung von `N01`.

**Beleg:**

- Der neue Eskalationstimer prüft zuerst `process.isRunning` und sendet danach separat `kill(process.processIdentifier, SIGKILL)` (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:94-100`).
- Zwischen Bool-Prüfung und `kill(2)` gibt es weder einen Startzeit-/Executable-Abgleich noch einen anderen Identitätsbeleg (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:97-100`).
- Der vorhandene Timeout-Test startet nur einen stabilen `/bin/sleep`-Prozess und prüft ausschließlich den Fehlertyp; ein Exit genau zwischen Check und Signal sowie PID-Reuse werden nicht modelliert (`Tests/WhisperM8Tests/AgentSessionAutoNamerTests.swift:49-59`).

**Konkretes Auslöseszenario:** Der Headless-Child ignoriert zunächst `SIGTERM`. Beim zweiten Timer ist `isRunning` noch `true`; unmittelbar danach endet der Child. macOS vergibt dieselbe PID an einen anderen Prozess, bevor Zeile 99 ausgeführt wird. Das rohe `kill` trifft dann nicht mehr den von `Process` gestarteten Child.

**Auswirkung:** WhisperM8 kann einen unbeteiligten Prozess desselben Users hart beenden. Der Fehler ist selten, aber irreversibel und entspricht exakt der bereits bestätigten Identitätsklasse `N01`.

**Fix-Skizze:** Keine getrennte `isRunning`→PID-Signal-Sequenz verwenden. Den Child in einen explizit besessenen Helper-/Prozessgruppen-Lifecycle legen und die Eskalation dort anhand eines stabilen Ownership-/Startzeit-Belegs ausführen. Mindestens unmittelbar vor dem Signal Prozessstartzeit und erwartete Executable über `proc_pidinfo` revalidieren und bei jeder Abweichung fail-closed abbrechen; das verbleibende TOCTOU-Fenster ist zu dokumentieren.

### R4-HCLI-02 — Der Failsafe meldet Abschluss, obwohl Nachkommen und Pipe-Writer weiterleben

**Schweregrad:** hoch
**Klasse / Alt-Findings:** Detach-/Exit-Wahrheit und Teardown; verwandt mit `N07`, `N14` und `C10`.

**Beleg:**

- Die Continuation soll laut Vertrag erst bei Prozessende plus EOF beider Streams freigegeben werden (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:78-85,116-119`).
- Die Reader warten blockierend auf EOF (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:69-75`); EOF bleibt aus, solange irgendein geerbter Nachkomme einen Pipe-Write-FD offen hält.
- Die Eskalation signalisiert nur `process.processIdentifier`, nicht eine Prozessgruppe oder Nachkommen (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:97-100`).
- Nach weiteren fünf Sekunden ruft der Failsafe trotzdem `forceFinish` auf (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:101-107`); `forceFinish` umgeht ausdrücklich die Exit-/EOF-Bedingung (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:174-190`).
- Die Tests decken große Ausgabe und stdin-EOF jeweils nur mit einem einzelnen, sich sauber beendenden `/bin/sh` ab; kein Test lässt einen Nachkommen Pipe-FDs oder Config-Schreibarbeit behalten (`Tests/WhisperM8Tests/AgentSessionAutoNamerTests.swift:62-82`).

**Konkretes Auslöseszenario:** Ein Headless-CLI startet einen Helper im Hintergrund, der stdout/stderr erbt. Der direkte Child endet, der Helper schreibt aber weiter oder hält die FDs offen. `processExited` ist gesetzt, beide Reader bleiben blockiert, der `SIGKILL`-Timer sieht den direkten Child bereits als beendet und signalisiert nichts. Der Failsafe gibt den Actor/Caller frei, während der Helper weiterhin Plugin-/Profil-Dateien ändern kann.

**Auswirkung:** Der in Commit `9e4b9f4` behauptete Serialisierungsvertrag „Aufruf erst fertig, wenn der Subprozess wirklich tot ist“ gilt nicht für den Prozessbaum. Ein nachfolgender serialisierter Plugin-Aufruf kann mit dem alten Helper über dieselben Config-Dateien konkurrieren; zusätzlich bleiben zwei blockierte GCD-Reader zurück.

**Fix-Skizze:** Child in eine eigene Prozessgruppe setzen, bei Timeout die ganze besessene Gruppe terminieren und erst nach bestätigtem Gruppenende plus geschlossenem Pipe-Writer freigeben. Falls ein harter Failsafe unvermeidbar ist, Reader-FDs aktiv schließen, Ergebnis als „Lifecycle unbekannt“ statt als normale Timeout-Serialisierung propagieren und weitere mutierende CLI-Operationen sperren, bis Ownership/Config-Zustand reconciled ist.

### R4-CTRL-01 — Eingebettete Bracketed-Paste-/Control-Sequenzen brechen die Ein-Block-Garantie

**Schweregrad:** hoch
**Klasse:** Terminal-Injection / Parser-Grenze.

**Beleg:**

- `sendPrompt` sendet den Request-Text unverändert zwischen den festen Sequenzen `ESC[200~` und `ESC[201~` (`WhisperM8/Views/AgentTerminalView.swift:645-661`).
- Es gibt vor `terminal.send(txt: text)` keine Filterung von `ESC`, CR oder anderen C0/C1-Steuerzeichen (`WhisperM8/Views/AgentTerminalView.swift:657-661`).
- Der Protokolltest prüft nur, dass JSON eingebettete Newlines escaped und wieder dekodiert; Steuerzeichen-/Paste-Terminatoren werden nicht abgewiesen oder normalisiert (`Tests/WhisperM8Tests/ChatsControlTests.swift:6-23`).

**Konkretes Auslöseszenario:** Ein Prompt enthält `\u{1B}[201~`, danach `\r` oder weitere Terminal-Sequenzen. Der eingebettete Terminator beendet den Paste-Modus vorzeitig; das folgende CR kann den bis dahin eingefügten Text sofort submitten. Der vom Controller anschließend gesendete eigene Terminator und Return gehören dann nicht mehr zu einem einzigen Paste-Block.

**Auswirkung:** Ein über `whisperm8 chats send` transportierter String kann mehr Terminalaktionen auslösen als das API verspricht. Mehrzeilige/weitergereichte Agent-Ausgaben sind damit keine reine Datennutzlast mehr; die behauptete Grenze „kein generisches send-keys, ein Block/ein Submit“ ist umgehbar.

**Fix-Skizze:** Am Control-/Terminal-Boundary ausschließlich Textdaten erlauben: `ESC`, DEL und nicht benötigte C0/C1-Zeichen ablehnen oder sichtbar ersetzen; Newline und optional Tab explizit whitelisten. Den exakten Byte-Stream mit Fixtures für eingebettetes `ESC[201~`, CR, NUL und Unicode testen.

### R4-CTRL-02 — `delivered` wird vor dem Submit quittiert; parallele Sends können zu einem Prompt verschmelzen

**Schweregrad:** hoch
**Klasse / Alt-Findings:** TOCTOU- und Lifecycle-Wahrheit; verwandt mit `C10` und `N14`.

**Beleg:**

- `sendPrompt` pastet synchron, verschiebt den eigentlichen Return aber um 80 ms (`WhisperM8/Views/AgentTerminalView.swift:657-668`). Der verzögerte Block verwirft den Submit still, wenn `isRunning` dann false ist (`WhisperM8/Views/AgentTerminalView.swift:665-667`).
- Der Control-Handler behandelt den Aufruf unmittelbar als Erfolg (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:127-152`), markiert die Idempotenz-Reservierung als abgeschlossen und antwortet `ack: delivered` (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:165-174`).
- Verbindungen werden absichtlich nebenläufig bis vier Stück bedient (`WhisperM8/Services/AgentChats/AgentControlServer.swift:27-34`); es gibt keine target-spezifische Send-FIFO bis einschließlich Return.
- Die Control-Tests prüfen Codec, Token-Registry und Marker, aber keinen realen oder gespieten Terminal-Byte-Stream und keine zwei überlappenden Sends (`Tests/WhisperM8Tests/ChatsControlTests.swift:4-119`).

**Konkrete Auslöseszenarien:**

1. Die TUI endet innerhalb der 80 ms. Der Return wird verworfen, der Server hat aber bereits dauerhaft „delivered“ gespeichert und gemeldet.
2. Zwei Clients senden innerhalb derselben 80 ms an dasselbe Ziel. Beide Paste-Blöcke landen vor dem ersten Return im Composer; der erste Return kann den verketteten Inhalt als einen Prompt submitten, der zweite Return anschließend einen leeren/anderen Composerzustand.
3. Der alte Prozess endet und derselbe Controller/Terminalpfad wird vor dem verzögerten Block wieder laufend; der Return ist an keine Launch-Generation gebunden und kann den neuen Prozess treffen.

**Auswirkung:** Der TOCTOU-freie Guard+Paste-Block endet faktisch vor der zustandsändernden Submit-Aktion. Audit und Idempotenz behaupten eine Zustellung, die nicht oder semantisch falsch stattgefunden hat.

**Fix-Skizze:** Pro Zielcontroller eine FIFO-Transaktion einführen, die Paste und Submit einschließlich TUI-Grace serialisiert. Jede Transaktion trägt eine Launch-Generation und liefert ein Completion-Ergebnis; erst danach darf der Handler Idempotenz abschließen und `delivered` antworten. Prozesswechsel, Exit oder konkurrierender Send müssen explizit als Konflikt/unsicherer Ausgang zurückkommen.

### R4-PROFILE-01 — Settings-I/O-Fehler lassen Context-Profile still fail-open

**Schweregrad:** hoch
**Klasse:** Security-/Policy-Fail-open.

**Beleg:**

- Ein Context-Profil kann unter anderem `deniedMcpServers`, deaktivierte `.mcp.json`-Server, Plugin-Zustände und Environment-Policies in das Settings-Fragment schreiben (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:27-42`).
- `prepareSettingsFile` fängt jeden Fehler beim Event-/Settings-Schreiben, loggt nur und liefert `nil` (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:91-117`).
- Der Coordinator reduziert dieses `nil` auf leere Settings-Argumente und `hooksActive == false`, ohne den angeforderten Profilzustand als Fehler zu erhalten (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:120-135`).
- Der interaktive Launch baut danach trotzdem den Command und startet den Controller (`WhisperM8/Views/AgentSessionDetailView.swift:518-528`). Der Background-Pfad dokumentiert denselben Fail-open sogar ausdrücklich: I/O-Fehler → Spawn ohne Live-Events/Overlay (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:73-95`).
- Der Matrix-Test deckt nur erfolgreiche Schreibpfade in ein beschreibbares Temp-Verzeichnis ab; es gibt keinen Disk-full-/Permission-/Serialisierungsfehler mit nichtleerem Profil (`Tests/WhisperM8Tests/AgentSessionStatusCoordinatorTests.swift:210-255`).

**Konkretes Auslöseszenario:** Das App-Support-Verzeichnis ist nicht beschreibbar oder die Platte ist voll. Der User startet ein Projektprofil, das einen MCP-Server sperrt. Die Settings-Datei kann nicht geschrieben werden; WhisperM8 startet Claude dennoch ohne `--settings`. Der eigentlich gesperrte Server und nicht deaktivierte Plugins stehen der Session zur Verfügung.

**Auswirkung:** Ein diagnostischer Degradationspfad, der für reine Status-Hooks vertretbar war, ist seit dem Merge mit Context-Profilen eine Policy-Umgehung. Der User sieht keinen Launchfehler und kann fälschlich annehmen, die gewählten Einschränkungen seien aktiv.

**Fix-Skizze:** Vorbereitung als typisiertes `Result` mit getrennten Fällen `hooksUnavailable` und `profileUnavailable` modellieren. Bei nichtleerem Profil muss der Launch fail-closed stoppen und eine sichtbare, retrybare Fehlermeldung zeigen. Nur ein reiner Hook-Ausfall darf bewusst auf Transcript-Fallback degradieren.

### R4-SCHEMA-01 — Neue Context-Profil-Referenzen sind ohne Schema-Bump downgrade-verlustgefährdet

**Schweregrad:** hoch
**Klasse / Alt-Finding:** Persistenz/Future-Schema; konkrete Erweiterung von `N05`.

**Beleg:**

- Das Delta persistiert `contextProfileID` neu in `AgentProject` (`WhisperM8/Models/AgentChat.swift:173-207`) und `AgentChatSession` (`WhisperM8/Models/AgentChat.swift:315-466`).
- Store-Erstellung und Mutator schreiben diese Referenzen produktiv (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:203-208,522-568`).
- `AgentWorkspace.currentSchemaVersion` bleibt trotzdem `1`; der Decoder akzeptiert jede gelesene Ganzzahl ohne Obergrenzenprüfung (`WhisperM8/Models/AgentChat.swift:602-628`).
- Die neuen Tests beweisen nur Legacy-Decode und Same-Version-Roundtrip (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:199-251`), nicht New-Version→Old-Binary→Save.

**Konkretes Auslöseszenario:** Version B speichert Projekt- und Session-Stempel mit `contextProfileID`, weiterhin als Schema 1. Der User startet anschließend eine ältere Version A, deren Schema ebenfalls 1 ist. A ignoriert die unbekannten Felder und speichert bei der nächsten normalen Mutation den Workspace wieder ohne beide Referenzen. Beim erneuten Start von B sind Projekt-Default und stabile Session-Zuordnung verloren.

**Auswirkung:** Das bestätigte `N05` ist nicht nur theoretisch geblieben, sondern erhält mit diesem Delta neue user-sichtbare Daten, die ein Downgrade unbemerkt vernichtet. Sessions können danach mit keinem oder einem später geänderten Projektprofil starten.

**Fix-Skizze:** Workspace-Schema bumpen und vor jeder Migration/Mutation `schemaVersion > currentSchemaVersion` hart als read-only/future-schema behandeln. Keine Save-/Recovery-Schreibpfade auf einem unbekannten Future-Schema zulassen. Einen echten Downgrade-Kompatibilitätstest mit einer alten Decoder-/Encoder-Form ergänzen.

### R4-RESUME-01 — Ein fehlgeschlagener CLI-Resume verriegelt den neuen Trigger dauerhaft

**Schweregrad:** hoch
**Klasse / Alt-Finding:** Lifecycle-/Resume-Wahrheit; neue Verschiebung von `C09`.

**Beleg:**

- Der neue `shouldLaunchOnOpen`-Trigger setzt vor dem asynchronen Launch `focusLaunchInFlight = true` (`WhisperM8/Views/AgentSessionDetailView.swift:165-178`).
- Das Flag wird ausschließlich zurückgesetzt, wenn tatsächlich ein Controller erscheint (`WhisperM8/Views/AgentSessionDetailView.swift:203-205`).
- Ein Command-/Settings-/Resume-Fehler endet dagegen nur in `errorMessage`; das Flag bleibt gesetzt (`WhisperM8/Views/AgentSessionDetailView.swift:470-551`).
- Der besonders reale Missing-Transcript-Guard setzt `shouldLaunchOnOpen` wieder auf false und wirft (`WhisperM8/Views/AgentSessionDetailView.swift:624-633`), setzt aber `focusLaunchInFlight` ebenfalls nicht zurück.
- `session.resume` setzt bei jedem Versuch lediglich `shouldLaunchOnOpen = true` und meldet danach Erfolg (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:259-304`). Nach dem ersten false→true kann der View-Guard wegen des klemmenden Flags jeden Folgetrigger verwerfen.
- Im Testbestand gibt es nur Store-Assertions zum Flag, aber keinen SwiftUI-/Trigger-Test für Launchfehler und zweiten Resume (`Tests/WhisperM8Tests/AgentSessionStoreTests.swift:353-356,619`).

**Konkretes Auslöseszenario:** `whisperm8 chats resume` fokussiert einen bereits offenen Tab, dessen Transcript vorübergehend nicht auffindbar ist. Der View setzt `focusLaunchInFlight`, der Guard wirft und setzt das Persistenzflag false. Nach Wiederherstellung des Transcripts setzt ein zweiter CLI-Aufruf false→true; der neue `onChange` läuft, verwirft aber wegen `focusLaunchInFlight == true`. Jeder weitere Aufruf schreibt true auf true und erzeugt gar keinen neuen Change. Der CLI meldet dennoch `ok`.

**Auswirkung:** Genau der neue Reparaturpfad für bereits offene Tabs wird nach einem einzigen erwartbaren Fehler dauerhaft inert, bis eine andere manuelle UI-Aktion oder ein View-Neuaufbau den Zustand ersetzt.

**Fix-Skizze:** Das In-flight-Flag an den Task-Lifecycle binden und in einem MainActor-`defer` auf allen Erfolg-, Guard- und Fehlerpfaden zurücksetzen. `session.resume` braucht außerdem ein auslösbares Request-/Generation-Signal statt eines Bool-Level-Triggers und darf Erfolg erst nach angenommener Launch-Anforderung melden.

### R4-LIFE-01 — Eager GPT-Startup fügt einen neuen Kill-Switch-/Quit-Race-Pfad hinzu

**Schweregrad:** hoch
**Klasse / Alt-Findings:** bestehende `G01` (Proxy-Lifecycle) und `G04` (Kill-Switch) werden erweitert; `G02`/`G05` bleiben unbehoben.

**Beleg:**

- Beim App-Start wird der Toggle einmal synchron gelesen; danach startet ein ungebundener `Task.detached` `ensureRunning` (`WhisperM8/WhisperM8App.swift:304-313`). Zwischen Check und Ensure gibt es keine erneute Preference-/Generation-Prüfung.
- Der Quit-Pfad setzt Fensterzustand, capturt Snapshots und antwortet sofort `.terminateNow`; er wartet nicht auf den neuen Startup-Task (`WhisperM8/WhisperM8App.swift:352-367`). `applicationWillTerminate` flusht nur Audio-/Window-State (`WhisperM8/WhisperM8App.swift:370-377`).
- Die bestehenden Manager-Tests prüfen einen sequenziell bereits abgeschlossenen Ensure und posten erst danach `willTerminate`; Ensure↔Quit bzw. Toggle↔Ensure wird nicht parallelisiert (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:302-317`).

**Konkrete Auslöseszenarien:**

1. Die App liest `enabled == true`, der User deaktiviert das Backend, bevor der detached Block `ensureRunning` erreicht. Der vorbereitete Startup startet trotz neuem Kill-Switch-Zustand.
2. Der User beendet die App unmittelbar nach Launch. Quit/Manager-Cleanup kann vor der Prozessregistrierung laufen; der Ensure-Pfad registriert/startet danach noch Proxy oder Router, ohne dass der App-Lifecycle auf ihn wartet.

**Auswirkung:** Der bereits bestätigte Race war zuvor an Chat- oder Settings-Aktionen gebunden; das Delta macht ihn zu einem automatischen Startpfad bei jedem App-Launch. Ein deaktivierter oder beendeter Lifecycle kann dadurch weiterhin einen Listener/Child starten bzw. einen inkonsistenten Ready-Snapshot erzeugen.

**Fix-Skizze:** Proxy/Router-Start, Toggle-Änderung und App-Quit in einen einzigen generationenbasierten Lifecycle-Actor legen. `ensureRunning` muss vor jedem externen Side Effect und vor `.success` dieselbe aktive Generation prüfen; Quit invalidiert die Generation, cancelt/drained den Task und wartet auf bestätigten Stop, bevor die App terminiert.

### R4-GPTCTX-01 — UI erlaubt Kontextfensterwerte oberhalb des ausdrücklich nicht erhöhbaren Serverlimits

**Schweregrad:** mittel
**Klasse:** Konfigurationsvalidierung / Kompaktierungswahrheit.

**Beleg:**

- Der Default und dokumentierte reale GPT-5.6-Wert sind 272.000; der Getter erlaubt aber bis 500.000 (`WhisperM8/Support/AppPreferences.swift:298-317`).
- Das sichtbare Settings-Feld beschreibt 272.000 ausdrücklich als „serverseitig, nicht erhöhbar“, besitzt aber keine sichtbare Range-/Fehlervalidierung (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:264-276`).
- Der Builder übergibt den geclampten Wert unverändert als `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:331-344`).
- Der Test segnet bereits 300.000 als gültig ab und prüft bei einem Tippfehler nur den Clamp auf 500.000 (`Tests/WhisperM8Tests/PreferencesTests.swift:53-73`).

**Konkretes Auslöseszenario:** Der User trägt 500.000 ein. Claude Code berechnet Kontextanzeige und Auto-Compact gegen ein Fenster, das das GPT-Backend laut eigener UI nicht bereitstellt. Der Upstream kann deshalb das reale 272k-Limit erreichen, bevor die lokal erwartete Kompaktierung greift.

**Auswirkung:** Der neue Schutz gegen zu späte Kompaktierung lässt weiterhin eine dokumentiert ungültige Einstellung zu und kann genau den Ausfall erzeugen, den der Default 272.000 verhindern soll.

**Fix-Skizze:** Für die aktuell wählbaren GPT-5.6-Modelle auf maximal 272.000 begrenzen. Größere zukünftige Fenster dürfen erst modell-/capability-gebunden freigeschaltet werden, nicht über eine pauschale 500k-Obergrenze. UI muss ungültige Eingaben unmittelbar markieren statt sie erst beim Lesen unsichtbar zu clampen.

### R4-TOKEN-01 — Session-Tokens werden nach PTY-Ende nie widerrufen

**Schweregrad:** mittel
**Klasse / Alt-Finding:** Secret-/Lifecycle-Hygiene; berührt `N09`, ist wegen des dokumentierten same-UID-Modells aber keine starke Auth-Umgehung.

**Beleg:**

- Jeder PTY-Start erzeugt ein neues Session-Token und legt es in die Prozessumgebung (`WhisperM8/Views/AgentTerminalView.swift:783-815`).
- Sowohl `terminate()` als auch der natürliche `processTerminated`-Pfad setzen den Prozess nur auf beendet; keiner ruft `AgentSessionTokenRegistry.revoke` (`WhisperM8/Views/AgentTerminalView.swift:820-842,1014-1025`).
- Die Registry bietet einen Widerrufspfad an (`WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift:31-44`), produktive Aufrufer existieren im gelesenen Lifecycle nicht.
- Ein gültiges Token steuert die verifizierte Audit-Zuordnung (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:550-580`). Die Registry-Tests widerrufen nur manuell am Testende und prüfen nicht den Terminal-Lifecycle (`Tests/WhisperM8Tests/ChatsControlTests.swift:78-100`).

**Konkretes Auslöseszenario:** Ein vom PTY gestarteter Nachkomme überlebt das Terminalende oder hat das Environment kopiert. Solange die Session nicht neu gestartet wird, bleibt sein Token im App-Prozess gültig. Spätere Control-Aufrufe dieses Prozesses erscheinen im Audit weiterhin als verifiziert von der längst beendeten Session.

**Auswirkung:** Das Token ist laut eigener Registry-Dokumentation primär Rechenschaft/Versehensschutz, nicht same-UID-Security. Deshalb ist der Schaden vor allem falsche Audit-Attribution und ein unnötig langes Secret-Lifetime-Fenster, nicht zusätzliche Control-Autorität.

**Fix-Skizze:** Token in beiden Exitpfaden idempotent widerrufen; auf Restart erst nach vollständigem Ende der alten Generation neu ausgeben. Einen Lifecycle-Test ergänzen: Start→verify true→natürlicher Exit/terminate→verify false.

## Einordnung von Commit `9e4b9f4` und `0476181`

Innerhalb dieses Audits fällt von `9e4b9f4` nur `AgentHeadlessCLI.swift` in den vorgegebenen Dateisatz. Die übrigen Commit-Teile (Plugin-Serializer, Scope-UI, `ClaudeContextProfileStore`, Plugin-Parser/-Model) liegen außerhalb dieses Delta-Auftrags und werden hier nicht als verifiziert ausgegeben.

Für den Headless-Teil ist die Einordnung zweigeteilt:

- **Wirksamer Fix:** stdin wird auf EOF gelegt (`AgentHeadlessCLI.swift:39-41`), und stdout/stderr werden schon während der Laufzeit konsumiert (`AgentHeadlessCLI.swift:61-75`). Der 300-kB-Regressionstest belegt den früheren Pipe-Puffer-Deadlock für einen einzelnen Prozess (`AgentSessionAutoNamerTests.swift:62-71`).
- **Sinnvoller Follow-up:** `0476181` ersetzt die EOF-anfälligen `readabilityHandler` durch zwei blockierende Reader. Damit sind leere Streams und Data+EOF nicht mehr vom Callback-Timing abhängig (`AgentHeadlessCLI.swift:61-75`).
- **Nicht eingelöste Garantie:** Die Timeout-Kaskade ist weder PID-identitätssicher noch prozessbaumvollständig (`R4-HCLI-01`, `R4-HCLI-02`). Der Commit behebt also Pipe-Durchsatz und den normalen Einzelprozess-Lifecycle, nicht die bestätigten Prozessidentitäts-/Detach-Klassen vollständig.

## Delta-Matrix: neue Fehler und Alt-Finding-Verschiebung

| Datei / Delta | (a) Neue Bugs/Races? | (b) Berührte bestätigte Findings |
|---|---|---|
| `ClaudeHookBridge.swift:86-117` | Ja: Profil-Settings degradieren bei I/O-Fehler still zu `nil` (`R4-PROFILE-01`). | Status-Hook-Degradation war zuvor nur Diagnose; seit Profil-Merge ist sie Security-fail-open. `C08` wird nicht behoben. |
| `ClaudeHookSettingsBuilder.swift:70-92` | Kein weiterer eigenständiger Fehler nachgewiesen; generischer atomischer Writer ermöglicht den Compose-Pfad. | Keine bestätigte C/N/G-Klasse behoben. |
| `AgentSessionStatusCoordinator.swift:98-135` | Der neue `hooksActive`-Typ verhindert korrekt, dass profil-only-Dateien als Hook-Dateien getrackt werden; er verliert aber den Profil-Schreibfehler (`R4-PROFILE-01`). | `C08` bleibt: harter Tod eines Background-Jobs ohne `SessionEnd` wird weiterhin nicht reconciled. |
| `AgentSessionStore.swift:203-208,522-568` | Neue persistierte Referenzen ohne Schema-Lifecycle (`R4-SCHEMA-01`). | `N05` wird konkret erweitert; `C07`-Bind-/Dedupe-Logik und `C11`-Callback-Ordnung werden durch dieses Delta nicht verändert. |
| `AgentHeadlessCLI.swift:28-212` | Ja: `R4-HCLI-01`, `R4-HCLI-02`; zusätzlich zwei blockierte Utility-Reader pro hängendem Prozessbaum. | Neuer `N01`-artiger PID-Race; `N07`-/`N14`-ähnliche Exit-Wahrheit bleibt offen. `C05` bleibt vollständig: kein `currentDirectoryURL`, kein `--no-session-persistence` in den Auto-Namer-/Summarizer-Args (`AgentSessionAutoNamer.swift:138-146,193-205`; `AgentSessionSummarizer.swift:32-38`). |
| `AgentCommandBuilder.swift:87-124,178-183,286-344,444` | Kontext-Env-Priorität ist im gelesenen Pfad deterministisch. Die neue Kontextfensterkonfiguration akzeptiert jedoch ein unmögliches Fenster (`R4-GPTCTX-01`). | `C06` wird nicht behoben: die neue Merge-Logik betrifft PTY-Commands; der Background-Stub/Spawner stempelt weiterhin kein `claudeProfileName` (`AgentChatsView+BackgroundAgents.swift:43-64`). `G05`-Port-Snapshot bleibt. |
| `AgentWorkspaceRepository.swift:20-35` | Kein neuer Writer-Race: `loadReadOnly` schreibt tatsächlich nicht. Bei korrupter Hauptdatei kann die CLI zwar still einen älteren Backup-Stand zeigen; das ist ein Sichtbarkeits-/Diagnoseproblem, kein Lost Update. | Verengt `N05` für `whisperm8 chats`: der CLI-Prozess migriert/quarantänisiert/speichert nicht. Der App-Store akzeptiert Future-Schema weiterhin und kann es überschreiben; `N05` ist daher nicht gelöst. |
| `Models/AgentChat.swift:173-207,315-466,602-628` | Ja: `R4-SCHEMA-01`. | Direkte Fortsetzung von `N05`. Parser-/Codex-Drift (`N15`, `N16`) wird nicht berührt. |
| `AgentTerminalView.swift:645-676,800-815` | Ja: Terminal-Injection, asynchron falsche Zustellwahrheit und fehlender Token-Revoke (`R4-CTRL-01`, `R4-CTRL-02`, `R4-TOKEN-01`). | `N09` wird um ein absichtlich injiziertes Secret erweitert. `C10` bleibt: der bestehende `terminate()` blockiert MainActor weiterhin per `usleep` und capturt vor später zugestellten Main-Queue-Bytes (`AgentTerminalView.swift:820-840`). Das ursprüngliche `N01`-Restart-Race wird nicht geändert. |
| `AgentChatsView+SessionLifecycle.swift:28-78,94-115` | Das Stempeln/Fork-Erben ist synchron und im Delta ohne eigenen Race; die Daten sind aber von `R4-SCHEMA-01` betroffen. | `C06` bleibt für Background-Accountprofile; `C07`/`C09` werden nicht durch das Stempeln gelöst. |
| `AgentSessionDetailView.swift:165-178,470-551` | Ja: In-flight-Latch nach Fehler (`R4-RESUME-01`); Profil-I/O startet fail-open (`R4-PROFILE-01`). | Verschiebt `C09`: ein stiller Fresh-Start wird im heutigen Missing-Transcript-Guard zwar verhindert (`AgentSessionDetailView.swift:624-633`), dafür kann der neue CLI-Resume-Trigger nach einem Fehler dauerhaft ausfallen. `G01`/`G04` des Proxy-Launches bleiben. |
| `WhisperM8App.swift:286-313` | Ja: automatischer Check→detached-Ensure ohne Generation/Drain (`R4-LIFE-01`). Der Control-Server selbst bindet UDS mit 0700/0600 und Peer-EUID-Prüfung (`AgentControlServer.swift:5-17,70-76,129-169`); kein Port-Hijack-Gegenbeleg gefunden. | Erweitert `G01` (Proxy Start↔Stop/Quit) und `G04` (Kill-Switch). `G02` (Crash ohne Recovery) und `G05` (Port-Snapshot) bleiben. Runde-3-Security-`G01` (fremder Health-Listener) wird durch Eager-Start weder behoben noch neu widerlegt. |
| `AppPreferences.swift:298-317,477` | Ja: erlaubte 500k widersprechen dem nicht erhöhbaren 272k-Limit (`R4-GPTCTX-01`). | Usage-/Kompaktierungsarbeit wird ergänzt, aber kein bestehendes C/N-Finding geschlossen. |

## Explizite Alt-Finding-Bilanz

### Berührt, aber nicht vollständig behoben

- `C05`: Headless-I/O ist robuster, Junk-Session-Persistenz und App-cwd bleiben.
- `C06`: Context-Profil-Env ist nicht Account-Profil-Propagation; Background-Spawn bleibt ohne `claudeProfileName`.
- `C08`: profil-only vs. Hooks wird korrekt getrennt, harte Background-Job-Tode bleiben unreconciled.
- `C09`: Resume-Missing-Transcript wird ehrlicher, der neue boolbasierte Trigger kann sich aber verriegeln (`R4-RESUME-01`).
- `C10`: neue Control-Sends führen einen weiteren verzögerten Teardown-/Zustellpfad ein; der alte `usleep`-Snapshot-Bug bleibt.
- `C11`: neuer Projektprofil-Mutator nutzt denselben Store; die Callback-Reihenfolge wird nicht serialisiert.
- `N01`: `AgentHeadlessCLI` führt eine neue rohe PID-Signalisierung ein (`R4-HCLI-01`).
- `N05`: `loadReadOnly` schützt den CLI-Reader, neue Schema-1-Felder verschärfen aber den App-Downgrade (`R4-SCHEMA-01`).
- `N07`/`N14`: Headless-Timeout hat weiterhin keine Prozessbaum-/vollständige Exit-Garantie (`R4-HCLI-02`); die ursprünglichen Supervisor-Fundstellen werden nicht geändert.
- `N09`: Context-Env und Session-Token werden bewusst an Child-Prozesse gegeben; die allgemeine Parent-Environment-Vererbung bleibt. Der Token-Lifecycle ist zu lang (`R4-TOKEN-01`).
- Runde-3-Proxy-`G01`, `G02`, `G04`, `G05`: Eager-Startup erweitert `G01`/`G04`; Crash-Recovery und atomarer Endpunkt-Snapshot bleiben offen.
- Runde-3-Proxy-`G03`: Context-Settings beim `--bg`-Spawn ersetzen keinen GPT-Guard/Router-Environment-Snapshot; kein Fix im geprüften Delta.

### Im geprüften Delta nicht materiell berührt

- `C01–C04`, `C12–C16`
- `N02–N04`, `N06`, `N08`, `N10–N13`, `N15`, `N16`
- Runde-3-Mixrouter-`G01–G07`
- Runde-3-Definition/Settings-`G01–G05` (die gleichnamigen `G`-IDs gehören zu einem anderen Teil-Audit)
- Runde-3-Security-`G02–G04`

Für diese IDs enthält der untersuchte Dateisatz weder einen belastbaren Fix noch eine neue Ausprägung; daraus folgt ausdrücklich kein Gesamturteil über Änderungen außerhalb dieses Bereichs.

## Testlücken

1. **Headless Prozessidentität/-baum:** Kein Exit-genau-vor-`SIGKILL`, keine PID-Reuse-Simulation, kein daemonisierter Nachkomme mit geerbten Pipe-FDs und kein Nachweis „keine Config-Mutation nach Timeout“ (`AgentSessionAutoNamerTests.swift:49-82`).
2. **Control-Terminal-Bytes:** Kein Test für `ESC[201~`, CR/NUL/C1, zwei parallele Sends, Exit/Restart in der 80-ms-Grace oder Ack erst nach Submit (`ChatsControlTests.swift:4-119`).
3. **Profil fail-open:** Die Settings-Matrix prüft nur erfolgreiche Temp-Datei-Schreibvorgänge, nicht readonly Directory, Disk-full oder atomischen Write-/chmod-Fehler (`AgentSessionStatusCoordinatorTests.swift:210-255`).
4. **Downgrade:** Legacy-Decode und aktueller Roundtrip sind grün, aber kein alter Encoder überschreibt einen Workspace mit den neuen `contextProfileID`-Feldern (`ClaudeContextProfileTests.swift:199-251`).
5. **Resume-Trigger:** Kein View-/State-Harness für `false→true`, Launchfehler, Flag-Reset und zweiten CLI-Resume (`AgentSessionStoreTests.swift:353-356,619`).
6. **Proxy Lifecycle:** Der bestehende Quit-Test serialisiert Ensure vollständig vor die Notification; Check→Toggle, Ensure↔Stop und Ensure↔Quit fehlen (`ClaudeCodeProxyManagerTests.swift:302-317`).
7. **Kompaktierungsgrenzen:** Tests prüfen das Mapping in die Environment, nicht die Invariante `konfiguriertes Fenster <= Capability des effektiven Modells`; 300k und 500k werden derzeit absichtlich akzeptiert (`PreferencesTests.swift:53-73`; `AgentCommandBuilderTests.swift:496-533`).
8. **Token-Lifecycle:** Registry-Revoke wird isoliert getestet, aber weder natürlicher PTY-Exit noch `terminate()` widerruft im Test (`ChatsControlTests.swift:78-100`).

## Positive Befunde

- `0476181` beseitigt den ursprünglichen Pipe-Puffer-Deadlock für normale Einzelprozesse: stdout und stderr werden parallel konsumiert, bevor der Child terminieren muss (`AgentHeadlessCLI.swift:61-75`).
- stdin auf `/dev/null` verhindert, dass Headless-Subcommands an interaktiven Prompts hängen (`AgentHeadlessCLI.swift:39-41`).
- `LaunchSettingsPreparation.hooksActive` trennt korrekt „Settings-Datei vorhanden“ von „Hook-Eventfile vorhanden“ und verhindert profil-only Tracking auf ein nicht existierendes Event-File (`AgentSessionStatusCoordinator.swift:98-135`).
- Context-Env verliert im PTY-Builder deterministisch gegen Account- und Router-Keys (`AgentCommandBuilder.swift:286-344,444`); die zugehörigen Tests decken Normal-, Konflikt- und Resume-Repair-Pfad (`AgentCommandBuilderTests.swift:821-894`).
- `loadReadOnly` ist für den neuen CLI-Reader tatsächlich schreibfrei und reduziert damit Single-Writer-/Lost-Update-Risiken (`AgentWorkspaceRepository.swift:20-35`).
- Der neue Control-Server verwendet UDS statt TCP, restriktive Dateirechte und `getpeereid`; im geprüften `WhisperM8App`-Delta wurde kein Port-Hijack der Klasse Runde-3-Security-`G01` eingeführt (`AgentControlServer.swift:5-17,70-76,129-169`).
