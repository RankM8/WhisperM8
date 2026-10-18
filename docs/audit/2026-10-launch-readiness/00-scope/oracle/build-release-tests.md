---
status: aktiv
updated: 2026-10-17
description: Regressions-Oracle Build, Release und Tests auf Stand a8e0f35. Release-Kette und Testsuite als Verträge.
---

# Regressions-Oracle · Build, Release, Tests

## Leseregel

Das Oracle beschreibt Verhalten, das kein Fix unbeabsichtigt ändern darf. Juli-Einträge (DI-…/AC-…) gelten weiter, sofern sie hier nicht ersetzt sind. Für diesen Bereich gab es im Juli-Inventar keine Einträge. Dort lagen nur Dictation und Agent Chats, nicht der Build-Bereich. Die folgenden Einträge sind deshalb neu und beschreiben Release-Kette und Testsuite als Verträge. Zeilenangaben beziehen sich auf a8e0f35. Bewusst absichtliche Änderungen wie die Befund-Fixes (LR-BR-…) bleiben erlaubt, solange der jeweilige Vertrag neu belegt wird.

### F-APP-02 · Dock-App, Bundle-Identität und Mindestsystem
- **Funktion:** Das Bundle ist eine reguläre Dock-App mit stabiler Identität und Systemvoraussetzung.
- **Einstiegspunkte:** `WhisperM8/Info.plist:5` (`CFBundleIdentifier` = `com.whisperm8.app`), `WhisperM8/Info.plist:13` (`LSMinimumSystemVersion` 14.0), `Package.swift:7` (`.macOS(.v14)`), `scripts/update-cask.sh:42` (`depends_on macos: :sonoma`), `Makefile:320` (`_bundle`).
- **Sichtbares Verhalten:** Die App erscheint im Dock, `LSUIElement` ist false. Der Cask lässt nur Sonoma oder neuer zu.
- **Erhaltungsinvarianten:** Bundle-ID unverändert, sonst gehen TCC, Keychain und Defaults verloren. Mindestsystem in Plist, Package.swift und Cask bleiben deckungsgleich. Die Architektur ist nicht im Cask festgelegt (LR-BR-006).
- **Befund-Bezug:** LR-BR-006.

### F-APP-04 · Release-Kette: Tag, DMG, GitHub-Release, Cask
- **Funktion:** Ein Tag `vX.Y.Z` erzeugt ein DMG, ein GitHub-Release und den aktualisierten Cask.
- **Einstiegspunkte:** `.github/workflows/release.yml:35` (Versionsabgleich), `.github/workflows/release.yml:55` (`make dmg`), `.github/workflows/release.yml:66` (Release-Asset), `.github/workflows/release.yml:81` (Cask-Push), `scripts/build-dmg.sh:32` (Signierzweig), `scripts/build-dmg.sh:102` (Notarisierung), `scripts/update-cask.sh:30` (Cask-Heredoc), `WhisperM8/Services/Shared/AppUpdateChecker.swift:116` (`checkNow`).
- **Sichtbares Verhalten:** `brew install --cask rankm8/tap/whisperm8` und `brew upgrade` liefern die Version aus dem Tag. Die App zeigt einen Update-Hinweis mit Brew-Befehl.
- **Erhaltungsinvarianten:**
  - Tag und `CFBundleShortVersionString` müssen übereinstimmen, sonst bricht die Pipeline ab.
  - Der DMG-Name `WhisperM8-<version>.dmg` und die Cask-URL passen zueinander, die SHA256 stammt aus demselben Artefakt.
  - Ein unveränderter Cask erzeugt keinen Commit.
  - Das Standard-GITHUB_TOKEN schreibt nur ins eigene Repo, der Tap braucht das PAT.
  - Ohne `DEVELOPER_ID_APPLICATION` entsteht ein ad-hoc-Bundle ohne Notarisierung.
- **Bekannte Abweichung vom Ziel:** ad-hoc signiert, Quarantäne-`postflight`, kein Test-Gate. Das ist heutiger Zustand, kein Ziel.
- **Befund-Bezug:** LR-BR-002, LR-BR-003, LR-BR-004, LR-BR-006, LR-BR-007, LR-DOK-002.

### F-APP-05/06 · Cask-Deinstallation, CLI-Symlink, Integrationen
- **Funktion:** Der Cask entfernt beim `zap` nur App-Daten. Der CLI-Symlink `whisperm8` und die Skill-/Statusline-Integration entstehen aus der App heraus.
- **Einstiegspunkte:** `scripts/update-cask.sh:49` (`zap trash`: Application Support, Caches, Preferences), `WhisperM8/Services/Shared/CLISymlinkInstaller.swift`, `scripts/sync-skills.sh:155` (`sync_plugin`).
- **Sichtbares Verhalten:** Nach `--zap` bleiben der CLI-Symlink und Dateien unter `~/.claude` bestehen. Eine laufende App wird nicht beendet.
- **Erhaltungsinvarianten:** Ein künftiger Uninstall darf `~/.claude`, `~/.codex` und fremde Proxys nie pauschal löschen. Eigene Symlinks und Statuslines werden nur nach Ownership-Prüfung entfernt.
- **Befund-Bezug:** LR-BR-001, LR-BR-005.

### F-APP-07 · Entitlements und TCC-Stabilität
- **Funktion:** Das Bundle erhält Mikrofon- und Netzwerkrechte und eine über Rebuilds stabile Codesign-Identität.
- **Einstiegspunkte:** `WhisperM8/WhisperM8.entitlements` (Sandbox false, `audio-input`, `network.client`), `Makefile:364` (Identitätswahl "WhisperM8 Local Dev" oder ad-hoc), `Makefile:371` (`codesign … --entitlements`), `scripts/setup-codesign-cert.sh`, `WhisperM8/Info.plist:17-21` (Usage-Strings).
- **Sichtbares Verhalten:** Mit lokalem Zertifikat bleiben Rechte nach `make dev` erhalten. Ohne Zertifikat fragt macOS bei jedem Build erneut.
- **Erhaltungsinvarianten:**
  - `make dev` nutzt rsync in das bestehende Bundle (`Makefile:227`).
  - Die Entitlements werden bei jedem Signieren mitgegeben.
  - Usage-Strings für Mikrofon, Bildschirmaufnahme und Spracherkennung bleiben vorhanden, sonst kann der Prozess beim Zugriff beendet werden.
  - `build-dmg.sh` signiert innen nach außen mit `--options runtime`.
- **Befund-Bezug:** LR-BR-003, LR-BR-004.

### F-DEV-01 · Dev-Zyklus: `make dev`, Guard, Self-Healing
- **Funktion:** Inkrementeller Release-Build ohne WMO in `.build-dev`, anschließend Sync nach `/Applications` und Start.
- **Einstiegspunkte:** `Makefile:96` (`dev`), `Makefile:104` (`_dev_finish`), `Makefile:114` (`_guard_chat`), `Makefile:122` (`_build_dev`), `Makefile:173` (`build`), `Makefile:224` (`_install_bundle`), `Makefile:254` (`kill`), `scripts/patch-resource-accessors.sh` (Exit-Code-Protokoll 0/3/1).
- **Sichtbares Verhalten:**
  - In einer App-Session meldet `make dev` einen Abbruch mit Hinweis auf `FORCE=1`.
  - Mit `FORCE=1` läuft der Neustart abgekoppelt per `nohup`, das Log liegt unter `$TMPDIR/whisperm8-make-dev.log`.
  - Ein Fehlbuild löst genau einen Self-Healing-Versuch aus (`chmod u+w` der Accessors, neuer Build).
  - Exit 3 des Patch-Skripts führt zu genau einem Rebuild.
- **Erhaltungsinvarianten:** Die vier Befehle `dev`, `dev-release`, `install` und `clean-install` bleiben vom Guard geschützt. Das Entfernen von `-incremental` lässt jeden Lauf komplett neu bauen. Debug-Plus-O ist verboten, weil SwiftTerm im Debug-Define abstürzt. Nach dem Patch gilt `chmod 444` auf den Accessors.
- **Befund-Bezug:** LR-BR-008.

### F-DEV-02 · Clean-Install-Reset
- **Funktion:** Bewusster Komplett-Reset (Prozesse, Bundles, TCC, Daten) zum Testen von Onboarding und Migration.
- **Einstiegspunkte:** `Makefile:315` (`clean-install`), `scripts/clean-install.sh:16-18` (`pkill -9 -f`, `killall`), `scripts/build-dmg.sh:80` (README im DMG verweist darauf).
- **Sichtbares Verhalten:** Alle WhisperM8-Daten und -Rechte verschwinden, danach folgt `make install`.
- **Erhaltungsinvarianten:** Nur der Entwickler-Reset darf alle Daten löschen. Ein nutzerseitiger Fehlerpfad darf nicht darauf verweisen. Der Guard gegen App-Sessions bleibt.
- **Befund-Bezug:** LR-BR-008, LR-DOK-004.

### F-DEV-03 · CI-Vertrag
- **Funktion:** Push auf main und PRs führen Debug-Tests und einen Release-Build aus.
- **Einstiegspunkte:** `.github/workflows/ci.yml:25` (Job `test`), `.github/workflows/ci.yml:41` (`swift build --build-tests`), `.github/workflows/ci.yml:44` (`swift test --skip-build`), `.github/workflows/ci.yml:46` (Job `release-build`).
- **Erhaltungsinvarianten:** Build und Test bleiben getrennte Schritte. Es gibt keinen `--parallel`-Schalter, solange Singleton-State nicht isoliert ist. Der Release-Build ist ein eigener Job, weil Release unabhängig vom Debug-Build brechen kann. Der Cache-Key hängt an `Package.resolved`.
- **Bekannte Lücke:** Der Workflow läuft nicht auf Tags und ist keine Voraussetzung des Release-Jobs.
- **Befund-Bezug:** LR-BR-007.

### F-DEV-04 · Paketvertrag (SwiftPM)
- **Funktion:** Abhängigkeiten, Targets und Ressourcenliste.
- **Einstiegspunkte:** `Package.swift:13` (KeyboardShortcuts exact 1.16.1), `Package.swift:31` (SwiftTerm-Revision), `Package.swift:41` (`ObjCExceptionBridge`), `Package.swift:46` (`executableTarget`), `Package.swift:90` (`testTarget`), `Package.resolved`.
- **Erhaltungsinvarianten:** Der SwiftTerm-Pin bleibt eine Revision. `-parse-as-library` bleibt gesetzt. Neue Ressourcen stehen in Package.swift UND werden vom Makefile kopiert. Eine abweichende Teilmenge im Makefile ist erlaubt, weil das SwiftPM-Bundle komplett kopiert wird. `Info.plist`, Entitlements und das Icon sind aus dem Target ausgeschlossen.

### F-DEV-05 · Testsuite als Vertrag
- **Funktion:** Eine flache XCTest-Suite (203 Dateien, rund 2.950 Tests) sichert die Subsysteme ab.
- **Einstiegspunkte:**
  - `Tests/WhisperM8Tests/AgentTestSupport.swift` (gemeinsame Helfer)
  - `Tests/WhisperM8Tests/TestTiming.swift` (Thread-CPU-Zeit)
  - `Tests/WhisperM8Tests/UISnapshotGallery.swift:158` (Skip ohne `WHISPERM8_SNAPSHOT_DIR`)
  - `Tests/WhisperM8Tests/StoreFormatCompatTests.swift` (Altformate)
  - `Tests/WhisperM8Tests/SettingsSourceGuardTests.swift`
  - `Tests/WhisperM8Tests/PerformanceBudgetTests.swift`
- **Abdeckung je Subsystem (nach Dateinamen):**
  - Agent-Chats-Store, Indexer, Watcher, Hooks: viele Dateien.
  - Konten und GPT-Backend: `ClaudeAccount*`, `GPTAccount*`, `ClaudeGPTMixRouter*`, `ClaudeCodeProxy*`.
  - Dictation: `Recording*`, `AudioFormat*`, `MultipartTranscription*`, `ChatGPTSubscriptionTranscription*`.
  - Absturzschutz: `ObjCExceptionTests`, `SigpipeGuardTests`, `StallWatchdogTests`.
  - Update, Plugin, Voice-Gate: `AppUpdateCheckerTests`, `WhisperM8ClaudePluginTests`, `CodexVoiceGateTests`.
  - Keine Tests für Release-Skripte, Cask-Erzeugung oder Bundle-Packaging.
- **Erhaltungsinvarianten:** Abhängigkeiten werden über Closures und kleine Protokolle injiziert, ohne DI-Framework. Budget-Tests messen CPU-Zeit, nicht Wandzeit. Kein Test darf reale `~/.claude`-, Keychain- oder App-Support-Daten verändern. Die Tests laufen seriell.
- **Befund-Bezug:** LR-BR-009, LR-BR-004 (fehlender Packaging-Test), LR-ONB-011.

### F-DEV-06 · Snapshot-Galerie und Plugin-Test
- **Funktion:** Eine UI-Ansicht ohne App-Start prüfen und die Mod ohne App-Build validieren.
- **Einstiegspunkte:** `Makefile:152` (`snapshots`), `scripts/ui-snapshots.sh`, `Makefile:149` (`plugin-test`), `scripts/test-claude-plugin.sh`.
- **Erhaltungsinvarianten:** Jeder Snapshot-Lauf schreibt in einen eigenen Zeitstempel-Ordner und löscht nichts. Der Lauf ist sicher aus einem Agent-Chat. Das Plugin-Gerüst wird für den Test in einen Temp-Ordner kopiert, der Repo-Inhalt bleibt unverändert.

## Aktualisierte Juli-Einträge

Keine. Im Juli-Inventar gab es für diesen Bereich keine DI-/AC-Einträge.
