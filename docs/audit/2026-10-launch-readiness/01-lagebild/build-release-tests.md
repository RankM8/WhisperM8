---
status: aktiv
updated: 2026-10-17
description: Lagebild Build, Release und Tests (Makefile, scripts/, CI-Workflows, Package.swift, Info.plist, Entitlements, Testsuite) auf Stand a8e0f35.
---

# Lagebild · Build, Release, Tests

## Zweck

Das Subsystem macht aus dem SwiftPM-Quelltext (kein .xcodeproj) ein lauffähiges, signiertes `WhisperM8.app` und verteilt es. Es umfasst drei Dinge:

- **Lokaler Entwicklungszyklus:** `make dev`, `make skills`, `make snapshots`.
- **Release-Kette:** Tag, DMG, GitHub-Release, Homebrew-Cask im Tap `RankM8/homebrew-tap`. Das ist laut Launch-Definition der einzige Installationsweg.
- **Testsuite:** XCTest, 203 Dateien, rund 50.400 Zeilen, rund 2.950 Testfunktionen.

## Datenfluss

```
 lokal                                     Release
 -----                                     -------
 make dev                                  git tag vX.Y.Z  ->  release.yml (macos-26)
   _guard_chat (WHISPERM8_SESSION_ID?)       Tag == Info.plist-Version?  (sonst Abbruch)
   _build_dev: swift build -c release        make dmg -> scripts/build-dmg.sh
     -no-WMO -incremental, .build-dev          make build -> _bundle (Makefile)
   patch-resource-accessors.sh                 codesign (ad-hoc; Developer ID nur per Env)
     (Exit 3 = Rebuild)                        hdiutil -> dist/WhisperM8-<v>.dmg
   kill -> _install_bundle (rsync)           shasum -> softprops/action-gh-release
   -> /Applications, open                    scripts/update-cask.sh -> Casks/whisperm8.rb
                                             -> push in den Tap-Repo (TAP_GITHUB_TOKEN)
 CI (ci.yml, Push auf main + PR)             -> Nutzer: brew install --cask rankm8/tap/whisperm8
   test: swift build --build-tests; swift test --skip-build
   release-build: swift build -c release
 (Tag-Release hat KEIN Test-Gate, siehe LR-BR-007)
```

## Schlüsseldateien

- `Makefile`: Ziele `dev`, `dev-release`, `build`, `install`, `kill`, `dmg`, `clean-install`, `skills`, `plugin-test`, `snapshots`. Der interne Bundle-Zusammenbau steckt in `_bundle`, der Guard gegen Aufruf aus App-Chats in `_guard_chat`.
- `scripts/build-dmg.sh`: baut das Bundle, signiert optional mit Developer ID, erzeugt das DMG und notarisiert optional.
- `scripts/update-cask.sh`: generiert die Cask-Datei (URL, SHA256, `postflight` entfernt die Quarantäne, `zap trash` mit drei Pfaden).
- `scripts/patch-resource-accessors.sh`: patcht SwiftPM-Resource-Accessors, damit `Bundle.module` in `Contents/Resources` findet. Exit-Codes: 0 = unverändert, 3 = frisch gepatcht (Rebuild nötig), 1 = Fehler.
- `scripts/setup-codesign-cert.sh`: einmalige selbstsignierte Identität "WhisperM8 Local Dev", damit TCC-Rechte Rebuilds überleben.
- `scripts/clean-install.sh`: Komplett-Reset (Prozesse, Bundles, TCC, Daten).
- `scripts/sync-skills.sh`: legt Skills und Plugin aus den Repo-Ressourcen ab (`make skills`).
- `scripts/test-claude-plugin.sh`: prüft die Mod ohne App-Build (`claude plugin validate` und `test`).
- `scripts/ui-snapshots.sh`: rendert die Snapshot-Galerie als PNG (ohne App-Start).
- `scripts/perf-load.sh`, `scripts/perf-report.sh`: Lastlauf und Log-Auswertung für Performance-Budgets.
- `scripts/build.sh`, `scripts/run.sh`: Hilfsskripte für Build und Debug-Lauf.
- `.github/workflows/ci.yml`: Debug-Tests und Release-Build auf Push nach main und auf PRs, ohne Parallelisierung.
- `.github/workflows/release.yml`: Tag-Push `v*`, Versionsabgleich, DMG, GitHub-Release, Cask-Push.
- `Package.swift`: Targets `ObjCExceptionBridge`, `WhisperM8`, `WhisperM8Tests`. Abhängigkeiten sind KeyboardShortcuts (exact 1.16.1), Defaults und LaunchAtLogin-Modern (je `from`) sowie der SwiftTerm-Fork (Revision-Pin). Der Resource-Block ist eine explizite Liste.
- `Package.resolved`: konkrete Revisionen. Der Cache-Key der Workflows hängt daran.
- `WhisperM8/Info.plist`: Bundle-ID `com.whisperm8.app`, Version 2.21.0, `LSMinimumSystemVersion` 14.0, Usage-Strings für Mikrofon, Bildschirmaufnahme und Spracherkennung.
- `WhisperM8/WhisperM8.entitlements`: Sandbox aus, `audio-input` und `network.client` an.
- `Tests/WhisperM8Tests/`: flache Struktur, thematisch pro Subsystem.
  - Gemeinsame Helfer: `AgentTestSupport.swift`, `TestTiming.swift`, `TestControlSocket.swift`.
  - Snapshot-Galerie: `UISnapshotGallery.swift`.

## Zustände und Persistenz

- **Build-Artefakte:** `.build` (geteilt, Release und Tests), `.build-dev` (nur `make dev`), lokales `WhisperM8.app`, `dist/` (DMG, Staging). Geschrieben werden sie von make und den Skripten.
- **Installation:** `/Applications/WhisperM8.app` wird per `rsync -a --delete` in place aktualisiert, nie gelöscht. Das erhält die TCC-Rechte.
- **Log für abgekoppelten Neustart:** `$TMPDIR/whisperm8-make-dev.log`.
- **Versionsquelle:** allein `CFBundleShortVersionString` in `Info.plist`. Tag und Plist müssen übereinstimmen.
- **Release-Zustand extern:** GitHub-Release-Asset und `Casks/whisperm8.rb` im Tap-Repo. Der Cask-Push läuft mit `secrets.TAP_GITHUB_TOKEN`.
- **Signaturidentität:** Keychain-Eintrag "WhisperM8 Local Dev" (lokal) oder ad-hoc (CI). `DEVELOPER_ID_APPLICATION`, `NOTARYTOOL_PROFILE` und Apple-ID-Variablen sind nur über Env vorgesehen.

## Externe Abhängigkeiten

- **Toolchain:** Xcode unter `/Applications/Xcode.app` (`DEVELOPER_DIR`, wegen SwiftUI-Makros). Runner ist `macos-26`.
- **Werkzeuge:** `codesign`, `hdiutil`, `xcrun notarytool` und `stapler`, `PlistBuddy`, `rsync`, `security`.
- **Netz:** GitHub (Actions, Releases, API für `AppUpdateChecker`), SwiftPM-Fetch von GitHub. Der Tap-Repo-Push braucht ein PAT.
- **Entwickler-CLI:** `claude` für `plugin-test`.
- **TCC:** Mikrofon, Bedienungshilfen und Bildschirmaufnahme hängen an der stabilen Codesign-Identität. Das Entitlement `audio-input` gehört zum Mikrofon.
- **Deinstallation:** `brew uninstall --zap` löscht nur drei Pfade (siehe LR-BR-001, LR-BR-005).

## Invarianten, die jeder Umbau erhalten muss

1. `make dev`, `dev-release`, `install`, `run` und `clean-install` brechen aus einer WhisperM8-Session (`WHISPERM8_SESSION_ID`) ab. `FORCE=1` setzt den Neustart abgekoppelt fort, `dev` läuft dann per `nohup`.
2. Die Installation läuft per rsync in das bestehende Bundle. Das Bundle wird nie gelöscht und neu kopiert, sonst entzieht macOS die TCC-Rechte.
3. Der Resource-Accessor-Patch ist Pflicht. Ohne ihn crasht das Bundle auf fremden Macs mit `fatalError "could not load resource bundle"`. Die gepatchten Dateien bleiben auf 444.
4. Ressourcen brauchen Package.swift UND das Makefile (`_bundle`). Das SwiftPM-Bundle wird zusätzlich komplett nach `Contents/Resources` kopiert.
5. Info.plist ist die einzige Versionsquelle. Der Tag-gegen-Plist-Abgleich in `release.yml` bleibt bestehen.
6. Die Bundle-ID `com.whisperm8.app` und der Entitlements-Satz bleiben stabil, weil TCC, Keychain und `defaults`-Schalter daran hängen.
7. Der SwiftTerm-Fork ist auf einen Commit gepinnt. `KeyboardShortcuts` ist `exact`. `Package.resolved` ist eingecheckt.
8. `DEVELOPER_DIR` zeigt auf Xcode. Tests laufen seriell, weil Singleton-State (z. B. `AppPreferences.shared`) nicht isoliert ist.
9. Budget-Tests messen Thread-CPU-Zeit über `TestTiming`, nicht Wandzeit. Die Snapshot-Galerie überspringt sich ohne `WHISPERM8_SNAPSHOT_DIR`.
10. Dev-Builds nutzen den eigenen Ordner `.build-dev`, damit andere `swift build`/`swift test`-Läufe den `.build`-Lock nicht halten.

## Top-Risiken

- **LR-BR-002 (P0):** Das Apple-App-Passwort steht beim Notarisieren im argv von `notarytool` (`scripts/build-dmg.sh`).
- **LR-BR-003 (P1):** Öffentliche Releases sind ad-hoc signiert und nicht notarisiert. Der Cask entfernt die Quarantäne, E4 ist damit nicht umgesetzt. Dazu gehört LR-DOK-002 (veraltete DMG-Anleitung, P2).
- **LR-BR-004 (P1):** Der Developer-ID-Pfad bricht ab, weil `Contents/Frameworks` fehlt (pipefail).
- **LR-BR-005 (P1) und LR-BR-001 (P1):** Der Cask hat keine `uninstall`-Stanza zum Beenden der App. Statuslines, CLI-Symlink und `~/.claude`-Änderungen bleiben nach `--zap` zurück.
- **LR-BR-006 (P1):** Das DMG enthält nur die Build-Architektur (arm64), der Cask prüft nur macOS.
- **LR-BR-007 (P1):** Tag-Releases laufen ohne Test-Gate. `ci.yml` läuft nicht auf Tags.
- **LR-BR-008 (P1) und LR-DOK-004 (P1):** `clean-install.sh` beendet per `pkill -9 -f whisperm8` fremde Prozesse und sich selbst. Das Handbuch empfiehlt diesen Reset als normale Fehlerbehebung.
- **LR-BR-009 (P2):** Ein Store-Test (`AgentWorkspaceStoreTests`) misst Wandzeit und ist unter Last flaky.
- **LR-DOK-001 (P2):** Die README bewirbt DMG-Download und Build-from-Source, obwohl nur Brew gelten soll.
- **LR-ONB-011 (P2):** Die UI hat keine Lokalisierungsressourcen. Das berührt auch die Testlage (kein Lokalisierungstest).
- **Testlücke:** Es gibt keinen automatischen End-to-End-Nachweis für Installation, Update, Deinstallation und TCC. Die Suite prüft überwiegend pure Logik und injizierte Teilschritte.
