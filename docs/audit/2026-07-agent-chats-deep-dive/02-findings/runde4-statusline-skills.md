---
status: aktiv
updated: 2026-07-19
description: Runde-4-Finalaudit des Statusline-Features und CLI-Skill-Exports mit Fokus auf Shell-Robustheit, settings.json-Mutationen, Profilpropagation, Symlink-Schutz und Installations-Lifecycle.
---

# Runde 4: Statusline und CLI-Skill-Export

## Gegenstand und Methode

Statische, zeilengenaue Prüfung der Commits `32a5afe` und `f50847e`, der vier beauftragten Produktdateien, `StatuslineInstallerTests.swift` sowie der unmittelbar beteiligten Ressourcen-, Bundle-, Profil- und Skill-Testpfade (`Package.swift`, `Makefile`, `ClaudeAccountProfiles.swift`, `CLISkillExporterTests.swift`). Keine Builds oder Tests ausgeführt; Produktcode blieb unverändert.

## Findings

### R4-STATUS-01 — Release-/App-Bundle enthält die von `Bundle.main` gesuchte Statusline nicht

**Schweregrad:** hoch

**Beleg:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:25-27, 71-75`; `Package.swift:38-45`; `Makefile:229-245`; `Tests/WhisperM8Tests/StatuslineInstallerTests.swift:26-32, 42-49`

**Konkretes Auslöse-Szenario:** Der User baut bzw. installiert die App über den regulären Makefile-Bundle-Pfad und klickt unter „CLI & Skills“ auf „Install“. Der Produktions-Initializer verwendet `Bundle.main`, und `bundledScript()` sucht dort direkt nach `whisperm8-statusline.sh`. SwiftPM packt die Datei dagegen in sein Resource-Bundle; der Makefile-Pfad kopiert zwar dieses Unter-Bundle, kopiert die Statusline aber — anders als alle sechs Skill-Markdown-Dateien — nicht direkt nach `Contents/Resources`. `Bundle.main.url(forResource:)` durchsucht verschachtelte Bundles nicht rekursiv: Vorschau und Installation enden deshalb mit `resourceMissing`, obwohl `swift test` grün bleibt. Der Test injiziert ausdrücklich `Bundle.module` und prüft damit einen anderen Lookup-Pfad als die App.

**Fix-Skizze:** Die Statusline wie die Skill-Ressourcen im Makefile direkt nach `Contents/Resources` kopieren oder den Installer konsequent mit dem SwiftPM-Resource-Bundle initialisieren. Zusätzlich einen Packaging-Test gegen das tatsächlich gebaute `.app`-Bundle ergänzen; der bestehende `Bundle.module`-Test deckt diesen Drift nicht ab.

### R4-SHELL-01 — Unvertrauenswürdige Namen werden durch `echo -e` zu Terminal-Steuersequenzen

**Schweregrad:** hoch

**Beleg:** `WhisperM8/Resources/whisperm8-statusline.sh:38, 50-56, 237-249, 374-377, 384-429`

**Konkretes Auslöse-Szenario:** Ein geöffnetes Repository bzw. dessen Projekt-MCP-Konfiguration liefert einen Namen mit literalen Backslash-Sequenzen, etwa `\\033]52;c;<base64>\\a`; alternativ enthält der Arbeitsordner solche Zeichen. Repo-Name, Modell, MCP-Namen, Profilname und Account-Mail werden ungefiltert in `output` übernommen. Das abschließende `echo -e` interpretiert die Backslashes anschließend als ESC/OSC-Steuerzeichen. Damit kann ein Repo-/MCP-Name mindestens die Statuszeile umbrechen oder abschneiden und — terminalabhängig — Titel bzw. Clipboard per OSC manipulieren. Shell-Metazeichen führen wegen der überwiegend korrekten Quotierung nicht zu einem normalen Command-Injection-Pfad; die Terminal-Injection entsteht erst durch die explizite zweite Interpretation in `echo -e`.

**Fix-Skizze:** Nie Nutzdaten durch `echo -e` interpretieren. Farben als separate, feste Argumente ausgeben (`printf '%b%s%b' "$color" "$sanitizedText" "$reset"`) und alle externen Textfelder vor Ausgabe von C0/C1, ESC, BEL, CR/LF und gegebenenfalls Backslash bereinigen. Tests mit Repo-, Profil- und MCP-Namen inklusive `\\n`, `\\c`, ESC und OSC-52 ergänzen; `StatuslineInstallerTests:42-49` prüft derzeit nur Marker und String-Vorkommen, führt das Skript aber nicht aus.

### R4-INSTALL-01 — Read-modify-write von `settings.json` verliert konkurrierende Änderungen

**Schweregrad:** hoch

**Beleg:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:191-216`

**Konkretes Auslöse-Szenario:** Während WhisperM8 `settings.json` bei Zeile 196 liest, schreibt Claude Code, ein Plugin-Manager oder ein zweites WhisperM8-Fenster einen neuen Hook/MCP-/Permission-Key. WhisperM8 serialisiert danach seinen alten In-Memory-Snapshot plus `statusLine` und ersetzt die Datei atomar. Der atomare Rename verhindert nur eine halb geschriebene Datei; er erkennt nicht, dass sich die Quelle seit dem Read geändert hat. Der zwischenzeitlich hinzugekommene fremde Key geht vollständig verloren — dieselbe Lost-Update-Klasse wie N12/N13, diesmal auf einer extern gemeinsam beschriebenen Konfigurationsdatei.

**Fix-Skizze:** Mutation pro kanonischem Settings-Pfad prozessweit serialisieren und unmittelbar vor Commit mtime/Inode oder einen Content-Hash gegen den gelesenen Stand prüfen. Bei Abweichung frisch einlesen, nur `statusLine` erneut mergen und begrenzt retryen; bei weiterem Konflikt abbrechen statt überschreiben. Ein deterministischer Test muss zwischen Read und Commit einen fremden Key injizieren; die vorhandenen Tests prüfen nur Fremdschlüssel, die schon vor dem Read existieren (`StatuslineInstallerTests.swift:53-77`).

### R4-SKILL-01 — „Update Skill“ überschreibt fremde Skills und lokale Änderungen ohne Ownership-Gate

**Schweregrad:** hoch

**Beleg:** `WhisperM8/Services/Shared/CLISkillExporter.swift:107-147, 150-179`; `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:209-217, 269-295`; `Tests/WhisperM8Tests/CLISkillExporterTests.swift:88-121`

**Konkretes Auslöse-Szenario:** Unter `~/.claude/skills/codex-subagent/SKILL.md` liegt bereits ein gleichnamiger, manuell installierter Skill oder der User hat den WhisperM8-Skill lokal angepasst. `isInstalledForClaudeCode` unterscheidet nur „Datei existiert“, `installedSkillIsCurrent` nur Bytegleichheit. Die UI zeigt bei jeder Abweichung „Update Skill“ und ruft ohne Warnung `installForClaudeCode()` auf; dieses schreibt `SKILL.md` und alle gleichnamigen verwalteten Referenzen bedingungslos atomar neu. Ein Marker-, Backup-, Force- oder Symlink-/Ownership-Check wie beim Statusline-Installer existiert nicht. Gerade der generische Name `codex-subagent` macht eine Kollision realistisch.

**Fix-Skizze:** Installierte Artefakte mit einem stabilen Managed-Marker plus Manifest/Hashes der verwalteten Dateien kennzeichnen. Markerlose bzw. vom letzten verwalteten Hash abweichende Dateien als `foreign/modified` ausweisen, Vorschau/Diff und getrennte Bestätigung anbieten und vor erzwungener Ersetzung ein Backup anlegen. Der Test `testAgentSkillNotCurrentWhenReferenceOutdated` erwartet heute gerade die stille Reparatur; zusätzliche Tests müssen markerlose `SKILL.md`, lokal geänderte verwaltete Referenzen sowie Skill-Verzeichnisse als Symlink abdecken.

### R4-PROFILE-01 — Skill-Verfügbarkeit in Zusatzprofilen hängt von der Installationsreihenfolge ab

**Schweregrad:** hoch

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:227-233, 255-272`; `WhisperM8/Services/Shared/CLISkillExporter.swift:107-123, 150-179`; `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:192-214, 279-295`; `Tests/WhisperM8Tests/CLISkillExporterTests.swift:8-20`

**Konkretes Auslöse-Szenario:** Der User legt zuerst ein Zusatzkonto an und installiert danach erstmals einen WhisperM8-Skill. Beim Profil-Anlegen wird `skills` nur dann auf `~/.claude/skills` verlinkt, wenn die Quelle zu diesem Zeitpunkt bereits existiert (`fileExists`-Guard vor `createSymbolicLink`). Fehlt der Ordner noch, bleibt im Profil kein Link zurück. Der spätere Skill-Export schreibt ausschließlich nach `~/.claude/skills/<name>` und repariert die Profilwurzel nicht. Eine mit `CLAUDE_CONFIG_DIR=~/.claude-profiles/<name>` gestartete Session sieht den installierten Skill damit nicht. Legt der User das Profil dagegen erst nach der Skill-Installation an, wird der Link erstellt — identische UI-Aktion, anderes Ergebnis allein durch Reihenfolge.

**Fix-Skizze:** Beim Skill-Install alle App-Profile prüfen: fehlendes `skills` sicher auf Main verlinken, echte fremde Profilordner nicht ersetzen und den Zustand pro Profil anzeigen. Alternativ den Export pro Config-Root durchführen. Tests müssen beide Reihenfolgen („Profil vor Skill“ und „Skill vor Profil“) sowie einen fremden echten `skills`-Ordner abdecken; die bestehenden Exporter-Tests injizieren nur ein einzelnes Temp-Home ohne `CLAUDE_CONFIG_DIR`-Profil.

### R4-SHELL-02 — Usage-Lock und Cache sind nicht atomar; parallele Sessions hebeln den Schutz aus

**Schweregrad:** mittel

**Beleg:** `WhisperM8/Resources/whisperm8-statusline.sh:102-105, 125-137, 153-172, 175-180`

**Konkretes Auslöse-Szenario:** Zwei Claude-Sessions desselben Profils rendern gleichzeitig ihre Statusline, während der Cache abgelaufen ist. Beide prüfen den noch fehlenden Lock in Zeile 133, bevor einer der erst im Hintergrund gestarteten Subshells ihn in Zeile 136 anlegt. Beide lesen dadurch dasselbe Keychain-Token und starten einen Usage-Request. Danach schreiben sie mit normaler Shell-Umleitung direkt auf dieselbe Cache-Datei; parallel laufende Statuslines lesen diese Datei gleichzeitig. Ein Reader kann den Zustand zwischen Truncate und Write sehen, ein zweiter Writer kann einen neueren Response überholen, und die unnötigen Parallelrequests erhöhen Rate-Limit- und Prompt-Latenz. Das Entfernen eines vermeintlich alten Locks ist ebenfalls check-then-delete statt ownership-gebunden.

**Fix-Skizze:** Lock atomar per `mkdir`/`noclobber` erwerben, Owner/Startzeit im Lock halten und nur den eigenen Lock entfernen. Response in eine mode-`0600` Temp-Datei im selben Verzeichnis schreiben, dort mit `jq -e` validieren und per `mv` atomar veröffentlichen. Cache-Reader sollten invalides/Leeres still ignorieren. Paralleltest mit zwei Script-Prozessen und einem instrumentierten Fake-`curl` ergänzen; die Swift-Tests führen die Shell derzeit überhaupt nicht aus (`StatuslineInstallerTests.swift:42-49`).

### R4-INSTALL-02 — Installation ist keine Transaktion und meldet nach Teilmutation einen Fehler

**Schweregrad:** mittel

**Beleg:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:134-155, 191-216`; `Tests/WhisperM8Tests/StatuslineInstallerTests.swift:145-160`; `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:479-489`

**Konkretes Auslöse-Szenario:** Das Skript wird in Zeile 148 erfolgreich geschrieben und ausführbar gemacht; Main-`settings.json` wird verdrahtet. Ein späteres Profil besitzt kaputtes JSON oder der Write scheitert wegen Rechten/Platzmangel. `install()` wirft, die UI zeigt nur „Error“, aber Skript und bereits bearbeitete Configs bleiben verändert. Besonders irreführend ist der bereits vorhandene Korrupt-JSON-Test: Er bestätigt nur, dass die kaputte Datei unverändert blieb, nicht dass die vorher installierte Skriptdatei und frühere Config-Mutationen zurückgerollt wurden. Bei erzwungener Ersetzung kann so ein bestätigtes fremdes Skript verloren sein, obwohl die Gesamtoperation als fehlgeschlagen erscheint.

**Fix-Skizze:** Vor jeder Mutation alle Ressourcen laden, alle Ziel-JSONs parsen, Symlink-/Ownership-Entscheidungen bestimmen und Schreibbarkeit prüfen. Danach Backups/Snapshots anlegen, Writes ausführen und bei Fehler rückwärts restaurieren; alternativ klar ein Teilresultat mit betroffenen Pfaden zurückgeben und die UI nicht als vollständigen Fehlschlag darstellen. Test mit gültigem Main plus kaputtem zweitem Profil und Assertions auf vollständigen Rollback ergänzen.

### R4-INSTALL-03 — Fremdschutz greift nur bei exakt erwarteter Dictionary-/String-Form

**Schweregrad:** mittel

**Beleg:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:115-122, 178-183, 206-216`; `Tests/WhisperM8Tests/StatuslineInstallerTests.swift:164-186`

**Konkretes Auslöse-Szenario:** Eine gültige `settings.json` enthält einen `statusLine`-Wert in einer zukünftigen Claude-Code-Form, einen String oder ein Dictionary ohne String-`command` (etwa weil ein anderes Tool sein eigenes Schema verwendet). `foreignSettingsCount()` zählt ihn nicht als fremd, und `wireSettings()` betritt den Schutzblock nur, wenn sowohl Dictionary als auch String-Command castbar sind. Sonst ersetzt Zeile 212 den Wert ohne `replaceForeignSettings` und ohne die P0-Bestätigung. Der Review-Fix schützt damit nur die heute bekannte Form, nicht die Ownership des vorhandenen Keys.

**Fix-Skizze:** Sobald der Key `statusLine` existiert und nicht exakt der eigenen kanonischen Struktur bzw. einer ausdrücklich kompatiblen eigenen Variante entspricht, als `foreign` behandeln — unabhängig von JSON-Typ und fehlenden Feldern. Nur ein wirklich fehlender Key darf ohne Bestätigung angelegt werden. Table-Tests für String, Array, Dictionary ohne `command`, Nicht-String-`command` und zusätzliche Zukunftsfelder ergänzen; vorhanden ist nur der Happy Path eines fremden String-Commands im bekannten Dictionary-Schema.

### R4-SHELL-03 — Kaputtes oder typfalsches stdin-JSON wird nicht einmalig validiert und erzeugt Fehlerkaskaden

**Schweregrad:** mittel

**Beleg:** `WhisperM8/Resources/whisperm8-statusline.sh:10, 38, 90-91, 234-243, 253-254, 279-305, 327-329, 371, 429`

**Konkretes Auslöse-Szenario:** Claude Code bzw. ein Wrapper liefert wegen Abbruch, Versionsdrift oder Teilschreibfehler leeres/kaputtes JSON. Das Skript prüft den gepufferten Input nicht am Eingang, sondern startet viele unabhängige `jq`-Aufrufe. Deren Parsefehler gehen überwiegend auf stderr; anschließend erhalten numerische `test`- und Bash-Arithmetikpfade leere oder typfalsche Werte. Ergebnis sind mehrere `jq`-/„integer expression expected“-Diagnosen pro Prompt statt der beabsichtigten klaren Fallback-Zeile. Auch gültiges JSON mit unerwarteten Typen — etwa nicht-arrayförmige `mcp_servers` oder nichtnumerische Kontextfelder — läuft in dieselben ungeprüften Pfade.

**Fix-Skizze:** Direkt nach `cat` genau einmal `jq -e 'type == "object"'` ausführen und bei Fehler eine kurze, stderr-freie Fallback-Zeile ausgeben. Alle numerischen Felder in einem einzigen `jq`-Pass mit `numbers`/`tonumber?` und `// 0` normalisieren; Strings für Anzeige separat extrahieren. Fixture-Tests für leer, abgeschnitten, `null`, falsche Feldtypen und fehlende Felder ergänzen.

### R4-PERF-01 — Jeder Prompt-Refresh startet zahlreiche Prozesse und scannt den Git-Worktree erneut

**Schweregrad:** mittel

**Beleg:** `WhisperM8/Resources/whisperm8-statusline.sh:10, 38-91, 110-131, 176-230, 234-313, 327-358, 371-429`

**Konkretes Auslöse-Szenario:** In einem großen Monorepo wird die Statusline bei interaktiven Prompt-Updates wiederholt ausgeführt. Schon ohne Usage-Fetch startet ein Lauf separate Prozesse für `cat`, mehrere `basename`/`dirname`, mindestens vier Git-Kommandos (`rev-parse` zweimal, `branch`, zwei `diff`, `rev-list`), viele vollständige `jq`-Parses desselben Inputs, `awk`/`bc` sowie optional `find` + `stat` + `grep` je frischem Subagent-Transcript. Insbesondere die zwei Worktree-Diffs laufen bei jedem Refresh erneut. Das Feature liegt damit direkt im Prompt-Hotpath, besitzt aber weder zusammengefasste JSON-Auswertung noch einen kurzlebigen Repo-State-Cache; die Tests messen oder starten den Pfad nicht.

**Fix-Skizze:** Input in einem `jq`-Aufruf in Shell-Felder überführen, Git-Zustand mit einem einzelnen porcelain-Kommando bestimmen und Repo-/Branch-/Ahead-Behind-Daten sehr kurz pro Repo cachen bzw. nur bei mtime-/HEAD-Änderung erneuern. Subagent-Modelle beim Erzeugen erfassen oder höchstens neue/geänderte Dateien lesen. Ein Zeitbudget-Test mit großem Fixture-Repo und vielen Subagent-Dateien ergänzen.

### R4-LIFE-01 — Es gibt keinen sicheren Deinstallationspfad für dauerhafte Hooks und Skills

**Schweregrad:** mittel

**Beleg:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:125-158`; `WhisperM8/Services/Shared/CLISkillExporter.swift:150-180`; `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:212-234, 368-393`; `WhisperM8/Resources/whisperm8-statusline.sh:138-170`

**Konkretes Auslöse-Szenario:** Der User möchte die Integration deaktivieren oder entfernt WhisperM8. Die Settings-Seite bietet für Skills nur Install/Save/Copy/View und für die Statusline Install/View/Copy; beide Services implementieren ausschließlich Installation. `statusLine` bleibt deshalb in allen Claude-Configs aktiv und das installierte Skript liest bei weiteren Prompts weiterhin Keychain-Credentials für den Usage-Request. Skills bleiben ebenfalls registriert und können weiter auf ein später fehlendes `whisperm8`-CLI verweisen. Manuelles Löschen ist fehleranfällig, besonders bei symlink-geteilten Profilen und fremden Dateien im `references`-Ordner.

**Fix-Skizze:** Explizite Deinstallation anbieten. Beim Statusline-Remove nur den exakt eigenen Command aus jedem nicht-symlinkenden Settings-Root entfernen, übrige Keys bewahren und das Skript nur bei Managed-Marker löschen. Bei Skills nur per Manifest als verwaltet bekannte Dateien entfernen, lokal fremde Dateien erhalten und leere Ordner aufräumen. Beide Operationen transaktional und idempotent testen, einschließlich Profile/Symlinks und lokal modifizierter Artefakte.

### R4-UI-01 — Main-Config wird in Produktion doppelt gezählt und bearbeitet

**Schweregrad:** niedrig

**Beleg:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:32-36`; `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:54-68, 82-86`; `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:460-473`

**Konkretes Auslöse-Szenario:** Der Default-Initializer legt zuerst `~/.claude` in `directories` ab und hängt danach `profiles().map(\.configDir)` an. `profiles()` enthält `main` jedoch immer als erstes Element, dessen `configDir` erneut `~/.claude` ist. Die UI meldet daher bei einem Main- und einem Zusatzprofil „3 of 3 Claude configs“, obwohl nur zwei Config-Roots existieren; Installation und Statusprüfung laufen für Main doppelt. Die Tests injizieren `[main, profile]` direkt und umgehen die fehlerhafte Default-Erzeugung (`StatuslineInstallerTests.swift:26-32`).

**Fix-Skizze:** Entweder ausschließlich `ClaudeAccountProfiles().profiles().map(\.configDir)` verwenden oder kanonische URLs stabil deduplizieren. Einen Test des echten Default-Directory-Builders mit `main` plus Profil ergänzen.

## Testlücken im Überblick

- `StatuslineInstallerTests.swift:42-49` prüft die Shell nur als Text; kein Test führt sie mit gültigem, kaputtem, typfalschem oder adversarialem JSON aus, prüft ANSI-Sicherheit, Parallelität oder Laufzeit.
- `StatuslineInstallerTests.swift:26-32` injiziert `Bundle.module` und eine bereits deduplizierte Directory-Liste. Dadurch bleiben sowohl der Produktions-Bundle-Drift als auch die doppelte Main-Config unsichtbar.
- `StatuslineInstallerTests.swift:145-160` prüft den Schutz der korrupten Datei, aber nicht den bereits vorher mutierten Skript-/Config-Zustand und keinen Rollback.
- `CLISkillExporterTests.swift:88-121` deckt Updates und den Erhalt zusätzlicher Referenzdateien ab, nicht jedoch fremde/angepasste `SKILL.md`, Symlink-Ziele, Transaktionsfehler, Deinstallation oder `CLAUDE_CONFIG_DIR`-Profile.

## Verifizierte Negativ-Checks

- Der Review-Fix bewahrt einen vorhandenen `settings.json`-Symlink im normalen Profilfall: `settingsIsSymlink` bricht vor dem atomaren Write ab (`StatuslineInstaller.swift:166-175, 191-192`), und der Test deckt genau diesen Fall ab (`StatuslineInstallerTests.swift:122-142`). Der Befund R4-INSTALL-03 betrifft nicht diesen Symlink-Pfad, sondern unerkannte fremde JSON-Formen.
- Access-Token landen im Usage-Fetch nicht in argv: Der Header wird über stdin an `curl -H @-` übergeben (`whisperm8-statusline.sh:149-159`). Ein N09/N10-analoger argv-Leak wurde in diesem Bereich daher nicht bestätigt.
- Fremde zusätzliche Dateien unter `references/` werden bewusst nicht gelöscht und sind getestet (`CLISkillExporter.swift:150-153`; `CLISkillExporterTests.swift:107-121`). Das schützt jedoch weder gleichnamige verwaltete Referenzen noch die `SKILL.md` selbst (R4-SKILL-01).

