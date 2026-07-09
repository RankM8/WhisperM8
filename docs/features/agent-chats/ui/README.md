---
status: aktiv
updated: 2026-07-09
---

# UI — Fenster, Sidebar, Tabs, Terminal, Timeline

Die Agent-Chat-UI ist das native macOS-Arbeitsfenster für interaktive Claude-
und Codex-Sessions, Terminal-Tabs, Claude-Background-Chats, Claude Agent Views
und Codex-Subagent-Jobs. Sie ist projektübergreifend: Die Sidebar zeigt den
Workspace-Bestand, die Tab-Leiste zeigt das aktive Arbeitsset dieses Fensters,
der rechte Inspector zeigt Projektkontext, und die Detailfläche rendert je
nach Session-Art ein PTY-Terminal oder eine Job-Ansicht.

## Fenster und Chrome

`AgentChatsView` ist pro Fenster instanziiert und bekommt eine `windowID`. Der
Fenster- und Tab-Zustand liegt nicht lokal in der View, sondern in
`AgentWindowStore.shared`; die View liest daraus `openTabIDs`,
`selectedSessionID`, `selectedProjectID`, `pinnedSessionIDs`,
`expandedProjectIDs` und die ephemere Multi-Auswahl als Bridges.

Das Fenster nutzt eine versteckte Titelzeile mit eigener Chrome-Zone. Freie
Header-Flächen dürfen das Fenster bewegen, der Tab-Strip und das Terminal
schalten `mouseDownCanMoveWindow` beziehungsweise `NSWindow.isMovable` gezielt
aus, damit Tab-Drag und Textselektion nicht als Fenster-Drag enden.
`AgentChatsWindowAccessor` bindet das `NSWindow`, setzt das Close-Tracking und
deaktiviert System-Restoration; Restore und Tab-Verteilung gehören zum
persistierten Store.

Details zu mehreren Fenstern, Tab-Detach und Cross-Window-Moves stehen in
[`multiwindow.md`](multiwindow.md) und
[`multiwindow-architecture.md`](multiwindow-architecture.md). Diese README
beschreibt nur die UI-Landkarte.

## Sidebar

Die Sidebar ist der Navigator über Projekte und Chats. Sie kann ein- und
ausgeblendet werden, hat eine persistierte Breite mit Clamp gegen die aktuelle
Fensterbreite und bietet oben Such-, Refresh-, Scope- und Layout-Controls. Der
Scope ist `Aktiv`, `Zuletzt` oder `Alle`; die Suche hebt den Scope auf `Alle`
an. Das Layout ist gruppiert nach Projekt oder flach nach Recency.

Die zentrale Erzeugungsfläche sitzt ebenfalls in der Sidebar und im Header.
Der Sidebar-Splitbutton „Neuer Chat" startet direkt im aktuellen Zielprojekt;
sein Dropdown öffnet den durchsuchbaren `newChatProjectPicker` zum Wechseln
oder Hinzufügen eines Projekts. Im Header öffnet das Plus-Menü neue Codex-,
Claude- und Terminal-Sessions, startet den `BackgroundDispatchModal`, erzeugt
eine Claude Agent View und zeigt die `SubAgentLibrarySheet`.

Im gruppierten Layout rendert jedes Projekt eine `ProjectChatGroup` mit
Projektkopf, Session-Rows, Drop-Zonen und einem Row-Limit mit
„weitere anzeigen". Gepinnte Sessions stehen in einer eigenen Sektion und
fallen aus den Projektlisten heraus. Archivierte Sessions sind nicht Teil der
normalen Liste, sondern werden über den Archiv-Modus gezeigt.

Session-Rows zeigen Provider-/Kind-Icons, Titel, Projektfarbe,
Offen-im-Tab-Hervorhebung, Multi-Select-Hervorhebung, fehlende Transcripts und
Live-Status. Der Status kommt row-lokal aus
`AgentSessionRuntimeStatusStore.statusPublisher(for:)`; der `AgentChatsView`
Body liest den globalen Status absichtlich nicht direkt.

Subagent-Jobs werden unter ihrem Parent gruppiert, wenn
`subagentParentSessionID` zur externen Session-ID des Parents passt.
Variante D ist im Code aktiv: fehlgeschlagene und laufende Kinder bleiben
immer sichtbar, erfolgreich fertige Kinder wandern in eine leise Footer-Zeile.
Der Footer zeigt die Zahl fertiger Kinder und einen Segment-Meter; ein Klick
klappt die fertigen Kinder auf. Ungelesene fertige Ergebnisse erscheinen als
Unread-Markierung am Kind, sobald es aufgeklappt oder selektiert wird.

## Tabs

Die Tab-Leiste ist global pro Fenster, nicht pro Projekt. `headerTabs` wird aus
`openTabIDs` und den Workspace-Sessions aufgebaut; sie enthält offene Tabs aus
allen Projekten in Store-Reihenfolge. Ein Tab zeigt Repo-Badge, Titel,
Live-Status und Close affordance. Gepinnte Sessions sind global persistiert,
aber Pinning ist eine Sidebar-/Aktionssemantik und kein eigenes Fenster.

Klick auf einen Tab selektiert ihn. Cmd-Klick und Shift-Klick verwenden die
pure `TabSelectionResolver`-Semantik für Mehrfachauswahl; Bulk-Aktionen wie
Schließen, Archivieren, Pinning und Farbe wirken auf die Auswahl, wenn die
auslösende Session Teil davon ist. Drag einer Auswahl verschiebt die Gruppe
innerhalb des Fensters als Block; Cross-Window- und Sidebar-Drops gehen über
die Drag-Daten mit Quellfenster.

Reorder in der Leiste nutzt gemessene Tab-Frames und eine sichtbare
Einfügelinie. Vertikales Herausziehen beziehungsweise das Kontextmenü lösen
einen Tab oder eine Auswahl in ein neues Fenster ab. Die genaue
Multi-Window-Mechanik ist in [`multiwindow.md`](multiwindow.md) dokumentiert.

Für viele Tabs gibt es ein Overflow-Menü und den Ctrl-Tab-Switcher. Der
Switcher rendert ein Karten-Grid über der Detailfläche, navigiert mit
Ctrl+Tab, Ctrl+Shift+Tab und Pfeiltasten und committet beim Loslassen von
Control.

## Header und Inspector

Der Header über der Detailfläche hält die Fenster-Controls, die globale
Tab-Leiste, das Plus-Menü, die Session-Kontextzeile und den Toggle für den
rechten Inspector. Die Kontextzeile zeigt Status, Session-Titel, Projekt,
Branch, Session-Aktionen, Quick-Buttons für neue Claude-/Codex-Chats und den
Projekt-Opener.

`ProjectDetailPanel` ist die rechte UI-Fläche für Projektkontext. Es hat eine
feste Breite, beeinflusst damit die verfügbare Hauptfläche und bietet Aktionen
wie Projekt-Refresh, neue Codex-/Claude-Chats und Öffnen des Projekts in
PhpStorm; die Wahl zwischen Finder und PhpStorm sitzt im Projekt-Opener der
Header-Zeile.

## Terminal-Bereich

Normale Claude-, Codex-, Background- und Shell-Sessions laufen in einem
eingebetteten SwiftTerm-PTY. `AgentTerminalRegistry` hält Controller pro
Session-ID, sodass laufende Vordergrund-PTYs fensterübergreifend wiedergefunden
und beendet werden können. Der Startpfad baut `AgentLaunchCommand` über
`AgentCommandBuilder`; er nutzt die Login-Shell-Umgebung statt des rohen
GUI-Environments.

`AgentSessionDetailView` bereitet den Launch vor, zeigt währenddessen
Transkript-/Ladezustände und rendert danach `AgentTerminalView`. Der Controller
setzt Theme-Palette, Keyboard-Profil, Link-Interceptor, Scroll-Guard,
Datei-Drop und graceful Termination. Details stehen in
[`terminal.md`](terminal.md).

Claude Agent Views sind ein eigener PTY-Pfad mit `AgentSessionKind.agentView`.
Sie starten die `claude agents`-TUI, tragen ein `VIEW`-Badge in Header und
Switcher und zeigen im Header eine zusätzliche Subsession-Zeile. Diese Zeile
kommt aus `ActiveBackgroundSessionTracker`: Der Tracker pollt die
Claude-Job-State-Dateien nur für selektierte Agent-View-Tabs und wird bei
Tastendruck im Terminal über `setUserKeystrokeListener` sofort angestoßen.

## Transcript-Timeline

Die rechte Detailfläche zeigt nicht nur das Terminal. Parallel dazu existiert
die Timeline-Projektion über `Views/Transcript/`: `AgentTranscriptContainerView`
wandelt geladene Transcripts über `TranscriptTimelineBuilder` in Rounds,
Prompts, Activity-Zeilen, Reports und Markdown-Blöcke. Sie kann frühere
History nachladen, abgeschnittene Köpfe markieren und optional eine
Summary-Card anzeigen.

`AgentChatTranscriptView` ist die ältere Chat-Bubble-Darstellung für rohe
Messages und Spezialzustände wie orphaned Background-Chats. Die Timeline ist
die kompakte Arbeitsansicht, die Tool-Aktivität, Teammate-Nachrichten,
Report-Inhalte und Live-Hinweise in chronologischen Runden zusammenfasst.

## Detail-Views

`AgentSessionDetailView` ist die Detailansicht für interaktive Sessions mit
PTY. Sie startet oder resumed Claude/Codex/Terminal, bindet externe
Session-IDs, meldet Launch/Termination zurück und hält Transcripts nachladbar.

`SubagentJobDetailView` ist die Detailansicht für Codex-Subagent-Jobs vor der
Übernahme. Sie rendert keinen PTY, sondern Job-Status, Auftrag, Report,
Metriken, Live-Transcript aus dem Job-Eventstrom, Stop, Follow-up-Composer,
Report-zu-Parent-Routing und die Übernahme in einen interaktiven Codex-Chat.
Nach der Übernahme greift wieder der normale `AgentSessionDetailView`-Pfad.

## Tastatur-Shortcuts

Die Agent-Chat-Shortcuts liegen als lokale `NSEvent`-Monitore in
`AgentChatsView+Shortcuts`. Sichtbar im Code sind unter anderem Tab schließen
per Cmd-W, neuer Chat per Shortcut-Pfad, Tab-Navigation mit Cmd+Option+Pfeil
beziehungsweise Cmd+Shift+Pfeil, Ctrl-Tab-Switcher mit Pfeilnavigation,
Tab-Strip-Mausradscroll, Zwei-Finger-Swipe für Tabwechsel und Doppelklick auf
die freie Titelzone für System-Zoom.

Terminal-spezifische Tastenkombinationen sind vom Fenster-Shortcut getrennt:
`TerminalKeyboardProfile` entscheidet, welche Bytes für Claude Code, Codex,
`claude agents` oder eine Plain Shell an das PTY gesendet werden.

## Schlüsseldateien

- `WhisperM8/Views/AgentChatsView.swift` ist der SwiftUI-Orchestrator für Fensterlayout, Sidebar, Header-Tabs, Detailfläche, Sheets, Store-Bridges und lokale Event-Monitore.
- `WhisperM8/Views/AgentChatsView+Shortcuts.swift` enthält die lokalen AppKit-Shortcut- und Scroll-Monitore für Tabwechsel, Cmd-W, Ctrl-Tab, Titelzonen-Zoom und Tab-Strip-Scroll.
- `WhisperM8/Views/AgentChatsSidebarViews.swift` rendert Projektgruppen, Session-Rows, Subagent-Kinder, Footer und Sidebar-Drop-Zonen.
- `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift` baut die pure, getestete Sidebar-Projektion inklusive Scope, flacher Liste, Subagent-Kindzuordnung und Variante-D-Split.
- `WhisperM8/Services/AgentChats/AgentWindowStore.swift` ist die Single Source of Truth für Fenster, Tabs, Pinning, Projekt-Expansion, Unread-Subagents und ephemere Multi-Selection.
- `WhisperM8/Views/AgentChatChromeViews.swift` enthält Chrome-Hilfen wie Mittelklick-Catcher, Drag-Exclusion, Titelzonen-Zoom und Tab-Button.
- `WhisperM8/Views/AgentStatusIndicator.swift` rendert die kompakten Statusanzeigen für working, awaiting input, idle, errored und stopped.
- `WhisperM8/Views/AgentTabSelection.swift` enthält die pure Multi-Select-Semantik der Tab-Leiste.
- `WhisperM8/Views/AgentTabReorderDrop.swift` enthält pure Reorder-Geometrie, Gruppen-Reorder und den Drop-Delegate der Tab-Leiste.
- `WhisperM8/Views/TabSwitcherModel.swift` enthält die pure Ctrl-Tab-State-Machine und Grid-Metrik.
- `WhisperM8/Views/AgentTerminalView.swift` bindet SwiftTerm ein und verwaltet Controller, Registry, Keyboard-Profile, Scroll-Guard, Link-Routing und Datei-Drop.
- `WhisperM8/Views/Transcript/` enthält die Timeline-, Markdown-, Report-, Summary- und History-Views der Transcript-Darstellung.
- `WhisperM8/Views/AgentSessionDetailView.swift` ist die Detailansicht für interaktive PTY-Sessions.
- `WhisperM8/Views/SubagentJobDetailView.swift` ist die Detailansicht für headless Codex-Subagent-Jobs.

## Keywords

Agent Chats UI, Agent-Chat-Fenster, Fenster-Chrome, versteckte Titelzeile,
Sidebar, Projektliste, Chatliste, Session-Row, Statuspunkt, arbeitet,
wartet auf Eingabe, Sidebar-Scope, Aktiv, Zuletzt, Alle, flache Sidebar,
Projektgruppen, gepinnte Chats, Archiv-Modus, Subagent-Kinder,
Subagent-Footer, Variante D, fertige Subagents, Segment-Meter,
ungelesenes Subagent-Ergebnis, globale Tabs, Tab-Leiste, Pinning,
Multi-Select, Cmd-Klick, Shift-Klick, Bulk-Aktion, Tab-Reorder,
Einfügelinie, Drag Drop, Tear-off, neues Fenster, Ctrl-Tab-Switcher,
Overflow-Menü, Terminal, SwiftTerm, LocalProcessTerminalView, PTY,
Transcript, Timeline, Report, Summary, `AgentChatsView`,
`AgentChatsView+Tabs`, `AgentChatsView+Shortcuts`,
`AgentChatsSidebarViews`, `ProjectChatGroup`, `SessionListButton`,
`AgentSidebarModelBuilder`, `SubagentChildSplit`, `AgentWindowStore`,
`AgentStatusIndicator`, `statusPublisher(for:)`, `ChatTabButton`,
`TabSelectionResolver`, `TabReorderGeometry`, `TabGroupReorder`,
`TabSwitcherModel`, `AgentTerminalRegistry`, `AgentTerminalController`,
`AgentTerminalView`, `AgentSessionDetailView`, `SubagentJobDetailView`,
`AgentTranscriptContainerView`, `AgentTimelineView`, `TranscriptTimelineBuilder`,
rechter Inspector, Projekt-Inspector, Header-Actions, Plus-Menü,
Projekt öffnen, Finder öffnen, PhpStorm öffnen, Agent View, Claude Agent View,
VIEW-Badge, aktive Subsession, `ProjectDetailPanel`,
`newChatProjectPicker`, `BackgroundDispatchModal`, `SubAgentLibrarySheet`,
`ActiveBackgroundSessionTracker`, `TerminalScrollGuard`, `TerminalShortcut`,
`TerminalDropPayload`, `PhpStormLauncher`.
