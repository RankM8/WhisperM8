# Nachprüfung Runde 2 (Stichprobe) — Fable

Unabhängige Stichproben-Nachprüfung der 16 bestätigten Runde-2-Findings aus
`verdicts-runde2.md` gegen den realen Code (Stand: main, 2026-07-18).
10 von 16 Findings wurden an den zitierten Datei:Zeile-Fundorten geöffnet und
gegengelesen; kein Code wurde geändert.

## Ergebnistabelle

| Finding | Fundort geprüft | Urteil | Anmerkung |
|---|---|---|---|
| N01 | nein | — | nicht Teil der Stichprobe |
| N02 | ja | bestätigt | `WhisperM8App.swift:343-351`: `applicationShouldTerminate` sichert nur Terminal-Snapshots (`captureAllSnapshotsForAppQuit`) und antwortet sofort `.terminateNow`; `:357-361` (`applicationWillTerminate`) beendet nur Audio-Ducking + WindowStore-Flush. `MenuBarView.swift:113-116` ruft direkt `terminate(nil)`. Keine Sicherung laufender Aufnahmen — Mechanismus exakt wie beschrieben. |
| N03 | ja | bestätigt | `OutputModeStore.loadModes()` (:126-134) dekodiert das Array ohne Eindeutigkeitsprüfung; `normalized()` übergibt die migrierten Modi ungeprüft an `Dictionary(uniqueKeysWithValues:)` — bei doppelter ID garantierter Crash. Kleine Abweichung: der Detailtext verortet den `Dictionary`-Aufruf bei „:64-69"; tatsächlich steht er in Zeile **162** (innerhalb des in der Tabelle korrekt zitierten Bereichs 145-165). :64-69 ist nur die `modes`-Property, die `normalized()` aufruft. Mechanismus stimmt. |
| N04 | ja | bestätigt | `loadModes()` liefert bei jedem Decoding-Fehler `[]` (:131-133), `modes` ersetzt leer sofort durch Built-ins (:66-68), `saveModes` schreibt atomar ohne Backup (:81-90). `OutputModesViewModel.updateMode` (:204-208) speichert bei jeder Moduseinstellung den kompletten (dann bereinigten) Bestand zurück (:210-212). Verlustpfad exakt wie beschrieben. |
| N05 | nein | — | nicht Teil der Stichprobe |
| N06 | ja | bestätigt | `KeychainManager.save` ist `Void`, Fehlschlag nur geloggt (:30-34), Cache nur bei Erfolg (:30-31). Migrationspfad `load` (:62-66): `save` aufrufen, `UserDefaults.removeObject` **bedingungslos**, Legacy-Wert trotzdem zurückgeben. Zeilenangaben treffen exakt. |
| N07 | nein | — | nicht Teil der Stichprobe |
| N08 | ja | bestätigt | `CodexExecRunner`-`terminationHandler` übernimmt nur `terminationStatus` (:269-271), nie `terminationReason`. `CodexTurnExecutor.mapOutcome` (:83-120): nach `stalled`, `turnFailedMessage` und `exitCode == 0` bedingungslos `.done` — `lastMessage == nil` ergibt lediglich `report = nil` (:113), kein Fehler. Exakt wie beschrieben. |
| N09 | ja | bestätigt | `LoginShellEnvironment.processEnvironment` (:91-137) kopiert das komplette Basis-Env und entfernt nur `CLAUDE_CODE_*`/`CLAUDECODE` (:106-108), `CLAUDE_CONFIG_DIR` (:119) und `NO_COLOR` (:132). AWS/GCP-Credentials, `SSH_AUTH_SOCK` etc. bleiben drin. Exakt wie beschrieben. |
| N10 | ja | bestätigt | `ClaudeAccountProfiles.renameProfile`: Secret-Read via `find-generic-password … -w` (:366), bei Erfolg landet `trimmedSecret` direkt hinter `-w` im Argument-Array von `add-generic-password` (:374-377); der `securityRunner` überträgt das Array 1:1 nach `Process.arguments` (:328-331). argv-Exposition real; die im Verdict vermerkte Fundort-Verschiebung (363-377 statt Ursprungsangabe) stimmt ebenfalls. |
| N11 | nein | — | nicht Teil der Stichprobe |
| N12 | nein | — | nicht Teil der Stichprobe |
| N13 | nein | — | nicht Teil der Stichprobe |
| N14 | ja | bestätigt | `AgentSuperviseCommand`: SIGTERM → `supervisor.requestStop()`; `requestStop` (:46-51) setzt nur `stopRequested` und ruft `runner.terminate()`. `CodexExecRunner.terminate()` (:329-335) ist No-op solange `process == nil`; `self.process` wird erst nach `process.run()` gesetzt (:284-286). `stopRequested` wird später nur noch zur Status-Etikettierung gelesen (`AgentJobSupervisor.swift:153`), nie als nachträglicher Kill nachgeholt. Running-State + PID werden vorher publiziert (:81-87) — das Verlustfenster existiert exakt wie beschrieben. |
| N15 | ja | bestätigt | `AgentChatBlock.toolUse`/`.toolResult` (`AgentChatTranscript.swift:96-103`) tragen keine Korrelations-ID. `ClaudeTranscriptReader`: `tool_result` liest nur `is_error`+`content` (:173-178), `tool_use` nur `name`+`input` (:211-214) — `tool_use.id`/`tool_use_id` werden ignoriert. `CodexTranscriptReader`: `function_call` (:153-161) und `function_call_output` (:162-170) ignorieren `call_id`. Exakt wie beschrieben. |
| N16 | ja | bestätigt | `CodexTranscriptReader.parseEntry` (:112-146): nur `event_msg` (2 Payload-Typen) und `response_item` (4 Typen in `parseResponseItem` :151-199), alle Defaults → `nil`. `readTail` (:95-108) entfernt `nil` per `compactMap` ohne Telemetrie; `read` (:65-87) zählt `skipped` nur bei ungültigem JSON (:74-78), nicht bei erkannten-aber-unbehandelten Typen. Exakt wie beschrieben. |

## Abschluss

- Stichprobe: **10 von 16** Findings (N02, N03, N04, N06, N08, N09, N10, N14, N15, N16) an den zitierten Fundorten im Code geöffnet.
- Ergebnis: **10 von 10 geprüften Findings im Code bestätigt** — kein Finding widerlegt, keines bereits gefixt.
- Einzige Abweichung (kosmetisch): Bei N03 verortet der Verdict-**Detailtext** den `Dictionary(uniqueKeysWithValues:)`-Aufruf fälschlich bei `OutputModeStore.swift:64-69`; tatsächlich Zeile 162. Die Fundort-Angabe in der Verdict-**Tabelle** (`118-134,145-165`) deckt die Stelle korrekt ab. Der beschriebene Crash-Mechanismus stimmt unverändert.
- Nicht geprüft (außerhalb der Stichprobe): N01, N05, N07, N11, N12, N13.
