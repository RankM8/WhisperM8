# WhisperM8 Refactoring Findings

## Hoch

### H1 - `AgentChatsView.swift` ist Root-View, Coordinator und Service-Orchestrierung zugleich

- Referenzen: `WhisperM8/Views/AgentChatsView.swift:15`, `157`, `804`, `909`, `1042`, `1102`, `1206`, `2701`
- Warum wartungsrelevant: Die Datei enthaelt UI-Komposition, Store-Mutationen, Indexing, Runtime-Watcher-Setup, Auto-Naming, Summary-Generierung, Terminal-Lifecycle, DnD und AppKit-Fensterlogik. Jede UI-Aenderung kann Domainverhalten beruehren.
- Ansatz: Erst mechanisch in View-Dateien splitten, danach `AgentChatsStateController`, `AgentSessionRefreshCoordinator`, `AgentSessionLifecycleCoordinator`, `AgentSessionEnrichmentCoordinator` einfuehren.

### H2 - `RecordingCoordinator` ist zu breit und zu schwer testbar

- Referenzen: `WhisperM8/Services/RecordingCoordinator.swift:36`, `59`, `141`, `366`, `492`
- Warum wartungsrelevant: Aufnahme, Kontext, Overlay, Transkription, Postprocessing, Clipboard/Auto-Paste, Reporting und Fehlerbehandlung laufen in einem Ablaufobjekt. Die wichtigste User-Journey ist dadurch kaum automatisiert absicherbar.
- Ansatz: Vor Verhaltensrefactors Testseams einfuehren: `AudioRecording`, `OverlayControlling`, `PasteDelivering`, `KeychainProviding`, `TranscriptionServiceFactory`, `Clock/Sleeper`, `WorkspaceProviding`.

### H3 - JSON-Store kann bei parallelen Updates Lost Updates erzeugen

- Referenzen: `WhisperM8/Services/AgentSessionStore.swift:10`, `36`, `83`, `147`, `213`, `226`, `384`
- Warum wartungsrelevant: UI, Runtime-Watcher, Auto-Namer, Summarizer und Indexing koennen denselben Workspace ueber getrennte `loadWorkspace`/`saveWorkspace`-Zyklen veraendern.
- Ansatz: `AgentWorkspaceRepository` mit serialer Mutations-API oder Actor/Queue. Migration und Merge-Policy getrennt halten. Tests fuer konkurrierende Writes vorziehen.

### H4 - Session-Lifecycle und External-ID-Bind sind timing-sensibel

- Referenzen: `WhisperM8/Views/AgentChatsView.swift:2839`, `WhisperM8/Services/AgentSessionStore.swift:362`
- Warum wartungsrelevant: `bindExternalSessionIDWhenAvailable` wartet fix 1,5 Sekunden und scannt begrenzt. Binding ueber Zeitfenster kann bei parallelen Starts falsch zuordnen.
- Ansatz: Lifecycle-Coordinator mit explizitem Polling/Retry, Provider-spezifischer Bind-Policy und tests fuer parallele Starts.

### H5 - Build-Setup hat stale Xcode-/Script-Pfade

- Referenzen: `Makefile:56`, `Makefile:147`, `scripts/build.sh`, `scripts/run.sh`, `WhisperM8.xcodeproj/project.pbxproj`, `WhisperM8/Info.plist:22`
- Warum wartungsrelevant: `make`/SwiftPM ist der reale Build-Pfad, Xcode-Projekt und Skripte koennen falsche Bundle-ID/Dependencies/Signing erzeugen.
- Ansatz: `make dev` als kanonisch dokumentieren; alte Skripte auf Makefile umleiten oder Xcode-Projekt synchronisieren. Version/Bundle-ID/Ressourcen zentralisieren.

## Mittel

### M1 - DnD-Ordering ist in der View und hat Self-Drop-/Hidden-Session-Risiken

- Referenzen: `WhisperM8/Views/AgentChatsView.swift:963`, `970`, `973`, `1015`, `1748`
- Warum wartungsrelevant: Self-drop kann Session ans Ende verschieben. UI zeigt teils nur sichtbare/manuelle Sessions, Drop-Logik bezieht alle nicht archivierten Sessions ein.
- Ansatz: Pure Ordering-Helper extrahieren, Self-drop als No-op absichern, Tests fuer stale IDs und sichtbare vs. persistierte Reihenfolge.

### M2 - Menues und Commands sind dupliziert und nicht macOS-zentral

- Referenzen: `WhisperM8/WhisperM8App.swift:26`, `WhisperM8/Views/AgentChatsView.swift:749`, `1386`, `1783`, `1897`
- Warum wartungsrelevant: Session-Aktionen sind mehrfach definiert und koennen driften. Wichtige Desktop-Aktionen fehlen in `.commands`.
- Ansatz: `AppCommand`/`AppRoute`, Focused Actions und gemeinsame Menu-Builder fuer Session/Project-Aktionen.

### M3 - Window-Routing ist indirekt an MenuBar-Label gebunden

- Referenzen: `WhisperM8/Services/WindowRequestCenter.swift:59`, `WhisperM8/WhisperM8App.swift:43`
- Warum wartungsrelevant: `WindowRequestHandler` haengt am `MenuBarIcon`; Routing ist schwer zu erkennen und potenziell lifecycle-sensibel.
- Ansatz: Routing-Host in App-Shell explizit platzieren; `outputDashboard`-Route korrigieren.

### M4 - Theme/AppKit-Interop hat doppelte Autoritaeten und duplizierte Farben

- Referenzen: `WhisperM8/Support/ThemeManager.swift:20`, `42`, `63`, `WhisperM8/Views/AgentChatsView.swift:2381`, `2406`, `3074`, `3184`, `WhisperM8/Views/AgentTerminalPalette.swift:63`
- Warum wartungsrelevant: SwiftUI Scene-Override, globale `NSApp.appearance`, Window-Background und Terminal-Palette koennen auseinanderlaufen.
- Ansatz: zentrale Theme-Tokens fuer SwiftUI/AppKit/Terminal, typisierter Theme-Notification-Kanal, isolierter Window-Configurator.

### M5 - `OutputDashboardView.swift` ist gross und enthaelt mehrere Feature-Flows

- Referenzen: `WhisperM8/Views/OutputDashboardView.swift:35`, `138`, `254`, `558`, `876`, `1112`, `1232`
- Warum wartungsrelevant: Reports, Tasks, Modes, Templates, Codex und Test Lab sind in einer Datei. Store-Initialisierung in `OutputModesView` ist inkonsistent.
- Ansatz: nach Bereichen splitten; `ReportBrowserView(filter:title:)`; `OutputModesView` ueber `reload()` initialisieren.

### M6 - Tests sind breit, aber kritische Integrationspfade fehlen

- Referenzen: `Tests/WhisperM8Tests/AgentChatsTests.swift:1`, `Tests/WhisperM8Tests/OutputDashboardTests.swift:6`, `WhisperM8/Services/RecordingCoordinator.swift:36`
- Warum wartungsrelevant: Refactors an Recording/Paste/Overlay/Postprocessing waeren kaum abgesichert.
- Ansatz: erst Testseams, dann schmale Coordinator-Tests und HTTP/Pasteboard-Stubs.

### M7 - Model- und UI-/Storage-Logik sind teils vermischt

- Referenzen: `WhisperM8/Models/AgentChat.swift:18`, `271`, `319`, `WhisperM8/Models/TranscriptContextBundle.swift:113`, `WhisperM8/Models/OutputMode.swift:182`, `WhisperM8/Models/PostProcessingTemplate.swift:12`
- Warum wartungsrelevant: Modelle lesen Preferences/Stores oder liefern UI-Texte/Farben. Pure Tests und Domain-Refactors werden indirekter.
- Ansatz: Presenter/Formatter/Store-Layer extrahieren; Model-Defaults rein halten.

## Niedrig

### L1 - UTI-Strings sind doppelt gepflegt

- Referenzen: `WhisperM8/Views/AgentDragDropTypes.swift:37`, `WhisperM8/Info.plist:38`
- Ansatz: zentrale Konstanten plus Test gegen `Info.plist`.

### L2 - `Transcribing`/`TranscriptionRequest` wirken ungenutzt

- Referenzen: `WhisperM8/Services/TranscriptionService.swift:9`
- Ansatz: entfernen oder als primaeres Interface integrieren.

### L3 - `PostProcessingService.didTimeout` ist thread-sensibel

- Referenzen: `WhisperM8/Services/PostProcessingService.swift:198`, `207`, `231`
- Ansatz: unter gleichem Lock/serial Queue lesen und schreiben.

### L4 - Audio-Tap-Code ist dupliziert

- Referenzen: `WhisperM8/Services/AudioRecorder.swift:141`, `334`
- Ansatz: `installRecordingTap(...)` extrahieren; spaeter Recording-Queue pruefen.

### L5 - Force-Cast in SelectedContextService ist vermeidbar

- Referenz: `WhisperM8/Services/SelectedContextService.swift:53`
- Ansatz: `guard let focusedElement = focusedValue as? AXUIElement` oder kleine AX-Wrapper-Funktion.

### L6 - Version ist hard-coded in der UI

- Referenzen: `WhisperM8/Views/SettingsView.swift:748`, `WhisperM8/Info.plist:24`
- Ansatz: aus `Bundle.main` lesen.

### L7 - Doku ist teils veraltet

- Referenzen: `AGENTS.md`, `docs/ARCHITECTURE.md`, `Package.swift`
- Ansatz: nach Refactor-Plan Build-/Architektur-Doku aktualisieren, besonders `LSUIElement=false`, SwiftTerm und fehlendes `ISSoundAdditions`.
