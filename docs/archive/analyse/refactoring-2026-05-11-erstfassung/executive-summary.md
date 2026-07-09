# Executive Summary

Die App ist funktional breit gewachsen. Der groesste Refactoring-Hebel liegt nicht in einem einzelnen Bug, sondern in Verantwortungsgrenzen.

## Wichtigste Erkenntnisse

- `WhisperM8/Views/AgentChatsView.swift` ist mit 3208 Zeilen der Hauptkandidat. Es mischt SwiftUI-Komposition, Store-Zugriffe, Indexing, Runtime-Watcher, Auto-Naming, Summaries, Drag-and-Drop, Terminal-Lifecycle und AppKit-Window-Konfiguration.
- `WhisperM8/Services/RecordingCoordinator.swift` ist der kritischste Flow-Koordinator. Er sollte erst nach Testseams zerlegt werden, weil er Aufnahme, Kontext, Transkription, Postprocessing, Clipboard, Auto-Paste und Reports verbindet.
- `AgentSessionStore` ist dateibasiert und nutzt viele Read-Modify-Write-Pfade ohne Serialisierung. Lost Updates sind bei parallelen Auto-Namer/Summarizer/Watcher/Indexer/UI-Aktionen moeglich.
- Drag-and-Drop ist gut angelegt, hat aber konkrete Edge Cases: Self-drop, sichtbare vs. persistierte Sessions, doppelte UTI-Strings.
- Theming/AppKit-Interop funktioniert, ist aber ueber mehrere Stellen verteilt. Window-Background, SwiftUI-Theme und Terminal-Palette sollten gemeinsame Tokens nutzen.
- Tests laufen durch: 148 Tests, 0 Fehler. Coverage ist gut fuer pure Helpers/Stores, aber schwach fuer Recording/Paste/Overlay/HTTP-Flows.
- Build-Setup: `Makefile` + SwiftPM ist kanonisch. Das Xcode-Projekt und alte `xcodebuild`-Skripte wirken stale und sollten nicht als gleichwertige Build-Quelle gelten.

## Hoechste Prioritaet

1. Tests/Guardrails fuer DnD, Store-Mutationen und kritische Refactor-Kanten.
2. Mechanischer Split von `AgentChatsView.swift` und `OutputDashboardView.swift`.
3. Pure Presenter/Ordering/Theme/GitStatus-Helper extrahieren.
4. Agent-Chat-Koordinatoren einfuehren: Workspace, Refresh, Lifecycle, Enrichment, Selection.
5. RecordingCoordinator erst danach mit Testseams zerlegen.

## Risiko-Hinweis

Bundle-ID, Signing, `LSUIElement`, Installationspfad, Entitlements und TCC-Verhalten duerfen nicht nebenbei in Refactor-PRs geaendert werden. Diese Aenderungen brauchen eigene Migration/QA.
