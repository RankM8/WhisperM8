---
status: abgeschlossen
updated: 2026-07-19
description: Adversariale Verifikation des hohen Runde-4-Findings im Views-/CLI-Abdeckungssweep sowie zweier Stichproben aus den mittleren und niedrigen Findings gegen HEAD und einschlägige Review-Fix-Commits.
---

# Runde 4: Adversariale Verifikation – Views und CLI

## Umfang

Vollständig zu prüfen: 0 kritische und 1 hohes Finding. Nur gezählt: 8 mittlere und 2 niedrige Findings; davon werden höchstens zwei stichprobenartig geprüft. Prüfstand ist `HEAD` vom 2026-07-19. Es wurden keine Builds oder Tests ausgeführt.

## Laufende Urteile

- **R4-VC-02 — BESTÄTIGT (mittel; Stichprobe).** Der Parser verlangt lediglich einen als `Double` lesbaren Wert `> 0`; eine Endlichkeits-, Mindestwert- oder Chunkzahlgrenze ist nicht vorhanden. Der Dry-Run berechnet `Int(ceil(duration / target))` ohne Prüfung auf Endlichkeit oder `Int`-Darstellbarkeit. Die gezielte Suche fand nur einen normalen 30-Sekunden-Parserfall, keine Extremwert- oder Dry-Run-Absicherung und keinen späteren Fix-Commit. Belege: `WhisperM8/CLI/CLIArguments.swift:111-116`; `WhisperM8/CLI/CLITranscribe.swift:270-280`; `Tests/WhisperM8Tests/CLITranscriptionTests.swift:67-71`. Eigene Schweregradeinordnung: **mittel**, da ein explizit übergebener lokaler Extremwert Crash beziehungsweise unbeschränkte Arbeit auslösen kann, der normale Defaultpfad aber nicht betroffen ist.

- **R4-VC-03 — BESTÄTIGT (hoch).** Nach `process.run()` wartet der Parent synchron mit `waitUntilExit()`; erst danach wird stderr gelesen, während stdout an eine weitere, nie gelesene Pipe gebunden ist. Damit kann bereits ein volles stderr- oder stdout-Pipe den Child-Prozess vor dessen Exit blockieren; zusätzlich fehlt jede Deadline oder Terminierung. Die Suche fand weder Extractor-/ffmpeg-Tests noch einen späteren Fix-Commit für diese Datei. Belege: `WhisperM8/CLI/CLIAudioExtractor.swift:197-211`; `WhisperM8/CLI/CLIAudioExtractor.swift:201-206`. Eigene Schweregradeinordnung: **hoch**, weil ein gültig erreichbarer Fallback-Pfad die CLI unbegrenzt blockieren kann, aber kein appweiter Datenverlust oder Sicherheitsbruch belegt ist.

- **R4-VC-11 — BESTÄTIGT (mittel; Stichprobe).** `parseIDCommand` akzeptiert jede einzelne Positionsangabe, sofern sie nicht mit `-` beginnt; `../backup-job` passiert damit unverändert. Der Store hängt diese Zeichenfolge direkt an sein Root an, ohne Standardisierung, Child-Prüfung oder Symlink-Abwehr, und `removeJob` löscht genau dieses berechnete Verzeichnis rekursiv. Die einzige gefundene `standardizedFileURL`-Nutzung gehört zu einer anderen Pfadhilfe, nicht zur Job-ID; negative Traversal-/Containmenttests und ein späterer Fix wurden nicht gefunden. Belege: `WhisperM8/CLI/AgentCLIArguments.swift:196-210`; `WhisperM8/Services/AgentChats/AgentJobStore.swift:56-67`; `WhisperM8/Services/AgentChats/AgentJobStore.swift:182-188`; zum ausgeschlossenen Gegenbeleg `WhisperM8/CLI/AgentCLICommand.swift:149-155`. Eigene Schweregradeinordnung: **mittel**, weil Read/Signal/rekursives Löschen die dokumentierte Job-Root-Grenze verlassen können, der Angriffspfad jedoch lokalen CLI-Zugriff und für die gefährlichsten Command-Pfade einen passend decodierbaren State voraussetzt.

## Gegenprüfung des Fix-Stands

Die gezielte Pfadprüfung der genannten Review-Fix-Commits `f50847e`, `c6ac557`, `9e4b9f4`, `e445b65` und `1bd655f` ergab keine Änderung an den für R4-VC-02, R4-VC-03 oder R4-VC-11 relevanten Produktions- und Testdateien. Die Befunde wurden deshalb gegen den aktuellen `HEAD`-Code geprüft; ältere bloße Finding-Texte waren nicht urteilsentscheidend.

## Gesamturteil

Der einzige hohe Befund hält der Widerlegungsprüfung stand. Auch beide bewusst risikoorientiert gewählten Stichproben sind am aktuellen Code bestätigt. Das ist kein Vollurteil über die acht nicht einzeln geprüften mittleren/niedrigen Findings; diese sind in der Tabelle ausdrücklich nur gezählt.

## Urteilstabelle

| ID | Ausgangsschwere | Prüfumfang | Urteil | Eigene Schwere |
|---|---:|---|---|---:|
| R4-VC-01 | mittel | nur gezählt | nicht einzeln geprüft | – |
| R4-VC-02 | mittel | Stichprobe | **BESTÄTIGT** | mittel |
| R4-VC-03 | hoch | vollständig | **BESTÄTIGT** | hoch |
| R4-VC-04 | mittel | nur gezählt | nicht einzeln geprüft | – |
| R4-VC-05 | mittel | nur gezählt | nicht einzeln geprüft | – |
| R4-VC-06 | mittel | nur gezählt | nicht einzeln geprüft | – |
| R4-VC-07 | niedrig | nur gezählt | nicht einzeln geprüft | – |
| R4-VC-08 | mittel | nur gezählt | nicht einzeln geprüft | – |
| R4-VC-09 | niedrig | nur gezählt | nicht einzeln geprüft | – |
| R4-VC-10 | mittel | nur gezählt | nicht einzeln geprüft | – |
| R4-VC-11 | mittel | Stichprobe | **BESTÄTIGT** | mittel |

**Summen:** 0 kritische, 1 hohes, 8 mittlere und 2 niedrige Findings im Quelldokument. Vollständig geprüft wurde das eine hohe Finding; zusätzlich wurden zwei der zehn mittleren/niedrigen Findings stichprobenartig geprüft. Ergebnis der drei Einzelprüfungen: 3 bestätigt, 0 widerlegt, 0 unklar.

## Drei wichtigste bestätigte Punkte

1. **ffmpeg-Fallback kann unbegrenzt blockieren.** Beide Child-Streams sind Pipes, aber der Parent wartet vor dem stderr-Drain auf den Exit und liest stdout nie; eine Deadline fehlt (`WhisperM8/CLI/CLIAudioExtractor.swift:197-211`).
2. **Job-IDs durchbrechen die Store-Grenze.** Ein freier Positionswert wird ungeprüft als Pfadkomponente verwendet und das resultierende Verzeichnis kann rekursiv gelöscht werden (`WhisperM8/CLI/AgentCLIArguments.swift:196-210`; `WhisperM8/Services/AgentChats/AgentJobStore.swift:58-67`; `WhisperM8/Services/AgentChats/AgentJobStore.swift:182-188`).
3. **Extrem kleine Chunk-Werte bleiben ungefangen.** Die Eingabeprüfung akzeptiert jeden positiven `Double`, während der Dry-Run den Quotienten direkt nach `Int` konvertiert (`WhisperM8/CLI/CLIArguments.swift:111-116`; `WhisperM8/CLI/CLITranscribe.swift:270-280`).
