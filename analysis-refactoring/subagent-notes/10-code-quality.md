# Subagent 10 - Allgemeine Codequalitaet

## Kurzbefund

Die groesste Qualitaetslast liegt in grossen, gemischten Dateien und impliziter Shared-State-Kopplung. Daneben gibt es mehrere kleine Low-Risk-Hygiene- und Threading-Kandidaten.

## Befunde

- Grosse Dateien: `AgentChatsView.swift` 3208 LOC, `OutputDashboardView.swift` 1332 LOC, `RecordingCoordinator.swift` 884 LOC, `SettingsView.swift` 765 LOC.
- `WhisperM8/Views/OutputDashboardView.swift:558`: `OutputModesView` legt `store`/`templateStore` als State an, initialisiert `modes`/`templates` aber aus neuen Store-Instanzen.
- `WhisperM8/Views/OutputDashboardView.swift:138` und `254`: `TranscriptReportsView` und `TaskReportsView` duplizieren Laden, Selektion und Loeschen desselben Report-Typs.
- `WhisperM8/Services/TranscriptionService.swift:9`: `Transcribing` und `TranscriptionRequest` sind definiert, aber offenbar nicht genutzt.
- `WhisperM8/Models/AppState.swift:50` vs. `WhisperM8/Services/RecordingCoordinator.swift:91`: `lastSelectedOutputModeID` wird geschrieben, Recording startet aber immer mit `OutputMode.defaultMode()`.
- `WhisperM8/Services/PostProcessingService.swift:198`, `207`, `231`: `didTimeout` wird auf globaler Queue geschrieben und ohne Lock gelesen.
- `WhisperM8/Services/PostProcessingService.swift:183`: Prozess wird erst nach `run()` registriert; kleines Cancel-Fenster.
- `WhisperM8/Services/AudioRecorder.swift:141` und `334`: Tap-Installation ist dupliziert.
- `WhisperM8/Services/AudioRecorder.swift:198` und `392`: Audio-Tap nutzt Shared State, waehrend Stop/Restart denselben State veraendern koennen.
- `WhisperM8/Services/SelectedContextService.swift:53`: vermeidbarer Force-Cast nach Type-ID-Check.
- `WhisperM8/Services/VisualContextCaptureService.swift:230` und `410`: `@unchecked Sendable` mit mutable Delegate-/Continuation-State.
- `WhisperM8/Models/OutputMode.swift:182`: Model-API instanziiert `OutputModeStore` direkt.
- `WhisperM8/Services/AudioRecorder.swift:2`: `import Combine` wirkt ungenutzt.

## Beste Low-Risk-Refactors

- `OutputDashboardView` entlang bestehender View-Bloecke splitten.
- `OutputModesView` Store-Initialisierung vereinheitlichen.
- Report-Browser-Komponente fuer Transcript/Task Reports extrahieren.
- `Transcribing`/`TranscriptionRequest` entfernen oder als primaeres Interface nutzen.
- Audio-Tap-Code extrahieren.
- `PostProcessingService.didTimeout` synchronisieren.
