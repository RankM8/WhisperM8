---
status: abgeschlossen
updated: 2026-07-19
description: Adversariale Verifikation aller kritischen und hohen Runde-4-Findings zur whisperm8-chats-CLI sowie zweier Stichproben aus den mittleren Findings.
---

# Runde 4: Verifikation whisperm8-chats-CLI

## Umfang und Methode

Die Findings-Datei enthält **0 kritische, 6 hohe, 6 mittlere und 0 niedrige** Findings. Auftragsgemäß wurden alle sechs hohen Findings vollständig gegen `HEAD` geprüft. Von den sechs mittleren Findings wurden genau zwei (`R4-AUTH-03`, `R4-SEC-01`) stichprobenartig geprüft; die übrigen vier sind nur gezählt und erhalten kein Sachurteil. Es wurden keine Builds oder Tests ausgeführt.

Pro Finding wurden die belegten Produktionsstellen eng gelesen und aktiv nach Guards sowie abweichenden Aufruferpfaden gesucht. Eine pfadbegrenzte Gegenprüfung der Review-Fix-Commits `f50847e`, `c6ac557`, `9e4b9f4`, `e445b65` und `1bd655f` ergab keine Änderung an den hier geprüften Control-Client-, Control-Server-, Wait-, Launch- oder Profilpfaden; sie liefern daher keinen Gegenbeleg.

## Vollständig geprüfte hohe Findings

### R4-AUTH-01 — BESTÄTIGT — eigene Schwere: hoch

Der Server grenzt Verbindungen nur auf dieselbe EUID ein (`WhisperM8/Services/AgentChats/AgentControlServer.swift:228-239`). Danach dispatcht der Handler anhand der Methode, ohne einen zentralen Authentisierungs- oder Autorisierungs-Guard (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:30-55`).

Auch die einzelnen Mutationspfade schließen die Lücke nicht:

- `session.send` übernimmt die ungeprüfte `actor.sessionID`; bei leerem Actor ist `actorID == nil`, der Self-Check greift nicht, und `force` überstimmt den Status-Guard vor dem Paste (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:124-151`).
- `session.interrupt` hat dieselbe ungeprüfte Actor-Ableitung und erlaubt `force` vor `sendInterrupt()` (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:185-213`).
- `session.new`, Workspace-Mutationen und Grid-Workspace-Rename validieren Methodenparameter, aber kein Actor-Token (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:310-334,339-407,424-475`).
- Die Token-Verifikation wird nur zur Marker-/Audit-Klassifizierung verwendet (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:550-581`).

**Gegenbeleg geprüft:** Die Doku erklärt Same-UID-Angreifer bewusst für außerhalb der Sicherheitsgrenze, behauptet aber zugleich, das Token beweise die Herkunft aus der PTY (`docs/features/agent-chats-cli.md:51-56`). Das widerlegt den technischen Befund nicht: Requests ohne Actor mutieren weiterhin, ohne den vorgesehenen Rechenschafts- und Versehens-Schutz zu erfüllen.

**Urteil:** BESTÄTIGT. Hoch, weil ein beliebiger Same-UID-Prozess laufende PTYs steuern und persistierte Workspace-Daten verändern kann, ohne eine verifizierte Chat-Identität zu besitzen. Die dokumentiert enge Trust-Grenze verhindert lediglich eine Einstufung als externe Remote-Lücke.

### R4-AUTH-02 — BESTÄTIGT — eigene Schwere: hoch

Der Client liest den Socket-Pfad blind aus der Discovery-Datei, verbindet sich und sendet Actor-Token sowie Parameter (`WhisperM8/CLI/ChatsControlClient.swift:23-40,50-57`). Er decodiert die Antwort, vergleicht aber weder `protocolVersion` noch `requestID`, obwohl beide Felder im Response vorhanden sind (`WhisperM8/CLI/ChatsControlClient.swift:33-40`; `WhisperM8/CLI/ChatsControlProtocol.swift:121-138`). Eine clientseitige Peer-, Owner-, Mode- oder Dateitypprüfung gibt es im gelesenen Connect-Pfad nicht (`WhisperM8/CLI/ChatsControlClient.swift:50-98`).

Die App startet bei einem fremd gehaltenen Single-Instance-Lock fail-closed nicht (`WhisperM8/Services/AgentChats/AgentControlServer.swift:82-97`). Ein Fake-Server derselben UID kann daher Lock und Discovery übernehmen und eine beliebige decodierbare Antwort liefern. Die echte Serverseite setzt zwar 0700/0600 und prüft die Peer-EUID (`WhisperM8/Services/AgentChats/AgentControlServer.swift:70-76,163-169,228-239`), diese Guards authentisieren den Server gegenüber dem Client jedoch nicht.

Die zusätzliche Cross-UID-Variante ist konditional, aber im Fallbackpfad plausibel: Fehler beim Erzeugen und Härten des deterministischen Fallback-Verzeichnisses werden ignoriert; Owner und Mode werden nicht validiert (`WhisperM8/Services/AgentChats/AgentControlServer.swift:99-112`).

**Urteil:** BESTÄTIGT. Hoch wegen Offenlegung von Token/Prompt und fälschbarer Erfolgsmeldungen; der Cross-UID-Teil setzt den seltenen langen Standardpfad und ein präpariertes Fallback-Verzeichnis voraus, der Same-UID-Hijack nicht.

### R4-IDEM-01 — BESTÄTIGT — eigene Schwere: hoch

Jeder `ChatsControlClient.send`-Aufruf erzeugt einen neuen Request (`WhisperM8/CLI/ChatsControlClient.swift:23-31`), dessen Default-Initializer eine neue UUID setzt (`WhisperM8/CLI/ChatsControlProtocol.swift:71-91`). Im CLI-Quellbaum gibt es außer diesem Protokollfeld keine Option zur stabilen Übergabe oder Wiederverwendung einer Request-ID.

Der Server antwortet nach zehn Sekunden mit „Zustand unklar“, während der Handler-Task weiterlaufen und noch mutieren kann (`WhisperM8/Services/AgentChats/AgentControlServer.swift:295-318`). Der vorhandene Idempotenzschutz reserviert ausschließlich `request.requestID` (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:108-122`). Er schützt damit wiederholte Transporte derselben ID, nicht den realen Retry als neuen CLI-Aufruf mit neuer UUID.

**Urteil:** BESTÄTIGT. Hoch, weil der normale Recovery-Versuch nach einem Timeout denselben Agent-Auftrag zweimal zustellen kann; die Folgewirkungen des Prompts sind nicht notwendig idempotent.

### R4-WAIT-01 — BESTÄTIGT — eigene Schwere: hoch

Der Control-Launch persistiert die interne Session-ID und verspricht sie ausdrücklich für ein sofortiges `chats wait --ref`, bevor eine externe Provider-ID garantiert gebunden ist (`WhisperM8/Services/AgentChats/AgentChatLaunchService.swift:38-42,79-96`). `wait` lädt den Workspace-Kontext genau einmal und übergibt ein festes Entry-Array an die Engine (`WhisperM8/CLI/ChatsWaitEngine.swift:321-342`). Die Engine speichert dieses Array unveränderlich und verwendet dieselben Entries bei Initialprobe, Watch-Aufbau, Reevaluation und Re-Armierung (`WhisperM8/CLI/ChatsWaitEngine.swift:41-67,74-105,193-215`).

Fehlt im Snapshot `externalSessionID`, liefert der Probe weder Revision noch Transcript-Pfad (`WhisperM8/CLI/ChatsStatusProbe.swift:74-86`). Der 10-Sekunden-Fallback und die Rotations-Rearmierung helfen nicht, weil sie denselben alten Entry erneut prüfen (`WhisperM8/CLI/ChatsWaitEngine.swift:108-112,193-201`).

**Urteil:** BESTÄTIGT. Hoch: Bei verzögertem Provider-ID-Binding bleibt der ausdrücklich vorgesehene unmittelbare `new → wait`-Pfad bis zum Timeout blind. Nicht bestätigt ist nur eine ausnahmslose Deterministik — bindet die ID vor dem einmaligen Snapshot, tritt der Fehler nicht auf.

### R4-WAIT-02 — BESTÄTIGT — eigene Schwere: hoch

Der gebündelte Supervisor-Ablauf verlangt für mehrere Sessions einen einzigen `--since <maxRevision>`-Wert (`WhisperM8/Resources/whisperm8-chats-skill.md:114-123`). `revision` ist in beiden Probe-Ausgängen lediglich die jeweilige Transcript-Dateigröße (`WhisperM8/CLI/ChatsStatusProbe.swift:137-153,186-193`). Die Engine hält nur einen skalaren `sinceRevision` und vergleicht für jedes Entry `rev > sinceRevision` (`WhisperM8/CLI/ChatsWaitEngine.swift:41-50,74-87`). Bytegrößen unabhängiger Dateien bilden keinen gemeinsamen Cursor; ein großes Transcript kann daher neue Ereignisse kleinerer Transcripts ausblenden.

Zusätzlich bewertet der Initial-Kurzschluss ein neueres Transcript mit `previous: nil` (`WhisperM8/CLI/ChatsWaitEngine.swift:82-85`). Das Default-Prädikat `attention` akzeptiert `idle`/`stopped` nur nach `previous == .working`, nicht von `nil` (`WhisperM8/CLI/ChatsWaitEngine.swift:243-269`). Ein zwischen zwei Aufrufen vollständig beendeter Turn kann so zur stillen Baseline werden. Da die Revision nur `stat.size` ist, kann sie bei Rotation oder Truncation außerdem rückwärts springen (`WhisperM8/CLI/ChatsStatusProbe.swift:145-152,186-193`).

**Gegenbeleg geprüft:** Die sofortige Reevaluation nach Watch-Aufbau schließt nur das Intra-Prozess-Fenster zwischen Initialprobe und Watch (`WhisperM8/CLI/ChatsWaitEngine.swift:101-105`); sie erzeugt weder einen per-Session-Cursor noch rekonstruiert sie einen vor Prozessstart beendeten Zustandsübergang.

**Urteil:** BESTÄTIGT. Hoch, weil der dokumentierte Supervisor-Loop Ereignisse still verlieren und anschließend bis zum langen Wait-Timeout blockieren kann.

### R4-PROF-01 — BESTÄTIGT, aber teilweise eingegrenzt — eigene Schwere: hoch

`session.new` reicht nur Provider, Projekt, Titel und Prompt weiter (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:310-324`). Der Claude-Control-Pfad ruft `createSession` ohne `claudeProfileName`, `claudeBackendModel` oder `contextProfileID` auf (`WhisperM8/Services/AgentChats/AgentChatLaunchService.swift:77-96`); diese Parameter defaulten auf `nil` und werden so persistiert (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:522-568`). Der UI-Pfad stempelt dagegen aktives Claude-Profil, GPT-Backend-Modell und Context-Profil (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:51-77`).

Diese Felder sind wirksam: `nil` beim Account bedeutet Main-Profil ohne `CLAUDE_CONFIG_DIR`, und nur ein gesetztes `claudeBackendModel` erzeugt `--model` (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:61-70,286-302,391-402`). Damit kann eine CLI-erzeugte Claude-Session tatsächlich unter einem anderen Account beziehungsweise ohne den in der UI gewählten GPT-Standard starten.

**Wichtiger Gegenbeleg:** Der Context-Teil des Ausgangsfindings ist zu pauschal. Beim Launch löst die Detailansicht `session.contextProfileID` mit Fallback auf `project.contextProfileID` auf (`WhisperM8/Views/AgentSessionDetailView.swift:508-525`). Ein fehlender Session-Stempel verliert den aktuellen Projekt-Default daher nicht unmittelbar. Verloren gehen jedoch die Snapshot-Semantik des Erstellungszeitpunkts und ein möglicher UI-Override; Account- und Backend-Abweichung bleiben vollständig bestehen.

**Urteil:** BESTÄTIGT, in der Context-Begründung eingegrenzt. Hoch bleibt angemessen, weil die Account-Abweichung Inhalte in den falschen Claude-Konfigurations-/Account-Kontext lenken kann; der Projekt-Context-Default allein trägt diese Schwere nicht.

## Stichproben aus den mittleren Findings

### R4-AUTH-03 — BESTÄTIGT — eigene Schwere: mittel

Beim PTY-Start werden Session-ID und neu ausgestelltes Token in die allgemeine Prozessumgebung geschrieben (`WhisperM8/Views/AgentTerminalView.swift:792-815`). Weder `terminate()` noch `processTerminated` widerrufen das Token (`WhisperM8/Views/AgentTerminalView.swift:820-842,1014-1025`). Repositoryweit liegt der einzige Produkt-Treffer von `revoke` in der Registry-Definition; Aufrufer existieren nur in Tests (`WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift:40`). Ein detached Kindprozess kann die geerbte Identität deshalb nach PTY-Ende weiterverwenden.

**Urteil:** BESTÄTIGT, mittel. Gegenwärtig betrifft dies vor allem falsche Marker-/Audit-Zurechnung, weil `R4-AUTH-01` Mutationen ohnehin nicht an das Token bindet; nach einer Auth-Behebung würde daraus eine unmittelbare Capability-Lücke.

### R4-SEC-01 — BESTÄTIGT — eigene Schwere: mittel

`send` nimmt den Prompt aus positionalen Argumenten (`WhisperM8/CLI/ChatsLiveCommands.swift:110-158`), `new` aus `--prompt` (`WhisperM8/CLI/ChatsLiveCommands.swift:280-316`). Das PTY-Token steht zugleich in der vererbbaren Umgebung (`WhisperM8/Views/AgentTerminalView.swift:800-815`). Erfolgreiche und nachgelagert fehlgeschlagene Sends übernehmen außerdem eine Audit-Vorschau (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:568-581`), die ohne Secret-Redaction die ersten 80 normalisierten Zeichen speichert (`WhisperM8/Services/AgentChats/ChatsAuditLog.swift:85-94`).

**Urteil:** BESTÄTIGT, mittel. Die Audit-Kürzung begrenzt die Datenmenge, schützt aber gerade vorangestellte Tokens, Passwörter oder Schlüssel nicht.

## Urteilstabelle

| ID | Ausgangsschwere | Prüfumfang | Urteil | Eigene Schwere |
|---|---:|---|---|---:|
| R4-AUTH-01 | hoch | vollständig | BESTÄTIGT | hoch |
| R4-AUTH-02 | hoch | vollständig | BESTÄTIGT | hoch |
| R4-AUTH-03 | mittel | Stichprobe | BESTÄTIGT | mittel |
| R4-SEC-01 | mittel | Stichprobe | BESTÄTIGT | mittel |
| R4-IDEM-01 | hoch | vollständig | BESTÄTIGT | hoch |
| R4-SEND-01 | mittel | nur gezählt | kein Sachurteil | — |
| R4-WAIT-01 | hoch | vollständig | BESTÄTIGT, Auslösungsbedingung präzisiert | hoch |
| R4-WAIT-02 | hoch | vollständig | BESTÄTIGT | hoch |
| R4-SOCK-01 | mittel | nur gezählt | kein Sachurteil | — |
| R4-PROF-01 | hoch | vollständig | BESTÄTIGT, Context-Teil eingegrenzt | hoch |
| R4-AUD-01 | mittel | nur gezählt | kein Sachurteil | — |
| R4-PARSE-01 | mittel | nur gezählt | kein Sachurteil | — |

**Summen:** 6/6 hohe Findings bestätigt; 2/2 mittlere Stichproben bestätigt; 4 mittlere Findings bewusst nicht sachlich geprüft. Keine kritischen oder niedrigen Findings vorhanden.

## Die drei wichtigsten bestätigten Punkte

1. **Die Control-Plane besitzt keine durchgesetzte Actor-Autorisierung:** Same-UID-Prozesse können mutieren; Token-Verifikation beeinflusst nur Marker und Audit (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:30-55,124-151,550-581`).
2. **Der dokumentierte Wait-/Supervisor-Vertrag ist in zwei Kernfällen unzuverlässig:** Ein einmaliger Entry-Snapshot sieht spätes ID-Binding nicht, und der globale Byte-Cursor ist zwischen Transcripts semantisch ungültig (`WhisperM8/CLI/ChatsWaitEngine.swift:41-67,74-105,193-215`; `WhisperM8/CLI/ChatsStatusProbe.swift:74-86,145-152`).
3. **CLI-erzeugte Claude-Sessions können Account und Backend verlieren:** Der Control-Pfad persistiert `nil`, während der UI-Pfad die aktiven Werte stempelt und der Command-Builder diese Werte tatsächlich in Umgebung beziehungsweise `--model` umsetzt (`WhisperM8/Services/AgentChats/AgentChatLaunchService.swift:77-96`; `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:51-77`; `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:61-70,286-302,391-402`).
