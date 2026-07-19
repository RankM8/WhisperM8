---
status: abgeschlossen
updated: 2026-07-19
description: Adversariale Verifikation aller hohen Runde-4-Findings des Services-Abdeckungssweeps sowie zweier Stichproben aus den mittleren Findings gegen Code, Tests und Review-Fix-Stand.
---

# Runde 4: Verifikation Abdeckungssweep Services

## Prüfrahmen

Geprüft werden alle drei hohen Findings; kritische Findings enthält die Quelle nicht. Von neun mittleren Findings werden zwei adversarial stichprobenartig geprüft; das eine niedrige Finding wird nur gezählt. Maßgeblich ist der aktuelle Code-Stand. Ziel ist ausdrücklich, Gegenbelege, Guards, Tests oder inzwischen eingebrachte Fixes zu finden.

## Einzelurteile

### R4-AS-01 — BESTÄTIGT — eigene Schwere: hoch

Der Writer dokumentiert parallele Fremd-Writer selbst, liest aber nur einmal den vollständigen JSON-Snapshot (`WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:16-18,108-119`), mutiert diesen im Speicher und ersetzt anschließend die ganze Zieldatei ohne Identitäts-, Hash- oder Re-Read-Prüfung (`WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:132-153`). Atomarer Replace schützt nur die Dateiintegrität, nicht gegen einen fremden Write zwischen Read und Replace. Der zitierte Test prüft ausschließlich das Light-/Dark-Mapping (`Tests/WhisperM8Tests/ThemeManagerTests.swift:59-67`), nicht die I/O-Konkurrenz. Die einschlägigen Review-Fix-Commits haben diese seit älteren Commits unveränderte Stelle nicht geschlossen.

### R4-AS-03 — BESTÄTIGT — eigene Schwere: hoch

Der Default-Runner startet `/usr/bin/git` mit getrennten stdout-/stderr-Pipes, wartet aber zuerst synchron auf Prozessende und liest beide Pipes erst danach (`WhisperM8/Services/AgentChats/AgentWorktreeManager.swift:73-87`). `isClean` ruft damit gerade `git status --porcelain` auf, dessen Ausgabe bei vielen Änderungen den Pipe-Puffer füllen kann (`WhisperM8/Services/AgentChats/AgentWorktreeManager.swift:53-56`): Child wartet auf freien Pipe-Platz, Parent auf Child-Exit. Es gibt weder paralleles Draining noch Timeout. Die Tests injizieren kleine Ergebnisse beziehungsweise verwenden ein Kleinstrepo (`Tests/WhisperM8Tests/AgentWorktreeManagerTests.swift:7-44,46-84`); kein Test erzeugt Pipe-Druck. Keiner der genannten Review-Fix-Commits berührt diesen Runner.

### R4-AS-11 — BESTÄTIGT — eigene Schwere: hoch

Der Planer baut ohne Vorprüfung ein `Dictionary(uniqueKeysWithValues:)` aus allen Sessions (`WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift:9-20`), dessen dokumentierte Laufzeitvorbedingung eindeutige Keys sind. Der Repository-Load dekodiert, migriert und liefert Sessions zurück (`WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:50-64`); die Migration entfernt bestimmte Sessionklassen, validiert oder dedupliziert IDs aber nicht (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1182-1196`). Bei aktivierter Auto-Summary wird dieser Planer nach zehn Sekunden automatisch mit dem geladenen Workspace aufgerufen (`WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:215-234`). Die vorhandenen Planertests erzeugen ihre Sessions standardmäßig mit jeweils neuer UUID und enthalten keinen doppelten ID-Fall (`Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift:84-141`). Die genannten Review-Fix-Commits berühren diese Vorbedingung nicht. Wegen des optionalen Auto-Summary-Gates bleibt die Einordnung hoch statt kritisch.

### R4-AS-04 — BESTÄTIGT — eigene Schwere: mittel (Stichprobe)

Jeder Event-Handler erfasst zwar seine lokale alte DispatchSource, bindet die anschließende Zustandsmutation aber nicht an deren Identität: Bei Delete/Rename ruft er unqualifiziert `self.stop()` auf (`WhisperM8/Services/Shared/FileEventSource.swift:39-54`). `stop()` cancelt stets die aktuell in `self.source` gespeicherte Source (`WhisperM8/Services/Shared/FileEventSource.swift:64-67`). Nach Stop→Start kann deshalb ein bereits zugestellter Alt-Callback die neue Source abbauen; Generation oder Identitätsguard fehlen. Die Tests prüfen nur Write, Delete und Open-Fehler (`Tests/WhisperM8Tests/AgentSessionEventWatchTests.swift:16-56`), nicht Re-Arm mit verspätetem Callback. Die Review-Fix-Commits ändern die Datei nicht.

### R4-AS-06 — BESTÄTIGT — eigene Schwere: mittel (Stichprobe)

Der Parser verspricht defensives Verhalten ohne Würfe (`WhisperM8/Services/AgentChats/CodexExecEventParser.swift:3-6`), akzeptiert JSON-Zahlen aber als `Double` und konvertiert sie ohne `isFinite`- oder Bereichsprüfung direkt mit `Int(double)` (`WhisperM8/Services/AgentChats/CodexExecEventParser.swift:89-94`). Derselbe Helper verarbeitet Usage-Werte und Exitcodes (`WhisperM8/Services/AgentChats/CodexExecEventParser.swift:49-70`). Für endliche, aber außerhalb des `Int`-Bereichs liegende Double-Werte ist diese Swift-Konvertierung trap-fähig; die Parser-Toleranz wird damit verletzt. Tests decken normale Usage-Integer sowie malformed/unknown Events ab (`Tests/WhisperM8Tests/CodexExecEventParserTests.swift:45-52,81-103`), aber keine Exponenten, Nicht-Endlichkeit oder Bereichsgrenzen. Die Review-Fix-Commits ändern den Parser nicht.

## Urteilstabelle

| Finding | Quellschwere | Verifikation | Eigene Einordnung / Hinweis |
|---|---:|---|---|
| R4-AS-01 | hoch | **BESTÄTIGT** | hoch — externer Lost Update (`WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:108-153`) |
| R4-AS-02 | mittel | nicht einzeln geprüft | nur gezählt |
| R4-AS-03 | hoch | **BESTÄTIGT** | hoch — unbeschränkter Pipe-Deadlock (`WhisperM8/Services/AgentChats/AgentWorktreeManager.swift:73-87`) |
| R4-AS-04 | mittel | **BESTÄTIGT** | mittel — Stichprobe; Alt-Callback kann neue Source stoppen (`WhisperM8/Services/Shared/FileEventSource.swift:39-67`) |
| R4-AS-05 | mittel | nicht einzeln geprüft | nur gezählt |
| R4-AS-06 | mittel | **BESTÄTIGT** | mittel — Stichprobe; trap-fähige Double-Konvertierung (`WhisperM8/Services/AgentChats/CodexExecEventParser.swift:89-94`) |
| R4-AS-07 | mittel | nicht einzeln geprüft | nur gezählt |
| R4-AS-08 | mittel | nicht einzeln geprüft | nur gezählt |
| R4-AS-09 | mittel | nicht einzeln geprüft | nur gezählt |
| R4-AS-10 | niedrig | nicht einzeln geprüft | nur gezählt |
| R4-AS-11 | hoch | **BESTÄTIGT** | hoch — doppelte ID verletzt trap-fähige Dictionary-Vorbedingung (`WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift:9-20`) |
| R4-AS-12 | mittel | nicht einzeln geprüft | nur gezählt |
| R4-AS-13 | mittel | nicht einzeln geprüft | nur gezählt |

**Abdeckung:** 0 kritische Findings vorhanden; 3/3 hohe vollständig geprüft und bestätigt; 2/9 mittlere stichprobenartig geprüft und bestätigt; weitere 7 mittlere sowie 1 niedriges Finding nur gezählt. Unter den fünf geprüften Findings: 5 bestätigt, 0 widerlegt, 0 unklar.

## Die drei wichtigsten bestätigten Punkte

1. **Fremde Settings können dauerhaft verloren gehen.** Zwischen einmaligem Read und vollständigem Replace fehlt jede Konkurrenzprüfung (`WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:108-119,132-153`).
2. **Worktree-Operationen können unbegrenzt hängen.** Der Parent wartet vor dem Leeren beider Pipes auf Git; `git status --porcelain` kann dabei große stdout-Ausgabe erzeugen (`WhisperM8/Services/AgentChats/AgentWorktreeManager.swift:53-56,73-87`).
3. **Dekodierbare Persistenzdaten können den Startup-Abgleich fatal beenden.** IDs werden beim Load/Migrieren nicht dedupliziert (`WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:50-64`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1182-1196`), anschließend setzt der Planer Eindeutigkeit hart voraus (`WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift:9-20`).

## Gesamturteil

Der adversariale Gegencheck konnte keines der priorisierten Findings widerlegen. Alle drei hohen Befunde bestehen auf HEAD unverändert; beide mittleren Stichproben überleben ebenfalls. Besonders belastbar sind die hohen Befunde, weil jeweils nicht nur ein fehlender Test, sondern eine konkrete trap-, Deadlock- oder Lost-Update-fähige Ausführungsfolge im Produktionscode vorliegt. Es wurden keine Builds oder Tests ausgeführt und kein Produktcode geändert.
