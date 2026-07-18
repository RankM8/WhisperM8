# cmux

## Umfang und Kurzfazit

cmux ist wie WhisperM8 kein eigener Agent-Chat-Runtime-Ersatz, sondern eine native macOS-Hülle um echte Terminalprozesse. Der entscheidende Unterschied liegt im Terminalkern: cmux bettet `libghostty` direkt ein und trennt die langlebige Pane-/Surface-Identität von SwiftUI-Views und vom jeweiligen nativen Runtime-Pointer. Agent-Status kommt bevorzugt aus semantischen Hooks; OSC 9/99/777 ist ein davon getrennter, surfacegenauer Notification-Eingang.

Die drei stärksten Muster für WhisperM8 sind:

1. Terminalmodell und PTY-Lebensdauer von `NSViewRepresentable` entkoppeln.
2. Hooks als Statuswahrheit verwenden und OSC nur als Attention-Fallback behandeln.
3. Fork als zweiphasigen Identitätswechsel modellieren; Parent-ID und Child-ID nie implizit gleichsetzen.

Vorgesehener Ablagepfad: `docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/cmux.md`.

## Projektüberblick und relevante Dateien

Stack: native macOS-App in Swift, AppKit und SwiftUI; Terminalemulation und PTY-Prozessführung über `libghostty`/`GhosttyKit`, Metal-Rendering in einer nativen `NSView` (`README.md:90-93`, `README.md:121-127`, `README.md:324-330`).

| Bereich | Code-Beleg |
|---|---|
| SwiftUI/AppKit-Brücke | `Sources/GhosttyTerminalView.swift:12067-12085`, `Sources/GhosttyTerminalView.swift:12258-12339` |
| Native View-Kette | `Sources/TerminalSurfaceRuntimeWiring.swift:24-33` |
| Stabile Surface-Identität | `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift:61-76`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift:147-180` |
| libghostty-Surface-Erzeugung | `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeSurfaceCreation.swift:21-38`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeSurfaceCreation.swift:239-297` |
| Teardown | `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Lifecycle/TerminalSurfaceRuntimeTeardownCoordinator.swift:8-14`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Lifecycle/TerminalSurfaceRuntimeTeardownCoordinator.swift:75-172` |
| OSC-Eingang | `Sources/GhosttyTerminalView.swift:2895-2910`, `Sources/GhosttyDesktopNotificationIngress.swift:3-65` |
| Hook-/Session-Store | `CLI/cmux.swift:129-213`, `CLI/cmux.swift:239-275` |
| Hook-Statusprojektion | `CLI/cmux.swift:24256-24360`, `CLI/cmux.swift:31671-31718` |
| Fork-Schutz | `CLI/cmux.swift:24018-24038`, `CLI/cmux.swift:24553-24595` |

## 1. Native Terminaleinbettung

### Aufbau

`TerminalSurface` ist der langlebige Swift-Owner einer Pane. Er besitzt eine stabile UUID, die Workspace-ID und separat den optionalen `ghostty_surface_t`. Eine monotone `runtimeSurfaceGeneration` steigt beim Installieren oder Entfernen des nativen Handles; damit bleibt ein wiederverwendeter Pointer nicht versehentlich gültig (`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift:61-76`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift:147-180`).

Die konkrete View-Kette ist `GhosttyNSView` in `GhosttySurfaceScrollView` (`Sources/TerminalSurfaceRuntimeWiring.swift:24-33`). Beim Erzeugen der nativen Surface erhält Ghostty den AppKit-`NSView`-Pointer, einen retained Callback-Kontext, Scale-Faktor, Kommando, CWD, Initialinput und Environment (`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeSurfaceCreation.swift:21-50`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeSurfaceCreation.swift:239-297`). Normale Terminals brauchen daher keinen zweiten Swift-`Process` und keinen selbstgebauten PTY-Parser.

`GhosttyNSView.makeBackingLayer()` stellt einen `GhosttyMetalLayer` auf Basis von `CAMetalLayer` bereit (`Sources/GhosttyTerminalView.swift:3641-3675`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/View/GhosttyMetalLayer.swift:5-14`). Das Host-Composite legt Status-, Ring- und Flash-Overlays über die native Terminaldarstellung (`Sources/GhosttyTerminalView.swift:8107-8149`, `Sources/GhosttyTerminalView.swift:8397-8498`).

### Warum SwiftUI die CLI nicht verliert

`GhosttyTerminalView: NSViewRepresentable` erzeugt nur einen leeren Host-Anker. Die echte Terminalview lebt in einer AppKit-Portalschicht über SwiftUI (`Sources/GhosttyTerminalView.swift:12067-12085`, `Sources/GhosttyTerminalView.swift:12258-12265`). Updates prüfen Pane-Eigentümer, Host-Instanz und Generation, bevor sie die langlebige View neu binden (`Sources/GhosttyTerminalView.swift:12305-12339`, `Sources/GhosttyTerminalView.swift:12434-12465`). `TerminalPanelView` hält zusätzlich die Representable-Identität mit `.id(panel.id)` stabil (`Sources/Panels/TerminalPanelView.swift:69-99`).

`dismantleNSView` bereitet lediglich den transienten Reattach vor; die echte Surface wird nicht an den Lebenszyklus des SwiftUI-Platzhalters gekoppelt (`Sources/GhosttyTerminalView.swift:12670-12720`). Das ist stärker als eine direkte Kopplung „SwiftUI-View besitzt PTY“: Split- oder Tab-Rebuilds dürfen die Darstellung austauschen, ohne den echten CLI-Prozess zu zerstören. Der Preis ist hohe Portal-, Lease- und Reparenting-Komplexität.

### PTY-/Runtime-Robustheit

- Ghostty-Wakeups werden gelockt auf einen Main-Queue-Tick coalesced (`Sources/GhosttyTerminalView.swift:1720-1743`).
- Beim Reattach wird die Display-ID erneut gesetzt, damit eine verschobene Surface weiter rendert (`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeLifecycle.swift:460-468`).
- Der PTY-Output-Tee wird nach Surface-Erzeugung mit Workspace- und Surface-ID installiert (`Sources/TerminalSurfaceRuntimeWiring.swift:93-115`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeLifecycle.swift:558-570`).
- Vor dem Free wird der native Pointer aus Ownerzustand und Registry entfernt. `ghostty_surface_free` läuft seriell außerhalb des Close-Pfads; Callback-, Manual-I/O- und Tee-Userdata bleiben bis nach dem nativen Free retained, weil erst dieser Ghosttys I/O-Threads joint (`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift:611-680`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Lifecycle/TerminalSurfaceRuntimeTeardownCoordinator.swift:75-172`).
- Restore-Spawns werden dedupliziert und zeitlich gepaced, um Lastspitzen durch viele Login-Shells zu vermeiden (`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Lifecycle/TerminalSurfaceRestoreSpawnScheduler.swift:3-18`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Lifecycle/TerminalSurfaceRestoreSpawnScheduler.swift:36-90`).
- App-Snapshots speichern Layout, CWD, begrenzten Scrollback und Resume-Bindings; beliebiger Live-Prozesszustand wird nicht checkpointed (`README.md:251-261`, `Sources/SessionPersistence.swift:13-34`, `Sources/SessionPersistence.swift:1379-1415`).

## 2. Hooks und OSC werden in Terminalzustand übersetzt

cmux hat zwei getrennte Signalwege.

### OSC: surfacegenaue Aufmerksamkeit

Der Swift-Code parst OSC nicht selbst. `libghostty` meldet eine `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`; cmux extrahiert Titel und Body und hängt das Ereignis an `tabId` plus `surfaceId` (`Sources/GhosttyTerminalView.swift:2895-2910`). App-target-Notifications werden bewusst als No-op behandelt, weil Ghosttys Desktop-Notification-Action von einer Surface stammen soll (`Sources/GhosttyTerminalView.swift:2642-2645`).

Ein begrenzter `AsyncStream` wahrt die Reihenfolge, blockiert den C-Callback nicht und verwirft unter Dauerflut die ältesten Einträge (`Sources/GhosttyDesktopNotificationIngress.swift:3-45`). Vor Zustellung wird der aktuelle Surface-Eigentümer erneut aufgelöst (`Sources/GhosttyDesktopNotificationIngress.swift:49-65`). Nach der asynchronen Auflösung konfigurierbarer Notification-Hooks wird das Ziel ein zweites Mal validiert und gegebenenfalls auf den neuen Live-Eigentümer retargetet (`Sources/TerminalNotificationStore+HookResolution.swift:15-20`, `Sources/TerminalNotificationStore+HookResolution.swift:37-64`).

Die Notification landet im `TerminalNotificationStore`, dessen `@Published`-Zustand surfacegenaue Unread-Indizes, Sidebar-Badge und Pane-Ring treibt (`Sources/TerminalNotificationStore.swift:352-368`, `Sources/TerminalNotificationStore.swift:492-510`). Der Ring wird als AppKit/Core-Animation-Overlay auf der langlebigen Ghostty-View dargestellt (`Sources/GhosttyTerminalView.swift:8462-8480`, `Sources/GhosttyTerminalView.swift:9300-9317`). `TerminalPanelView` reicht ihn nur bei ungelesener Notification und aktivierter Einstellung an den stabil identifizierten Host durch (`Sources/Panels/TerminalPanelView.swift:69-99`).

### Hooks: semantischer Agent-Lifecycle

Claude-/Codex-Hooks liefern Session-ID, Turn, CWD, Transcriptpfad und Ereignistyp. Der Hook-Katalog unterscheidet unter anderem SessionStart, UserPromptSubmit und Stop (`CLI/CMUXCLI+AgentHookCatalog.swift:6-27`). Der Hook-Store persistiert Session-, Workspace- und Surface-Zuordnung getrennt von PID und UI-Auswahl (`CLI/cmux.swift:129-213`).

Prompt-Submit setzt die pane-spezifische Lifecycle-Grenze auf `running`, löscht alte Notifications und schreibt den Sidebar-Status (`CLI/cmux.swift:24256-24360`). Stop-/Notification-Pfade schreiben `idle`, `needsInput` oder `error`, senden `set_status` und erzeugen bei Bedarf `notify_target_async` (`CLI/cmux.swift:31619-31651`, `CLI/cmux.swift:31671-31718`). Ein verspätetes Idle wird unterdrückt, wenn eine neuere laufende Session dieselbe Surface besitzt (`CLI/cmux.swift:31543-31555`).

Raw-OSC-Notifications werden für eine Pane unterdrückt, sobald dort ein strukturierter Agent-PID registriert ist (`Sources/Workspace+PanelLifecycle.swift:221-247`). PID-Liveness wird nicht nur über die Nummer geprüft: cmux speichert zusätzlich die Prozessstartidentität, damit eine wiederverwendete PID keinen alten Agentzustand am Leben hält (`Sources/Workspace+PanelLifecycle.swift:126-159`, `Sources/Workspace+PanelLifecycle.swift:199-218`).

Damit konkurriert ein generisches Terminalsignal nicht mit dem reicheren Hook-Zustand. Für WhisperM8 ist das die wichtigste Übersetzung: Hook = Statuswahrheit; OSC = Fallback für Aufmerksamkeit, nicht zweite Lifecycle-Quelle.

## 3. Die fünf Auditfragen

### Session-Identität und aktive Session

Pro Agent werden persistente `sessionId`, `workspaceId` und `surfaceId` gespeichert; PID und Launchkommando sind nur zusätzliche Laufzeitevidenz (`CLI/cmux.swift:129-155`). Die aktive Grenze existiert sowohl pro Workspace als auch pro Surface (`CLI/cmux.swift:204-213`, `CLI/cmux.swift:743-755`). `isCurrent` prüft zuerst die Surface-Grenze, damit ein Geschwister-Pane die eigene Session nicht stale macht (`CLI/cmux.swift:1285-1340`).

Der Live-Index adressiert Agenten pane-genau über Workspace und Panel; tote oder stale PIDs entfernen nicht automatisch die persistente Session-Identität (`Sources/RestorableAgentSession.swift:922-952`, `Sources/RestorableAgentSession.swift:1213-1218`). UI-Auswahl wird separat als ausgewähltes Panel, fokussiertes Panel und Workspace-Index persistiert (`Sources/SessionPersistence.swift:1674-1678`, `Sources/SessionPersistence.swift:1739-1766`, `Sources/SessionPersistence.swift:1816-1820`). Prozess, Agent-ID und UI-Auswahl sind folglich drei verschiedene Dinge.

### Fork und Resume

Resume und Fork sind verschiedene CLI-Übergänge: Claude-Resume wird als `claude --resume <id>` gebaut; Fork als `claude --resume <parent> --fork-session` (`Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentResumeArgv.swift:406-416`, `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentForkArgv.swift:70-86`). Ein vom Host vorab gewähltes Claude-`--session-id` wurde im Forkpfad nicht gefunden; die Child-ID wird von Claude erzeugt.

Claude meldet beim Fork-`SessionStart` zunächst die Parent-ID. cmux schreibt diesen Event deshalb nicht in die neue Pane; die Child-ID wird erst beim ersten `UserPromptSubmit` gebunden (`CLI/cmux.swift:24018-24038`, `CLI/cmux.swift:24303-24342`). Auch ein früher `SessionEnd` darf den Parent-Datensatz nicht konsumieren (`CLI/cmux.swift:24553-24595`).

Prozessscanner behandeln eine nur aus Fork-Argumenten abgeleitete Parent-ID ausdrücklich als schwächeren `forkParentFallback`; sie darf eine hook-gestützte Identität nicht verdrängen (`Sources/VaultAgentProcessScanner+ForkParentFallback.swift:3-53`, `Sources/RestorableAgentSession.swift:1248-1260`). Persistierte Resume-Bindings werden außerdem über Agent-Kind und `checkpointId == sessionId` an den Snapshot gekoppelt (`Sources/Workspace.swift:958-1008`). Das verhindert den klassischen falschen Zweig.

### Verlorene oder nicht wiedergefundene Sessions

Der Hook-Store liegt standardmäßig unter `~/.cmuxterm/`, ist aber per Environment umleitbar (`CLI/cmux.swift:239-267`). Er wird mit Dateisperre gelesen und über temporäre Datei plus atomisches Rename mit restriktiven Dateirechten geschrieben (`CLI/cmux.swift:1482-1490`, `CLI/cmux.swift:1530-1556`). Veraltete Records werden nach einer Altersgrenze bereinigt (`CLI/cmux.swift:239-242`, `CLI/cmux.swift:1559-1576`).

cmux speichert zusätzlich Agent-Snapshot, Scrollback und Resume-Binding im App-Snapshot (`Sources/SessionPersistence.swift:1379-1415`). Wiederherstellung prüft Transcriptexistenz und wechselt bei veraltetem Pfad nur dann auf eine andere JSONL, wenn genau ein eindeutiger Kandidat existiert (`Sources/RestorableAgentSession.swift:1362-1437`, `Sources/RestorableAgentSession.swift:1481-1499`). Es gibt kein unsicheres „neueste Datei gewinnt“.

Für directory-namespaced Agenten wird der stabile Launch-CWD statt eines später driftenden Hook-CWD verwendet, weil die CLI ihre Session andernfalls möglicherweise nicht findet (`Sources/RestorableAgentSession.swift:1573-1615`). Wiederhergestellte Claude-/Codex-Kommandos laufen erneut durch den cmux-Wrapper, damit die echte CLI ihre Hooks wieder erhält (`Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentResumeArgv.swift:387-415`, `Sources/RestorableAgentSession.swift:405-433`).

### Terminal-/PTY-Persistenz

cmux persistiert nicht den laufenden PTY-Prozess, sondern rekonstruiert Layout und Surface und startet anschließend das echte Agent-CLI mit dessen nativer Resume-ID (`README.md:251-261`, `README.md:315-318`). Das entspricht dem harten WhisperM8-Constraint. Robuster als der bloße Restart ist die Trennung zwischen stabiler Surface-ID, nativer Runtime-Generation und SwiftUI-Host-Lease.

Sichtbare PIDs und Running-Status werden beim Restore bewusst nicht als lebende Wahrheit übernommen, weil die Prozesse nach einem Neustart nicht mehr existieren. Erst Resume und neue Hooks rekonstruieren den Live-Status (`Sources/Workspace.swift:238-244`). Dadurch entsteht keine falsche „Running“-Pille aus einem alten Snapshot.

### Multi-Account-Isolation

Eine eigene `accountId` gehört nicht zum Session-Key; harte Isolation gleichlautender Session-IDs ist daher nicht belegt (`CLI/cmux.swift:129-155`, `CLI/cmux.swift:270-275`). Gefunden wurde Config-Root-Isolation: `CLAUDE_CONFIG_DIR` wird in den Terminalprozess übernommen (`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeSurfaceCreation.swift:91-95`), und Hook-Stores können über `CMUX_AGENT_HOOK_STATE_DIR` getrennt werden (`CLI/cmux.swift:251-265`).

`CLAUDE_CONFIG_DIR` und `CODEX_HOME` gehören zur erlaubten, für Resume relevanten Umgebung; beliebige Secrets werden nicht pauschal persistiert (`Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentLaunchEnvironmentPolicy.swift:33-35`, `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentLaunchEnvironmentPolicy.swift:58-115`). Transcript-Recovery bindet sich bei vorhandenem `CLAUDE_CONFIG_DIR` an diesen Root (`Sources/RestorableAgentSession.swift:1896-1934`).

Für WhisperM8 ist cmux hier nur teilweise besser: Config-Root und Store-Root sind transportierbar, aber Account-Identität ist kein Bestandteil des Primärschlüssels.

## 4. Direkter Vergleich zu WhisperM8

Vergleichsbasis ist das im Auditauftrag beschriebene WhisperM8-Modell: echte Claude-Code-CLI in SwiftTerm-PTYs, native CLI-Flags, JSONL und Hooks.

| Thema | cmux gegenüber WhisperM8 |
|---|---|
| CLI bleibt echt | Gleiches und richtiges Grundmodell; cmux ersetzt die CLI ebenso wenig durch eine Chat-Runtime. |
| Terminaleinbettung | cmux ist mit stabiler Surface-ID, Runtime-Generation, Portal-Lease und serialisiertem Teardown robuster belegt. Die Umsetzung ist wesentlich komplexer und nicht 1:1 zu kopieren. |
| Status | cmux ist stärker bei surfacegenauem Retargeting und der Trennung Hook/OSC. WhisperM8 kann wegen des engeren Claude-Fokus einfacher bleiben. |
| Fork/Resume | cmux hat einen sehr konkreten Parent-ID-Guard. WhisperM8 sollte denselben Übergang direkt auf `--resume`, `--fork-session`, optional `--session-id` und die erste bestätigte Child-ID aus Hook/JSONL abbilden. |
| Recovery | cmux ist konservativ: persistente ID, CWD, Config-Root, Wrapper und eindeutige JSONL müssen zusammenpassen. Dieses Muster ist direkt übertragbar. |
| Multi-Account | cmux transportiert Config-Roots, modelliert aber keinen Account im Session-Key. WhisperM8 sollte hier strenger sein. |

cmux ist vor allem bei der Lebensdauer des eingebetteten Terminals und beim Routing asynchroner Statusereignisse besser abgesichert. WhisperM8 hat dagegen den Vorteil eines engeren Produktschnitts: Es muss nicht viele Agenttypen generalisieren und kann Claude-spezifische Invarianten um `--session-id`, `--resume`, `--fork-session`, JSONL und Hook-Events expliziter modellieren.

## 5. Priorisierte übertragbare Muster

### P0 — Drei Identitäten explizit trennen

Für jede WhisperM8-Pane getrennt halten:

- stabile Pane-ID,
- langlebige Claude-Session-ID,
- flüchtige PTY-/Prozessgeneration.

SwiftUI darf nur die Präsentation wechseln. Jeder Callback muss mindestens Pane-ID plus erwartete Generation prüfen; Hook-Mutationen zusätzlich die erwartete Claude-Session-ID. Der SwiftTerm-View-Lebenszyklus darf nicht Eigentümer der CLI-Session sein.

### P0 — Hook-first-Status mit einem OSC-Fallback

Hooks aktualisieren `running`, `idle`, `needsInput` und `error` und binden jede Mutation an `{workspace, pane, session, turn}`. OSC darf nur eine Attention-Notification erzeugen. Sobald ein strukturierter Hook-Lifecycle für die Pane aktiv ist, wird das rohe OSC-Signal dedupliziert oder unterdrückt. Das verhindert doppelte Ringe und spätes Zurückspringen auf „Idle“.

Die Zustellung sollte wie bei cmux den Live-Eigentümer nach jedem asynchronen Schritt erneut prüfen. Ein gespeicherter Pane-Verweis vor I/O oder Hook-Auswertung ist keine ausreichende Routing-Garantie.

### P0 — Fork als zweiphasige Transition

Beim Start von `claude --resume <parent> --fork-session` einen Übergang `forkPending(parentID, paneID, processGeneration)` anlegen. Frühe Hooks mit Parent-ID dürfen weder den Parent umadressieren noch dessen Resume-Binding löschen. Erst eine neue, pane- und prozesskonsistente Child-ID aus Hook oder JSONL wird aktiv.

Resume bleibt ein eigener Übergang und muss `{account/configRoot, cwd, sessionID}` exakt matchen. Falls WhisperM8 `--session-id` selbst vergibt, muss diese ID als erwartete Child-ID Teil des Übergangs sein; sie darf nicht stillschweigend durch eine Parent- oder „zuletzt gefundene“ JSONL-ID ersetzt werden.

### P1 — Teardown-Reihenfolge festschreiben

Für SwiftTerm/PTY analog das cmux-Prinzip übernehmen:

1. Runtime aus Registry und UI-Routing entfernen.
2. Generation invalidieren und Pointer/FD im Owner auf `nil` setzen.
3. PTY-Lese-/Schreibpfade stoppen und joinen.
4. Erst danach Callback-Kontexte, Pipes und Beobachter freigeben.

Das genaue Ghostty-API ist nicht übertragbar, die Besitzreihenfolge schon.

### P1 — Recovery konservativ halten

Persistieren sollten gemeinsam: Agent-Kind, Session-ID, Account-/Config-Root, Launch-CWD, relevante sichere CLI-Flags, Transcriptpfad und Wrapper-/Hook-Version. Beim Wiederfinden nur eindeutige JSONL-Kandidaten akzeptieren. Mehrere plausible Kandidaten sind ein sichtbarer Konflikt und kein Anlass für „latest wins“.

## Nicht auffindbar

- Das `ghostty/`-Submodul enthält im Klon keinen Parsercode. Die genaue Implementierung und Edge-Case-Behandlung von OSC 9/99/777 konnte daher nicht geprüft werden; lokal belegt sind die README-Aussage und die von `libghostty` gelieferte Desktop-Notification-Action.
- Eine periodische Hook-Heartbeat-Quelle ist nicht belegt; Stale-Cleanup stützt sich auf PID-/Prozessidentität und spätere Hooks.
- Eine account-spezifische Session-Key-Komponente oder Account-Auswahl in der Terminal-UI wurde nicht gefunden.
