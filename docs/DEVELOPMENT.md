---
status: aktiv
description: Entwickler-Einstieg — aus dem Quelltext bauen, make-Ziele, Reset und Release. Nicht für Endnutzer.
updated: 2026-10-19
---

# Development

> **End users:** install and update WhisperM8 only via Homebrew —
> `brew install --cask rankm8/tap/whisperm8`, `brew upgrade --cask whisperm8`.
> Everything below is for contributors. A copy built from source is not managed by the
> Homebrew update channel and makes `brew upgrade` fail until it is removed.

## Build from source

Requirements: macOS 14 (Sonoma) or later, Xcode (SwiftUI macros need the full toolchain;
the Makefile sets `DEVELOPER_DIR`).

```bash
git clone https://github.com/RankM8/whisperm8.git
cd whisperm8
make dev          # incremental release build, synced into /Applications, launched
```

Other targets:

| Target | Purpose |
|---|---|
| `make dev` | Incremental release build (no WMO) in `.build-dev`, in-place sync to `/Applications` (keeps TCC permissions), launch |
| `make dev-release` | Full release build (WMO) as shipped — use for performance measurements |
| `make run` | Quick debug build from the project dir (separate TCC entry) |
| `make build` | Release build only, creates a local `.app` |
| `make snapshots` | Render UI fixtures as PNG (light + dark), no app start |
| `make dmg` | Distributable DMG |

Run `scripts/setup-codesign-cert.sh` once for a persistent local signing identity; otherwise
ad-hoc signing re-prompts for permissions on every rebuild.

Tests: `swift test` (with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
An isolated test instance with its own bundle ID, data folder and socket: `scripts/test-instance.sh`
(see [features/ui-testing.md](features/ui-testing.md)).

## Duplicate apps in Spotlight

```bash
make clean-apps   # removes all WhisperM8 bundles
make dev
```

## Full reset (destructive)

```bash
make clean-install
```

Deletes **all** app data — API keys in the Keychain, settings, permissions **and** the whole
`~/Library/Application Support/WhisperM8` folder (Agent Chats workspace, projects, custom output
modes, reports, failed recordings) — then reinstalls. Only for testing onboarding and migrations.
Back up `~/Library/Application Support/WhisperM8` first if you want to keep anything.

## Releasing

Releases are automated via `.github/workflows/release.yml` (triggered on a `v*` tag):

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `WhisperM8/Info.plist`.
2. `git tag vX.Y.Z && git push --tags`.

The pipeline builds the DMG, creates a GitHub Release with the asset, and updates the Homebrew
cask in [`RankM8/homebrew-tap`](https://github.com/RankM8/homebrew-tap) (version + sha256). The tag
must match the Info.plist version or the build fails.

> One-time setup: the `homebrew-tap` repo must exist (public), and a `TAP_GITHUB_TOKEN` secret
> (PAT with `Contents: write` on the tap) must be set in this repo's Actions secrets.

## Betriebswissen aus CLAUDE.md

*Am 19.10.2026 wörtlich aus der Projekt-CLAUDE.md übernommen (LR-DOK-008); dort stehen nur noch die Arbeitsregeln. Beim nächsten Überarbeiten dieser Seite in den Fließtext einarbeiten.*

**`make dev` baut seit 11.10.2026 Release ohne Whole-Module-Optimierung, mit `-incremental`, in einem eigenen Build-Ordner `.build-dev`**: typische Änderungen ~4–5 s statt ~98 s (WMO übersetzte immer das ganze Modul auf einem Kern); Änderungen an zentralen Modellen kaskadieren weiter (~45–80 s). SwiftPM schaltet `-incremental` im Release nicht selbst ein — ohne das Flag baute auch „ohne WMO" jedes Mal alles. **Kein Debug+O:** Debug definiert `DEBUG` für SwiftTerm, dort brechen vier Setter in `Buffer.swift` bei negativem Cursorwert per `abort()` ab. Ohne WMO fehlen dateiübergreifende Optimierungen — Messläufe gegen die Budgets mit `make dev-release`. Der eigene Ordner verhindert, dass `swift build`/`swift test` anderer Chats den `.build`-Lock halten. Nach dem Accessor-Patch werden die `resource_bundle_accessor.swift` wieder auf 444 gesetzt (sonst baute jeder Lauf doppelt). Aus einem WhisperM8-Chat/-Terminal (`WHISPERM8_SESSION_ID` gesetzt) brechen `dev`, `dev-release`, `install`, `run`, `clean-install` ab; `FORCE=1` lässt `dev` nach dem Build abgekoppelt (`nohup`, Log in `$TMPDIR/whisperm8-make-dev.log`) weiterlaufen.
`make dev` uses `rsync` into the existing bundle on purpose: deleting and recopying the bundle would make macOS TCC revoke mic/accessibility/screen permissions. Run `scripts/setup-codesign-cert.sh` once for a persistent local signing identity (otherwise ad-hoc signing re-prompts TCC on every rebuild).
