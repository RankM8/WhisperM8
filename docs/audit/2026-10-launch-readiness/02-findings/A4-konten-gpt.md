---
status: roh
updated: 2026-10-17
description: Workflow A, A4 Konten + GPT-Backend — Rohbefunde des GPT-Finders (aus der strukturierten Rückgabe erzeugt, noch unverifiziert).
---

# A4 Konten + GPT-Backend

> Unverifiziert. Schweregrade sind die Einschätzung des Finders; Workflow C prüft sie gegen.

## Kurzfazit

A4 statisch geprüft: 35 Dateien des Auftrags vollständig gelesen, ergänzende Integrationsstellen und Regressionstests geprüft. Ergebnis: 16 Befunde (7 P0, 8 P1, 1 P2). Besonders kritisch sind Secret-Übergaben in argv, fremde Transcript-Löschungen beim Usage-Ping, ungeschützte lokale GPT-Zugänge und zwei Wege zum Verlust laufender Arbeit. Positiv: Downloads werden tatsächlich SHA-256-geprüft; der reguläre App-Start lädt bei ausgeschaltetem GPT-Backend keinen Proxy herunter; Transkriptions-Prewarm ist gegatet; Usage-Fetcher rotieren selbst keine Tokens; Memory-Migration sichert Quellen und überschreibt reguläre Konfliktdateien nicht. Keine Produktänderungen, Builds, Tests oder App-Starts durchgeführt. Berichtdateien wurden nicht angelegt; alle Ergebnisse stehen in diesem Objekt.

## Befunde

### LR-KO-001 (A4-01) · OAuth- und Refresh-Tokens stehen beim Umbenennen und Hochstufen im Prozess-argv

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-KO-01  ·  **Alt-ID:** N10

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:468-471`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:422-430`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles+Promote.swift:218-222`

**Szenario:** Ein angemeldetes Profil wird umbenannt oder zum Hauptkonto gemacht. Das vollständige Keychain-Secret einschließlich Refresh-Token wird als Wert hinter security ... -w an einen Kindprozess übergeben. Ein lokaler Prozess mit Zugriff auf dessen Prozessargumente kann den Login während dieses Aufrufs abgreifen. Dies verletzt unmittelbar die Definition of Done für Secrets in argv.

**Fix:** Keychain-Lesen und -Schreiben über Security.framework statt über security mit Passwortargument durchführen. Bestehende Service-Namen, Rollback, Verschieben statt dauerhafter Credential-Kopie und Profil-Stempel beibehalten; Regressionstest darf Secret-Werte in keinem Prozessargument finden.

### LR-KO-002 (A4-02) · MCP-Angleich veröffentlicht Header-Tokens und andere Server-Secrets in argv

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-KO-04

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeMCPSync.swift:75-79`, `WhisperM8/Services/AgentChats/ClaudeMCPSync.swift:131-136`, `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:246-249`

**Szenario:** Ein User-MCP-Server enthält beispielsweise headers.Authorization mit einem Bearer-Token. Beim Klick auf Copy oder beim aktivierten Start-Angleich wird die gesamte unveränderte Definition als add-json-Argument gestartet. Der Token ist damit über Prozessargumente zugänglich, obwohl der Code Definitionen bewusst nicht protokolliert.

**Fix:** Für die echte CLI einen nachweislich unterstützten, nicht über argv oder vererbtes Env laufenden Secret-Kanal verwenden. Bis dahin secret-haltige Definitionen nicht automatisch verteilen, sondern deren sichere Einrichtung je Konto anbieten. Nur-Ergänzen, Konfliktsperre und Ausschlüsse erhalten; Argv-Leak-Test mit Header- und Env-Secrets ergänzen.

### LR-KO-003 (A4-03) · Usage-Ping löscht fremde Projektverläufe allein aufgrund eines Namenssuffixes

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-KO-05, F-AC-02

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift:35-43`, `WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift:119-129`, `WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift:166-172`, `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:327-328`

**Szenario:** Der Nutzer hat reguläre Chats in einem Projekt /Users/x/repos/whisperm8-limit-ping. Dessen encodierter projects-Ordner endet ebenfalls auf -whisperm8-limit-ping. Nach einem manuellen Usage-Update mit abgelaufenem Token löscht cleanupPingArtifacts diesen gesamten Ordner einschließlich aller echten Transcripts und Memory-Dateien ohne Backup. Das funktioniert auch mit genau einem Konto.

**Reproduktion:** Isolierte Fixture mit zwei projects-Ordnern anlegen: echter Ping-cwd und fremder Repo-cwd mit identischem Basename. cleanupPingArtifacts darf ausschließlich die eigenen Ping-Artefakte entfernen.

**Fix:** Ausschließlich den aus dem tatsächlichen Ping-Arbeitsverzeichnis berechneten Projektpfad und vorzugsweise die konkret erzeugte Session-ID bereinigen; vor rekursiver Löschung Ownership und cwd prüfen. Fremde gleichnamige Projekte müssen unberührt bleiben. Die gewünschte Unterdrückung importierter Ping-Sessions erhalten.

### LR-GPT-001 (A4-04) · Jeder lokale Benutzer kann GPT-Konten über den Router ohne Authentisierung benutzen

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand L · Risiko hoch*

**Features:** F-GPT-01, F-GPT-02  ·  **Alt-ID:** R3-SEC-G02

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:250-254`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:725-746`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:119-128`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:639-645`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:920-996`

**Szenario:** Bei aktiviertem Backend sendet ein anderer lokaler macOS-Benutzer einen HTTP-Request mit gültigem GPT-Modell und X-WhisperM8-GPT-Profile an den Loopback-Router. Es gibt weder Benutzer- noch Client-Credential-Prüfung. Der Router entfernt gegebenenfalls mitgelieferte Auth-Header und benutzt stattdessen die angemeldete Proxy-Instanz des gewählten Kontos, nötigenfalls nach deren Hintergrundstart. Fremde Prozesse können dadurch Kontingent verbrauchen und Konten unter fremder Identität verwenden.

**Fix:** Eine echte per-User-Zugriffsgrenze und Client-Authentisierung vor Routing und Instanzstart einführen; Loopback und ein frei wählbarer Profilheader reichen nicht. Direkte Proxyports müssen ebenfalls geschützt werden, damit kein Bypass entsteht. Echte CLIs, Streaming und kontostabile Profilzuordnung erhalten; Negativtests mit fremden/fehlenden Credentials ergänzen.

### LR-GPT-002 (A4-05) · Eine nachgeahmte Health-Antwort genügt zur Übernahme sämtlicher GPT-Prompts

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand L · Risiko hoch*

**Features:** F-GPT-01, F-GPT-03, F-DIK-03  ·  **Alt-ID:** R3-SEC-G01

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:404-412`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:1298-1366`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:187-194`, `WhisperM8/Services/Dictation/ChatGPTSubscriptionTranscription.swift:231-251`

**Szenario:** Vor dem Backend-Start belegt ein fremder lokaler Prozess den konfigurierten Proxyport und liefert auf /healthz HTTP 200, application/json und {"ok":true}. ensureRunning überspringt daraufhin den eigenen Prozessstart. GPT-Anfragen mit vollständigem Verlauf und Tool-Inhalten gehen an den Fremdlistener. Die Transkription sendet bei bekanntem main-Port sogar unmittelbar ihr Audio dorthin. Eine Prozess- oder Serveridentität wird nicht geprüft.

**Fix:** Vor Wiederverwendung eines Listeners dessen Benutzer, Prozessidentität und Instanzzugehörigkeit nachweisen und den HTTP-Kanal authentisieren. Externe Proxys nur nach expliziter, geprüfter Zuordnung übernehmen; keine statische Health-Antwort als Vertrauensnachweis verwenden. Audio-Uploads müssen dieselbe Identitätsgarantie nutzen, ohne den vorhandenen Connection-refused-Retry zu verlieren.

### LR-GPT-003 (A4-06) · Hohe konfigurierte Proxyports bringen die gesamte App beim Profilstart zum Absturz

*P0 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-GPT-02, F-GPT-03

**Beleg:** `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:270-275`, `WhisperM8/Support/AppPreferences.swift:273-278`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:727-735`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:748-752`, `WhisperM8/Views/Settings/Pages/GPTAccountsSection.swift:443-448`

**Szenario:** Der Nutzer trägt beispielsweise 65530 als Port ein und aktiviert anschließend ein angemeldetes Zusatzprofil. Der Preference-Getter akzeptiert den positiven Wert. allocateProfilePort addiert zehn und übergibt 65540 an isPortFree; UInt16(port) löst einen Overflow-Trap aus. Damit endet die gesamte App einschließlich aller normalen Diktate und PTY-Chats.

**Fix:** Ports an UI- und Servicegrenzen validieren; den Profilbereich vor Addition auf 1...65535 begrenzen und UInt16(exactly:) verwenden. Bei erschöpftem Bereich einen verständlichen Fehler liefern, niemals trapen. Grenzwerttests für 65525, 65530, 65535 und Int.max ergänzen.

### LR-KO-004 (A4-07) · Vorgemerkte Kontowechsel können zwischenzeitlich eingegebene Entwürfe verwerfen

*P0 · Launch-Blocker · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-KO-02

**Beleg:** `WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift:175-215`, `WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift:224-245`, `WhisperM8/Services/AgentChats/AccountSwitchPlanner.swift:130-147`

**Szenario:** Zwei Chats haben Vormerkungen zu unterschiedlichen Zielkonten. Ein Timerlauf klassifiziert beide als idle und entnimmt beide aus pending. Während der erste Zielgruppenwechsel an waitForExit suspendiert, tippt der Nutzer einen neuen, ungesendeten Entwurf in den zweiten Chat oder startet dort einen Turn. Danach verarbeitet die Schleife dessen zuvor berechnete ready-Gruppe; switchRunning prüft weder Status noch Composer erneut und beendet den Prozess. Der Entwurf geht verloren beziehungsweise der neue Turn wird unerwartet abgebrochen.

**Fix:** Unmittelbar vor jedem terminate auf dem MainActor Status, Entwurf, Hintergrundaufgaben und Laufidentität neu prüfen. Neu beschäftigte Chats wieder vormerken statt stoppen. Das gemeinsame Journal-Batching und nachgewiesene Prozessende vor Dateibewegung erhalten. Einen Reentranztest mit zwei Zielgruppen und während des ersten waitForExit neu gesetztem Entwurf ergänzen.

### LR-KO-005 (A4-08) · Ein laufendes inaktives Claude-Profil lässt sich ohne Prozessschutz entfernen

*P1 · datenintegritaet · Konfidenz mittel · Aufwand S · Risiko mittel*

**Features:** F-KO-01

**Beleg:** `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:231-234`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:523-531`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:612-635`

**Szenario:** Ein Chat unter Profil A läuft weiter, während B zum aktiven Profil für neue Chats wird. Remove ist für A dadurch freigeschaltet. Anders als Rename und Promote prüft removeProfile keine laufenden Sessions und verschiebt unmittelbar den gesamten Config-Root samt Transcripts in den Papierkorb. Der laufende Prozess behält seinen alten CLAUDE_CONFIG_DIR, dessen Verlauf dort nicht mehr liegt; weitere Verlaufsschreibvorgänge können scheitern oder einen getrennten neuen Root erzeugen.

**Fix:** Entfernen bei laufenden Profil-Chats sperren oder einen ausdrücklichen Stop-and-wait-Ablauf vor dem Verschieben anbieten. Nach einer Bestätigung frisch prüfen, nicht nur vor dem Dialog. Papierkorb-Rettbarkeit und Plugin-Registry-Schutz erhalten.

### LR-KO-006 (A4-09) · Profil-Rename bricht profilgebundene Plugin-Registrierungen für alle Konten

*P1 · korrektheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-KO-01

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles+SharedConfig.swift:82-111`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:449-463`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles+Promote.swift:81-84`

**Szenario:** Ein Plugin oder Marketplace wurde aus einem Profil installiert; die gemeinsame Registry unter main enthält daher einen installPath beziehungsweise installLocation durch ~/.claude-profiles/alt/. Das Umbenennen nach neu verschiebt alt vollständig, ohne den bei Remove und Promote vorhandenen Registry-Guard. Die registrierten alten Pfade verschwinden und das gemeinsam verwendete Plugin ist anschließend auch in main und anderen Konten nicht mehr ladbar.

**Fix:** Den vorhandenen pluginRegistryReferences-Guard auch vor Rename anwenden oder einen über die echte CLI kontrollierten Registry-Umzug implementieren. Gemeinsame Plugins, eigene abweichende Profilkonfigurationen und Login-Erhalt müssen unverändert funktionieren.

### LR-KO-007 (A4-10) · Ein Keychain-Lesefehler wird beim Rename als fehlender Login behandelt

*P1 · robustheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-KO-01

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:457-477`, `Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:394-406`

**Szenario:** Das Profil besitzt einen Login, aber der Schlüsselbund ist gesperrt oder der Nutzer verweigert den Lesezugriff. security liefert einen Fehlerstatus. renameProfile unterscheidet diesen Zustand nicht von ItemNotFound, verschiebt den Profilordner trotzdem und meldet Erfolg. Wegen des pfadabhängigen Keychain-Service-Namens findet der umbenannte Account den weiterhin unter dem alten Namen vorhandenen Login nicht mehr.

**Fix:** Nur einen eindeutig nachgewiesenen ItemNotFound-Status als loginlos akzeptieren. Bei Zugriffs-, Interaktions- und sonstigen Lesefehlern vor jeder Dateibewegung abbrechen. Mit Security.framework die tatsächlichen OSStatus-Werte erhalten; Tests für verweigerten Zugriff und gesperrten Schlüsselbund ergänzen.

### LR-KO-008 (A4-11) · Transcript-Kollisionen werden beim Umzug nach main als erfolgreicher No-op verschleiert

*P1 · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-KO-01

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:295-296`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:527-539`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:570-579`, `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:364-372`, `WhisperM8/Services/AgentChats/AccountMoveService.swift:81-95`

**Szenario:** Ein Chat ist auf Zusatzprofil A gestempelt und hat dort den aktuellen Verlauf; unter main liegt noch eine ältere Kopie derselben ID und desselben cwd. Beim Umzug nach main sucht der Locator global mit main zuerst. Dadurch hält bereits die Konfliktvorschau die alte Zieldatei für die Quelle, meldet keinen Konflikt und moveTranscript liefert No-op. Der Service stempelt den Chat dennoch nach main: Resume setzt die alte Kopie fort, während der aktuelle Verlauf in A zurückbleibt.

**Fix:** Den bekannten Herkunftsaccount in Vorschau und Ausführung als verbindlichen Quell-Root verwenden. Bei mehreren vorhandenen Kopien außerhalb dieses Roots einen Konflikt melden, statt eine davon still auszuwählen. Glob-Fallback für abweichende cwd-Kodierung, Subagent-Mitnahme und Nichtüberschreiben erhalten; beide Kollisionsrichtungen testen.

### LR-KO-009 (A4-12) · Teilweise fehlgeschlagenes Rückgängig löscht auch die noch offenen Journal-Einträge

*P1 · korrektheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-KO-01

**Beleg:** `WhisperM8/Services/AgentChats/AccountMoveService.swift:137-157`, `WhisperM8/Services/AgentChats/AccountMoveService.swift:165-169`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:558-561`

**Szenario:** Ein Batch hat Chats aus zwei Herkunftsprofilen nach C verschoben. Vor Undo ist eines der Herkunftsprofile vorübergehend entfernt oder sein Ziel nicht beschreibbar. Ein Chat wird erfolgreich zurückbewegt, der andere scheitert. Weil outcome.moved nicht leer ist, entfernt clearLastBatch sämtliche Einträge außer aktuell laufenden Chats. Der fehlgeschlagene Chat verliert damit seine Undo-Information; nach Behebung des Hindernisses kann Rückgängig ihn nicht mehr zurückholen.

**Fix:** Nur erfolgreich zurückgenommene Entry-/Session-IDs aus dem Batch entfernen. Fehlgeschlagene, laufende und nicht auflösbare Einträge mit ihrer Herkunft erhalten und getrennt melden. Best-effort-Teilerfolge und Vermeidung einer Undo-Pendelschleife beibehalten.

### LR-GPT-004 (A4-13) · Ein paralleler Start kann den Proxy nach Stop oder App-Quit weiterlaufen lassen

*P1 · Launch-Blocker · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-GPT-03  ·  **Alt-ID:** R3-PROXY-G01

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:404-435`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:457-462`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:761-777`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:603-612`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:383-390`

**Szenario:** ensureRunning hält ensureLock, hat aber seinen gerade startenden main-Prozess noch nicht veröffentlicht. Parallel läuft Stop oder der willTerminate-Hook: stopIfSelfStarted sieht keinen Handle und stoppt keinen Router. Erst das abschließende stopAllProfileInstances wartet auf ensureLock. Dazwischen veröffentlicht ensureRunning den main-Prozess und startet den Router; anschließend stoppt der wartende Aufruf ausschließlich Profilinstanzen. Der neue main-Prozess bleibt bestehen und überlebt gegebenenfalls das App-Ende beziehungsweise die Deinstallation entgegen W7.

**Fix:** Start, Stop und Quit über dieselbe Lifecycle-Serialisierung mit Stop-/Shutdown-Generation führen. Vor einem Start-Commit einen inzwischen gesetzten Stop-Zustand beachten; alle selbst gestarteten Instanzen und der eigene Router müssen in derselben Zustandsänderung erfasst werden. Externe Prozesse weiterhin unangetastet lassen.

### LR-GPT-005 (A4-14) · GPT-Hauptkonto wird auch bei weiterhin lebenden alten Proxys ausgetauscht

*P1 · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-GPT-02

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:662-675`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:677-681`, `WhisperM8/Services/AgentChats/GPTAccountProfiles.swift:462-485`

**Szenario:** Beim Promote reagiert main oder die Profilinstanz innerhalb der etwa drei Sekunden nicht auf SIGTERM. Nach Ablauf der Schleife wird isRunning nicht erneut als Abbruchbedingung geprüft: moveGrant tauscht trotzdem den Grant und entfernt das Profil. Ein alter lebender main-Prozess kann danach weiterhin mit seinem bisherigen Konto antworten oder einen alten Refresh-Grant zurückschreiben. Der anschließende ensureRunning kann ihn wegen erfolgreicher Health-Probe sogar wiederverwenden. Die angezeigte neue Kontoidentität stimmt dann nicht mit dem tatsächlich verwendeten Login überein.

**Fix:** Den Grant erst nach positiv nachgewiesenem Ende beider konkreten Prozesse austauschen. Bei Timeout vor jeder Dateimutation abbrechen und Handles zur weiteren kontrollierten Bereinigung behalten; gegebenenfalls begrenzte Eskalation für ausschließlich eigene Prozesse anbieten. Tests mit einem Handle ergänzen, der trotz terminate weiterlebt.

### LR-GPT-006 (A4-15) · Waisen-Schutz beendet auch bewusst extern gestartete Hintergrund-Proxys

*P1 · robustheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-GPT-03

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyOrphanGuard.swift:55-68`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyOrphanGuard.swift:88-103`, `WhisperM8/WhisperM8App.swift:359-370`, `Tests/WhisperM8Tests/ClaudeCodeProxyOrphanGuardTests.swift:13-17`

**Szenario:** Ein Nutzer betreibt den Proxy auf dem konfigurierten Port absichtlich per launchd oder nach dem Ende seiner startenden Shell. Der Prozess hat dann PPID 1, obwohl WhisperM8 ihn nie gestartet hat. Liegt sein Binary an einem anderen Pfad als das aktuell aufgelöste Binary, klassifiziert replaceReason ihn allein deshalb als eigene veraltete Waise und sendet beim App-Start SIGTERM. Externe laufende Anfragen werden dadurch abgebrochen. Der dokumentierte Schutz fremder Instanzen wird durch die PPID-Heuristik nicht erfüllt.

**Fix:** Eigene Prozesse mit persistierter Ownership aus PID, Startzeit, Benutzer, Profil und Binary-Identität kennzeichnen. Nur solche nachweislich selbst gestarteten Überreste automatisch ersetzen. Andere Listener weder allein aufgrund ihres Dateinamens noch wegen PPID 1 beenden; stattdessen eine Konfliktmeldung anbieten. Den beabsichtigten Update- und Transkriptionsrouten-Guard für eigene Waisen erhalten.

### LR-GPT-007 (A4-16) · Das normale Usage-Popover fragt GPT-Profilkonten trotz ausgeschaltetem Backend ab

*P2 · privacy · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-GPT-01, F-GPT-02, F-KO-05

**Beleg:** `WhisperM8/Views/AgentUsagePopovers.swift:313`, `WhisperM8/Views/AgentUsagePopovers.swift:467-485`, `WhisperM8/Services/AgentChats/CodexUsageReader.swift:214-225`, `WhisperM8/Support/AppPreferences.swift:268-270`

**Szenario:** Das GPT-Backend ist ausgeschaltet, auf Disk existiert aber ein Proxy-Login aus früherer Nutzung oder aus einer externen Installation. Beim Öffnen der normalen ChatGPT/Codex-Nutzungsanzeige berücksichtigt load nur den Profil-Kill-Switch, nicht claudeGPTBackendEnabled. Es liest deshalb die GPT-Credentials und sendet zusätzlich zur Codex-CLI-Abfrage authentisierte Requests an chatgpt.com. Das ausgeschaltete Labs-Backend verursacht weiterhin externe Kontozugriffe und bis zu einen zusätzlichen Request pro Profil.

**Fix:** GPT-Profilanzeige und deren Fetches am Backend-Zustand gaten; bei ausgeschaltetem Backend nur das ausdrücklich angeforderte Codex-CLI-Konto abfragen. Optional eine getrennte, ausdrücklich ausgelöste Abfrage inaktiver GPT-Konten anbieten. Die bewusste Trennung von CLI- und Proxy-Logins beibehalten.

## Nicht abgedeckt

- Die angeforderten Markdown-Dateien für Rohbericht und Lagebild wurden nicht angelegt; report_path ist deshalb leer. Die Befunde werden ausschließlich strukturiert zurückgegeben.
- Die ausdrücklich ausgeklammerten AgentChatsView-, Workspace-/Grid-/Tab-/Sidebar-, Control-Server-/Chats-CLI- und Plugin-Dateien wurden nicht analysiert. Daher keine Aussage zur vollständigen GUI-/CLI-Verdrahtung, zur Deaktivierungsbeobachtung außerhalb der geprüften Settings-Seite oder zu dort vorhandenen zusätzlichen Guards.
- Keine dynamischen Reproduktionen, Builds, Tests, Netzwerkabrufe oder App-Starts. Aussagen beruhen auf statischen Kontroll- und Datenflüssen; Laufzeitkosten von Keychain-Aufrufen, großen Promote-Merges und Idle-CPU wurden nicht gemessen.
- Die 35 ausdrücklich beauftragten Quelldateien wurden vollständig gelesen. Unterstützende Dateien WhisperM8App.swift, AgentCommandBuilder.swift, AppPreferences.swift und BackgroundAgentSpawner.swift sowie die umfangreichen Tests ClaudeAccountProfilesTests.swift und ClaudeCodeProxyManagerTests.swift wurden nur in relevanten Abschnitten gelesen.
- Der Proxy selbst ist nachgeladener externer Code und wurde nicht heruntergeladen oder ausgeführt. Tatsächliche Bind-Adresse, externe Auth-Fallbacks, Traffic-Log-Verhalten, Archiv-Inhalte und Refresh-Schreibverhalten der aktuellen Upstream-Version benötigen eine gesonderte hermetische Verifikation.
- Möglicher Credential-Rückschreibkonflikt laufender Claude-main-Prozesse beim Promote wurde mangels Einsicht in deren aktuelle native Refresh-Implementierung nicht als eigener Befund gemeldet.
- Kein vollständiger POSIX-/ACL-/Symlink- und Mehrprozess-Stresstest der Promote-Rollbacks, Memory-Migration und Shared-Config-Reconciliation; keine belastbare Aussage zu Absturzsicherheit zwischen sämtlichen einzelnen Dateisystemschritten.
- Nutzungsbedingungen mehrerer Claude-Konten sowie Lokalisierung und allgemeine Labs-Kennzeichnung wurden nicht rechtlich beziehungsweise vollständig über die gesamte App geprüft.

## Gelesene Dateien

50 Dateien:

- `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md`
- `docs/audit/2026-10-launch-readiness/00-scope/feature-inventar.md`
- `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-findings-matrix.md`
- `WhisperM8/Services/AgentChats/AccountMoveFacts.swift`
- `WhisperM8/Services/AgentChats/AccountMoveJournal.swift`
- `WhisperM8/Services/AgentChats/AccountMovePlanner.swift`
- `WhisperM8/Services/AgentChats/AccountMoveService.swift`
- `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift`
- `WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift`
- `WhisperM8/Services/AgentChats/AccountSwitchPlanner.swift`
- `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift`
- `WhisperM8/Services/AgentChats/ClaudeAccountProfiles+Promote.swift`
- `WhisperM8/Services/AgentChats/ClaudeAccountProfiles+SharedConfig.swift`
- `WhisperM8/Services/AgentChats/ClaudeAccountUsageFetcher.swift`
- `WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift`
- `WhisperM8/Services/AgentChats/ClaudeMCPSync.swift`
- `WhisperM8/Services/AgentChats/ClaudeMemoryMigration.swift`
- `WhisperM8/Services/AgentChats/ClaudeSharedMemoryPath.swift`
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift`
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift`
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyModelRegistry.swift`
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyOrphanGuard.swift`
- `WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift`
- `WhisperM8/Services/AgentChats/ClaudeGPTLaunchGuard.swift`
- `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift`
- `WhisperM8/Services/AgentChats/ClaudeGPTModelAlias.swift`
- `WhisperM8/Services/AgentChats/ClaudeGPTModelCatalog.swift`
- `WhisperM8/Services/AgentChats/GPTAccountProfiles.swift`
- `WhisperM8/Services/AgentChats/CodexUsageReader.swift`
- `WhisperM8/Services/Dictation/ChatGPTSubscriptionTranscription.swift`
- `WhisperM8/Views/Settings/Pages/ClaudeAccountsSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift`
- `WhisperM8/Views/Settings/Pages/ClaudeMCPSyncSection.swift`
- `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/GPTBackendSetupRunner.swift`
- `WhisperM8/Views/Settings/Pages/GPTAccountsSection.swift`
- `WhisperM8/Views/AgentUsagePopovers.swift`
- `WhisperM8/Views/AccountMenuData.swift`
- `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift`
- `WhisperM8/Services/Shared/LoginShellEnvironment.swift`
- `WhisperM8/WhisperM8App.swift`
- `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift`
- `WhisperM8/Support/AppPreferences.swift`
- `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift`
- `Tests/WhisperM8Tests/AccountMoveServiceTests.swift`
- `Tests/WhisperM8Tests/ClaudeCodeProxyBinaryInstallerTests.swift`
- `Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift`
- `Tests/WhisperM8Tests/ClaudeAccountLimitPingerTests.swift`
- `Tests/WhisperM8Tests/ClaudeCodeProxyOrphanGuardTests.swift`
- `Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift`
