# Subagent 03 - State, Stores, Persistenz und Modelle

## Kurzbefund

Persistenz und globaler Zustand sind pragmatisch, aber stark gekoppelt. Mehrere Pfade lesen und schreiben dieselbe JSON-Datei per Read-Modify-Write ohne Serialisierung. Das ist fuer Refactors riskant, weil Auto-Namer, Summarizer, Runtime-Watcher, UI-Drops und Indexing zeitlich ueberlappen koennen.

## Befunde

- `WhisperM8/Models/AppState.swift:3`: `AppState.shared` ist `@MainActor @Observable`, liest aber indirekt `AppPreferences.shared` und Stores schon beim Init.
- `WhisperM8/Services/RecordingCoordinator.swift:36`: nur ein Teil der Abhaengigkeiten ist injizierbar. `AudioRecorder`, `OverlayController`, `PasteService`, `VisualAttachmentDeliveryBuilder`, `TranscriptionSettings`, `KeychainManager` und `AppPreferences` sind teils fest verdrahtet.
- `WhisperM8/Support/AppPreferences.swift:3`: `static var shared` ist mutable global state; der Initializer migriert sofort.
- `WhisperM8/Models/TranscriptionProvider.swift:106`: Migration bricht ab, sobald `selectedModelRaw != nil`; inkonsistente Provider/Model-Kombinationen werden nicht zwingend repariert.
- `WhisperM8/Services/KeychainManager.swift:5`: statische API plus UserDefaults-Migration ist nicht injizierbar; `exists()` kann true liefern, obwohl `load()` spaeter scheitert.
- `WhisperM8/Services/AgentSessionStore.swift:10`: JSON-Store ohne Lock/Queue; konkurrierende Saves koennen Updates verlieren.
- `WhisperM8/Services/AgentSessionStore.swift:25`: `loadWorkspace()` migriert destruktiv und speichert mit `try?`; bei Save-Fehler ist In-Memory-State bereinigt, Disk aber nicht.
- `WhisperM8/Services/AgentSessionStore.swift:213`: `reorderProjects`/`reorderSessions` validieren nicht, dass `orderedIDs` komplett sind. Fehlende IDs behalten alte `sortIndex`-Werte; Duplikate/Gaps moeglich.
- `WhisperM8/Services/AgentSessionStore.swift:445`: gesetzter `sortIndex` gewinnt immer gegen `nil`; neue importierte Elemente sinken hinter manuell sortierte Eintraege.
- `WhisperM8/Services/OutputModeStore.swift:67`: `Dictionary(uniqueKeysWithValues:)` crasht bei doppelten IDs in korrupter/handeditierter JSON.
- `WhisperM8/Models/PostProcessingTemplate.swift:12`: Modell-Rendering liest `AppPreferences.shared.codexVisualInputModeRaw`.
- `WhisperM8/Services/TranscriptRunReportStore.swift:44`: Attachments werden vor Report-Write kopiert; bei nachfolgendem Fehler bleiben verwaiste Dateien.

## Testluecken

- konkurrierende Store-Writes
- korrupte JSON-Dateien und doppelte IDs
- unvollstaendige `orderedIDs`
- fehlgeschlagene Migration-Saves
- Provider/Model-Inkonsistenzen
