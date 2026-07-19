---
status: abgeschlossen
updated: 2026-07-19
description: Adversariale Verifikation aller fünf hohen Runde-4-Findings zu Statusline und CLI-Skill-Export sowie zweier Stichproben aus den sieben übrigen Findings gegen den Code-Stand HEAD.
---

# Runde 4: Verifikation Statusline und CLI-Skill-Export

## Methode

Alle fünf als hoch markierten Findings werden vollständig gegen `HEAD` geprüft; aus den sechs mittleren und dem einen niedrigen Finding werden zwei Stichproben geprüft, die übrigen nur gezählt. Die Verifikation sucht nach Gegenbelegen in den eng begrenzten Produktionsstellen, Aufrufern, Tests und den Review-Fix-Commits `f50847e`, `c6ac557`, `9e4b9f4`, `e445b65` und `1bd655f`. Builds und Tests wurden nicht ausgeführt.

## Einzelurteile

### R4-STATUS-01 — App-Bundle verfehlt den Lookup-Ort

**Urteil: BESTÄTIGT. Eigene Schwere: hoch.** Der Produktions-Initializer verwendet `Bundle.main`, und `bundledScript()` fragt dort unmittelbar `whisperm8-statusline.sh` ab (`WhisperM8/Services/Shared/StatuslineInstaller.swift:24-27,70-76`). SwiftPM deklariert die Shell-Datei zwar als Target-Ressource (`Package.swift:37-45`), der App-Bundle-Schritt kopiert jedoch nur die sechs Markdown-Ressourcen direkt nach `Contents/Resources`; anschließend werden die generierten `.bundle`-Verzeichnisse verschachtelt kopiert (`Makefile:217-245`). Anders als für die Markdown-Dateien existiert kein Root-Copy der Shell-Datei. Der Test widerlegt das nicht: Er injiziert ausdrücklich `Bundle.module` statt des Produktionswerts und prüft nur den Ressourceninhalt (`Tests/WhisperM8Tests/StatuslineInstallerTests.swift:27-33,41-49`). `f50847e` änderte Installer, UI, Shell und Tests, aber weder `Package.swift` noch `Makefile`; HEAD enthält daher weiterhin den beschriebenen Lookup-/Packaging-Drift.

### R4-SHELL-01 — Zweite Interpretation externer Anzeigetexte

**Urteil: BESTÄTIGT. Eigene Schwere: hoch.** Das Skript übernimmt Modellnamen aus stdin (`WhisperM8/Resources/whisperm8-statusline.sh:36-38`), Repo-/Ordnernamen aus Git bzw. dem Arbeitsverzeichnis (`:39-56`), MCP-Namen aus stdin (`:232-249`) sowie Profilname und Account-Mail aus Pfad bzw. JSON (`:369-377`) ohne Steuerzeichenbereinigung in Anzeigevariablen. Am Ende werden sämtliche festen Farbcodes und Nutzdaten zu einem String verkettet und gemeinsam mit `echo -e` erneut interpretiert (`:382-429`). Ein literales `\033`, `\a`, `\n` oder `\c` in einem Repo-, Modell-, MCP-, Profil- oder Mailfeld wird damit als Escape-/Ausgabesteuerung behandelt. Die überwiegend quotierte Variablenexpansion verhindert normale Shell-Command-Injection, widerlegt aber gerade nicht die behauptete Terminal-/OSC-Injection durch `echo -e`. Es gibt weder `printf`-Trennung von Format und Nutzdaten noch einen Sanitizer in diesem Pfad (`:36-56,232-249,369-429`).

### R4-INSTALL-01 — Lost Update zwischen Read und atomarem Replace

**Urteil: BESTÄTIGT. Eigene Schwere: hoch.** `wireSettings()` liest die komplette Datei, deserialisiert sie in ein lokales Dictionary, ersetzt darin `statusLine`, serialisiert den Snapshot und schreibt ihn atomar zurück (`WhisperM8/Services/Shared/StatuslineInstaller.swift:190-216`). Zwischen `Data(contentsOf:)` (`:195`) und `.atomic` (`:215`) existieren weder Lock noch Versions-/mtime-/Hash-Prüfung oder erneutes Merge. `.atomic` schützt nur die Veröffentlichung des bereits veralteten Snapshots. Der reale UI-Aufrufer ruft den synchronen Installer direkt auf (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:479-489`); selbst eine Main-Thread-Serialisierung würde konkurrierende externe Writer wie Claude Code oder andere Konfigurationswerkzeuge nicht koordinieren. Der vorhandene Fremdschlüssel-Test legt seine Keys vor dem Read an und beweist nur deren Merge im konfliktfreien Fall (`Tests/WhisperM8Tests/StatuslineInstallerTests.swift:54-74`). Keiner der genannten späteren Review-Fix-Commits ändert diese Datei nach `f50847e`; insbesondere betrifft die „Installer-Transaktion“ aus `c6ac557` andere GPT-Backend-Dateien.

### R4-SKILL-01 — Fremde oder lokal geänderte Skill-Dateien werden überschrieben

**Urteil: BESTÄTIGT. Eigene Schwere: hoch.** Der Installationsstatus ist ausschließlich `fileExists`, Aktualität ausschließlich Bytegleichheit von `SKILL.md` und verwalteten Referenzen (`WhisperM8/Services/Shared/CLISkillExporter.swift:127-148`). Bei jeder Abweichung bietet die UI ohne Ownership-Hinweis „Update Skill“ an und ruft direkt `installForClaudeCode()` auf (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:269-295`). Dieser Pfad schreibt die bestehende `SKILL.md` und jede gleichnamige verwaltete Referenz atomar, aber bedingungslos neu (`WhisperM8/Services/Shared/CLISkillExporter.swift:151-177`); Marker-, Backup-, Symlink- und Force-Guard fehlen an der belegten Stelle. Der Test schützt nur zusätzliche, anders benannte Dateien im Referenzordner, während er das Überschreiben einer veralteten verwalteten Referenz ausdrücklich erwartet (`Tests/WhisperM8Tests/CLISkillExporterTests.swift:89-121`).

### R4-PROFILE-01 — Fehlender Skill-Link wird nachträglich nicht repariert

**Urteil: BESTÄTIGT. Eigene Schwere: mittel.** `skills` gehört zwar zu den geteilten Profileinträgen (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:227-233`), doch `createProfile()` erzeugt den Symlink nur, wenn die Quelle beim Anlegen bereits existiert (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:259-272`). Der spätere Export kennt ausschließlich `~/.claude/skills/<name>` und schreibt nur dort (`WhisperM8/Services/Shared/CLISkillExporter.swift:107-124,151-179`); auch der UI-Aufrufer führt keine Profilreparatur aus (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:279-295`). Die vorhandenen Profiltests belegen nur die Link-Erzeugung für eine vorab vorhandene `settings.json`, nicht das Nachziehen später entstehender Shared Items (`Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:139-151`). Damit entscheidet die Installationsreihenfolge tatsächlich über die Skill-Sichtbarkeit des Zusatzprofils.

## Stichproben der übrigen Findings

### R4-SHELL-02 — Usage-Lock und Cache sind nicht atomar

**Urteil: BESTÄTIGT. Eigene Schwere: mittel.** Der Guard prüft den Lock im Vordergrund mit `! [ -f "$usage_lock" ]`, erzeugt ihn aber erst innerhalb des danach gestarteten Hintergrund-Subshells (`WhisperM8/Resources/whisperm8-statusline.sh:125-137`). Zwei Prozesse können daher beide den Guard passieren. Auch der erfolgreiche Response wird per normaler `>`-Umleitung direkt in die von parallelen Refreshes gelesene Cache-Datei geschrieben (`WhisperM8/Resources/whisperm8-statusline.sh:153-177`), ohne temporäre Datei plus Rename. Stale-Erkennung und Löschen sind ebenfalls getrennte, nicht ownership-gebundene Schritte (`:125-130`).

### R4-UI-01 — Main-Config wird doppelt gezählt und bearbeitet

**Urteil: BESTÄTIGT. Eigene Schwere: niedrig.** Der Default-Initializer beginnt mit `~/.claude` und hängt danach alle von `profiles()` gelieferten Config-Verzeichnisse an (`WhisperM8/Services/Shared/StatuslineInstaller.swift:25-38`). `profiles()` enthält `main` zwingend als ersten Eintrag, dessen `configDir` ebenfalls `~/.claude` ist (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:54-68,82-86`). Eine Deduplizierung fehlt. Die UI verwendet die rohe Array-Länge als `totalConfigs` und zeigt sie im Summary an (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:460-473`); die behauptete Doppelzählung folgt damit direkt aus dem Produktionspfad.

## Urteilsmatrix

| ID | Originalschwere | Prüfumfang | Urteil | Eigene Schwere |
|---|---|---|---|---|
| R4-STATUS-01 | hoch | vollständig | BESTÄTIGT | hoch |
| R4-SHELL-01 | hoch | vollständig | BESTÄTIGT | hoch |
| R4-INSTALL-01 | hoch | vollständig | BESTÄTIGT | hoch |
| R4-SKILL-01 | hoch | vollständig | BESTÄTIGT | hoch |
| R4-PROFILE-01 | hoch | vollständig | BESTÄTIGT | mittel |
| R4-SHELL-02 | mittel | Stichprobe | BESTÄTIGT | mittel |
| R4-INSTALL-02 | mittel | nur gezählt | NICHT EINZELN GEPRÜFT | — |
| R4-INSTALL-03 | mittel | nur gezählt | NICHT EINZELN GEPRÜFT | — |
| R4-SHELL-03 | mittel | nur gezählt | NICHT EINZELN GEPRÜFT | — |
| R4-PERF-01 | mittel | nur gezählt | NICHT EINZELN GEPRÜFT | — |
| R4-LIFE-01 | mittel | nur gezählt | NICHT EINZELN GEPRÜFT | — |
| R4-UI-01 | niedrig | Stichprobe | BESTÄTIGT | niedrig |

**Zählung:** 0 kritisch, 5 hoch, 6 mittel, 1 niedrig. Vollständig geprüft wurden alle 5 hohen Findings; zusätzlich wurden 1 mittleres und 1 niedriges Finding stichprobenartig geprüft. Alle 7 geprüften Findings sind bestätigt, eines davon mit Herabstufung von hoch auf mittel. Die fünf nur gezählten mittleren Findings erhalten bewusst kein Sachurteil.

## Drei wichtigste bestätigte Punkte

1. **Statusline im ausgelieferten App-Bundle nicht installierbar:** Der Produktions-Lookup sucht im Main-Bundle (`WhisperM8/Services/Shared/StatuslineInstaller.swift:25-28,71-77`), während der App-Bundle-Schritt die Shell-Ressource nicht direkt nach `Contents/Resources` kopiert (`Makefile:214-247`).
2. **Terminal-Steuersequenzen aus Anzeigedaten:** Modell-, Repo-, MCP- und Accountdaten gelangen in denselben String wie die gewünschten Escapes und werden abschließend durch `echo -e` interpretiert (`WhisperM8/Resources/whisperm8-statusline.sh:37-57,232-249,369-429`).
3. **Stiller Verlust lokaler Skill-Inhalte:** „Update Skill“ führt ohne Ownership-Gate zum bedingungslosen Überschreiben von `SKILL.md` und verwalteten Referenzen (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:269-295`; `WhisperM8/Services/Shared/CLISkillExporter.swift:151-177`).
