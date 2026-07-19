---
status: abgeschlossen
updated: 2026-07-19
description: Adversariale Vollverifikation der acht hohen Findings und Stichprobenprüfung der zwei mittleren Findings des Runde-4-Delta-Audits gegen HEAD, Guards, Tests und Review-Fix-Stand.
---

# Runde 4: Verifikation des Delta-Audits bereits auditierter Dateien

## Auftrag und Methode

Geprüft werden die acht hohen Kernaussagen aus `02-findings/runde4-delta-auditierte-dateien.md` vollständig gegen den Code-Stand `HEAD`; die zwei mittleren Findings werden gezählt und stichprobenartig geprüft. Berücksichtigt werden enge Quellcodeausschnitte, Guards, einschlägige Tests und die relevanten Review-Fix-Commits. Es wurden weder Produktcode geändert noch Builds oder Tests ausgeführt.

## Einzelurteile

### R4-HCLI-01 — Unvalidiertes `SIGKILL` nach PID-Reuse

**Urteil: BESTÄTIGT. Eigener Schweregrad: mittel.** Der Eskalationspfad liest erst `process.isRunning` und signalisiert anschließend separat die rohe PID mit `SIGKILL`; ein Identitätsbeleg zwischen beiden Operationen existiert nicht (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:97-100`). Der Timeout-Test verwendet nur einen stabilen `/bin/sleep` und deckt das Reuse-Fenster nicht ab (`Tests/WhisperM8Tests/AgentSessionAutoNamerTests.swift:49-59`). Die Wirkung wäre gravierend, das notwendige Timingfenster ist jedoch extrem eng; deshalb ist „hoch“ nicht angemessen.

### R4-HCLI-02 — Failsafe vor EOF des Prozessbaums

**Urteil: BESTÄTIGT. Eigener Schweregrad: hoch.** Beide Reader blockieren bis EOF (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:69-75`), signalisiert wird aber nur die direkte Child-PID (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:97-100`). Der fünf Sekunden spätere Failsafe ruft ungeachtet von Exit und Stream-EOF `forceFinish` auf (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:101-106`), während `forceFinish` die reguläre Bedingung `exitStatus` plus zwei beendete Streams explizit umgeht (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:174-182`). Die vorhandenen Tests erzeugen keinen Nachkommen mit geerbtem Pipe-Write-FD (`Tests/WhisperM8Tests/AgentSessionAutoNamerTests.swift:62-82`). Damit kann der serialisierte Caller weiterlaufen, obwohl Nachkommen und Reader noch aktiv sind.

### R4-CTRL-01 — Eingebettete Control-Sequenzen verlassen den Paste-Block

**Urteil: BESTÄTIGT. Eigener Schweregrad: hoch.** `sendPrompt` sendet den Request-Text unverändert zwischen `ESC[200~` und `ESC[201~`; vor `terminal.send(txt: text)` gibt es keinerlei Zeichenfilter (`WhisperM8/Views/AgentTerminalView.swift:657-661`). Ein im Text enthaltenes `ESC[201~` kann daher den Paste-Modus vorzeitig beenden, und ein folgendes CR wird wieder als Terminalaktion interpretiert. Das widerspricht der im Code behaupteten Ein-Block-/Ein-Submit-Garantie (`WhisperM8/Views/AgentTerminalView.swift:649-652`).

### R4-CTRL-02 — Erfolg vor Submit und überlappende Sends

**Urteil: BESTÄTIGT. Eigener Schweregrad: hoch.** Der MainActor-Block garantiert zwar atomare Guards plus Paste, nicht aber Paste plus Submit: Return folgt erst in einem separaten 80-ms-Block und wird bei inzwischen beendetem Terminal verworfen (`WhisperM8/Views/AgentTerminalView.swift:657-667`). Der Handler wertet bereits die Rückkehr von `sendPrompt` als Erfolg, schließt die Idempotenzreservierung ab und antwortet `ack: delivered` (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:127-174`). Da bis zu vier Verbindungen parallel bedient werden (`WhisperM8/Services/AgentChats/AgentControlServer.swift:27-34`), können zwei Paste-Blöcke vor dem ersten Return in denselben Composer gelangen. Eine zielbezogene FIFO oder Submit-Bestätigung ist an diesen Stellen nicht vorhanden.

### R4-PROFILE-01 — Profil-Settings scheitern fail-open

**Urteil: BESTÄTIGT. Eigener Schweregrad: hoch.** `prepareSettingsFile` fängt jeden Schreibfehler ab und reduziert ihn auf `nil` (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:91-117`). Der Coordinator wandelt `nil` ohne Fehlerzustand in leere `settingsArguments` um (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:102-135`), und der interaktive Launch baut und startet den Command danach weiter (`WhisperM8/Views/AgentSessionDetailView.swift:518-532`). Zwar wird das separate Environment-Overlay weiterhin gesetzt (`WhisperM8/Views/AgentSessionDetailView.swift:523-525`), die in der Settings-Datei liegenden Profilregeln sind aber verloren. Bei einem angeforderten Restriktionsprofil ist das ein stiller Policy-Bypass, nicht bloß Hook-Degradation.

### R4-SCHEMA-01 — Profilreferenzen ohne Schema-Bump

**Urteil: BESTÄTIGT. Eigener Schweregrad: hoch.** `contextProfileID` ist produktiv Teil von Projekt und Session (`WhisperM8/Models/AgentChat.swift:178-207`, `WhisperM8/Models/AgentChat.swift:320-466`), während `AgentWorkspace.currentSchemaVersion` unverändert `1` ist (`WhisperM8/Models/AgentChat.swift:602-625`). Der Decoder hat keine Future-Version-Sperre (`WhisperM8/Models/AgentChat.swift:623-627`); die Normalisierung überschreibt sogar jede gelesene Version bedingungslos mit der aktuellen (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1182-1189`). Damit kann ein älteres Binary unbekannte Felder dekodierend ignorieren und beim nächsten Speichern entfernen, ohne die Datei als inkompatibel zu erkennen.

### R4-RESUME-01 — Fehlgeschlagener Resume verriegelt den View-Trigger

**Urteil: BESTÄTIGT. Eigener Schweregrad: hoch.** Der neue `onChange` setzt `focusLaunchInFlight` vor dem asynchron vorbereiteten Launch (`WhisperM8/Views/AgentSessionDetailView.swift:171-177`). Zurückgesetzt wird das Flag nur, wenn ein Controller sichtbar wird (`WhisperM8/Views/AgentSessionDetailView.swift:203-205`); jeder Fehler endet lediglich in `errorMessage` (`WhisperM8/Views/AgentSessionDetailView.swift:545-551`). Der Missing-Transcript-Guard setzt zwar `shouldLaunchOnOpen` auf `false`, wirft danach aber ohne Reset des View-Flags (`WhisperM8/Views/AgentSessionDetailView.swift:624-633`). Ein späterer false→true-Trigger wird deshalb vom klemmenden `focusLaunchInFlight` verworfen (`WhisperM8/Views/AgentSessionDetailView.swift:171-176`).

### R4-LIFE-01 — Eager Startup läuft an Kill-Switch und Quit vorbei

**Urteil: BESTÄTIGT. Eigener Schweregrad: hoch.** Der Toggle wird einmal vor einem ungebundenen `Task.detached` gelesen; innerhalb des Tasks gibt es keine erneute Preference- oder Generation-Prüfung (`WhisperM8/WhisperM8App.swift:304-313`). Der früheste Quit-Hook antwortet sofort `.terminateNow`, ohne diesen Task zu binden oder abzuwarten (`WhisperM8/WhisperM8App.swift:359-367`). Der Manager reagiert zwar auf `willTerminate`, aber `stopIfSelfStarted` synchronisiert nicht über den `ensureLock`, unter dem `ensureRunning` später noch einen Prozess registrieren und Router starten kann (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:198-205`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-255`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:272-299`). Der Cleanup-Observer widerlegt die Race daher nicht.

## Stichproben der mittleren Findings

Das Quelldokument enthält **2 mittlere und 0 niedrige** Findings. Beide mittleren Findings wurden als die maximal erlaubten zwei Stichproben geprüft.

### R4-GPTCTX-01 — Erhöhbares UI-Feld für nicht erhöhbares aktuelles Limit

**Urteil: BESTÄTIGT. Eigener Schweregrad: mittel.** Der Code dokumentiert 272.000 als reales GPT-5.6-Limit, lässt aber Werte bis 500.000 zu (`WhisperM8/Support/AppPreferences.swift:298-315`). Die UI bezeichnet 272.000 zugleich ausdrücklich als serverseitig nicht erhöhbar (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:265-266`). Die im Code genannte Vorsorge für künftig größere Modelle (`WhisperM8/Support/AppPreferences.swift:304-308`) erklärt die Obergrenze, widerlegt aber nicht, dass die aktuelle UI einen für das aktuelle Modell ungültigen Wert akzeptiert.

### R4-TOKEN-01 — Token bleibt nach PTY-Ende gültig

**Urteil: BESTÄTIGT. Eigener Schweregrad: mittel.** Jeder Start ersetzt bzw. erzeugt ein Session-Token und injiziert es in die PTY-Umgebung (`WhisperM8/Views/AgentTerminalView.swift:783-815`). Weder explizites `terminate()` (`WhisperM8/Views/AgentTerminalView.swift:820-842`) noch natürlicher `processTerminated` (`WhisperM8/Views/AgentTerminalView.swift:1014-1025`) ruft den vorhandenen Widerrufspfad auf (`WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift:40-44`). Wegen des ausdrücklich dokumentierten Same-UID-/Rechenschaftsmodells (`WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift:5-13`) bleibt die Einordnung mittel statt hoch.

## Urteilstabelle

| Finding | Quell-Schwere | Prüfumfang | Urteil | Eigene Schwere | Kernbeleg |
|---|---:|---|---|---:|---|
| R4-HCLI-01 | hoch | vollständig | BESTÄTIGT | mittel | Check und rohes Signal sind getrennt (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:97-100`) |
| R4-HCLI-02 | hoch | vollständig | BESTÄTIGT | hoch | Failsafe umgeht Exit-/EOF-Gate (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:101-106`, `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:174-182`) |
| R4-CTRL-01 | hoch | vollständig | BESTÄTIGT | hoch | Nutztext wird ungefiltert in Bracketed Paste gesendet (`WhisperM8/Views/AgentTerminalView.swift:657-661`) |
| R4-CTRL-02 | hoch | vollständig | BESTÄTIGT | hoch | Return ist verzögert, ACK bereits abgeschlossen (`WhisperM8/Views/AgentTerminalView.swift:657-667`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:165-174`) |
| R4-PROFILE-01 | hoch | vollständig | BESTÄTIGT | hoch | Schreibfehler wird `nil`, Launch läuft ohne Settings weiter (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:91-117`, `WhisperM8/Views/AgentSessionDetailView.swift:518-532`) |
| R4-SCHEMA-01 | hoch | vollständig | BESTÄTIGT | hoch | Schema bleibt 1 und kennt keine Future-Sperre (`WhisperM8/Models/AgentChat.swift:602-627`) |
| R4-RESUME-01 | hoch | vollständig | BESTÄTIGT | hoch | Fehlerpfad setzt In-Flight-Flag nicht zurück (`WhisperM8/Views/AgentSessionDetailView.swift:171-177`, `WhisperM8/Views/AgentSessionDetailView.swift:545-551`) |
| R4-LIFE-01 | hoch | vollständig | BESTÄTIGT | hoch | Detached Ensure ist nicht an Preference-/Quit-Generation gebunden (`WhisperM8/WhisperM8App.swift:304-313`, `WhisperM8/WhisperM8App.swift:359-367`) |
| R4-GPTCTX-01 | mittel | Stichprobe 1/2 | BESTÄTIGT | mittel | 272k dokumentiert, bis 500k akzeptiert (`WhisperM8/Support/AppPreferences.swift:298-315`) |
| R4-TOKEN-01 | mittel | Stichprobe 2/2 | BESTÄTIGT | mittel | Terminate-Pfade rufen `revoke` nicht auf (`WhisperM8/Views/AgentTerminalView.swift:820-842`, `WhisperM8/Views/AgentTerminalView.swift:1014-1025`) |
| Niedrige Findings | 0 | nur gezählt | — | — | Im Quelldokument sind keine niedrigen Findings ausgewiesen. |

**Bilanz:** Quelle: 0 kritisch, 8 hoch, 2 mittel, 0 niedrig. Verifikation: 10 BESTÄTIGT, 0 WIDERLEGT, 0 UNKLAR. Eigene Schweregrade: 7 hoch, 3 mittel. `R4-HCLI-01` wird wegen des extrem engen PID-Reuse-Fensters von hoch auf mittel abgestuft; die übrigen Einstufungen bleiben bestehen.

## Die drei wichtigsten bestätigten Punkte

1. **Context-Profile können still ohne ihre Settings-Policies starten.** Ein Schreibfehler wird zu `nil`, und der Launch wird ohne `--settings` fortgesetzt (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:91-117`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:102-135`, `WhisperM8/Views/AgentSessionDetailView.swift:518-532`). Das ist bei Restriktionsprofilen ein Fail-open.
2. **Die Control-Send-Grenze behandelt Nutztext nicht als reine Datenlast.** Ungefilterte Paste-Terminatoren können den Block verlassen; zugleich liegt der Submit 80 ms hinter dem als `delivered` quittierten Paste (`WhisperM8/Views/AgentTerminalView.swift:649-667`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:165-174`). Dadurch sind zusätzliche Terminalaktionen und verschmolzene parallele Sends möglich.
3. **Der Prozess-Lifecycle ist an zwei Stellen nicht wahrheitsgetreu abgeschlossen.** Der Headless-Failsafe kann trotz ausstehendem EOF fortsetzen (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:69-75`, `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:101-106`), und der detached GPT-Startup ist nicht gegen Quit bzw. einen nachträglichen Toggle-Wechsel generation-gebunden (`WhisperM8/WhisperM8App.swift:304-313`, `WhisperM8/WhisperM8App.swift:359-367`).
