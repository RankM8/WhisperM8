# Subagent 04 - Chat-, Session- und Project-Domainlogik

## Kurzbefund

Der Agent-Chat-Bereich hat gute Einzelservices, aber die Domänenkoordination sitzt stark in `AgentChatsView.swift`. Dadurch entstehen fragile Snapshot-, Timing- und UI-Lifecycle-Abhaengigkeiten.

## Konkrete Stellen

- `WhisperM8/Views/AgentChatsView.swift:157`: `onAppear` initialisiert Runtime-Services, laedt Workspace, synchronisiert `AppState.activeAgentChat` und startet Icon-Auto-Detect.
- `WhisperM8/Views/AgentChatsView.swift:177`: `syncActiveAgentChat()` schreibt direkt in `AppState.shared`.
- `WhisperM8/Views/AgentChatsView.swift:804`: Runtime-Service-Lazy-Init in der View.
- `WhisperM8/Views/AgentChatsView.swift:909`: `refreshSessionsInBackground` umfasst Index-Cache, beide Indexer, Store-Merge, Stale-Close, Auto-Naming und Summary-Generation.
- `WhisperM8/Views/AgentChatsView.swift:1042`, `1061`, `1102`: Auto-Naming und Summary-In-Flight-State liegen in der View.
- `WhisperM8/Views/AgentChatsView.swift:1142` vs. `1163`: unterschiedliche Filterlogik fuer sichtbare Sessions und Auswahl; Risiko, dass Selection auf nicht sichtbare Sessions zeigt.
- `WhisperM8/Views/AgentChatsView.swift:1206`: `createSession` enthaelt Provider-Policy, z. B. Claude bekommt vorab eine UUID als `externalSessionID`.
- `WhisperM8/Views/AgentChatsView.swift:2701`: `AgentSessionDetailView` startet Terminal-Prozesse, baut Commands, schreibt Store-Status, bindet externe IDs und scannt Indexer.
- `WhisperM8/Views/AgentChatsView.swift:2839`: `bindExternalSessionIDWhenAvailable` wartet fix 1,5 Sekunden und scannt nur 20 Sessions.
- `WhisperM8/Services/AgentSessionStore.swift:362`: Binding an indexed Session nutzt Zeitfenster um `createdAt`; parallele Starts im selben Projekt koennen falsch binden.
- `WhisperM8/Services/AgentSessionStore.swift:384`: `mergeIndexedSessions` macht Import, Projektanlage, Migration, Cleanup, Matching und Defaults in einer Methode.
- `WhisperM8/Services/AgentSessionIndexer.swift:231`: Codex erwartet `session_meta` in der ersten JSONL-Zeile.
- `WhisperM8/Services/AgentSessionIndexer.swift:369`: Claude liest nur begrenzte Lines/Bytes; spaetere Titel koennen fehlen.
- `WhisperM8/Services/AgentSessionTranscript.swift:173`: Runtime-Status, Provider-Formatwissen und Statusentscheidung sitzen zusammen.
- `WhisperM8/Services/AgentSessionAutoNamer.swift:342`: Auto-Naming haengt absichtlich an einer reihenfolgeempfindlichen Snapshot-Logik.
- `WhisperM8/Models/AgentChat.swift:271`: UI-Text und Icons/Farben liegen im Modell.
- `WhisperM8/Models/TranscriptContextBundle.swift:113`: Anzeige-Strings liegen im Kontextmodell.

## Refactor-Grenzen

- `AgentWorkspaceRepository`: Laden/Speichern/Migration.
- `AgentSessionRefreshCoordinator`: Indexing, Merge, Reload.
- `AgentSessionLifecycleCoordinator`: Start/Resume/Terminate/External-ID-Bind.
- `AgentSessionPresentation`: Labels, Farben, Filter fuer Sidebar/Tabs.
- `AgentTranscriptProviderAdapter`: Parser, Locator, Indexer pro Provider.
- `AgentSessionEnrichmentCoordinator`: Auto-Naming und Summary-Generierung.
