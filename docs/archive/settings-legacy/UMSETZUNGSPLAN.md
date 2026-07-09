---
description: Settings-Refactor V3 — Phasenplan (Audit-basiert, wartet auf Freigabe)
description_long: |
  Vollständiger Umsetzungsplan für das Settings-Refactoring: Layout V3
  „Linear Hairline", geteiltes AppTheme, SettingsKit, 10 neue Seiten mit
  Strangler-Migration. Basiert auf drei Codex-Deep-Dives (View-Qualität,
  Persistenz/Kompatibilität, Infrastruktur) und den validierten
  Referenz-Docs. Jede Phase mit Test- und Review-Gate.
updated: 2026-07-06 12:05
status: ✅ UMGESETZT (Phasen 0–10, 2026-07-06) — Review-Flotte läuft
---

# Settings-Refactor — Umsetzungsplan (V3)

**Ziel:** Settings vollständig refactoren auf die beschlossene Struktur
(10 Seiten, settings-redesign.html) im Layout **V3 „Linear Hairline"**
(settings-layout-varianten.html) — bei besserer Code-Qualität, Wartbarkeit
und **100 % Funktions- und Daten-Kompatibilität für Bestandsnutzer**.

**Audit-Basis (2026-07-06):** Deep-Dive A `e319e561` (View-Code-Qualität),
B `2e1df5fd` (Persistenz/Kompatibilität/Tests), C `acc906a8`
(Theme/Routen/Kit). Kernzahlen: 20 Dateien / 3.250 LOC Settings-Views,
36 verstreute `@AppStorage`-Properties, ~330 hartkodierte Styling-Stellen,
7–10 wiederkehrende UI-Muster, 5 Force-Unwraps, 413 `AgentTheme.*`-Aufrufe
(bleiben unberührt via `typealias`).

**Betriebsregeln (gelten für alle Phasen):**
- ❗ **Kein `make dev`/`make kill`/App-Relaunch** — Claude-Sessions laufen in
  WhisperM8. Verifikation headless (`swift build`, `swift test`); GUI-QA
  macht der User nach eigenem Relaunch. Gilt auch für Codex-Job-Prompts.
- Codex-Subagents bauen in **Worktrees**, ich reviewe Diffs und übernehme
  commit-frei; jede Phase endet mit **Codex-Diff-Review** (read-only,
  zweite Meinung) + `swift test` grün, erst dann Commit.
- UserDefaults-Keys, Defaults, Migrationsflags, Keychain, JSON-Formate:
  **eingefroren** laut Kompatibilitäts-Vertrag (Report B). Änderungen nur
  additiv.

---

## Phase 0 — Sicherheitsnetz: Characterization-Tests (VOR jedem Refactor)

Pinnt den Ist-Zustand, damit jede spätere Phase Regressionen sofort zeigt.

- `PreferencesTests` erweitern: `testPreferenceKeysRawNamesAreStable` (alle
  Key-Strings inkl. Migrationsflags), `testAllAppPreferencesDefaults…`
  (alle Defaults inkl. versteckter Settings), Roundtrip aller Keys,
  Screenshot-Migration (missing/0/3/7/21 + Flag), Transcription-Migration
  (kein Überschreiben bestehender Modelle).
- **Neu `OutputModeCompatTests`:** Fallback-Vertrag `defaultOutputModeID`
  (absent→clean · explizit `raw` bleibt `raw` · unknown ID mutiert den
  gespeicherten Wert nicht; effektiver Fallback bewusst gepinnt),
  JSON-Rückwärtskompatibilität (Legacy-Felder fehlen), Store-Normalisierung.
- **Neu `TemplateStoreCompatTests` / `ReportStoreCompatTests`:** Dateiformat
  (nur Customs, ISO8601), Legacy-Report-Decode, Pfad + Cleanup-Konstanten.
- Gates für die geplanten Verhaltens-Fixes: Visual-Context-Werte überleben
  Disable (A3), `updateCheckEnabled`-Gate (A21), Auto-Summary-Gate +
  Force-Refresh (F7), `agentDefaultProjectPath`-Konsumenten (F6),
  Mini-Overlay-Key Single-Writer (A2).
- CI-Guard (P2): Source-Scan-Test „jeder `@AppStorage`-String ist in
  `PreferenceKeys` deklariert oder dokumentierte Ausnahme".

**Delegation:** 1 Codex-Job (Worktree). **Gate:** Tests laufen GEGEN
unveränderten Code grün; Codex-Review prüft „pinnt Ist-Verhalten, nicht
Wunschverhalten". ~½ Tag.

## Phase 1 — Fundament: AppTheme + Preferences-Konsolidierung

- **1a Theme:** `AppTheme` = umbenanntes `AgentTheme` (Datei zieht nach
  `Support/AppTheme.swift`), `typealias AgentTheme = AppTheme` als Brücke —
  null Diff in Agent-Chats-Views. `Color.dynamic` funktioniert im
  Settings-Fenster bereits (`.preferredColorScheme` gesetzt, Beleg
  WhisperM8App.swift:83-86).
- **1b Preferences:** Zentrale Default-Konstante für `defaultOutputModeID`
  in `AppPreferences` (Fix A1); die drei widersprüchlichen `@AppStorage`-
  Fallbacks (`rawID` in OutputModesView) verschwinden. Seiten-Modelle
  entstehen erst mit der jeweiligen Seiten-Migration (kein Big-Bang).
- Direktzugriffs-Konsolidierung: UserDefaults-Zugriffe außerhalb
  AppPreferences inventarisiert lassen (Report B), nur Neue verhindern
  (CI-Guard aus Phase 0).

**Gate:** Phase-0-Tests grün (beweisen A1-Fix ändert kein gespeichertes
Verhalten), Codex-Review. ~½ Tag.

## Phase 2 — SettingsKit (V3-Bausteine, Theme-Token-basiert)

Neuer Ordner `WhisperM8/Views/Settings/Kit/`:

| Baustein | Ersetzt (Vorkommen) |
|---|---|
| `SettingsSection` (Mono-Uppercase-Label + Indigo-Hairline) | ~57 Card/Section-Stellen |
| `SettingsRow` (Titel/Subtitel/Trailing-Control, Hairline) | Basiszeile überall |
| `SettingsToggleRow` / `SettingsPickerRow` | 22 / 21 |
| `SettingsButtonRow` + ActionCluster | ~30 |
| `SettingsStatusRow` (Punkt + Ton: ok/warn/error/off) | 7 Familien |
| `SettingsCopyCommandRow` + `ClipboardClient` + cancellable `FeedbackState` | 8 + 4 Copy-Stellen (ersetzt `asyncAfter`-Risiken) |
| `SettingsCodeBlock` / `SettingsTextArea` | 6 / 11 |
| `SettingsHelpText(tone:)` | ~50 |
| `SettingsTabs` (Segmented-Tab-Leiste für AI Output/Agent Chats) | neu |
| `SettingsListPanel` (Master-Detail-Liste) | 4 |
| Dünne Wrapper: SliderRow, StepperRow, KeyRecorderRow | 2/1/1 — bewusst nicht überabstrahiert |

Dazu ein interner Preview-Katalog (`SettingsKitPreview`) für beide Modi.
Pure Logik (FeedbackState, StatusTone-Mapping) mit Unit-Tests.

**Delegation:** 1 Codex-Job (Worktree) nach meiner API-Skizze.
**Gate:** Build + Kit-Tests + Codex-Review. ~1 Tag.

## Phase 3 — Navigation & Fenster (Strangler-Start)

- `ControlCenterSection` → 10 neue Cases + Tab-Sub-Routen
  (`ai-output#modes` …). **Alias-Mapping alt→neu** (Report C, vollständige
  Tabelle): `api→transcription`, `outputOverview/history→output`,
  `codex/modes/templates/testLab→ai-output(+Tab)`,
  `claudeCode→agent-chats(+Tab)`, `hotkey/audio→recording`,
  `behavior→general`, Rest 1:1. `WindowRequestCenter` bleibt unverändert.
- Fenster: defaultSize 960×680, minWidth 920.
- Neue Sidebar (V3-Look) rendert die 10 Seiten; jede Seite hostet zunächst
  die **alten Views** — die App ist nach Phase 3 voll funktionsfähig, nur
  neu sortiert.
- Unit-Tests: Routen-Mapping (alle alten IDs → neues Ziel).

**Gate:** Tests + Codex-Review + **User-QA nach eigenem Relaunch**. ~½–1 Tag.

## Phasen 4–9 — Seiten-Migration (je Seite: V3-View mit Kit, ViewModel-Extraktion, Fixes, EN-Sprache, Tests)

Reihenfolge nach Schmerz/Nutzen; pro Phase 1–2 Codex-Jobs im Worktree,
danach Codex-Diff-Review + meine Übernahme:

| Phase | Seite(n) | ViewModel-Extraktion (testbar) | Fixes/Features |
|---|---|---|---|
| 4 | **Recording** | — (reine Prefs) | A2 Doppel-Toggle, A29 Delivery, A28-Hinweis |
| 5 | **AI Output** (4 Tabs, größte) | `OutputModesViewModel` (Regeln aus OutputModesView:279-447), `TemplateEditorModel` (Dirty-State + Save-Validierung A15), `CodexConnectionModel` + `CodexProbeClient` (Status-Dreifachprobe konsolidiert) | A1 sichtbar (ein Picker), A8–A16 |
| 6 | **Agent Chats** (4 Tabs) | `AgentCLIArgumentsPreview` (pure, A18), Notification/Sound-Descriptor | A17, F6, F7 |
| 7 | **Context & Privacy + General** | — | A3, A20, A21, Startup-Platzierung |
| 8 | **Permissions + About** | `PermissionSettingsModel` (Polling cancellable statt Timer), Status-Descriptor | A22, A23; Force-Unwrap-Fixes (AboutView:57 u.a.) |
| 9 | **Output** (Workspace) | `OutputArchiveViewModel` (Latest aus Store = A25, Filter aus OutputHistoryFilter wiederverwendet) | A24, A26 Delete-Confirm, A27 |

Jede Seiten-Phase: EN-Strings (F1), Theme-Tokens statt hartkodierter Farben,
Force-Unwraps/`asyncAfter` im berührten Code beseitigt, betroffene
Referenz-Doc (docs/features/settings/NN-*.md) aktualisiert. ~4–5 Tage gesamt.

## Phase 10 — Cleanup & Abschlussprüfung

- Alte Views + tote `ControlCenterSection`-Cases löschen; Sprachreste-Sweep.
- Referenz-Docs auf neue Struktur umziehen (Codex, doc-system-Konventionen).
- **Abschluss-Gates:** kompletter `swift test`-Lauf · Codex-Full-Review des
  Gesamt-Diffs · Opus-Gegenprüfung gegen die Rückwärts-Checkliste (02c):
  kein Control verloren · User-QA in Dark + Light nach eigenem Relaunch.
~1 Tag.

---

## Zusammenfassung

- **Aufwand:** ~8–9 Arbeitstage, stark parallelisierbar über Codex-Jobs.
- **Nach jeder Phase shipbar** (Strangler-Muster: alte Views laufen weiter,
  bis ihre Ersatzseite fertig ist).
- **Sicherheit:** Kompatibilitäts-Vertrag eingefroren, Phase-0-Tests als
  Regressions-Netz, doppelte Reviews (Codex + ich), User-QA-Punkte nach
  Phase 3 und je Seiten-Block.
