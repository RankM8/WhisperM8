---
status: abgeschlossen
updated: 2026-07-19
description: Adversariale Verifikation aller hohen und zweier stichprobenartig ausgewählter weiterer Runde-4-Findings zum Claude-Plugin-Manager gegen Produktionscode, Tests und einschlägige Review-Fix-Commits.
---

# Runde 4: Verifikation Claude-Plugin-Manager

## Prüfrahmen

Verifiziert wurde gegen `HEAD` (`2e79f40`). Vollständig geprüft wurden die **zwei hohen** Findings; kritisch eingestufte Findings enthält der Ausgangsbericht nicht. Von den **fünf mittleren** und **einem niedrigen** Finding wurden gemäß Auftrag nur R4-PLUG-03 und R4-PLUG-07 stichprobenartig geprüft. Builds und Tests wurden nicht ausgeführt.

Maßstab war nicht die Plausibilität des Berichts, sondern der Versuch, jedes geprüfte Finding durch Guards, Serialisierung, Cache-Invarianten, Tests oder die Review-Fix-Commits `f50847e`, `c6ac557`, `9e4b9f4`, `e445b65` und `1bd655f` zu widerlegen. Von diesen Commits berührt nur `9e4b9f4` die hier relevanten Produktdateien; dessen Gegenmaßnahmen sind im aktuellen Code enthalten, schließen die vier geprüften Lücken aber nicht.

## Einzelurteile

### R4-PLUG-01 — BESTÄTIGT

**Eigener Schweregrad: hoch.**

Das Installations-Sheet akzeptiert freie `key=value`-Zeilen und übergibt das ungefilterte Parser-Ergebnis an `install` (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:466-479`; `WhisperM8/Views/Settings/Kit/SettingsLineParsing.swift:13-22`). `install` serialisiert jedes Paar unverändert als `--config`, `key=value` (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:91-101`), und der Prozess-Runner setzt genau dieses Array als `Process.arguments`; lediglich stdin wird auf `/dev/null` gelegt (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:35-41`). Damit gelangen secret-verdächtige Werte tatsächlich in den Prozess-`argv`.

**Widerlegungsversuch:** Weder Parser noch Installationspfad besitzen eine Key-Denylist, Secret-Klassifikation oder einen alternativen Übergabekanal (`WhisperM8/Views/Settings/Kit/SettingsLineParsing.swift:13-22`; `WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:91-101`). Der Fake-Runner-Test schreibt die argv-Form sogar fest, kann aber keine reale Prozesssichtbarkeit absichern (`Tests/WhisperM8Tests/ClaudePluginCLITests.swift:212-252`). Der stdin-Guard verhindert interaktive Hänger, schützt aber keine Argumentwerte (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:35-41`).

### R4-PLUG-02 — BESTÄTIGT

**Eigener Schweregrad: hoch.**

Die dokumentierte harte Garantie beruht auf einem prozessweiten Serializer, der die nächste Operation freigibt, sobald der vorherige Swift-Task endet (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:13-31,162-174`). Beim Timeout adressieren `Process.terminate()` und der spätere `kill(process.processIdentifier, SIGKILL)` ausschließlich den direkten Prozess; eine Prozessgruppe wird weder erzeugt noch signalisiert (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:78-100`). Nach weiteren fünf Sekunden umgeht `forceFinish` ausdrücklich die normale Invariante „Prozess beendet und beide Streams auf EOF“ (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:101-111,116-130,174-190`). Ein Kindprozess mit geerbten Pipes kann den Runner-Task und damit den Serializer deshalb überleben.

**Widerlegungsversuch:** Der reguläre Abschluss wartet korrekt auf Exit und beide Streams (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:116-130,180-190`), wird aber gerade im beanstandeten Failsafe-Pfad umgangen (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:101-111,174-177`). Der Serializer verhindert überlappende Runner-Tasks, nicht überlebende Betriebssystem-Kindprozesse (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:19-31,162-174`). Die Tests prüfen nur acht asynchrone Closures beziehungsweise `/bin/sleep`, nicht einen Kindprozess mit geerbten Pipes (`Tests/WhisperM8Tests/ClaudePluginCLITests.swift:93-125`; `Tests/WhisperM8Tests/AgentSessionAutoNamerTests.swift:49-59`).

### R4-PLUG-03 — BESTÄTIGT

**Eigener Schweregrad: mittel.**

Der Cache-Key enthält nur Plugin-ID und Version, nicht das Profil (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:19-21,46-48`). `loadDetailsIfNeeded` ermittelt Key und Profil vor dem `await`, schreibt danach aber ohne Profil- oder Generationsprüfung (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:66-83`). `switchAccountProfile` leert den Cache, entwertet laufende Detail-Requests jedoch nicht (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:156-160`).

**Widerlegungsversuch:** Der Profil-Picker ist nur bei `isBusy` deaktiviert (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:55-69`), Detail-Loads setzen `isBusy` aber nicht (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:66-83`) und starten unabhängig über eine `Task` (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:421-427`). Die globale CLI-Serialisierung verhindert parallele CLI-Prozesse, aber keinen verspäteten MainActor-Cache-Write nach Ende des alten Aufrufs (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:19-31`; `WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:66-83`). Der vorhandene Profiltest führt Laden und Wechsel strikt nacheinander aus (`Tests/WhisperM8Tests/ClaudePluginManagerModelTests.swift:153-165`).

### R4-PLUG-07 — BESTÄTIGT

**Eigener Schweregrad: mittel.**

Die Summe verwirft fehlende Werte per `compactMap`, während `isTokenSumComplete` nur die Existenz irgendeines Cache-Eintrags prüft (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:31-44`). Ein Detailfehler wird als leerer Cache-Placeholder gespeichert (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:66-83`); auch der nie werfende Parser kann bei nicht passendem Text ein leeres Details-Objekt liefern (`WhisperM8/Services/AgentChats/ClaudePluginDetailsParser.swift:2-19,29-38,94-105`). Die UI verwendet `isTokenSumComplete` unmittelbar für `.ok` und entfernt dann den Zusatz `(partial)` (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:163-171`).

**Widerlegungsversuch:** Der Placeholder behebt den Endlos-Spinner, modelliert aber Fehler und erfolgreich geladene Details nicht als verschiedene Zustände (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:66-83`). Der Failure-Test bestätigt nur Placeholder und `alwaysOnTokens == nil`; die daraus folgende Completeness wird nicht geprüft (`Tests/WhisperM8Tests/ClaudePluginManagerModelTests.swift:136-151`).

## Nur gezählte Findings

Die folgenden vier Findings wurden bewusst **nicht inhaltlich verifiziert** und erhalten daher kein Sachurteil:

- R4-PLUG-04 — mittel — Uninstall, Marketplace-Remove und Prune ohne Bestätigung.
- R4-PLUG-05 — mittel — Komplettverlust einer Plugin- oder Marketplace-Liste bei gedriftetem JSON-Feld.
- R4-PLUG-06 — mittel — englische Labels und ungefilterter Terminaltext im Details-Parser.
- R4-PLUG-08 — niedrig — stilles Verwerfen fehlerhafter Config-Zeilen vor der CLI-Validierung.

## Urteilstabelle

| ID | Bericht | Prüfumfang | Urteil | Eigene Einordnung |
|---|---:|---|---|---:|
| R4-PLUG-01 | hoch | vollständig | **BESTÄTIGT** | hoch |
| R4-PLUG-02 | hoch | vollständig | **BESTÄTIGT** | hoch |
| R4-PLUG-03 | mittel | Stichprobe 1/2 | **BESTÄTIGT** | mittel |
| R4-PLUG-04 | mittel | nur gezählt | **NICHT GEPRÜFT** | — |
| R4-PLUG-05 | mittel | nur gezählt | **NICHT GEPRÜFT** | — |
| R4-PLUG-06 | mittel | nur gezählt | **NICHT GEPRÜFT** | — |
| R4-PLUG-07 | mittel | Stichprobe 2/2 | **BESTÄTIGT** | mittel |
| R4-PLUG-08 | niedrig | nur gezählt | **NICHT GEPRÜFT** | — |

**Bilanz:** 0 kritisch, 2 hoch, 5 mittel, 1 niedrig im Ausgangsbericht. Geprüft: 4; davon 4 bestätigt, 0 widerlegt, 0 unklar. Nur gezählt: 4.

## Drei wichtigste bestätigte Punkte

1. **Freie Plugin-Konfiguration wird Teil des Prozess-`argv`.** Der UI- und Parserpfad besitzt keinen Secret-Guard, und der CLI-Wrapper schreibt die Werte direkt in `Process.arguments` (`WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:466-479`; `WhisperM8/Views/Settings/Kit/SettingsLineParsing.swift:13-22`; `WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:91-101`; `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:35-41`).
2. **Der Timeout wahrt die behauptete Prozessbaum-Exklusivität nicht.** Direkte PID-Signale plus ein quieszenzfreier Failsafe können den Serializer freigeben, obwohl Kindprozesse fortbestehen (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:78-111,174-190`; `WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:19-31,162-174`).
3. **Fehlende Details werden als vollständige Token-Summe präsentiert.** Cache-Existenz und numerischer Tokenwert sind zwei verschiedene Bedingungen, die das Modell derzeit vermischt (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:31-44,66-83`; `WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:163-171`).
