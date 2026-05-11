# Subagent 09 - Build, Dev und Deployment

## Kurzbefund

Der primaere Build-Pfad ist `Makefile` + SwiftPM. Das Xcode-Projekt und alte Skripte wirken veraltet und koennen andere Bundle-IDs, Dependencies oder Signing-Artefakte erzeugen.

## Befunde

- `Makefile:56` und `147`: `make dev/build/run/install` nutzt `swift build` und baut das `.app` manuell zusammen.
- `WhisperM8.xcodeproj/project.pbxproj`: Xcode-Projekt ist stale; nur ein Teil der Swift-Dateien ist eingetragen, `SwiftTerm` fehlt, Bundle-ID ist `com.yourname.WhisperM8`.
- `scripts/build.sh` und `scripts/run.sh`: nutzen `xcodebuild` gegen das stale Projekt.
- Bundle-ID ist mehrfach/inkonsistent: `Info.plist` nutzt `com.whisperm8.app`; Xcode nutzt historische ID; `clean-install.sh` kennt mehrere IDs.
- Version ist mehrfach gepflegt: `Info.plist`, Xcode `MARKETING_VERSION`, UI hard-coded `Version 1.2.0`.
- Dependencies driften: `Package.swift` enthaelt `SwiftTerm`, Doku/AGENTS nennen noch `ISSoundAdditions`; es gibt Root- und Xcode-Workspace-`Package.resolved` mit abweichenden Pins.
- Ressourcenliste ist doppelt: `Package.swift` deklariert Ressourcen, `Makefile` kopiert sie manuell.
- `build-dmg.sh`: ohne Developer-ID bleibt das DMG ad-hoc signiert; Notarisierung ist optional und kein harter Release-Gate.
- `make dev` schuetzt TCC per in-place `rsync`; Bundle-ID, Installationspfad, Signing und Entitlements sind permission-sensibel.
- App-Typ-Doku widerspricht sich: aktuelles `Info.plist` setzt `LSUIElement=false`, waehrend AGENTS noch menu-bar-only/true beschreibt.

## Guardrails

- `make dev` als einzige lokale Dev-Quelle behandeln.
- `scripts/build.sh`/`run.sh` auf `make` umleiten oder Xcode-Projekt vollstaendig synchronisieren.
- Eine Quelle fuer Version, Bundle-ID, Deployment Target und Ressourcen definieren.
- UI-Version aus `Bundle.main` lesen.
- Release-Gate: `codesign --verify --deep --strict`, Entitlements-Inspection, `spctl`, Notary submit + staple.
- Aenderungen an Bundle-ID, Signing, `LSUIElement`, Installationsort oder Entitlements nur als explizite Migrationsaenderungen behandeln.

## Geprueft

- `plutil -lint` fuer `Info.plist` und Entitlements war laut Subagent OK.
