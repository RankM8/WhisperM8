# Neustart ohne Chatverlust: Übersicht für das Gesamt-Review

Stand 13.11.2026, Sammel-Branch `neustart/integration` 17dae135 gegenüber `main` b5f6f9ad. Plan und Mechanik: [neustart-ohne-chatverlust.md](neustart-ohne-chatverlust.md), Vertrag des Aufbewahrers: [neustart-aufbewahrer.md](../features/agent-chats/neustart-aufbewahrer.md). Handtest für den ersten echten Lauf: [neustart-ohne-chatverlust-handtest.md](neustart-ohne-chatverlust-handtest.md).

Der Schalter ist `restartKeepsChatsEnabled` (Standard aus, Labs-Seite ausgehängt). Pakete 0 bis 3 (Aufbewahrer, Router-Dienst) sind schon in `main`; hier steht nur, was der Sammel-Branch darüber hinaus ändert.

## 1. Wirkt bei jedem Chat, auch mit Schalter aus

Das sind die Stellen, an denen ein Fehler alle Nutzer träfe. Jede ist so gebaut, dass sie ohne Schalter das bisherige Verhalten liefert.

| Änderung | Dateien | Tests | Urteil Vic |
|---|---|---|---|
| SwiftTerm-Fork mit Ablösen, Übernehmen, Ende per kqueue (Pin `ce47a2c` statt main-Pin) | `Package.swift`, Fork `whisperm8-handover` | Fork-Tests; `HandoverTerminalControllerTests` | Paket 1 merge ja, Fork-Befunde 1–7 behoben |
| Ende eines Chats über die Registry statt über die Ansicht (Store, Status, dann Ansicht) | `AgentChatTermination.swift`, `AgentTerminalRegistry.swift`, `AgentTerminalView.swift`, `AgentChatsView+Grid.swift` | `AgentChatTerminationTests` | merge ja (Befund 1: `.inert` nur in Tests) |
| Start ruft `HandoverTakeService.takeAtLaunch`; ohne Marker „übergeben“ und ohne lebenden Aufbewahrer kostet das gemessene 6 ms, kein Socket | `WhisperM8App.swift`, `HandoverTakeService.swift` | `testNormalStartCostsNoSocketWait`, `testStaleDiscoveryIsRemovedWithoutWaiting` | Startbremse 525 ms → 6 ms, merge ja |
| `make dev` fragt vor dem Beenden `app handover`; mit Schalter aus antwortet die App „classic“, dann wie bisher `kill`. Wartet nur, wenn die App gerade startet oder übernimmt (`take.lock`), mit sichtbarer Meldung | `Makefile` (`_handover`), `HandoverCommands.swift` | `testMakefileTriesHandoverBeforeKillAndSparesKeeper`, `testHandoverWaitsForARunningTake` | merge ja; Grenze 65 s im Plan |
| Absturz-Wiederaufnahme plant mit laufenden Chats (`alreadyStarted`) und Gus' Halter-Regel samt Hinweis am übersprungenen Chat | `AgentCrashRecovery.swift`, `HandoverPlanning.swift` | `testCrashRecoverySkipsADoubleOfAnAdoptedChat`, `AgentCollectiveStartPlannerTests` | merge ja (Merge 5bb84874 nach Vics Anleitung) |
| `chats show` und `recent` schneller: Suche der Sitzung per `memmem`, rotierte Datei nur bei Bedarf (270 ms → 2 ms am echten Journal) | `ChatsStatusJournal.swift` | `testJournalRecentAlsoReadsTheRotatedFile`, `testLineRangesFindOnlyLinesWithTheNeedle` | in Ordnung, Großschreibung der UUID am Journal geprüft |
| Ansicht startet nichts, solange die Registry Starts verweigert (nur nach einer Abgabe der Fall) | `AgentCommandBuilder.swift`, `AgentSessionDetailView.swift` | `testRegistryRefusesStartsAfterHandover` | merge ja |
| Keine Geheimnisse und Tokens im Log, geschwärzte Beschreibungen, Quellprüfung | `HandoverRedaction.swift` | `HandoverRedactionTests` | merge ja, drei Nacharbeiten erledigt |
| Testskripte (Test-Instanz, Dauerlauf, Fehler-Szenarien) | `scripts/test-instance.sh`, `scripts/handover-soak*.sh` | `self-test` der Skripte | nur Test-Instanz |

## 2. Wirkt nur mit Schalter an

| Änderung | Dateien | Tests | Urteil Vic |
|---|---|---|---|
| Abgabe beim Neustart: Ablösen, Manifest (Startkommando, Token, offene Bindung, „arbeitet seit“), Aufbewahrer starten, `COMMIT`, Marker „übergeben“; kein Start mehr danach | `HandoverRestartService.swift`, `HandoverDepositCoordinator.swift`, `HandoverManifestParts.swift`, `AgentTerminalController+Handover.swift` | `HandoverDepositCoordinatorTests` | Paket 4 merge ja mit Auflagen, alle erledigt |
| Übernahme beim Start: TAKE je Chat, Leitung und Bild, Token, Hooks ab Cursor, Status, Statistik, Kontowechsel | `HandoverTakeService.swift`, `HandoverTakeService+Live.swift`, `StatisticsCollectors.swift` | `HandoverTakeServiceTests` | merge ja |
| Bindung übernommener Chats gegen Claudes Registry abgleichen (Punkt d), offene Bindung im Manifest (Punkt c) | `AgentSessionStatusCoordinator.swift` | `testAdoptedChatIsRebindWhenStoredIDRunsElsewhere` u. a. | merge ja ohne Auflage |
| Rückfall: nie zwei Prozesse; SIGKILL nur für fortzusetzende Chats mit bekannter Startzeit; Sammelstart-Planer mit Belegen; auch unterdrückte Grid-Panes starten; Chats ohne Sitzungs-ID nur ohne nachweisbaren Turn frisch | `HandoverTakeService.swift`, `HandoverFallbackLaunchQueue.swift` | `testOrphanSurvivingSigtermIsKilledAndThenResumed`, `HandoverFallbackLaunchQueueTests` | merge ja (mehrere Runden) |
| Fehler-Szenarien aus Dex' Abnahme: abgelehntes Geheimnis beendet den Aufbewahrer, tote Verbindung sofort Rückfall, Reste eines toten Aufbewahrers weg, Sperre gegen zweite Instanz | `HandoverTakeService.swift`, `HandoverKeeper+Session.swift` | `HandoverTakeHelloTests` | merge ja |
| Größe nach der Übernahme (Prozess bekommt die echte Größe mit der Ansicht) | `AgentTerminalController+Handover.swift` | `testAdoptedChatGetsTheRealSizeOnceTheViewIsLaidOut` | merge ja |

## 3. Kommt mit Option A dazu (`feat/handover-geheimnis-datei`, wartet auf Entscheidung)

| Änderung | Dateien | Tests | Urteil Vic |
|---|---|---|---|
| Einmal-Geheimnis als Datei `take-secret` (0600, 0700-Ordner) statt im Schlüsselbund; Schlüsselbund-Weg bleibt für Option C | `HandoverFileSecretStore.swift`, `HandoverProtocol.swift`, `HandoverKeeper.swift` | `HandoverFileSecretStoreTests`, `testFileSecretCarriesTheTakeAcrossInstances` | merge-bereit, sobald der User A wählt; fünf Auflagen erfüllt |
| Abnahme in der Test-Instanz: Dev auf Dev und ad hoc auf ad hoc je 4 von 4 übernommen, Sichtprüfung im Fenster gut | – | `handover-soak-faults.sh --only binary-swap` | Auflage 4 (nicht selbst nachgestellt) |

Ohne Option A übernimmt die App über zwei Builds hinweg nie (Schlüsselbund bindet an den cdhash), jeder Neustart fällt in den Rückfall.

## 4. Liste „vor dem Einschalten“, Stand

| Punkt | Stand |
|---|---|
| 1 Geheimnis-Weg | Option A+ gewählt (13.11.), Datei gemergt in 074af842; Apple-Konto später |
| 2–5 kein Start nach `COMMIT`, Fortsetzen nach Abgabe-Fehler, Aufbewahrer liest ab `COMMIT`, `app handover` gegen Chats | erledigt |
| 6 Bindungs-Befund a–f | erledigt (a, b, e, f1 Gus; c, d Ole); Bereinigung der Altlasten im echten Workspace wartet auf Freigabe des Users |
| 7 Prüfungen gegen die Wirklichkeit | Größe, Fehler-Szenarien, zehn Chats (134 ms Abgabe, 179 ms Übernahme), beide Signaturarten und Bild im Fenster erledigt; offen: fünfmal `make dev`, erster echter Lauf (Handtest) |
| 9 „arbeitet seit“, 10 `make dev` ohne Steuer-Socket | erledigt |
| 11 Rückfall für Chats ohne Sitzungs-ID | erledigt, mit Verlaufsbeleg und rotiertem Journal |
| 8 Labs-Seite einhängen | als Letztes, nach dem ersten echten Lauf |
| 12 Übergabe nur mit Router-Dienst | erledigt auf `fix/handover-review-teil1` |
