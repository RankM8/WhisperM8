---
status: beschlossen
updated: 2026-10-18
description: Welle W5 des Launch-Readiness-Plans — Verteilung: Developer ID, Notarisierung, Cask, Update, Deinstallation. Befunde, Abnahmekriterien, Tests zuerst.
---

# W5 · Verteilung: Developer ID, Notarisierung, Cask, Update, Deinstallation

W1, W6 und W7: Release mit Developer ID signiert und notarisiert (E4 b), Cask ohne Quarantäne-Entfernung und mit korrekter Architektur, Update sichtbar und geführt, `brew uninstall --zap` beendet Prozesse und räumt nur eigene Spuren.

**Umfang:** 12 Befunde · P1 3, P2 7, P3 2 · 5 Launch-Blocker · Aufwand S×4, M×4, L×4

## Abnahmekriterien der Welle

- [ ] Release-Job: `codesign --verify --deep --strict`, `spctl -a -vv -t exec`, `xcrun stapler validate` grün; Job bricht sonst ab. Cask ohne `xattr`-postflight.
- [ ] Universal-Build oder Cask auf die gebaute Architektur beschränkt.
- [ ] Tag-Release nur nach grüner Suite; CI mit `timeout-minutes`.
- [ ] Cask: `uninstall quit` + Proxy/Socket beenden; `zap` nur eigene Pfade, entfernt eigene Statusline/Hooks/Symlink (Skripttest auf den generierten Cask).
- [ ] Update-Hinweis in allen Profilen sichtbar; Update per Klick mit Fortschritt und Ergebnis statt Terminal-Befehl.
- [ ] W6 auf echtem Bestand: Update von der aktuellen Version auf die signierte – keine neue Rechte-Abfrage, Keychain-Zugriff bleibt (ACL-Wechsel durch Developer ID prüfen), Downgrade überschreibt kein neueres Schema.

## Test-Infrastruktur zuerst

- CaskGenerationTests (Skript in Temp-Verzeichnis ausführen).
- InfoPlistContractTests (Bundle-ID, Mindestsystem, Usage-Strings).

## Feature-Erhalt

Vor dem ersten Commit die Invarianten lesen und je Fix prüfen, welche berührt sind: [oracle/build-release-tests.md](../../00-scope/oracle/build-release-tests.md), [oracle/onboarding-shell.md](../../00-scope/oracle/onboarding-shell.md). Dazu die Zeilen der [Testmatrix](../anforderungs-testmatrix.md) für diese Features.

## Befunde

| ID | Schwere | Blocker | Aufwand | Risiko | Status | Titel |
|---|---|---|---|---|---|---|
| LR-BR-003 | P1 | ja | L | mittel | geplant · bestätigt | Öffentliche Releases umgehen Gatekeeper statt E4 umzusetzen |
| LR-BR-005 | P1 | ja | L | hoch | geplant · teilbestätigt | Cask-Deinstallation besitzt keinen Prozess- und Integrationsabbau |
| LR-BR-006 | P1 | ja | M | mittel | geplant · bestätigt | Cask akzeptiert beide Mac-Architekturen, das DMG enthält nur die Build-Architektur |
| LR-BR-001 | P2 | ja | L | hoch | geplant · teilbestätigt | Brew-Zap lässt installierte Statuslines und fremde Konfigurationsänderungen zurück |
| LR-ONB-009 | P2 | ja | S | niedrig | geplant · bestätigt | Diktatprofile erhalten keinen sichtbaren automatischen Update-Hinweis |
| LR-AK-002 | P2 | — | M | mittel | geplant · teilbestätigt | Downgrade überschreibt ein neueres Workspace-Schema |
| LR-BR-004 | P2 | — | S | niedrig | geplant · bestätigt | Developer-ID-Build bricht am fehlenden Frameworks-Ordner ab |
| LR-BR-007 | P2 | — | M | niedrig | geplant · teilbestätigt | Tag-Releases werden ohne Test-Gate veröffentlicht |
| LR-BR-008 | P2 | — | M | mittel | geplant · teilbestätigt | Clean-Install beendet fremde Prozesse und kann sich selbst töten |
| LR-ONB-010 | P2 | — | L | mittel | geplant · bestätigt | Der Update-Dialog endet bei einem Terminal-Befehl statt einer geführten Aktualisierung |
| LR-BR-010 | P3 | — | S | niedrig | geplant · unverifiziert | Deinstallation hinterlaesst `~/.local/bin/whisperm8` als toten Symlink; laufende Chats behalten Hooks auf das entfernte Binary (W7) |
| LR-DOK-002 | P3 | — | S | niedrig | geplant · bestätigt | DMG-Anleitung verspricht einen nicht mehr unterstützten Build ohne Xcode |

### LR-BR-003 · Öffentliche Releases umgehen Gatekeeper statt E4 umzusetzen

*P1 · Launch-Blocker · build-release / infra · Aufwand L · Risiko mittel*

**Beleg:** `.github/workflows/release.yml:5-9`, `.github/workflows/release.yml:55-56`, `Makefile:364-371`, `scripts/build-dmg.sh:31-52` (Stand `a8e0f35`)

**Fehlerbild:** Ein normaler Versions-Tag veröffentlicht weiterhin ein ad-hoc-signiertes, nicht notarisiertes DMG. Der Cask entfernt anschließend rekursiv die Quarantäne. Es gibt weder eine Developer-ID-Provisionierung in CI noch eine verpflichtende Notarisierung. Damit erfüllt der einzige öffentliche Installationsweg die beschlossene Vertrauensanforderung E4 nicht; der bisherige Quarantäne-Workaround ersetzt sie ausdrücklich nicht.

**Fix:** Der Fix hängt direkt an LR-BR-004: Solange der Developer-ID-Zweig im Skript abbricht, lässt sich E4 nicht umsetzen. Zertifikat in einer temporären Keychain im CI bereitstellen. Die Bundle-ID com.whisperm8.app muss stabil bleiben, sonst gehen TCC-Rechte verloren. Den Cask-postflight erst nach dem ersten notarisierten Release entfernen.

*Ursprünglicher Vorschlag:* Lokale Dev-Signierung und öffentliche Distribution trennen. Im Release-Job Developer-ID-Zertifikat in einer temporären Keychain bereitstellen, Hardened Runtime und Zeitstempel erzwingen, Notarisierung mit akzeptiertem Ergebnis verlangen, stapeln und Ticket/Gatekeeper-Vertrauen prüfen. Den Cask-postflight zur Quarantäne-Entfernung danach entfernen. Stabile Bundle-ID sowie unveränderte Ressourcen- und PTY-Funktion erhalten.

**Test zuerst:** Kein Unit-Test. Release-Gate im CI: nach dem Build 'codesign -dv' muss eine Authority=Developer ID Application zeigen, 'spctl -a -vv -t install' muss 'accepted, source=Notarized Developer ID' liefern, 'xcrun stapler validate' muss ok sein. Der Check schlägt heute fehl.

**Teilaufgaben:** LR-BR-004

<details><summary>Prüfurteil</summary>

Die Release-Pipeline baut ad-hoc, ohne Developer ID und ohne Notarisierung. Der Cask entfernt die Quarantäne per postflight (update-cask.sh:42-47). Die Entscheidung E4 (b: Developer ID plus Notarisierung) ist beschlossen, der Ist-Zustand erfüllt sie nicht. Für das bloße Starten genügt der xattr-Workaround, den Gatekeeper-Teil von W1 umgeht er also funktional. Der stärkere Grund für den Blocker: Ad-hoc-Signaturen sind an den cdhash gebunden, deshalb fragt macOS nach jedem Update erneut TCC-Rechte ab. Das verletzt W6 ('ohne neue Rechte-Abfrage'). Kein Bug, sondern eine bekannte, beschlossene Lücke. Sie hängt an einem Apple-Developer-Konto (organisatorische Voraussetzung).

</details>

### LR-BR-005 · Cask-Deinstallation besitzt keinen Prozess- und Integrationsabbau

*P1 · Launch-Blocker · build-release / robustheit · Aufwand L · Risiko hoch*

**Beleg:** `scripts/update-cask.sh:40-54`, `Makefile:218-221`, `scripts/sync-skills.sh:34-38`, `scripts/sync-skills.sh:421-445` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer führt brew uninstall --zap whisperm8 bei laufender App aus. Der erzeugte Cask hat keine uninstall-Aktion zum Beenden der App oder ihrer selbst gestarteten Hilfsprozesse, sondern nur drei trash-Pfade. Eine bereits laufende App wird dadurch nicht kontrolliert heruntergefahren. Außerdem bleiben Integrationen außerhalb dieser drei Pfade, etwa der CLI-Symlink und installierte Statusline-Dateien unter ~/.claude, unberücksichtigt. Der explizite Nutzerweg W7 ist damit nicht implementiert.

**Fix:** Sofortmaßnahme: 'uninstall quit: "com.whisperm8.app"' (graceful, damit die gedebouncten Stores geflusht werden) plus optional 'launchctl'/'signal' nur für eigene Helfer. Die Bereinigung von ~/.claude (Statusline-Dateien mit dem Marker 'managed-by: whisperm8-statusline', Stempel) nur über Marker-Prüfung, nie pauschal. Für 'brew uninstall' ohne Rückfrage ist ein Cask-uninstall-script riskant, besser ein In-App-Menüpunkt 'Integrationen entfernen' vor dem Deinstallieren.

*Ursprünglicher Vorschlag:* Einen gezielten, geordneten Uninstall-Pfad samt Cask-uninstall-Stanza schaffen: App beenden und Ende abwarten, ausschließlich eigene Hilfsprozesse abbauen und nur nach Ownership-Prüfung eigene Symlinks/Claude-Integrationen entfernen beziehungsweise vorherige Einstellungen wiederherstellen. Zusatzprofil-Daten mit Lösch-/Behalten-Entscheidung inventarisieren; niemals pauschal ~/.claude, ~/.codex oder fremde Proxys löschen. W7 auf einer frischen Brew-Installation testen.

**Test zuerst:** Kein Unit-Test. Skript-Test auf update-cask.sh: Die erzeugte whisperm8.rb muss eine uninstall-Stanza mit quit: 'com.whisperm8.app' enthalten ('brew audit --cask' plus grep). Heute schlägt das fehl. Dazu ein manueller W7-Lauf auf einer frischen Brew-Installation.

<details><summary>Prüfurteil</summary>

Der generierte Cask hat nur app, postflight und zap trash, aber keine uninstall-Stanza (update-cask.sh:28-54). Eine laufende App wird bei 'brew uninstall --zap' nicht beendet, ihr Bundle wird nur entfernt. Zusammen mit ihren Hilfsprozessen (Proxy, Control-Socket) und den Daten läuft sie weiter. Genau das schließt W7 aus ('hinterlässt keine laufenden Prozesse'). Außerdem bleiben ~/.local/bin/whisperm8 (dangling), die Statusline-Dateien samt Stempel in ~/.claude und das Plugin-Setup übrig. W7 ist explizit definiert und nicht erfüllt, daher Blocker. Der Aufwand L stimmt aber nur für die vollständige Integrationsbereinigung. Der Kern (Prozess beenden) ist mit 'uninstall quit: "com.whisperm8.app"' eine Zeile. Die Warnung vor pauschalem Löschen in ~/.claude ist richtig.

</details>

### LR-BR-006 · Cask akzeptiert beide Mac-Architekturen, das DMG enthält nur die Build-Architektur

*P1 · Launch-Blocker · build-release / korrektheit · Aufwand M · Risiko mittel*

**Beleg:** `Makefile:176-190`, `Makefile:323`, `scripts/build-dmg.sh:27-29`, `scripts/update-cask.sh:30-40` (Stand `a8e0f35`)

**Fehlerbild:** Das DMG wird auf dem dokumentierten Apple-Silicon-Buildrechner erstellt. swift build ohne Architekturparameter erzeugt das native arm64-Executable; genau dieses wird ins einzige DMG kopiert. Der Cask prüft lediglich macOS Sonoma, nicht die CPU. Ein Intel-Mac mit macOS 14 kann die Installation daher erfolgreich abschließen, die App aber nicht ausführen. Die Launch-Definition schließt Intel-Macs nicht aus.

**Fix:** Der schnellste und sicherste Weg ist die Entscheidung 'Apple-Silicon-only' mit 'depends_on arch: :arm64' im Cask und einem Hinweis im README. Ein Universal-Build (swift build --arch arm64 --arch x86_64) ändert die Build-Ausgabepfade (.build/apple/Products/Release statt .build/release). Das würde Makefile BUILD_DIR, patch-resource-accessors.sh und die Resource-Bundle-Schleife in _bundle brechen, weshalb dort ein eigener Test nötig wäre.

*Ursprünglicher Vorschlag:* Entweder ein Universal-Bundle bauen und beide Mach-O-Architekturen prüfen oder getrennte arm64-/x86_64-Assets mit architekturbewusstem Cask erzeugen. Falls ausschließlich Apple Silicon unterstützt werden soll, diese Produktentscheidung ausdrücklich treffen und im Cask vor der Installation durchsetzen. Architekturabhängige Build-Ausgabepfade sowie alle Ressourcen korrekt übernehmen.

**Test zuerst:** Test auf die generierte whisperm8.rb: enthält 'depends_on arch: :arm64' (oder passende Mach-O-Archs). Alternativ ein CI-Schritt 'lipo -archs WhisperM8.app/Contents/MacOS/WhisperM8' muss mit der im Cask deklarierten Architektur übereinstimmen. Heute: Cask ohne arch-Angabe, Binary nur arm64.

<details><summary>Prüfurteil</summary>

Der Build läuft ohne --arch und damit nativ arm64 (macos-26-Runner und der dokumentierte Apple-Silicon-Rechner in DMG_BAUEN.md:5). Der Cask hat nur 'depends_on macos: :sonoma', keine Architekturprüfung. Ein Intel-Mac mit macOS 14 bis 26 installiert den Cask erfolgreich, die App startet aber nicht ('bad CPU type', Rosetta übersetzt kein arm64). Eine Produktentscheidung zur Architektur existiert nirgends (grep Intel/arm64/universal: nur DMG_BAUEN). Das ist ein reales, aber kleines Segment mit billigem Fix. Für Apple-Silicon-only reicht 'depends_on arch: :arm64' im Cask. Als Blocker taugt es nicht, weil es nach einer Entscheidung eine Einzeiler-Korrektur ist und keinen W-Weg für die Zielgruppe bricht.

</details>

### LR-BR-001 · Brew-Zap lässt installierte Statuslines und fremde Konfigurationsänderungen zurück

*P2 · Launch-Blocker · build-release / infra · Aufwand L · Risiko hoch*

**Beleg:** `scripts/update-cask.sh:40-53`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:259-294`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:343-358`, `WhisperM8/Services/Shared/CLISymlinkInstaller.swift:13-35` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer installiert über die Einstellungen die Statusline und deinstalliert danach per brew uninstall --zap. Der generierte Cask entfernt nur drei app-eigene Library-Verzeichnisse beziehungsweise Dateien. Die beiden Skripte, Statusline-Einträge in ~/.claude/settings.json, Install-Stempel, verschobene lose Skills und ~/.local/bin/whisperm8 werden weder entfernt noch wiederhergestellt. Damit bleiben die von W7 ausdrücklich ausgeschlossenen Fremdänderungen bestehen; der CLI-Symlink zeigt zusätzlich auf das entfernte Binary.

**Fix:** Schlanke Lösung: ~/.local/bin/whisperm8 in die zap-trash-Liste (oder uninstall delete:) aufnehmen, ggf. W7-Formulierung auf 'ohne vom Nutzer nicht bewusst eingerichtete Änderungen' präzisieren und die Statusline-Reste in der Doku als bewusste Opt-in-Installation nennen. Kein Journal-System bauen; brew zap kann settings.json-Einträge ohnehin nicht sauber rückbauen.

*Ursprünglicher Vorschlag:* Ein Ownership- und Restore-Journal für externe Installationsänderungen führen und einen vom Cask verwendbaren, app-unabhängigen Bereinigungspfad vorsehen. Nur unveränderte eigene Einträge entfernen, zuvor gesicherte Fremdeinträge konfliktbewusst wiederherstellen und umgezogene Skills wieder anbieten. Niemals ~/.claude pauschal löschen oder Nutzer-Transcripts und zwischenzeitliche Änderungen überschreiben. W7 mit vorhandener Fremdkonfiguration testen.

**Test zuerst:** Kein Swift-Test sinnvoll; Skript-/Cask-Test: generierte Cask-Datei per grep auf zap-Eintrag ~/.local/bin/whisperm8 (shell-Test in scripts/ oder CI-Lint). Manuell: brew install, App starten, brew uninstall --zap, danach ls -l ~/.local/bin/whisperm8 muss fehlen.

<details><summary>Prüfurteil</summary>

Der Cask-zap (update-cask.sh:46-50) löscht nur Application Support, Caches und Preferences; der automatisch angelegte Symlink ~/.local/bin/whisperm8 (CLISymlinkInstaller beim Start, für jeden Nutzer) bleibt als toter Link zurück, ebenso ggf. Statusline-Skripte/-Einträge, die nur nach bewusstem Klick in den Einstellungen existieren, und verschobene lose Skills (im Backup, der Nutzer kann sie dort zurückholen). Das verletzt formal W7 (keine Fremdänderungen in ~/.claude), ist aber nicht schadenträchtig: ein toter Symlink und weiterlaufende Nutzer-Statusline-Skripte, die der Nutzer selbst installiert hat. Kein Datenverlust, keine Sicherheitslücke. Das vorgeschlagene Ownership-/Restore-Journal (Aufwand L, Risiko hoch) steht in keinem Verhältnis.

</details>

### LR-ONB-009 · Diktatprofile erhalten keinen sichtbaren automatischen Update-Hinweis

*P2 · Launch-Blocker · onboarding / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Shared/AppUpdateChecker.swift:97-111,162-169 — Automatik setzt nur den internen available-Zustand.`, `WhisperM8/Views/AppUpdateViews.swift:9-30,123-157 — sichtbare Hinweise befinden sich im Sidebar-Badge und in About.`, `WhisperM8/Views/MenuBarView.swift:15-135 — kein Update-Status und kein Update-Eintrag.`, `WhisperM8/Models/AppUsageProfile.swift:29-37 — Diktatprofile laufen ohne reguläres Dock-Fenster.` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer verwendet ausschließlich Dictation only und öffnet keine Agent Chats oder About-Seite. Der tägliche Check findet eine neue Version, aber in seiner normalen Oberfläche erscheint keinerlei Hinweis. W6 beginnt für dieses ausdrücklich unterstützte Profil nie mit App meldet Update.

**Fix:** Den zentralen Update-Zustand auch in der Menüleiste sichtbar machen und dort eine erreichbare Update-Aktion anbieten. Automatik aus respektieren, keine wiederholten aufdringlichen Meldungen und keine breite Reaktivitätsabhängigkeit großer Chat-Views einführen.

**Test zuerst:** UI-Snapshot-Fixture in UISnapshotGallery.swift: MenuBarView mit AppUpdateChecker-State .available(…) und Profil dictationRaw rendern. Erwartung: ein Update-Eintrag. Als Unit-Test über eine pure Funktion UpdateHintSurfaces.surfaces(for: .dictationRaw), die .menuBar enthalten muss. Heute gibt es diese Fläche nicht.

### LR-AK-002 · Downgrade überschreibt ein neueres Workspace-Schema

*P2 · agent-kern / datenintegritaet · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Models/AgentChat.swift:615-619`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1499-1507`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:54-64` (Stand `a8e0f35`)

**Fehlerbild:** Eine neuere App hat AgentSessions.json mit schemaVersion 2 und zusätzlichen Session-Feldern geschrieben. Dieser Build dekodiert die bekannten Felder, setzt schemaVersion bedingungslos auf 1 und schreibt beim Load sofort zurück. Unbekannte Felder verschwinden aus der aktiven Datei; unbekannte Kinds werden zudem zu normalen Chats. Ein pre-migration-Backup existiert, wird aber nicht automatisch wiederhergestellt und verhindert die destruktive aktive Migration nicht.

**Fix:** Future-Version-Guard jetzt einbauen ist billig (vor dem ersten Schema-2-Release), aber nicht launch-kritisch.

*Ursprünglicher Vorschlag:* Future-Version vor jeder Migration erkennen und den gesamten Store schreibgesperrt öffnen oder mit verständlichem Update-Hinweis ablehnen. Unbekannte Datensätze nicht in andere Session-Arten umdeuten. Invariante: unverstandene Daten bleiben bytegetreu erhalten; Backup allein ersetzt keinen Write-Guard.

**Test zuerst:** AgentWorkspaceRepositoryTests: Datei mit schemaVersion 2 + unbekanntem Zusatzfeld laden; nach load(migrate:) muss die Datei bytegleich bleiben bzw. der Store schreibgesperrt sein. Heute wird sie auf 1 überschrieben.

**Zusammengeführt mit:** LR-AK-029

<details><summary>Prüfurteil</summary>

Mechanik stimmt: migratedWorkspace setzt schemaVersion bedingungslos auf currentSchemaVersion (=1), Codable ignoriert unbekannte Felder, Load speichert zurück. Aber es gibt im Feld keine Schema-2-Datei: currentSchemaVersion ist 1, W6 (Update) geht nur vorwärts. Betroffen wäre nur ein Downgrade nach Nutzung einer künftigen Version, und vor dem Überschreiben wird ein pre-migration-Backup geschrieben plus 3 rotierende Generationen. Das ist Zukunftssicherung, kein Launch-Datenverlust.

</details>

### LR-BR-004 · Developer-ID-Build bricht am fehlenden Frameworks-Ordner ab

*P2 · build-release / korrektheit · Aufwand S · Risiko niedrig*

**Beleg:** `scripts/build-dmg.sh:5`, `scripts/build-dmg.sh:32-48`, `Makefile:320-354` (Stand `a8e0f35`)

**Fehlerbild:** DEVELOPER_ID_APPLICATION ist gesetzt und das aktuelle SwiftPM-Bundle wurde gebaut. Das Makefile erzeugt Contents/MacOS und Contents/Resources, aber kein Contents/Frameworks. find auf dem fehlenden Ordner liefert trotz unterdrückter Fehlermeldung Status 1; durch pipefail und errexit endet das Skript vor der äußeren Developer-ID-Signierung und vor dem DMG. Die Shell-Semantik wurde mit einer ausschließlich lesenden Probe bestätigt.

**Fix:** Fix des Finders passt ('[[ -d ... ]] &&' vor find oder 'find ... // true' nur für den Nicht-Existenz-Fall). '2>/dev/null' darf echte codesign-Fehler nicht verschlucken. Wenn man 'set +o pipefail' lokal setzt, werden Signierfehler in der while-Schleife sonst nicht mehr gemeldet. Die Fehlerprüfung deshalb in die Schleife legen.

*Ursprünglicher Vorschlag:* Den optionalen Frameworks-Pfad vor find auf Existenz prüfen. Ein fehlender Ordner muss erlaubt sein, echte Signierfehler eingebetteter Komponenten dagegen müssen weiterhin abbrechen. Einen Packaging-Test für das aktuelle Bundle ohne Frameworks und einen für eingebetteten Code hinzufügen.

**Test zuerst:** Shell-Test (bats oder XCTest mit Process): Eine Fake-.app ohne Contents/Frameworks, ein codesign-Stub im PATH und DEVELOPER_ID_APPLICATION=X. build-dmg.sh bis zum Signing laufen lassen (make build per Stub ersetzen). Erwartet: Exit 0 und genau ein codesign-Aufruf für das Bundle. Heute bricht es mit Exit 1 vor dem Aufruf ab.

**Teil von:** LR-BR-003

<details><summary>Prüfurteil</summary>

Mit bash und 'set -euo pipefail' habe ich es nachgestellt: find auf einem fehlenden Verzeichnis liefert Status 1, und die Pipeline find / while bricht das Skript ab, sodass 'survived' nie erscheint. Das Makefile-_bundle legt kein Contents/Frameworks an, und SwiftPM bettet statisch ein. Der Developer-ID-Zweig würde also zuverlässig vor dem App-Signing abbrechen. Heute läuft der Zweig aber nirgends, weil weder CI noch ein dokumentierter Weg DEVELOPER_ID_APPLICATION setzt. Der Defekt ist ein Teilschritt von LR-BR-003 und kein eigener Nutzerweg-Bruch. Er fällt beim ersten Versuch sofort auf und lässt sich mit einem Einzeiler beheben. Ein Blocker ist er nur über BR-003.

</details>

### LR-BR-007 · Tag-Releases werden ohne Test-Gate veröffentlicht

*P2 · build-release / infra · Aufwand M · Risiko niedrig*

**Beleg:** `.github/workflows/ci.yml:10-13`, `.github/workflows/ci.yml:41-44`, `.github/workflows/release.yml:12-15`, `.github/workflows/release.yml:55-70` (Stand `a8e0f35`)

**Fehlerbild:** Ein Commit enthält einen Compile-Fehler ausschließlich im Testtarget oder einen fehlgeschlagenen Regressionstest und erhält einen Versions-Tag. Der Tag-Workflow baut nur das Produkt und veröffentlicht anschließend DMG und Cask. Er führt keine Tests aus und wartet nicht auf einen erfolgreichen Testlauf desselben Commits; der separate CI-Workflow läuft nicht auf Tags. So kann eine Version trotz nachweislich kaputter Tests ausgeliefert werden.

**Fix:** Vorschlag des Finders (Tests desselben SHA als Voraussetzung) ist richtig. Einfachste Variante: ci.yml mit 'workflow_call' versehen und im Release-Job per 'needs' einbinden. Die Tests laufen dann im Tag-Lauf doppelt (~Laufzeit), was bei seltenen Releases vertretbar ist.

*Ursprünglicher Vorschlag:* Die vollständigen Tests desselben getaggten SHA als verpflichtige Voraussetzung des Release-Jobs ausführen, beispielsweise über einen wiederverwendbaren Workflow und needs. Veröffentlichung erst nach grünen Tests und erfolgreicher Bundle-Prüfung erlauben; ein älterer grüner main-Lauf darf nicht genügen.

**Test zuerst:** Kein Unit-Test. Workflow-Lint (actionlint) plus Prüfung: release.yml enthält einen Job mit 'swift test' oder 'uses: ./.github/workflows/ci.yml', und der Release-Job hat 'needs:' darauf.

<details><summary>Prüfurteil</summary>

Die Lücke ist real. release.yml läuft nur bei Tag-Push, hat kein 'needs' und keinen Testschritt (nur make dmg, also swift build -c release), und ci.yml läuft nicht auf Tags. Ein Tag auf einem Commit mit kaputten Tests oder einem Fehler im Testtarget würde ausgeliefert. Der übliche Ablauf ist aber merge nach main, CI grün, dann Tag (frühere Releases liefen laut Notizen mit grünem CI). Ein Release-Bug entsteht erst durch den Prozessfehler 'taggen ohne CI'. Die DoD-Zeile 'swift test grün in CI' ist über main erfüllt. Das ist Release-Hygiene und kein Nutzerweg-Bruch. Die Kompilierung des Produkts wird im Tag-Job immerhin geprüft.

</details>

### LR-BR-008 · Clean-Install beendet fremde Prozesse und kann sich selbst töten

*P2 · build-release / robustheit · Aufwand M · Risiko mittel*

**Beleg:** `scripts/clean-install.sh:14-19`, `Makefile:252-272`, `scripts/build-dmg.sh:80` (Stand `a8e0f35`)

**Fehlerbild:** Das Skript wird über einen absoluten Pfad gestartet, dessen Repo-Name whisperm8 enthält. pkill -9 -f whisperm8 trifft dann auch den ausführenden bash-Prozess und beendet den Reset vorzeitig. Zusätzlich trifft die unbeschränkte Suche beliebige andere Prozesse mit diesem Text in argv, beispielsweise einen Editor mit dem Projektpfad oder laufende Compiler. Die gezielte, geordnete Prozessauswahl des Makefiles wird hier gerade nicht verwendet.

**Fix:** Der Fix des Finders (präzise GUI_PIDS-Auswahl plus SIGTERM-Wartepfad aus dem Makefile) ist sinnvoll. Besser noch: zuerst 'make kill' bzw. dieselbe awk-Auswahl nutzen. Wichtig bleibt, dass supervisor-Prozesse (agent-supervise) ausgenommen werden, wie im Makefile. Die LIES-MICH-Zeile ersatzlos streichen oder auf 'brew reinstall' ändern.

*Ursprünglicher Vorschlag:* Die bestehende präzise GUI-Prozessauswahl und den geordneten SIGTERM-/Wartepfad zentral wiederverwenden. Eigene PID/Prozessidentität absichern; keine Substring-SIGKILL-Suche über alle Argumentvektoren. Direkten Skriptaufruf aus einer App-Session ebenfalls abfangen und destruktive Recovery nicht als allgemeine Fehlerbehebung bewerben.

**Test zuerst:** Shell-Test: Ein Dummy-Prozess 'sleep 60 # whisperm8-testmarker' starten, das Skript mit absolutem Pfad in ein Verzeichnis mit 'whisperm8' im Namen kopieren und ausführen (rm/tccutil per PATH-Stubs). Erwartet: Der Dummy bleibt am Leben und das Skript läuft bis zum Ende durch. Heute wird der Dummy getötet und das Skript endet vorzeitig.

<details><summary>Prüfurteil</summary>

clean-install.sh:16-17 nutzt pkill -9 -f mit 'WhisperM8' und 'whisperm8' über alle argv. Bei absolutem Aufruf eines Pfads mit 'whisperm8' (z. B. /Users/.../repos/whisperm8/scripts/clean-install.sh) trifft das auch den eigenen bash-Elternprozess, pkill schließt nur sich selbst aus. Der Reset bricht dann bei Zeile 16 ab, bevor irgendetwas gelöscht wurde, was harmlos ist. Über 'make clean-install' (relatives ./scripts/...) greift der Selbsttreffer nicht, und der Make-Target hat _guard_chat. Realer Kollateralschaden: Es trifft Fremdprozesse mit dem Text in argv (Compiler, Editoren, whisperm8-agent-supervise-Jobs, Chat-CLI) mit SIGKILL ohne Flush, ohne Warnung. Das Skript ist aber ausdrücklich ein destruktiver Voll-Reset (Zeile 11) und wird vom Maintainer genutzt. Das Skript liegt nicht im Brew-Cask-Weg, der Hinweis in 'LIES MICH.txt' (build-dmg.sh:80) zeigt Endnutzern auf ein Skript, das sie gar nicht haben (ein separater Doku-Fehler).

</details>

### LR-ONB-010 · Der Update-Dialog endet bei einem Terminal-Befehl statt einer geführten Aktualisierung

*P2 · onboarding / ux · Aufwand L · Risiko mittel*

**Beleg:** `WhisperM8/Views/AppUpdateViews.swift:51-69 — ausschließlich CopyableCommandBox und Im Terminal ausführen; kein Ausführungs-/Fortschritts-/Ergebnisweg.`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:20-26 — Upgrade und Adopt werden als zwei unterschiedliche Befehle bereitgestellt.` (Stand `a8e0f35`)

**Fehlerbild:** Ein Laie öffnet den Update-Hinweis und kopiert den Befehl. Die App erklärt nicht geführt, wie er ausgeführt wird, prüft keinen Erfolg und bietet keine Reparatur für Brew-Fehler. Beim Adopt-Fall steht zusätzlich zuerst der ohne Receipt ungeeignete Upgrade-Befehl. Der Nutzer muss den eigentlichen W6-Ablauf selbst außerhalb der App organisieren.

**Fix:** Homebrew als einzigen Installationskanal erhalten, aber einen verständlichen geführten Update-Ablauf mit Zustimmung, korrekt gewähltem Upgrade-/Adopt-Pfad, sichtbarem Ergebnis und sicheren Neustart anbieten. Daten-/Prozessschutz und stabile signierte App-Identität vor Relaunch nachweisen; keine ungefragte Hintergrundinstallation.

**Test zuerst:** Die Befehlsauswahl in eine pure Funktion auslagern: AppUpdateChecker.primaryCommand(for: UpdateInfo). Mit isBrewInstall == false muss brewAdoptCommand herauskommen. Heute zeigt die View fest brewUpgradeCommand zuerst.

### LR-BR-010 · Deinstallation hinterlaesst `~/.local/bin/whisperm8` als toten Symlink; laufende Chats behalten Hooks auf das entfernte Binary (W7)

*P3 · build-release / infra · Aufwand S · Risiko niedrig*

**Beleg:** `scripts/update-cask.sh:49-53`, `WhisperM8/Services/Shared/CLISymlinkInstaller.swift:20-36`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:96-99` (Stand `76256ad`)

**Fehlerbild:** `brew uninstall --zap` entfernt Application Support, Caches und Preferences, aber nicht den von der App angelegten Symlink `~/.local/bin/whisperm8`. Er bleibt als toter Link im PATH, `whisperm8 ...` meldet dann `No such file`. Chats, die zum Zeitpunkt der Deinstallation noch laufen, rufen bei jedem Prompt den Hook `"/Applications/WhisperM8.app/Contents/MacOS/WhisperM8" chats _prompt-guard` mit absolutem Pfad auf. Er scheitert mit Exit 127 und Claude zeigt bei jedem Prompt einen Hook-Fehler. Der Schaden ist klein und passt zu W7 (keine Fremdaenderungen).

**Fix:** Den Symlink in die `zap`-Liste des Casks aufnehmen (`~/.local/bin/whisperm8`, loescht nur den Link). Den Hook-Befehl so bauen, dass ein fehlendes Binary still mit Exit 0 endet (`[ -x path ] && path ... // exit 0`).

**Test zuerst:** Test auf promptGuardCommand: fuehrt der Befehl mit nicht existentem Pfad zu Exit 0.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-DOK-002 · DMG-Anleitung verspricht einen nicht mehr unterstützten Build ohne Xcode

*P3 · doku / doku · Aufwand S · Risiko niedrig*

**Beleg:** `docs/DMG_BAUEN.md:3-6`, `docs/DMG_BAUEN.md:16-30`, `docs/DMG_BAUEN.md:45-53`, `Makefile:9-10` (Stand `a8e0f35`)

**Fehlerbild:** Ein Maintainer folgt der DMG-Anleitung auf einem Mac mit CommandLineTools, aber ohne vollständiges Xcode. Die Anleitung behauptet, ein Dependency-Preview-Patch plus DEVELOPER_DIR=/Library/Developer/CommandLineTools genüge. Das Makefile überschreibt diese Umgebungsvariable jedoch mit /Applications/Xcode.app/Contents/Developer; der Build scheitert am fehlenden Toolchain-Pfad. Die Anleitung nennt außerdem den manuellen Gatekeeper-Override statt des beschlossenen Brew-/Notarisierungswegs.

**Fix:** Die Anleitung auf den kanonischen Xcode-/Makefile-Build und die neue verbindliche Developer-ID-/Notarisierungskette umstellen. Den alten Checkout-Patch und die CommandLineTools-Ausweichanweisung entfernen; öffentliche Installation ausschließlich über den Brew-Cask dokumentieren.

**Test zuerst:** Kein Swift-Test. Doku-Lint im CI: docs/DMG_BAUEN.md darf kein 'DEVELOPER_DIR=/Library/Developer/CommandLineTools' enthalten, solange das Makefile DEVELOPER_DIR fest exportiert. Alternativ die Datei löschen und auf scripts/build-dmg.sh bzw. den Release-Workflow verweisen.
