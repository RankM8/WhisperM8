---
status: abgeschlossen
updated: 2026-07-19
description: Finalrunden-Audit der whisperm8-chats-CLI mit Fokus auf Unix-Socket-Autorisierung, Session-Tokens, TOCTOU-Sicherheit, Workspace-Single-Writer, Auditierbarkeit und Wait-Korrektheit.
---

# Runde 4: whisperm8 chats CLI — Security und Korrektheit

## Prüfrahmen

Geprüft wurden die im Auftrag genannten CLI-, Control-Server-, Token-, Launch-, Audit- und Skill-Dateien sowie die zugehörigen Tests. Lesezugriffe bleiben prozesslokal und read-only; die Workspace-Mutationen gehen tatsächlich über den App-Prozess und verletzen die Single-Writer-Vorgabe nicht (`WhisperM8/CLI/ChatsWorkspaceReader.swift:13-23`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:339-393`). Der als „TOCTOU-frei“ bezeichnete synchrone Guard/Paste-Abschnitt existiert ebenfalls (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:127-153`), deckt aber weder Autorisierung noch den verzögerten Submit und den Timeout-Retry ab.

Die vorhandenen Tests prüfen vor allem Codec-Roundtrips, Token-Primitive, isolierte Idempotenz-Reservierungen, einen vereinfachten Test-Socket und pure Wait-Prädikate. Sie prüfen nicht die Produktions-Autorisierung des Handlers, Client-zu-Server-Authentizität, Socket-Rechte/Fallback-Pfad, Slow Clients, App-Quit, echte Timeout-Retries, PTY-Exit während des verzögerten Submit, nachträgliches Binden einer externen Session-ID, `--since` über mehrere Dateien, Profilpropagation oder Audit-Schreibfehler (`Tests/WhisperM8Tests/ChatsControlTests.swift:63-99,176-221,221-261`; `Tests/WhisperM8Tests/ChatsWaitEngineTests.swift:1-61`; `Tests/WhisperM8Tests/TestControlSocket.swift:8-79`).

## Findings

### R4-AUTH-01 — hoch — Session-Token autorisiert keine einzige Mutation

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlServer.swift:228-239`; `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:30-55,97-153,185-214,310-335,339-393,424-471,550-581`; `WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift:31-38`

**Auslöseszenario:** Ein beliebiger Prozess unter derselben macOS-UID verbindet sich mit dem Socket und sendet einen Request mit leerem Actor, zum Beispiel `session.send` mit `force=true`, `session.interrupt`, `session.new`, `workspace.archive` oder `gridWorkspace.rename`. Der Server prüft nur `getpeereid(...).euid == getuid()`. Der Handler verifiziert das Token ausschließlich beim Erzeugen von Marker und Audit-Label; vor der Mutation gibt es keinen Auth-Guard. Damit kann der Prozess fremde PTYs prompten oder unterbrechen, Sessions anlegen/archivieren und Metadaten ändern. Ein leerer Actor umgeht zusätzlich den Selbst-Send-Schutz, weil dieser nur die ungeprüfte `actor.sessionID` vergleicht.

**Fix-Skizze:** Vor allen mutierenden Methoden zentral `sessionID + token` verifizieren und bei fehlender/ungültiger Identität fail-closed antworten. Berechtigungen explizit modellieren: mindestens „diese laufende PTY darf handeln“, optional erlaubte Ziel-/Methodenmenge. `force` nur für authentisierte Actors zulassen. Lese-Methoden separat klassifizieren. Self-Checks ausschließlich mit der verifizierten Actor-ID ausführen.

**Nicht abgedeckt:** Die Token-Tests prüfen nur `issue/verify/revoke`; kein Test schickt einen mutierenden Request mit fehlendem oder falschem Token durch den echten Handler.

### R4-AUTH-02 — hoch — Die CLI authentisiert den Server nicht; Socket-/Lock-Hijack legt Tokens und Prompts offen

**Beleg:** `WhisperM8/CLI/ChatsControlClient.swift:23-40,50-57`; `WhisperM8/Services/AgentChats/AgentControlServer.swift:82-97,121-125`; `WhisperM8/CLI/ChatsControlProtocol.swift:21-40`

**Auslöseszenario:** Ein Prozess derselben UID öffnet vor dem App-Start `control.lock`, hält `flock` und bindet einen Fake-Server am publizierten beziehungsweise stale bekannten Socket-Pfad. Die App verweigert daraufhin ihren Serverstart, die CLI vertraut aber blind dem Pfad aus `socket-path`. Beim ersten `chats send/new/...` erhält der Fake-Server Actor-Token und Prompt und kann eine beliebige decodierbare Erfolgsmeldung zurückgeben. Der Client prüft weder Peer-EUID/PID noch `response.protocolVersion` oder `response.requestID`. Dateirechte und `getpeereid` schützen nur die Server-Seite gegen andere UIDs, nicht den Client gegen einen Prozess derselben UID.

Eine zusätzliche Cross-UID-Variante besteht am Fallback-Pfad: Das Anlegen und Härten von `/private/tmp/whisperm8-<uid>/` ignoriert Fehler und prüft Owner/Mode nicht (`WhisperM8/Services/AgentChats/AgentControlServer.swift:99-107`). Wird dieser vorab fremdbesessen und schreibbar angelegt, kann ein anderer lokaler User den Socket-Namen ersetzen; der Client hat keine Peer-Prüfung.

**Fix-Skizze:** Für eine belastbare lokale Grenze XPC mit Audit-Token/Code-Signing-Requirement oder einen app-generierten, clientseitig geschützten per-launch Handshake verwenden. Mindestens auf beiden Seiten Peer-Credentials prüfen, Discovery-Datei und Socket per `lstat` auf Typ/Owner/Mode validieren, Fallback-Verzeichnis fail-closed validieren und Response-Version sowie Request-ID binden. Ein EUID-Check allein kann Prozesse derselben UID nicht unterscheiden.

**Nicht abgedeckt:** Der Roundtrip-Test nutzt `TestControlSocket` an einem Temp-Pfad und prüft weder Produktions-Lock/Discovery noch Server-Peer-Credentials oder gefälschte Responses.

### R4-AUTH-03 — mittel — PTY-Tokens werden vererbt und nach Prozessende nie widerrufen

**Beleg:** `WhisperM8/Views/AgentTerminalView.swift:792-815,820-842,1014-1025`; `WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift:22-44`

**Auslöseszenario:** Das Token liegt in der Umgebung des Agent-Prozesses und wird an alle von ihm gestarteten Tools, Shells und Projekt-Skripte vererbt. Ein per `nohup`/Detach weiterlebender Kindprozess behält es auch nach dem Ende der PTY. Weder `terminate()` noch `processTerminated` rufen `revoke`; im Produktcode existiert kein Revoke-Aufrufer. Der Kindprozess kann daher bis zum nächsten Token-Reissue beziehungsweise App-Ende Requests mit `verified: true` und der Identität der beendeten Session erzeugen. Schon heute verfälscht das Marker/Audit-Zuordnung; nach Behebung von R4-AUTH-01 wäre es ein direkter Auth-Bypass.

**Fix-Skizze:** Token in beiden Exit-Pfaden idempotent widerrufen und an eine konkrete Controller-/PTY-Generation binden. Keine langlebige Capability in die allgemeine Tool-Umgebung geben; besser kurzlebige, methodengebundene Claims über einen Broker/FD oder rotierende Tokens mit Ablaufzeit verwenden.

**Nicht abgedeckt:** Tests rufen `revoke` manuell auf, prüfen aber keinen Terminal-Lifecycle und keine vererbten/detachten Kindprozesse.

### R4-SEC-01 — mittel — Prompts und Token gelangen in breit sichtbare Prozess-Metadaten

**Beleg:** `WhisperM8/CLI/ChatsLiveCommands.swift:110-158,280-316`; `WhisperM8/Resources/whisperm8-chats-skill.md:38-47`; `WhisperM8/Views/AgentTerminalView.swift:800-815`; `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:568-581`; `WhisperM8/Services/AgentChats/ChatsAuditLog.swift:9-19,85-94`

**Auslöseszenario:** `send` nimmt den kompletten Prompt positional aus `argv`, `new` über `--prompt`; der Skill schreibt genau diese Form vor. Während der bis zu zwölf Sekunden langen Socket-Anfrage ist der Text in der Prozessargumentliste sichtbar. Das Session-Token steht zugleich in der vererbbaren PTY-Umgebung. Enthält der Prompt ein Passwort, einen API-Key oder vertraulichen Text, landet außerdem sein unredigierter 80-Zeichen-Anfang dauerhaft im Audit-JSONL.

**Fix-Skizze:** Prompt standardmäßig über stdin beziehungsweise `--prompt-file -` übertragen und die Skill-Beispiele auf Pipe/Heredoc umstellen; argv-Prompt nur als klar markierten Legacy-Komfortpfad behalten. Tokens nicht über die allgemeine Umgebung verteilen. Audit-Vorschau standardmäßig deaktivieren oder secrets-aware redigieren; Länge und Hash reichen für Korrelation.

**Nicht abgedeckt:** Parser- und Audit-Tests verwenden harmlose Strings; es gibt keinen Test, der Prozessargumente, Umgebungsvererbung oder Secret-Redaction betrachtet.

### R4-IDEM-01 — hoch — Der Idempotenzschutz ist für den realen Timeout-Retry nicht erreichbar

**Beleg:** `WhisperM8/CLI/ChatsControlProtocol.swift:71-91`; `WhisperM8/CLI/ChatsControlClient.swift:23-31`; `WhisperM8/Services/AgentChats/AgentControlServer.swift:295-318`; `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:108-122,155-175,492-532`

**Auslöseszenario:** Ist der MainActor länger als zehn Sekunden blockiert, antwortet der Server „Zustand unklar“, obwohl der Handler-Task später weiterlaufen und den Prompt noch pasten kann. Wiederholt der User den CLI-Befehl, erzeugt `ChatsControlRequest` automatisch eine neue UUID; es gibt weder automatische Wiederverwendung noch eine `--request-id`-Option. Der Cache sieht deshalb einen frischen Request und pastet ein zweites Mal. Doppelte Agent-Aufträge können ihrerseits doppelte destruktive Datei-/Git-/Deploy-Aktionen auslösen.

**Fix-Skizze:** Request-ID im Command vor dem ersten Transportversuch erzeugen, für alle Transport-Retries stabil halten und eine explizite Retry-/Status-Abfrage anbieten. Bei Server-Timeout den Handler abbrechbar strukturieren oder einen abfragbaren finalen Request-Zustand persistieren; keine späte Mutation nach einer nicht korrelierbaren Timeout-Antwort.

**Nicht abgedeckt:** Die Tests reservieren dieselbe ID direkt am Handler. Kein Test bildet „Server-Timeout → neuer CLI-Prozess/Retry → späte Originalmutation“ ab.

### R4-SEND-01 — mittel — `ack=delivered` wird vor dem eigentlichen Submit bestätigt

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:127-174`; `WhisperM8/Views/AgentTerminalView.swift:645-668`

**Auslöseszenario:** Beim Standardfall `submit=true` schreibt `sendPrompt` zwar den Bracketed-Paste-Block sofort, sendet Return aber erst 80 ms später. Der Handler markiert die Request-ID unmittelbar als completed, schreibt Audit `ok` und antwortet `ack=delivered`. Beendet sich die PTY in diesem Fenster, verwirft die Closure Return wegen `isRunning == false`; der Auftrag wurde nie abgeschickt, kann wegen Idempotenz aber als erfolgreich dupliziert gelten.

**Fix-Skizze:** `sendPrompt` mit Completion/Result ausstatten und erst nach erfolgreichem Return-Write bestätigen. PTY-Generation/Prozessidentität in der verzögerten Closure prüfen. Response-Wording zwischen „pasted“, „submitted“ und „TUI acknowledged“ unterscheiden.

**Nicht abgedeckt:** Es gibt keinen Test mit kontrolliertem PTY-Exit zwischen Paste und delayed Return.

### R4-WAIT-01 — hoch — Direktes `new → wait` hängt dauerhaft auf einer Session ohne externe ID

**Beleg:** `WhisperM8/Services/AgentChats/AgentChatLaunchService.swift:38-42,79-96`; `WhisperM8/CLI/ChatsWaitEngine.swift:41-67,89-117,193-215,321-342`; `WhisperM8/CLI/ChatsStatusProbe.swift:74-86`

**Auslöseszenario:** `chats new` persistiert und antwortet mit der internen UUID, bevor der SessionStart-Hook die externe Claude-/Codex-ID gebunden hat; der Kommentar verspricht ausdrücklich, dass der Aufrufer sofort `wait --ref` verwenden kann. `wait` lädt jedoch genau einmal einen unveränderlichen `ChatsSessionEntry`. Hat dessen `externalSessionID` beim Start noch `nil`, liefern alle späteren Polls derselben Snapshot-Session weiterhin `missingExternalSessionID`; Workspace und Live-App werden nie neu geladen, kein Watch wird je armiert, und der Befehl endet erst nach dem Timeout.

**Fix-Skizze:** Bei jedem Fallback-Poll beziehungsweise solange ID/Transcript fehlen den Workspace anhand der internen Session-ID neu laden oder `sessions.live` um die autoritative Transcript-/External-ID ergänzen. Erst danach Entry und Watch atomar ersetzen. Einen E2E-Test `new` mit verzögertem ID-Binding und anschließendem `wait` hinzufügen.

**Nicht abgedeckt:** Wait-Tests rufen nur die pure Übergangsfunktion mit bereits vorhandenem Transcript-Pfad auf.

### R4-WAIT-02 — hoch — Der skalare Byte-`--since`-Cursor kann die dokumentierte Ereignislücke nicht schließen

**Beleg:** `WhisperM8/Resources/whisperm8-chats-skill.md:108-123`; `WhisperM8/CLI/ChatsWaitEngine.swift:41-50,74-87,211-230,243-280`; `WhisperM8/CLI/ChatsStatusProbe.swift:142-153,186-193`

**Auslöseszenario 1:** Der Skill fordert bei mehreren Sessions `--since <maxRevision>`. Revision ist aber die jeweilige Dateigröße. Hat Session A 10 MB und Session B 100 KB, kann B zwischen zwei Wait-Aufrufen auf 101 KB wachsen und fertig werden; `101 KB > 10 MB` ist falsch, also wird das Ereignis nicht als „seit Cursor“ erkannt.

**Auslöseszenario 2:** Selbst bei einer Session prüft der Initial-Kurzschluss den aktuellen Zustand mit `previous=nil`. Ein kompletter Turn kann zwischen zwei Aufrufen von working nach idle wechseln und die Revision erhöhen; das Default-Prädikat `attention` akzeptiert `nil → idle` nicht. Danach wird idle als neue Baseline gespeichert, es kommen keine weiteren Writes, und `wait` läuft bis zum Timeout. Bei Rotation/Truncation kann die Byte-Revision zusätzlich rückwärts springen.

**Fix-Skizze:** Cursor pro Session als opaque Tupel aus Session-ID, Transcript-Identität (dev/inode oder stabiler Generation), Offset und letztem Status ausgeben und wieder einlesen. Kein `max` über unabhängige Dateien. Der Kurzschluss muss „Revision/Generation änderte sich seit Cursor“ unabhängig vom unbekannten `previous` korrekt als verpasstes Ereignis modellieren.

**Nicht abgedeckt:** Tests konstruieren nur direkte `previous → current`-Übergänge; `sinceRevision`, mehrere Dateien und Rotation werden nicht getestet.

### R4-SOCK-01 — mittel — Vier Slow Clients können den Control-Server unbegrenzt sperren

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlServer.swift:30-34,241-268,338-347`; `WhisperM8/CLI/ChatsControlProtocol.swift:143-159`

**Auslöseszenario:** Ein Prozess derselben UID öffnet vier Verbindungen und sendet jeweils spätestens alle knapp fünf Sekunden ein Byte ohne Newline. `SO_RCVTIMEO` gilt pro blockierendem `read`, nicht als absolute Frame-Deadline; jeder erfolgreiche Byte-Read startet die Wartephase erneut. Alle vier Semaphore-Slots bleiben so bis zu 1 MiB lang belegt, während jede weitere legitime CLI-Verbindung sofort geschlossen wird. Das ist mit wenigen FDs und praktisch ohne Last ein dauerhafter lokaler Control-Plane-DoS.

**Fix-Skizze:** Absolute monotone Frame-Deadline und/oder Idle-plus-Gesamtdauer erzwingen, gepuffert in größeren Chunks lesen, Verbindungen erst nach vollständigem kleinem Header/Auth-Handshake einem Handler-Slot zurechnen und Slots fair verwalten.

**Nicht abgedeckt:** Der Test-Socket sendet stets ein vollständiges NDJSON-Frame; Slowloris, Slot-Limit und Timeout-Semantik fehlen.

### R4-PROF-01 — hoch — CLI-erzeugte Claude-Sessions verlieren Account-, Backend- und Context-Profil

**Beleg:** `WhisperM8/Services/AgentChats/AgentChatLaunchService.swift:49-96`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:522-568`; Vergleichspfad `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:51-77`

**Auslöseszenario:** `whisperm8 chats new --provider claude` ruft `createSession` auf, ohne `claudeProfileName`, `claudeBackendModel` oder `contextProfileID` zu setzen. Diese Parameter defaulten auf `nil`. Der normale UI-Pfad stempelt dagegen aktives Claude-Konto, gewähltes GPT-Backend-Modell und Projekt-/Override-Context-Profil. Eine aus Jarvis gestartete Session kann damit unter dem falschen Konto laufen, Kontext-/Tool-Settings verlieren und Inhalte an den falschen Backend-/Account-Kontext senden.

**Fix-Skizze:** Die Profilauflösung in einen gemeinsamen Session-Factory-/Launch-Pfad ziehen, den UI und Control-Service identisch verwenden. Projekt-Default und aktives Account-/Backend-Profil explizit auflösen und persistieren; optional CLI-Overrides nur nach Validierung erlauben.

**Nicht abgedeckt:** Die genannten CLI/Control-Tests instanziieren den Launch-Service nicht und vergleichen keine Sessionfelder mit dem UI-Erzeugungspfad.

### R4-AUD-01 — mittel — Das Audit ist weder vollständig noch stabil pro Session

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:97-104,155-175,216-227,232-257,265-305,325-334,395-407,467-474,568-581`; `WhisperM8/Services/AgentChats/ChatsAuditLog.swift:11-19,41-59,63-74`; `WhisperM8/CLI/ChatsLiveCommands.swift:504-538`

**Auslöseszenario:** Parameterfehler und mehrere erfolglose `open/resume/new/gridWorkspace.rename`-Pfade kehren ohne Audit zurück. Fehlgeschlagene Send/Interrupt-Versuche werden mit `target=nil` protokolliert. `audit --session` filtert jedoch per aktuellem Stringlabel `projekt/titel`; dadurch verschwinden alle Fehlversuche und nach einem Rename auch historische Einträge mit altem Label aus der gefilterten Sicht. Zusätzlich schluckt `append` sämtliche Encode-, Directory-, Open-, Seek-, Write- und Rotationsfehler, während die Mutation trotzdem Erfolg meldet. „Kein Audit-Log vorhanden“ kann daher ebenso „Schreiben gescheitert“ bedeuten.

**Fix-Skizze:** Stabile `actorSessionID`/`targetSessionID` und Request-ID im Schema speichern und danach filtern; jeden mutierenden Versuch einschließlich Validation/Auth/Conflict protokollieren. `append` muss ein Ergebnis liefern, Schreibfehler sichtbar in Unified Log/Response/Health anzeigen und Rotation crash-sicher ausführen. Labels nur als denormalisierte Anzeige behalten.

**Nicht abgedeckt:** Tests prüfen Append/Limit und exakte Label-Filter mit konstanten Strings, aber keine Renames, nil-Targets, Handler-Frühreturns oder I/O-Fehler.

### R4-PARSE-01 — mittel — Ein einzelnes JSONL-Event über 64 KiB macht den aktuellen CLI-Status unlesbar

**Beleg:** `WhisperM8/CLI/ChatsStatusProbe.swift:36-38,156-163,251-262`; `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:30-60,219-236`

**Auslöseszenario:** Tool-Results und Assistant-Records können größer als 64 KiB sein. Ist der letzte Record größer als das feste Tail-Fenster, beginnt der Read mitten in genau dieser Zeile und enthält keinen vollständigen JSON-Record. `lastEvent` findet nichts, der Decider liefert `nil`; `list/overview` zeigen `unknown`, und `wait --until attention` erkennt ein relevantes Ende erst über spätere Stall-/mtime-Heuristik oder gar nicht vor einem kurzen Timeout.

**Fix-Skizze:** Vom Dateiende rückwärts bis zu mindestens einem vollständigen parsebaren Record lesen, mit einem vernünftigen oberen Einzelrecord-Limit und explizitem `oversizedRecord`-Status. Alternativ einen streamingfähigen rückwärts gerichteten JSONL-Reader gemeinsam mit dem Runtime-Watcher verwenden.

**Nicht abgedeckt:** Status- und Wait-Fixtures enthalten nur kleine vollständige JSONL-Zeilen; ein >64-KiB-Schlussrecord und ein Tail-Start mitten im einzigen relevanten Record fehlen.

## Priorisierung

1. **Sofort:** R4-AUTH-01 und R4-AUTH-02 — die Control-Plane hat aktuell weder belastbare Client-Autorisierung noch Server-Authentizität.
2. **Vor Nutzung als Supervisor:** R4-WAIT-01, R4-WAIT-02 und R4-IDEM-01 — sonst hängen Standardabläufe oder führen Aufträge doppelt aus.
3. **Vor breiter Freigabe von `chats new`:** R4-PROF-01 — Konto-/Context-Grenzen müssen mit dem UI-Pfad identisch sein.
4. **Danach:** Token-Lifecycle, Prompt-Secrets, Submit-Ack, Slow-Client-Abwehr, stabiles Audit und Oversize-Parser.
