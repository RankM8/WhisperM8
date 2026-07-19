---
status: abgeschlossen
updated: 2026-07-19
description: Adversariale Verifikation aller hohen und zweier stichprobenartig ausgewählter mittlerer Runde-4-Findings zur GPT-Backend-Einrichtung gegen HEAD und einschlägige Review-Fix-Commits.
---

# Runde 4: Verifikation GPT-Backend-Einrichtung

## Prüfrahmen

Die Quelle enthält **0 kritische, 2 hohe, 3 mittlere und 0 niedrige Findings** (`docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde4-gpt-setup.md:15-63`). Vollständig geprüft wurden beide hohen Findings; aus den drei mittleren wurden R4-GPTL-03 und R4-GPTI-05 stichprobenartig geprüft. R4-GPTL-04 wird nur gezählt und nicht bewertet. Builds und Tests wurden auftragsgemäß nicht ausgeführt.

Die Fix-Commits wurden nur datei- und stellenbezogen gegengeprüft: `c6ac557` berührt Installer, Settings-Seite und Installer-Tests; `e445b65` und `1bd655f` verschärfen den Stempelpfad. `f50847e` und `9e4b9f4` berühren laut gezieltem Dateiscope keine der hier geprüften Dateien. Maßgeblich bleibt HEAD.

## Einzelurteile

### R4-GPTS-01 — Update ohne unabhängige Vertrauenswurzel

**Urteil: BESTÄTIGT — eigene Schwere: hoch.**

Der stärkste Gegenbeleg gilt nur für die Erstinstallation: Version `0.1.21` und beide Darwin-Hashes sind fest eingebettet; `installKnownGood()` führt genau in diesen gepinnten Pfad (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:13-21`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:133-150`). Der Test beweist außerdem, dass ein Fake-Sidecar diesen Pin nicht ersetzen kann (`Tests/WhisperM8Tests/ClaudeCodeProxyBinaryInstallerTests.swift:95-117`). Das begrenzt, widerlegt aber nicht das Update-Finding.

Für jede nicht gepinnte Version werden Archiv und erwarteter Hash aus demselben GitHub-Release geladen (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:123-128`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:220-232`). Die Settings-Seite übernimmt die von `releases/latest` gelieferte neuere Version direkt in `install(version:)` (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:353-375`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:380-395`). Eine kompromittierte Release-Quelle kann daher Payload und Sidecar gemeinsam konsistent ersetzen; der SHA-256-Vergleich prüft dann nur deren Übereinstimmung (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:141-150`). Der gelesene Pfad enthält keine davon unabhängige Signatur- oder Publisher-Prüfung und geht nach dem Hashvergleich über Extraktion und Quarantäneentfernung zum Replace (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:152-198`).

Zusätzliche Guards schließen das Szenario nicht: Der Default-Downloader verwirft `URLResponse` und damit HTTP-Status und finale Redirect-URL (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:53-75`); `removeQuarantine` ignoriert Startfehler und wertet den Exitstatus von `xattr` nicht aus (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:235-242`). Nach erfolgreichem Update löst `refreshStatus()` unmittelbar `authStatus()` aus, das ein ausführbares Managed Binary als `codex auth status` startet (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:387-393`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:475-485`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:302-329`). Die Teststichprobe modelliert nur gemeinsam vom Fake gelieferte Payload und Sidecar, keine unabhängige Publisher-Identität (`Tests/WhisperM8Tests/ClaudeCodeProxyBinaryInstallerTests.swift:55-69`).

### R4-GPTL-02 — Keine Identität/Generation für Setup- und Refresh-Läufe

**Urteil: BESTÄTIGT — eigene Schwere: hoch.**

`runFullSetup` speichert weder Task-Handle noch Generation. Die SwiftUI-`.task(id: backendEnabled)` stößt nur die synchrone Hilfsmethode an (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:101-115`); diese startet eine unstrukturierte `Task` und darin `Task.detached`, friert aber lediglich den Port ein (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:404-430`). Der in `c6ac557` ergänzte Abschluss-Guard prüft nur den aktuellen Bool `backendEnabled` (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:432-440`). Ein Aus→Ein-Zyklus macht ihn wieder wahr, während `clearStatus()` `isSetupRunning` nicht zurücksetzt (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:101-108`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:542-550`); dadurch blockiert der alte Lauf einen Neustart und seine spätere Completion gilt erneut als aktuell (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:404-456`).

Auch Port- und Refresh-Gegenproben widerlegen das Finding nicht. Der Runner verwendet den am Start eingefrorenen Port erst nach einem potenziell langsamen Binary-Download für den Proxy-Start (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:411-416`, `WhisperM8/Views/Settings/Pages/GPTBackendSetupRunner.swift:59-83`). `refreshStatus()` friert zwar `checkedPort` ein, schreibt den Snapshot danach jedoch ohne Prüfung von aktuellem Backend-Zustand, Port oder Generation zurück (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:460-492`). `clearStatus()` setzt parallel nur `isRefreshing = false`, ohne den laufenden Refresh abzubrechen (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:542-550`). Die gezielte Testsuche fand in `GPTBackendSetupRunnerTests` nur direkte Runner-Aufrufe; kein Treffer instanziiert die Settings-Seite oder modelliert Toggle, Cancellation beziehungsweise Generation (`Tests/WhisperM8Tests/GPTBackendSetupRunnerTests.swift:33-36`).

### R4-GPTL-03 — Toggle-off verliert den Code, nicht den Login-Prozess

**Urteil: BESTÄTIGT — eigene Schwere: mittel.**

Die Seite hält Code und Running-State nur lokal (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:11-24`). Beim Deaktivieren ruft sie ausschließlich `clearStatus()` auf; diese Methode löscht `deviceCodeInfo`, verändert `isDeviceLoginRunning` aber nicht und ruft keinen Manager-Teardown (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:101-108`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:542-550`). Der einzige Login-Button bleibt bei wahrer Running-Flag deaktiviert (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:193-206`), und erst der Prozess-Callback setzt die Flag zurück (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:514-538`).

Der Manager-Gegenbeleg reicht nicht: `stopDeviceLogin()` ist privat und wird im gelesenen Produktionscode nur vor einem neuen Manager-Start sowie bei `NSApplication.willTerminate` aufgerufen (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:198-205`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:336-346`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:443-451`). Der vorhandene Test startet den Manager zweimal direkt und prüft Terminate sowie Handle-Identität; Toggle-off, verlorener Code und Page-State sind nicht Teil des Tests (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:239-271`).

### R4-GPTI-05 — Binary und Stempel sind nicht crash-atomar

**Urteil: BESTÄTIGT — eigene Schwere: mittel.**

Die Fix-Commits liefern echte Gegenbelege gegen die breitere Altbehauptung: Ein statischer Lock serialisiert die finale Mutation, der neue Stempel wird vorab gestaged, und ein vorhandener alter Stempel muss vor dem Binary-Tausch erfolgreich entfernt werden (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:27-30`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:169-190`). Damit verhindern `c6ac557`, `e445b65` und `1bd655f` paralleles A/B-Mischen sowie „neues Binary mit altem Stempel“.

Die engere Crash-Lücke bleibt: Nach Entfernen des alten Stempels folgen Binary-Replace, `chmod` und Stempel-Replace als drei separate, werfende beziehungsweise crashbare Operationen ohne Rollback (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:187-200`). Nach erfolgreichem `chmod`, aber vor dem finalen Replace kann daher ein ausführbares Binary ohne Stempel verbleiben. `installedManagedVersion()` liefert dann `nil` (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:107-114`), während `resolvedBinaryPath()` dasselbe Managed Binary allein wegen seines Executable-Bits akzeptiert (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:318-329`). Der SetupRunner sieht damit ein vorhandenes Binary und überspringt die Neuinstallation (`WhisperM8/Views/Settings/Pages/GPTBackendSetupRunner.swift:59-75`).

Die Tests decken erfolgreichen Overwrite und Rechte-Reparatur sowie einen Fehler **vor** dem Binary-Swap ab (`Tests/WhisperM8Tests/ClaudeCodeProxyBinaryInstallerTests.swift:120-164`, `Tests/WhisperM8Tests/ClaudeCodeProxyBinaryInstallerTests.swift:167-200`). Einen Crash/Fehler zwischen Binary-Replace, `chmod` und Stempel-Replace oder den Resolver-/Runner-Pfad ohne Stempel modellieren sie nicht. Die eigene Schwere bleibt mittel, weil das Binary vor dem Replace bereits gegen den jeweils geltenden Pin beziehungsweise Release-Hash geprüft wurde (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:141-150`); die Restwirkung betrifft primär Versionswahrheit, Selbstreparatur und Verfügbarkeit.

## Urteilstabelle

| ID | Quellschwere | Prüfstatus / Urteil | Eigene Schwere | Kurzgrund |
|---|---:|---|---:|---|
| R4-GPTS-01 | hoch | **BESTÄTIGT** | **hoch** | Update-Payload und Sidecar besitzen dieselbe Vertrauenswurzel; der gepinnte Known-good-Pfad schützt nur Version `0.1.21`. |
| R4-GPTL-02 | hoch | **BESTÄTIGT** | **hoch** | Bool-Guard erkennt dauerhaftes Aus, aber weder Aus→Ein noch Port-/Refresh-Generationen. |
| R4-GPTL-03 | mittel | **BESTÄTIGT** (Stichprobe) | **mittel** | Toggle-off löscht den sichtbaren Code, beendet den Manager-Prozess aber nicht. |
| R4-GPTL-04 | mittel | **nur gezählt, nicht einzeln geprüft** | — | Gemäß Stichprobenlimit nicht bewertet. |
| R4-GPTI-05 | mittel | **BESTÄTIGT** (Stichprobe) | **mittel** | Lock und Vorab-Staging verhindern keine Crash-Lücke zwischen drei separaten finalen Operationen. |

**Bilanz:** 0 kritische, 2 hohe, 3 mittlere, 0 niedrige Findings in der Quelle. Von 4 geprüften Findings wurden 4 bestätigt, 0 widerlegt und 0 als unklar bewertet; 1 mittleres Finding wurde nur gezählt.

## Die drei wichtigsten bestätigten Punkte

1. **Der Update-Flow besitzt keine unabhängige Code-Identität.** Ein gemeinsam manipuliertes Release-Archiv plus Sidecar passiert die Prüfung; der Abschluss-Refresh kann das Managed Binary unmittelbar ausführen (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:141-150`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:220-232`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:387-393`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:302-329`).
2. **Der Setup-Wizard besitzt keine Laufidentität.** Aus→Ein, Portwechsel und alte Refresh-Snapshots können einen veralteten Lauf wieder legitim erscheinen lassen (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:404-456`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:460-492`).
3. **Backend-Toggle und Device-Login bilden keinen geschlossenen Lifecycle.** Die Seite löscht den Code, ohne den weiterlaufenden Login-Prozess abzubrechen, und bietet keine öffentliche Cancel-Verbindung zum Manager (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:101-108`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:514-550`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:336-346`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:443-451`).

