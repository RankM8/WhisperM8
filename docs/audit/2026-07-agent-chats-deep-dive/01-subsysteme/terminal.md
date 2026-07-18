# Subsystemkarte: Terminal/PTY (Foreground-Chats)

Audit-Stand: 2026-07-18. Untersucht wurden die interaktiven Vordergrund-PTYs für Claude Code,
Codex und Shell-Tabs einschließlich Registry, SwiftTerm-Adapter, Snapshots und Link-Routing.
Background-Spawns selbst gehören nicht zum Scope; ihr späteres `claude attach` läuft jedoch
durch denselben Foreground-Pfad (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:257-280`).

## 1. Zweck & Verantwortung

Das Subsystem baut provider- und sessionabhängige CLI-Kommandos, startet sie in einem
SwiftTerm-PTY, hält Prozess und Terminal-Scrollback unabhängig vom SwiftUI-View-Lebenszyklus
und verbindet Tastatur, Scrollen, Drag-and-drop sowie Link-Klicks mit AppKit
(`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:137-168`,
`WhisperM8/Views/AgentTerminalView.swift:322-365,614-715,984-1115`). Beendete Chats können
zusätzlich einen Plaintext-Snapshot des normalen Terminal-Buffers anzeigen, ohne zuerst das
provider-spezifische JSONL-Transcript zu laden
(`WhisperM8/Views/AgentTerminalView.swift:799-820`,
`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14-29`).

## 2. Datenfluss & Trigger

### 2.1 PTY-Spawn

1. Eine neue Session wird mit `shouldLaunchOnOpen = true` angelegt, als Tab geöffnet und per
   `.start` adressiert (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:28-64`). Die
   Detail-View startet außerdem beim Mount beziehungsweise Sessionwechsel automatisch und
   verarbeitet explizite Start-/Restart-Requests
   (`WhisperM8/Views/AgentSessionDetailView.swift:129-162,372-379`).
2. `launchAfterCacheWarmup()` wärmt Login-PATH und CLI-Pfad in einem detached Task vor. Für
   Claude-Resumes wird dort auch die Transcript-Reparatur vorbereitet; vor dem Rücksprung auf
   den MainActor wird nochmals geprüft, ob die Session noch existiert und nicht archiviert ist
   (`WhisperM8/Views/AgentSessionDetailView.swift:382-430`).
3. Auf dem MainActor erzeugt `prepareCommand()` gegebenenfalls Claude-Hook-Argumente, baut den
   `AgentLaunchCommand` und übergibt ihn an die globale Registry
   (`WhisperM8/Views/AgentSessionDetailView.swift:433-480`).
4. Die Registry verwendet einen bereits laufenden Controller derselben lokalen Session-ID
   wieder. Sonst legt sie einen Controller an, trägt ihn vor dem Start in ihr Dictionary ein
   und ruft `start()` (`WhisperM8/Views/AgentTerminalView.swift:345-365`).
5. Der Controller mischt das korrigierte Login-Shell-Environment mit command-spezifischen
   Overrides und ruft `LocalProcessTerminalView.startProcess(executable:args:environment:
   currentDirectory:)` (`WhisperM8/Views/AgentTerminalView.swift:749-772`). Der anschließende
   `onLaunched`-Callback markiert die Session als `.running`, setzt den Launch-Marker, entfernt
   Initial-Prompt und Auto-Launch-Flag, flusht den Store sofort und startet die externe
   ID-Bindung (`WhisperM8/Views/AgentSessionDetailView.swift:583-606`).

### 2.2 Neue Session, Resume, Fork und Attach

| Session-Art | Entscheidung und Kommando |
|---|---|
| Codex neu | Ohne Launch-Marker: `codex -C <cwd> -m <model> ...`, ergänzt um Bilder und Initial-Prompt (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:204-224`). |
| Codex Resume | Mit Launch-Marker ist eine externe ID Pflicht; gebaut wird `codex resume ... <id>`, andernfalls wird `missingExternalSessionID` geworfen (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:170-202`). |
| Claude neu | Ohne Fork-Quelle und ohne Kombination aus Launch-Marker plus gebundener ID: frischer Start ohne `--session-id`; ein Initial-Prompt wird nur vor dem ersten markierten Launch angehängt (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:290-313,341-345`). |
| Claude Resume | `hasLaunchedInitialPrompt && externalSessionID != nil` erzeugt `--resume <id>`; der reale Transcript-Root kann dabei einen veralteten Account-Stempel überstimmen (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:302-335`). Vorher stoppt die Detail-View den Launch, wenn das Transcript auch nach Reparatur nicht auffindbar ist (`WhisperM8/Views/AgentSessionDetailView.swift:487-560`). |
| Claude Fork | Solange noch keine eigene externe ID gebunden ist, gewinnt `forkSourceSessionID`; gebaut wird `--resume <source> --fork-session` (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:290-301,334-338`). |
| Claude Agent View | Eigenständiges Dashboard `claude agents`, ohne Resume-, Session-ID- oder Hook-Bridge-Semantik (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:240-255`). |
| Background-Attach | Der nicht-PTY Spawn liegt außerhalb dieses Subsystems; der Vordergrund-Tab startet `claude attach <shortID>` (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:257-280`). |
| Shell-Tab | Immer eine frische Login-Shell mit `-i -l`, ohne Resume (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:156-168`). |

### 2.3 Registry- und View-Lebenszyklus

`AgentTerminalRegistry.shared` hält Controller stark nach lokaler Session-ID; aktive IDs und
„Stop all“ werden aus `isRunning` abgeleitet
(`WhisperM8/Views/AgentTerminalView.swift:322-339,372-383`). Das reine Schließen eines Tabs
beendet das PTY ausdrücklich nicht; beim erneuten Öffnen wird derselbe Controller samt
Scrollback wiederverwendet (`WhisperM8/Views/AgentChatsView+Tabs.swift:70-95`).

`AgentTerminalView` ist nur der SwiftUI/AppKit-Adapter. Sein Dismantle flusht gepufferte Bytes
und entfernt Subviews, lässt den Registry-Controller aber weiterleben
(`WhisperM8/Views/AgentTerminalView.swift:984-1006`). Genau eine Terminal-NSView gehört zu
einem Controller; `AgentTerminalContainerView` adoptiert sie nur als fenstergebundener Host
und heilt ein verlorenes Reparenting in `layout()`
(`WhisperM8/Views/AgentTerminalView.swift:1037-1085`).

Beim expliziten Stop sendet der Controller zweimal Ctrl+C, wartet 80/180 ms, flusht, capturt,
ruft SwiftTerm-`terminate()` und entfernt seine Event-Monitore; die Registry löscht den
Controller direkt danach (`WhisperM8/Views/AgentTerminalView.swift:367-370,775-797`). Beim
natürlichen Prozessende setzt der Delegate-Callback dagegen nur Status und Snapshot, baut die
Monitore ab und lässt den Controller für den Scrollback im Registry-Dictionary
(`WhisperM8/Views/AgentTerminalView.swift:329,839-849,969-980`).

### 2.4 Snapshot-Erzeugung und Anzeige

Snapshots entstehen in drei Pfaden: expliziter Stop, natürlicher Prozess-Exit und App-Quit
(`WhisperM8/Views/AgentTerminalView.swift:775-837,969-980`). Beim App-Quit sendet die Registry
allen laufenden PTYs gemeinsam zweimal Ctrl+C, wartet insgesamt 260 ms und capturt danach;
der früheste AppKit-Terminate-Hook ruft diesen Pfad vor dem Fensterabbau
(`WhisperM8/Views/AgentTerminalView.swift:385-401`,
`WhisperM8/WhisperM8App.swift:336-351`). Dieser Quit-Pfad wurde durch Commit `a26d29f`
ergänzt; Commit `f448e02` hatte zuvor Store, Capture und Anzeige eingeführt
(`WhisperM8/Views/AgentTerminalView.swift:385-401,799-837`).

Der Controller liest den normalen SwiftTerm-Buffer als UTF-8 und speichert synchron über
`TerminalSnapshotStore` (`WhisperM8/Views/AgentTerminalView.swift:808-820`). Der Store trimmt
Leerzeilen, behält höchstens die jüngsten 2.000 Zeilen und schreibt Header plus Payload atomar
in einen Sidecar unter Application Support
(`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14-29,48-60,75-106`). Ohne Live-
Controller lädt die Detail-View den Sidecar detached und kann dadurch den JSONL-Load im
Terminal-Modus aufschieben (`WhisperM8/Views/AgentSessionDetailView.swift:201-225,255-260`).
Die Anzeige zerlegt den Text in 50-Zeilen-Blöcke einer `LazyVStack`
(`WhisperM8/Views/Transcript/TerminalSnapshotView.swift:8-42`).

### 2.5 Link-Klick-Pfad

SwiftTerm leitet `requestOpenLink` nicht an seinen `processDelegate` weiter. Der Controller
ersetzt deshalb den schwachen `terminalDelegate` durch einen stark gehaltenen
`AgentTerminalLinkInterceptor`, dessen Basis wiederum schwach ist
(`WhisperM8/Views/AgentTerminalView.swift:668-678`,
`WhisperM8/Views/AgentTerminalLinkInterceptor.swift:4-28`). Der Proxy übernimmt nur den
Link-Callback und reicht die übrigen explizit implementierten Delegate-Methoden dynamisch an
`LocalProcessTerminalView` weiter (`WhisperM8/Views/AgentTerminalLinkInterceptor.swift:30-69`).

Der Controller liest den Option-Modifikator, löst lokale Pfade gegen das beim Launch
festgelegte Arbeitsverzeichnis auf und führt die Resolver-Aktion aus
(`WhisperM8/Views/AgentTerminalView.swift:917-956`). Der Resolver behandelt `file:` als lokal,
URLs mit Authority beziehungsweise bekannte Bare-Schemes als Web-Link und alles andere als
lokalen Pfad; vorhanden sind außerdem Tilde-/Relativpfad-Normalisierung und ein Fallback für
`path:line[:column]` (`WhisperM8/Views/TerminalLinkResolver.swift:49-120,147-200`). Code- und
Textdateien gehen primär an PhpStorm, sonstige Dateien/Ordner/Web-Links an `NSWorkspace`, und
Option-Klick zeigt das Ziel im Finder (`WhisperM8/Views/AgentTerminalView.swift:932-966`,
`WhisperM8/Services/Shared/PhpStormLauncher.swift:22-47`).

## 3. Zentrale Typen & Zustände

| Typ | Rolle | Relevante Zustände / Besitz |
|---|---|---|
| `AgentLaunchCommand` | Wertobjekt zwischen Builder und Controller | Executable, argv, cwd, Keyboard-Profil, Environment-Overrides (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:3-16`). |
| `AgentCommandBuilder` | Provider-/Session-State auf konkretes CLI-Kommando abbilden | Resolver-Closures für Binary, Extra-Args, Service Tier, Claude-Profil/Transcript und Login-Shell (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:38-84,137-154`). |
| `AgentTerminalRegistry` | Prozessweiter Owner der Foreground-Controller | Starkes `[UUID: AgentTerminalController]`; Ableitungen `activeSessionIDs` und `runningControllers` (`WhisperM8/Views/AgentTerminalView.swift:322-343`). |
| `AgentTerminalController` | Lifecycle-, SwiftTerm- und AppKit-Koordinator pro lokaler Session | `hasStarted`, `isRunning`, `exitCode`, `didCaptureSnapshot`, Launch-Command sowie starke Terminal-/Interceptor-Referenz (`WhisperM8/Views/AgentTerminalView.swift:614-655,799-820`). |
| `QuietableTerminalView` | Angepasste `LocalProcessTerminalView` | Tail-Following/erhaltene Scrollposition, Feed-Priorität, optionaler Metal-Renderer und Bell-Override (`WhisperM8/Views/AgentTerminalView.swift:21-69,71-183`). |
| `TerminalFeedBatcher` | PTY-Byte-Bündelung für Hintergrund-Panes | `isThrottling`, FIFO-Puffer, genau ein geplanter Flush, 256-KiB-High-Water (`WhisperM8/Views/TerminalFeedBatcher.swift:18-83`). |
| `TerminalKeyboardShortcutHandler` / `TerminalScrollGuard` | App-weite NSEvent-Adapter pro laufendem Controller | Schwache Terminal-Referenz, Monitor-Token, explizites `detach`; ScrollGuard besitzt zusätzlich Trackpad-Delta (`WhisperM8/Views/AgentTerminalView.swift:208-239,543-610`). |
| `AgentTerminalLinkInterceptor` / `TerminalLinkResolver` | SwiftTerm-Delegate-Proxy und pure Routing-Entscheidung | Schwache Proxy-Basis; Resolver-Aktionen `openWeb`, `openInEditor`, `openFile`, `openFolder`, `reveal`, `notFound`, `reject` (`WhisperM8/Views/AgentTerminalLinkInterceptor.swift:20-69`, `WhisperM8/Views/TerminalLinkResolver.swift:16-43`). |
| `AgentTerminalContainerView` | Einziger fenstergebundener Host der Terminal-NSView plus Finder-Drop | Schwache Terminal-Referenz, Session-ID und selbstheilende Adoption (`WhisperM8/Views/AgentTerminalView.swift:1019-1115`). |
| `TerminalSnapshotStore` / `TerminalSnapshotView` | Persistierter Endstand und read-only Darstellung | Formatversion 1, Capture-Zeit, maximal 2.000 Zeilen, 50-Zeilen-Renderchunks (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:9-34`, `WhisperM8/Views/Transcript/TerminalSnapshotView.swift:12-42`). |

## 4. Threading-Modell & Invarianten

- Registry, Controller, Link-Interceptor sowie beide NSEvent-Adapter sind MainActor-isoliert
  (`WhisperM8/Views/AgentTerminalView.swift:208-209,322-323,543-544,613-614`,
  `WhisperM8/Views/AgentTerminalLinkInterceptor.swift:20-21`). SwiftTerms `LocalProcess`
  verwendet ohne explizite Queue die Main Queue; `LocalProcessTerminalView` konstruiert ihn
  ohne Queue-Override (`.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:116-129`,
  `.build/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift:83-87`).
- PTY-Reads passieren in SwiftTerm auf einer Read-Queue, die Delegate-Zustellung wird aber auf
  die gewählte Dispatch-Queue gelegt (`.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:132-209,320-342`).
  WhisperM8 assertiert deshalb im Feed-Pfad den Main Thread
  (`WhisperM8/Views/AgentTerminalView.swift:112-117`).
- Der Feed-Batcher garantiert FIFO und verliert bei seinem High-Water keinen Prefix; Fokus,
  Teardown und High-Water fluschen synchron (`WhisperM8/Views/TerminalFeedBatcher.swift:3-15,49-83`).
- Teure Launch-Vorbereitung soll detached erfolgen; Controller-Erzeugung, SwiftTerm-Aufruf und
  Store-Statuswechsel erfolgen danach auf dem MainActor
  (`WhisperM8/Views/AgentSessionDetailView.swift:382-430,433-480`).
- Pro lokaler Session darf höchstens ein laufender Controller existieren
  (`WhisperM8/Views/AgentTerminalView.swift:345-365`). Pro Controller existiert genau eine
  Terminal-NSView, die zwischen SwiftUI-Hosts reparentet, nicht dupliziert wird
  (`WhisperM8/Views/AgentTerminalView.swift:1039-1085`).
- Explizites Terminieren sollte erst nach graceful Exit oder Eskalation den Prozess als beendet
  markieren und aus der Registry entfernen. Aktuell entfernt die Registry unmittelbar nach dem
  synchronen Controller-Aufruf (`WhisperM8/Views/AgentTerminalView.swift:367-370`), während der
  gepinnte SwiftTerm-Fork nur SIGTERM sendet und nicht auf Exit/Reaping wartet
  (`.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:546-572`).
- Der Link-Interceptor muss alle Semantik tragenden `TerminalViewDelegate`-Callbacks an die
  Basis weiterreichen; weil SwiftTerm den Delegate schwach hält, muss der Controller den Proxy
  stark besitzen (`WhisperM8/Views/AgentTerminalLinkInterceptor.swift:15-19,35-69`,
  `WhisperM8/Views/AgentTerminalView.swift:621-624,674-678`).
- Snapshot-Extraktion greift auf ein UI-Objekt zu und gehört auf den MainActor; Dateiaufbereitung
  und atomarer Write sind dagegen I/O, werden derzeit aber im selben synchronen Aufruf erledigt
  (`WhisperM8/Views/AgentTerminalView.swift:808-820`,
  `WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:75-91`).

## 5. Risiken & Schwachstellen

| Schweregrad | Datei:Zeile | Problem | Mögliche Wirkung |
|---|---|---|---|
| kritisch | `WhisperM8/Views/AgentTerminalView.swift:775-795,969-980`; `WhisperM8/Views/AgentSessionDetailView.swift:563-565`; `WhisperM8/Views/AgentChatsView.swift:2632-2636`; `.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:365-370,546-572` | Nach natürlichem Exit reapt SwiftTerm zwar per `waitpid`, setzt `shellPid` aber nicht auf 0. Ein späteres `terminate()` auf diesem toten Controller ruft trotz `isRunning == false` weiter SwiftTerm-`terminate()` auf; nach PID-Reuse adressiert dessen `kill(shellPid, SIGTERM)` einen fremden Prozess. Erreichbar ist dies mindestens im Race „Restart angefordert, Prozess endet vor Behandlung des Requests“. | Sporadische Terminierung eines nicht zu WhisperM8 gehörenden Prozesses; wegen des engen Race-Fensters selten, im Schadensfall aber gravierend. |
| hoch | `WhisperM8/Views/AgentTerminalView.swift:367-370,775-797`; `.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:269-277,365-370,513-523,546-572` | Der explizite Hard-Stop schließt I/O, sendet SIGTERM und ruft sofort `childStopped()`, das den Process-Monitor cancelt. Der einzige `waitpid` liegt im gecancelten Exit-Handler; die Registry verwirft den Controller ohne Exit-Bestätigung. | Nicht gereaptes Kind kann als Zombie bis zum App-Ende verbleiben; ein SIGTERM-ignorierender Prozess oder Descendant kann weiterlaufen. |
| hoch | `WhisperM8/Views/AgentTerminalView.swift:613-614,393-400,775-819,969-980`; `.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:124-150,320-342` | `terminate()` schläft auf dem MainActor 260 ms, obwohl SwiftTerm Exit-Bytes asynchron genau auf die Main Queue liefert. `flushPendingOutput()` erreicht nur WhisperM8s nachgelagerten Batcher, nicht SwiftTerms noch wartende Queue; Capture und Idempotenz-Flag kommen vor diesen Bytes. `terminateAll()` wiederholt die Blockade seriell pro Controller. | Der Snapshot verpasst den Claude-/Codex-Exit- und Resume-Hinweis; Stop-all friert die UI für `N × 260 ms` plus Snapshot-I/O ein. |
| hoch | `WhisperM8/Views/AgentTerminalView.swift:749-773`; `WhisperM8/Views/AgentSessionDetailView.swift:583-594`; `.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:383-394,496-543` | Controller setzt `hasStarted/isRunning` vor dem Spawn und ruft `onLaunched()` bedingungslos auf. SwiftTerms Void-API meldet im `forkpty == nil`-Pfad weder Fehler noch Termination-Callback; danach entfernt WhisperM8 den Initial-Prompt und persistiert `.running`. | Phantom-PTY ohne Prozess, dauerhaft falscher Running-State und Verlust des noch nicht zugestellten Initial-Prompts. |
| mittel | `WhisperM8/Views/AgentSessionDetailView.swift:495-500,583-600,634-696`; `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:181-184,302-345` | Claude behandelt `hasLaunchedInitialPrompt == true` ohne gebundene externe ID anders als Codex: kein Fehler, sondern frischer Launch ohne `--resume` und ohne Initial-Prompt. Das ID-Binding läuft erst nach dem Launch und gibt nach fünf Versuchen still auf. | Nach frühem Stop/Crash oder fehlgeschlagener Bindung startet „Resume“ einen leeren neuen Claude-Chat; der vorhandene Kontext wirkt verloren, obwohl das alte Transcript weiter existieren kann. |
| mittel | `WhisperM8/Views/AgentTerminalView.swift:329-369,839-849,969-980`; `WhisperM8/Views/AgentChatsView+Tabs.swift:120-160`; `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:56-64` | Natürliche Exits entfernen den Controller nicht. Archiv-, Terminal-Lösch- und Projekt-Löschpfade rufen Registry-`terminate` nur für noch laufende Controller auf, daher bleiben tote Controller auch nach Entfernung der Session stark im Singleton. | Kumulative Retention von Controller, Terminal-NSView, Buffer und Theme-Observer bis zum App-Ende; bei viel Session-Churn steigender Speicherbedarf. |
| mittel | `WhisperM8/Views/AgentSessionDetailView.swift:201-225,255-260`; `WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:94-106` | Die JSONL-Load-Weiche prüft nur, ob eine Sidecar-Datei existiert. Liefert `load()` wegen korruptem Header oder unbekannter Version `nil`, setzt die Completion nur `terminalSnapshot = nil` und stößt keinen Transcript-Load an. | Eine kaputte oder neuere Snapshot-Datei lässt einen geschlossenen Chat im Defaultmodus leer erscheinen, bis der User den Anzeigemodus wechselt. |
| mittel | `WhisperM8/Views/AgentTerminalView.swift:808-820`; `WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:77-91` | `didCaptureSnapshot` wird vor UTF-8-Prüfung und vor dem fehlertolerant geschluckten Dateischreibfehler gesetzt. Zusätzlich laufen Aufbereitung, JSON-Encoding und atomarer Write synchron auf dem MainActor. | Decode-/I/O-Fehler verhindern jeden Retry; langsames Dateisystem verlängert Teardown und UI-Blockade. |
| mittel | `WhisperM8/Views/AgentSessionDetailView.swift:382-386,538-557`; `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:315-330`; `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:334-400,403-419` | Trotz Off-main-Warmup wiederholen finale Resume-Garantie und Command-Build auf dem MainActor Transcript-Lookups. Beim Canonical-Miss listet der Locator alle Projektordner und liest zur Kandidatenprüfung bis zu 1 MiB JSONL-Kopf. | Sporadischer UI-Hänger gerade im Claude-Recovery-/verschobenes-Transcript-Fall. |
| niedrig | `WhisperM8/Views/AgentTerminalView.swift:66-69,670-678`; `WhisperM8/Views/AgentTerminalLinkInterceptor.swift:60-69`; `.build/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift:2806-2808,2951-2974` | Der installierte Link-Proxy implementiert `bell` nicht. SwiftTerm ruft deshalb den Proxy-Default `NSSound.beep()` statt `QuietableTerminalView.bell`; die App-Präferenz wird umgangen. Das manuelle Proxying lässt auch künftige Delegate-Defaults ohne Compilerfehler durchrutschen. | Terminal-Bell ertönt trotz deaktivierter Einstellung; SwiftTerm-Upgrades können weitere stille Delegate-Regressionen erzeugen. |
| niedrig | `WhisperM8/Services/Shared/PhpStormLauncher.swift:40-47`; `WhisperM8/Views/AgentTerminalView.swift:932-943` | Der asynchrone NSWorkspace-Fallback verwirft seinen Completion-Fehler und meldet sofort Erfolg; der Controller probiert dann die Standard-App nicht mehr. | Ein Link-Klick kann bei einem PhpStorm-Launchfehler still ohne sichtbare Aktion bleiben. |

Kein direkter Crash im SwiftUI-Container-Teardown ist aus dem aktuellen Code belegbar: Der
Container hält das Terminal schwach, adoptiert nur fenstergebunden und die vorhandenen Tests
decken die kritischen Reparenting-Konstellationen ab
(`WhisperM8/Views/AgentTerminalView.swift:1020-1085`,
`Tests/WhisperM8Tests/AgentTerminalContainerViewTests.swift:32-116`). Das größte
Teardown-Risiko liegt stattdessen im Prozess-Reaping und in der blockierten
Main-Queue-Zustellung, nicht im NSView-Dismantle
(`WhisperM8/Views/AgentTerminalView.swift:984-1006`).

## 6. Testabdeckung

### Vorhanden

- `AgentCommandBuilderTests` deckt Codex neu/Resume, Claude neu/Resume/Fork, Agent View,
  Background-Attach, Argumentreihenfolge, Service Tier und Claude-Account-Root ab
  (`Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:6-198,278-291,313-384,390-512`).
  Shell-Kommando und Shell-Fallback liegen in
  `AgentTerminalSessionTests.swift:12-53`.
- `TerminalLinkResolverTests` deckt Web-Schemes, Datei-/Ordner-/Editor-Routing, Reveal,
  Relativpfade, Tilde, Sonderzeichen, `file:` und `path:line[:column]` ab
  (`Tests/WhisperM8Tests/TerminalLinkResolverTests.swift:36-227`).
- `TerminalSnapshotStoreTests` prüft Trim/2.000-Zeilen-Limit, Resume-Hinweis, Roundtrip,
  leere/fehlende/kaputte/neue Versionen sowie Einzel-/Bulk-Delete
  (`Tests/WhisperM8Tests/TerminalSnapshotStoreTests.swift:22-108`). Diese Store-Tests kamen mit
  `f448e02`; `a26d29f` ergänzte den App-Quit-Produktivpfad ohne entsprechenden Test
  (`WhisperM8/Views/AgentTerminalView.swift:385-401`).
- Container-Adoption, Self-Heal, Schutz vor einem detached Zwischen-Host und
  Controller-Wechsel werden mit echten NSViews geprüft
  (`Tests/WhisperM8Tests/AgentTerminalContainerViewTests.swift:32-116`).
- Feed-FIFO, Einmal-Scheduling, Fokus-/High-Water-/Oversize-Flush sind unit-getestet
  (`Tests/WhisperM8Tests/TerminalFeedBatcherTests.swift:40-120`); die Shortcut-Byte-Matrix
  deckt die Claude-, Codex-, Agent-View- und Plain-Shell-Profile ab
  (`Tests/WhisperM8Tests/TerminalKeyboardShortcutTests.swift:8-199`,
  `Tests/WhisperM8Tests/AgentTerminalSessionTests.swift:58-97`).
- Das Drag-Payload-Escaping ist als pure Logik getestet
  (`Tests/WhisperM8Tests/AgentTranscriptUtilityTests.swift:92-123`).

### Konkrete Lücken

- Es gibt keine direkten Tests für Registry/Controller: Spawnfehler, Start-Deduplizierung,
  natürlicher Exit, Restart, `terminate`/`terminateAll`, Exitcode, PID-Invalidierung,
  SIGTERM→Reaping und Event-Monitor-Abbau bleiben ungetestet; der Produktivcode liegt in
  `WhisperM8/Views/AgentTerminalView.swift:322-401,614-849,969-980`.
- Controller-Capture aus dem echten SwiftTerm-Normalbuffer, Reihenfolge
  Ctrl+C→Exit-Bytes→Flush→Capture, Idempotenz zwischen explizitem Stop und Callback sowie
  App-Quit-Capture sind nicht getestet
  (`WhisperM8/Views/AgentTerminalView.swift:385-401,775-837,969-980`).
- Kein Test installiert `AgentTerminalLinkInterceptor` als realen Delegate oder verifiziert
  vollständiges Forwarding, Bell-Präferenz, `NSWorkspace`-/`NSAlert`-Aktionen und
  `PhpStormLauncher` (`WhisperM8/Views/AgentTerminalLinkInterceptor.swift:20-69`,
  `WhisperM8/Views/AgentTerminalView.swift:917-966`,
  `WhisperM8/Services/Shared/PhpStormLauncher.swift:8-48`).
- Nicht getestet sind `QuietableTerminalView` plus realer SwiftTerm-Feed, das Canceln des
  `asyncAfter`-Flushes, NSEvent-Window-/FirstResponder-Gates, Alternate-Buffer-SGR-Scrolling,
  Drag-Pasteboard und `dismantleNSView`
  (`WhisperM8/Views/AgentTerminalView.swift:87-127,208-320,543-610,984-1115`).
- Maximize/Restore zwischen SwiftUI-Hosts, echter Claude-Code-Alt-Buffer, Trackpad,
  FirstResponder, App-Quit und Prozessbaum-Verhalten sind AppKit-/PTY-Integration und sollten
  als manuelle QA beziehungsweise kleine Prozessbasierte Integrationstests geprüft werden;
  künstliche SwiftUI-UI-Tests wären für diese Pfade nicht belastbar
  (`WhisperM8/Views/AgentTerminalView.swift:186-320,860-890,984-1115`).

## 7. Refactor-Kandidaten

1. **Async `TerminalProcessLifecycle` mit bestätigtem Exit und Reaping.** SwiftTerms
   Void-Spawn/Terminate hinter ein kleines Protokoll mit `start() throws`,
   `requestGracefulStop()`, Deadline, SIGTERM→SIGKILL-Eskalation und garantiertem `waitpid`
   kapseln; PID beim Reap atomar invalidieren. Nutzen: keine Phantom-PTYs, Zombies oder
   stale-PID-Kills; Lifecycle lässt sich ohne NSView unit-testen
   (`WhisperM8/Views/AgentTerminalView.swift:749-797`,
   `.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:365-370,496-572`).
2. **Registry-Zustandsmaschine und Eviction.** Zustände `starting`, `running`, `terminating`,
   `exited(snapshot)` explizit modellieren; nach natürlichem Exit Controller/Terminal freigeben
   und den Snapshot anzeigen. Delete/Archiv muss auch nicht laufende Einträge entfernen.
   Nutzen: klare Invarianten und begrenzter Speicher bei Session-Churn
   (`WhisperM8/Views/AgentTerminalView.swift:329-370,969-980`).
3. **Graceful Stop nicht blockierend koordinieren.** Ctrl+C senden, Runloop per `Task.sleep`
   weiterlaufen lassen, Exit oder Output-Ruhe bis Deadline abwarten und erst danach capturen;
   Stop-all parallel koordinieren. Für App-Quit `.terminateLater` nutzen und nach Abschluss
   antworten. Nutzen: korrekter Claude-Resume-Hinweis im Snapshot und keine N×260-ms-UI-Freeze
   (`WhisperM8/Views/AgentTerminalView.swift:385-401,775-837`,
   `WhisperM8/WhisperM8App.swift:343-351`).
4. **Snapshot-Pipeline zweiphasig und erfolgsbasiert.** Buffer auf dem MainActor kopieren,
   Prepare/Write auf einem seriellen Actor ausführen, `didCaptureSnapshot` erst nach Erfolg
   setzen und die UI per Completion aktualisieren. Die Anzeige-Weiche muss auf erfolgreiches
   Decode statt bloße Dateiexistenz reagieren. Nutzen: Retry bei I/O-Fehlern, kein leerer
   Offline-View und weniger Main-Thread-I/O
   (`WhisperM8/Views/AgentTerminalView.swift:808-820`,
   `WhisperM8/Views/AgentSessionDetailView.swift:201-225`,
   `WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:75-106`).
5. **Claude-Resume-Zustand genauso strikt wie Codex behandeln.** Bei gesetztem Launch-Marker
   ohne externe ID Launch blockieren und Reparatur/Indexer-Bindung anbieten, statt frisch zu
   starten. Nutzen: keine stille Kontextabkopplung im wichtigsten Use-Case
   (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:181-184,302-345`).
6. **Command-Build vollständig I/O-frei machen.** Transcript-Ort und effektives Claude-Profil
   im detached Warmup bestimmen und als `ResumeLaunchPreparation` an den MainActor übergeben;
   im Builder keine Directory-Listings oder JSONL-Reads. Nutzen: Recovery-Fälle blockieren die
   UI nicht (`WhisperM8/Views/AgentSessionDetailView.swift:382-430,538-557`,
   `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:334-419`).
7. **Delegate-Proxy als getesteten Adapter isolieren.** Alle aktuellen Callbacks explizit
   weiterleiten, Bell und Clipboard-Policy bewusst im Adapter implementieren und beim
   SwiftTerm-Pin-Upgrade einen Protocol-Diff-Test beziehungsweise eine Checkliste verlangen.
   Nutzen: Link-Fix bleibt erhalten, ohne Terminal-Grundfunktionen oder Präferenzen still zu
   verändern (`WhisperM8/Views/AgentTerminalLinkInterceptor.swift:35-69`,
   `Package.swift:16-24`).
8. **Externe Open-Aktionen asynchron und injizierbar machen.** `PhpStormLauncher` und
   `NSWorkspace` hinter Closures/kleinem Protokoll testen, Completion-Fehler an den
   Standard-App-Fallback reichen und modale Not-found-Alerts durch eine nichtmodale
   Fehlermeldung ersetzen. Nutzen: deterministischer Link-Pfad ohne Main-Thread-Modalität
   (`WhisperM8/Services/Shared/PhpStormLauncher.swift:22-47`,
   `WhisperM8/Views/AgentTerminalView.swift:932-966`).
