---
status: roh
updated: 2026-10-17
description: Delta-Lauf (5 Sonnet-Finder + Kritiker) auf 76256ad — Agent-UI, Grid/Notizen, Control/CLI/Board/Mod, Änderungen seit a8e0f35.
---

# Delta-Lauf

52 Befunde, davon 7 interne Dubletten, 11 erweitern einen Register-Eintrag, 2 sofort behoben.

| Finder | Kurzfazit |
|---|---|
| D1 Agent-UI: Fenster, Sidebar, Tabs | D1 gelesen auf 76256ad: Tabs/Multi-Window/Persistenz und die NSEvent-Monitore sind solide (Monitore werden in onDisappear abgebaut, Fenster-Gating, zustandsloser Hit-Test statt Hover-Flag, Debounce-Save plus flush beim Beenden, Prune diff-gated). Es gibt keinen P0 und keinen klaren P1. Die wesentlichen Befunde sind Laien-Fallen und Bestätigungslücken. (1) Bei vorhandenen, aber auto-importierten Projekten zeigt die Sidebar den Leerzustand „Noch keine Projekte", während „Neuer Chat" aktiv ist und in einem unsichtbaren Projekt startet (W4). (2) Terminal schließen, Restart, Hintergrund-Agent entfernen und Projekt löschen beenden laufende Prozesse ohne Rückfrage. Im Bulk-Archivieren sind die Terminals schon weg, bevor die Rückfrage für die Chats beantwortet ist. (3) Cmd+Q beendet alle laufenden Chats ohne Warnung. (4) Ein defekter agent-ui-state.json wird stillschweigend auf die Erst-Migration zurückgesetzt, ohne Backup (Pins, benannte Workspaces, Fenster weg). (5) Fenster-Drag (isMovable) kann nach Hover-Verlust hängen, weil SidebarResizeHandle.onDisappear den Hover nicht zurücksetzt. (6) Barrierefreiheit der Chat-UI ist praktisch nicht vorhanden: Status-Punkte nur über Farbe plus Hover-Tooltip, Close-Aktionen als Image mit onTapGesture, die nur bei Hover erscheint. Kleinere Punkte: die Tab-Chords ⌘⇧←/→ werden auch im Sidebar-Filterfeld geschluckt, der Zwei-Finger-Swipe ist nicht abschaltbar, und die Bulk-Pin-Reihenfolge ist zufällig (Set-Reihenfolge). Sprachmix (E1) ist hier nicht neu gegenüber LR-ONB-011 und wird nicht einzeln gemeldet. Register-Befunde: CPU-/Pulse-Themen sind bekannt und nicht erneut gemeldet. |
| D2 Agent-UI: Grid, Workspaces, Switcher, Randnotizen | Ich habe die D2-Dateien vollständig gelesen: Grid-View und Container, Resolver, Shrink-Modus, Drop-Zonen, Sidebar-Workspaces, alle Switcher-Dateien, Randnotizen-Views und -Store sowie den Board-Store. Dazu kamen die Workspace-Mutationen im AgentWindowStore und die UI-State-Migration, soweit sie das Grid betreffen. Ein sicherer, reproduzierbarer Befund: Beim Entfernen des fokussierten Chats aus einem Workspace mit Slot-Lücken kann die App abstürzen (Range-Trap in `gridFocusFallback`). Das passiert nach Drag in einen leeren Slot, nach Archivieren von Chats oder per CLI `workspace remove`. Der Fall ist ungetestet und liegt im Kern-Feature Grid, ich stufe ihn als P1 und Launch-Blocker ein. Weitere Befunde: Der UI-State wird bei einem einzigen Decode-Fehler komplett verworfen (inklusive des abgeleiteten, ungenutzten `layouts`-Felds), ohne Backup und nur mit `Logger.debug`. Der Divider-Drag löst weiter PTY-Resizes mit 30 Hz aus; die Dehn-Technik liegt nur im ungenutzten Layout-Paket. Das hoverbasierte Pane-Routing hat noch keinen zustandslosen Gegencheck, anders als der Tab-Strip nach dem Vorfall vom 23.08. Der Rest sind P3 (Board-Store-Härtung, O(N)-Lookups pro Pane, Shrink-Modus ohne Esc, Divider nicht per Tastatur bedienbar, toter Layout-Code). Gut gelöst und nicht anzufassen: die Switcher-Performance-Regeln werden eingehalten, die Abbruchpfade sind vollständig, und die Notiz-Hover-Flags räumen sich beim Verschwinden der View selbst auf. Das Notiz-Overlay blockiert den Klick ins Terminal nicht. Die Layout-Reihenfolge-Logik und die `WorkspaceSlotOps` sind pur und konsistent. Nicht ausgeführt wurden Build, Tests und App, alles ist statische Analyse; der Crash ist aus der Swift-Semantik abgeleitet, nicht gelaufen. |
| D3 Control-Server, Chats-CLI, Board, Plugin-Mod | Der Control-Socket ist solide gebaut: Ordner 0700, Socket 0600, getpeereid-Pruefung, flock, close-on-exec, SO_NOSIGPIPE. Die Board- und Speak-Methoden verlangen ein gueltiges Session-Token. Ich habe keinen P0 und keinen Launch-Blocker gefunden. Die staerksten Befunde liegen in der Send-Pipeline. (1) pastePrompt schreibt den Prompt ungefiltert zwischen ESC[200~ und ESC[201~. Ein eingebettetes ESC[201~ beendet den Paste-Block, und der Rest wird als Tastendruecke in die fremde TUI getippt. (2) send und Queue-Zustellung ignorieren einen vom User getippten Entwurf im Composer und haengen den Agent-Text daran. (3) enqueue stellt bei launching (das auf idle abbildet) sofort zu, ohne den Readiness-Guard, der genau diesen Race verhindern soll. (4) open/resume/unarchive rufen NSApp.activate auf und holen die App in den Vordergrund, auch waehrend der User in einer anderen App tippt. Weitere Befunde: Das Token ist nur ein Label, nichts erzwingt es, und widerrufen wird es nie. Der 10-s-Handler-Timeout passt nicht zu move-account. `chats watch` liest das ganze Journal alle 2 s neu. Die Plugin-Mod startet in jedem Chat einen CLI-Kaltstart und stapelt bei jedem session.start einen weiteren 30-s-Timer. Zum Registerabgleich: LR-PJ-001 und LR-PJ-002 bestehen weiterhin, ich habe sie nicht erneut gemeldet. Nicht gelesen oder nur ueberflogen: ChatsArchiveCommands, ChatsMoveAccountCommand (CLI-Seite), ChatsSnapshotCommand, ChatsOutput, ChatsTailFormatter, ChatsAnomalyDetector, die Mod-Tests und types/index.d.ts. Alles rein statisch, nichts ausgefuehrt, keine Laufzeitmessung. |
| D4 Delta in bereits geprüften Bereichen | Delta-Lauf D4 (a8e0f35..76256ad, ausserhalb D1-D3): Der Registry-Statuspfad ist solide gebaut. Er hat PID- und procStart-Pruefung, Grabstein gegen Scan/Event-Rennen, eine 5-s-Sperre nach Prozessende, ein Terminal-Gate (kein PTY, kein Status), ein bg-Gate und eine geordnete FSEvents-Zustellung ueber DispatchQueue.main. Kill-Switch, Ruecksprung auf Transcript und CLI-Overlay (`ChatsStatusProbe`) sind konsistent. Ich habe keinen P0/P1 und keinen Launch-Blocker gefunden. Gefunden habe ich sieben Befunde der Stufen P2/P3. (1) Der 10-s-Abbruch-Merker kann ein echtes Turn-Ende samt Queue-Zustellung verschlucken. (2) Der frische Composer-Fix (76256ad) sendet Ctrl+C anhand eines Flags, das nie an den Zustand gekoppelt wird, und das gilt provider-uebergreifend; `chats send` erlaubt standardmaessig auch `awaitingInput`. (3) Der reduzierte Hook-Satz hat kein Versions- oder Registry-Gate fuer aeltere Claude-Versionen. (4) Die Warte-Art ist teils falsch und die Benachrichtigung wird nie korrigiert. (5) Registry-`busy` umfasst delegierte Arbeit und kann Send, Queue und `wait` lange blockieren. (6) FSEvents-Pfade werden per Stringvergleich zugeordnet und brechen bei Symlink-Config-Dirs. (7) Die Statuspunkte sind nur per Farbe und Tooltip lesbar (Barrierefreiheit). Zum Ctrl+C-Tracker: Ein echter User-Entwurf geht nur verloren, wenn der Tracker ihn nie gesehen hat (Rechtsklick-Paste, System-Diktat, History-Recall per Pfeil hoch). Doppeltes Ctrl+C bis zum Beenden von Claude konnte ich nicht belegen: Der Guard-Block-Clear kommt rund 1 s spaeter, ausserhalb des 800-ms-Fensters. Beim Register-Abgleich werden LR-AK-019 und LR-AK-020 als geaendert gemeldet. Sie haben jetzt andere Auswirkungen, bestehen aber weiter. LR-KO-004 besteht unveraendert. Es wurde nichts gebaut oder ausgefuehrt; alle Aussagen stammen aus statischer Analyse. |
| D5 Laien-UX der Agent Chats (W4/W5) | Delta-Lauf D5 (Laien-UX der Agent Chats, W4/W5), rein statisch auf 76256ad. Die Agent-Chats-UI ist funktional und gut durchdacht (Bestätigungsdialoge bei laufenden PTYs, Archiv statt Löschen, Resume-Schutz gegen verlorene Transcripts). Für Laien bleiben aber echte Sackgassen. Der schwerste Befund ist W4: Fehlt die Claude- oder Codex-CLI, zeigt der Chat nur den englischen Satz „claude CLI is not installed." in einem kleinen gelben Balken. Darunter steht ein Leerzustand, der „Resume oben" verspricht. Es gibt weder Installationsweg noch Retry, und jeder Versuch legt einen weiteren Leer-Chat an. Für W5 schließt ⌘W oder das Tab-X den Tab, während Claude unsichtbar weiterläuft. ⌘Q beendet arbeitende Chats ohne Warnung und ohne automatisches Resume. Der Header-Button Restart bricht einen laufenden Turn ohne Rückfrage ab. Die Statuslegende existiert nur auf einer englischen Settings-Seite (Hooks). Status und Schließen-Aktionen sind nicht per Tastatur/VoiceOver erreichbar und teils farb- oder hover-abhängig. Sprachmix (E1), Entwicklerbegriffe und Erweitert/Labs-Einträge auf Kern-Ebene sind die übrigen Hotspots. Das USER_GUIDE hat kein Agent-Chats-Kapitel. Bereits bekannte Register-Themen sind nur mit neuem Aspekt und related_ids aufgeführt. Nicht abgedeckt: Trust-Dialog und Login laufen in Claudes eigener TUI. |

## Befunde

| ID | Ref | Schwere | Blocker | Status | Titel |
|---|---|---|---|---|---|
| LR-AU-013 | D2-01 | P1 | ja | umgesetzt (6661351) | Entfernen des fokussierten Chats aus einem Workspace mit Slot-Lücken stürzt die App ab (Range-Trap in gridFocusFallback) |
| LR-AU-022 | D5-01 | P1 | ja | neu, erweitert LR-ONB-003 | Fehlende Claude/Codex-CLI beim Chatstart: nur englischer Mini-Balken, kein Weg weiter, Leer-Chats sammeln sich an |
| LR-AK-034 | D4-01 | P2 | — | neu | Abbruch-Merker (10 s) verschluckt ein echtes Turn-Ende und strandet vorgemerkte Folgeauftraege |
| LR-AK-035 | D4-03 | P2 | — | neu | Reduzierter Hook-Satz ohne Versions- oder Registry-Gate: aeltere Claude-Versionen verlieren Status, Permission-Erkennung und ID-Nachbindung |
| LR-AK-037 | D4-05 | P2 | — | neu | Registry-`busy` umfasst delegierte Arbeit: Send, Queue, Fertig-Meldung und `wait --until idle` haengen an Subagents und Hintergrund-Tasks |
| LR-AU-004 | D1-01 | P2 | — | neu | „Neuer Chat“ startet bei nur auto-importierten Projekten in einem unsichtbaren Projekt, während die Sidebar „Noch keine Projekte“ zeigt |
| LR-AU-005 | D1-02 | P2 | — | neu | Terminal schließen, Restart, Hintergrund-Agent entfernen und Projekt löschen beenden laufende Prozesse ohne Rückfrage; im Bulk-Archivieren sind Terminals schon weg, bevor der Chat-Dialog beantwortet ist |
| LR-AU-006 | D1-03 | P2 | — | neu, erweitert LR-TRM-001 | Cmd+Q beendet alle laufenden Chats ohne Warnung und markiert den Lauf als sauber, sodass kein Chat automatisch wieder anläuft |
| LR-AU-007 | D1-04 | P2 | — | neu, erweitert LR-AK-002 | Defekter oder nicht dekodierbarer agent-ui-state.json wird stillschweigend durch die Erst-Migration ersetzt, ohne Backup |
| LR-AU-008 | D1-05 | P2 | — | neu | Fenster-Verschieben (isMovable) kann dauerhaft aus bleiben: SidebarResizeHandle und Inspector setzen den Hover beim Verschwinden nicht zurück |
| LR-AU-009 | D1-06 | P2 | — | neu | Chat-UI ist für VoiceOver und Farbfehlsichtigkeit kaum bedienbar: Status nur über Farbe plus Hover-Tooltip, Schließen-Aktionen als Image mit onTapGesture und nur bei Hover sichtbar |
| LR-AU-014 | D2-02 | P2 | — | neu, Dublette von LR-AU-007, erweitert LR-AK-029 | UI-State: ein Decode-Fehler (auch im abgeleiteten, ungenutzten `layouts`-Feld) verwirft alle Tabs und Workspaces ohne Backup und ohne persistiertes Log |
| LR-AU-015 | D2-03 | P2 | — | neu | Divider-Drag und Fenster-Resize erzeugen PTY-Resizes mit ~30 Hz je betroffener Pane (Dehn-Technik nur im ungenutzten Layout-Paket) |
| LR-AU-016 | D2-04 | P2 | — | neu | Pane-Fokus-Routing per Maus hängt am Hover-Flag ohne zustandslosen Gegencheck: ein verlorenes onHover(false) lässt Klicks außerhalb des Grids die Selektion verschieben |
| LR-AU-023 | D5-02 | P2 | — | neu, Dublette von LR-AU-006 | ⌘Q/Menü-Beenden stoppt arbeitende Chats ohne Warnung; nach sauberem Quit kein automatisches Resume |
| LR-AU-024 | D5-03 | P2 | — | neu | Tab schließen (X, ⌘W, Mittelklick) lässt den Chat unsichtbar weiterlaufen, ohne Hinweis |
| LR-AU-025 | D5-04 | P2 | — | neu, Dublette von LR-AU-005 | Header-Button Restart bricht einen laufenden Turn ohne Rückfrage ab; Beschriftung Englisch/Jargon |
| LR-AU-026 | D5-05 | P2 | — | neu, Dublette von LR-AU-009 | Status-Punkte ohne Legende im Hauptfenster, nur Farbe/Hover; Legende versteckt auf englischer Settings-Seite |
| LR-AU-027 | D5-06 | P2 | — | neu, Dublette von LR-AU-009 | Schließen-Aktionen in Sidebar und Tabs sind hover-only Bilder mit onTapGesture: weder Tastatur noch VoiceOver; der aktive Chat verliert seinen Status-Punkt |
| LR-AU-028 | D5-07 | P2 | — | neu, Dublette von LR-AU-030, erweitert LR-ONB-011 | Technische, teils englische Fehlermeldungen mit Pfaden und Session-IDs im Chatstart |
| LR-AU-029 | D5-08 | P2 | — | neu | Leerzustände ohne Anleitung; Markdown-Sternchen und widersprüchliche Begriffe |
| LR-AU-030 | D5-09 | P2 | — | neu, erweitert LR-ONB-011 | Sprachmix Deutsch/Englisch (E1): konkrete Hotspots in Agent-Chats-UI und Settings |
| LR-AU-031 | D5-10 | P2 | — | neu, erweitert LR-ONB-012 | Erweitert/Labs-Funktionen und Entwicklerjargon im Standard-UI der Chats |
| LR-AU-032 | D5-11 | P2 | — | neu | Platzhalter --dangerously-skip-permissions im Feld für zusätzliche CLI-Argumente |
| LR-CLI-001 | D3-01 | P2 | — | neu | Prompt-Zustellung ist nicht gegen eingebettetes Paste-Ende (ESC[201~) und Steuerzeichen gesichert |
| LR-CLI-002 | D3-02 | P2 | — | neu, erweitert LR-KO-004 | send und Queue-Zustellung haengen den Agent-Prompt an einen vom User getippten Entwurf und schicken beides ab |
| LR-CLI-003 | D3-03 | P2 | — | neu | `chats enqueue` stellt bei launching sofort zu und umgeht den Readiness-Guard, den die Fehlermeldung als Ausweg empfiehlt |
| LR-CLI-004 | D3-04 | P2 | — | neu | Steuerbefehle (open, resume, unarchive --open/--resume) holen die App per NSApp.activate in den Vordergrund und stehlen den Fokus waehrend der User tippt |
| LR-CLI-008 | D3-08 | P2 | — | neu | Handler-Timeout 10 s passt nicht zu move-account: Antwort `Zustand unklar` waehrend der Umzug weiterlaeuft |
| LR-CLI-009 | D3-09 | P2 | — | neu | `chats watch` liest und dekodiert das komplette Status-Journal (bis 2 MB) alle 2 s je Jarvis-Session |
| LR-DOK-009 | D5-13 | P2 | — | neu, erweitert LR-DOK-005 | USER_GUIDE ohne Agent-Chats-Kapitel; Hooks-Seite beschreibt veralteten Statusweg |
| LR-PJ-003 | D3-10 | P2 | — | neu | Plugin-Mod verursacht in jedem WhisperM8-Chat CLI-Kaltstarts und stapelt bei jedem session.start einen weiteren 30-s-Timer |
| LR-TRM-002 | D4-02 | P2 | — | umgesetzt (46bab45), erweitert LR-KO-004 | Composer-Clear (Ctrl+C) haengt an einem zustandslosen Flag und gilt fuer alle Provider und Wartezustaende |
| LR-AK-036 | D4-04 | P3 | — | neu | Warte-Art aus Registry: veraltetes letztes Tool und vorlaeufige Art in der Benachrichtigung |
| LR-AK-038 | D4-06 | P3 | — | neu | Registry-FSEvents werden per exaktem Pfad-String den Profilen zugeordnet; Symlink-Config-Dirs liefern keine Live-Updates |
| LR-AU-010 | D1-07 | P3 | — | neu | ⌘⇧←/→ wird im ganzen Agent-Fenster als Tab-Wechsel konsumiert, auch bei Fokus in Textfeldern des Fensters (Sidebar-Filter, Archiv-Suche) |
| LR-AU-011 | D1-08 | P3 | — | neu | Zwei-Finger-Horizontal-Swipe wechselt im ganzen Fenster den Tab, ist nicht abschaltbar und wird konsumiert |
| LR-AU-012 | D1-09 | P3 | — | neu | Bulk-Pin und Bulk-Aktionen arbeiten in zufälliger Set-Reihenfolge; die Reihenfolge angepinnter Chats wird beim Mehrfach-Anpinnen vertauscht |
| LR-AU-017 | D2-05 | P3 | — | neu | Jarvis-Board-Store: Lesefehler gilt als „keine Datei“ und überschreibt das Board; Quarantäne löscht vorherige Beweise; ein defekter Eintrag zerstört das ganze Board |
| LR-AU-018 | D2-06 | P3 | — | neu | Pro Grid-Pane und Sidebar-Slot O(Sessions)-Lookups im Body (selectedSession, projects.first, sessions.first), im Fallback sogar headerTabs über alle Sessions |
| LR-AU-019 | D2-07 | P3 | — | neu | Shrink-Auswahlmodus ist nur per Maus abbrechbar (kein Esc) und nur per Maus bedienbar |
| LR-AU-020 | D2-08 | P3 | — | neu | Etwa 1.400 Zeilen Layout-Paket (WorkspaceLayout, LayoutEngine, WorkspaceLayoutView) sind nirgends eingebunden, ihre Ableitung läuft aber bei jedem Laden und wird mitpersistiert |
| LR-AU-021 | D4-07 | P3 | — | neu, Dublette von LR-AU-009 | Statuspunkte nur per Farbe und Tooltip unterscheidbar, ohne VoiceOver-Label |
| LR-AU-033 | D5-12 | P3 | — | neu, erweitert LR-ONB-016 | Sehr kleine Schriften (8-10 pt) und Kontrastarmut in Chat-Chrome |
| LR-AU-034 | D5-14 | P3 | — | neu | Warnsymbol für gelöschtes Transcript nur per Tooltip erklärt |
| LR-BR-010 | D3-14 | P3 | — | neu | Deinstallation hinterlaesst `~/.local/bin/whisperm8` als toten Symlink; laufende Chats behalten Hooks auf das entfernte Binary (W7) |
| LR-CLI-005 | D3-05 | P3 | — | neu | Control-Token ist nur ein Label: kein Befehl erzwingt es, kein Widerruf, Token liegt im Env aller Kindprozesse |
| LR-CLI-006 | D3-06 | P3 | — | neu | Socket-Server: Slot-Erschoepfung durch langsamen Client, /tmp-Fallbackordner ohne Eigentuemerpruefung, Client prueft den Server-Owner nicht |
| LR-CLI-007 | D3-07 | P3 | — | neu | `chats address` oeffnet Claudes native SendMessage-Bruecke ueber alle Konten, an Audit, Marker und Selbstschutz vorbei |
| LR-CLI-010 | D3-11 | P3 | — | neu | `chats wait` pollt doppelt, probt jede Session zweimal beim Start und beobachtet bei leerem Scope alle Chats der letzten 14 Tage |
| LR-CLI-011 | D3-12 | P3 | — | neu | Audit-Log fuehrt queue-deliver immer als verified: true, auch wenn der Auftrag von einem unverifizierten oder externen Aufrufer stammt |
| LR-PJ-004 | D3-13 | P3 | — | neu | Board- und Chat-Titel gehen ungefiltert (nur Zeilenumbrueche entfernt) in Mod-Anzeige und Jarvis-Weck-Prompt |

### LR-AU-013 (D2-01) · Entfernen des fokussierten Chats aus einem Workspace mit Slot-Lücken stürzt die App ab (Range-Trap in gridFocusFallback)

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/AgentWindowStore.swift:649-680 (removeSession: removedIndex aus ALTER Entity, Fallback gegen die KOMPAKTIERTE `updated`-Entity)`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:1004-1011 (gridFocusFallback: entity.slots[removedIndex...] und entity.slots[..<removedIndex] ohne Klemmung)`, `WhisperM8/Services/AgentChats/WorkspaceSlotOps.swift:206-243 (remove(compacting: true) senkt capacity auf die kleinste passende Stufe, slots.count schrumpft)`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:762-768 (setCapacity klemmt anchor, removeSession nicht)`, `WhisperM8/Views/AgentChatsView+Grid.swift:51 und :960-975 (⊖ im Pane-Header)`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:844 (CLI workspace remove, gleicher Pfad)`, `Tests/WhisperM8Tests/AgentGridWorkspaceStoreTests.swift:630-690 (Tests entfernen nur Index 1/2 und decken kein removedIndex > neue Slot-Anzahl ab)`

**Szenario:** 2×2-Workspace mit Chats A und B → Header von B in den leeren Slot 4 ziehen (moveSlot) → Slots [A, nil, nil, B], B ist fokussiert. Klick auf ⊖ im Pane-Header von B (oder Kontextmenü „Aus Workspace entfernen“, oder CLI `whisperm8 chats workspace remove`): compacted() macht daraus [A, nil] mit Kapazität 2, removedIndex = 3. gridFocusFallback bildet `slots[3...]` auf einem Array der Länge 2, das ist ein fatal error „Range requires lowerBound <= upperBound“, die App beendet sich samt aller PTY-Chats. Dieselben Slot-Lücken entstehen auch, wenn zwei Chats eines 4er-Workspace archiviert werden (prune setzt nil ohne Kompaktierung), weil nur der Slot-Index des Fokus-Chats zählt.

**Fix:** In removeSession den Fallback gegen die neue Entity klemmen: anchor = min(removedIndex, updated.slots.count) (wie in setCapacity), oder gridFocusFallback selbst robust machen (clamp auf 0...slots.count). Zusätzlich im selben Zug AgentUIState.prune (entity.slots[anchor.index...], Zeile 563/564) mit demselben Clamp absichern, dort ist es derzeit nur durch unveränderte Slot-Anzahl geschützt.

**Regressionstest:** Store-Test: Workspace-Kapazität 4, createGridWorkspace(slots:[A,nil,nil,B], activateIn:w), setGridFocusedSession(B), removeSession(B) → darf nicht crashen, selectedSession == A. Gleiches für Kapazität 6 mit [A,nil,nil,nil,nil,F].

### LR-AU-022 (D5-01) · Fehlende Claude/Codex-CLI beim Chatstart: nur englischer Mini-Balken, kein Weg weiter, Leer-Chats sammeln sich an

*P1 · Launch-Blocker · ux · Konfidenz hoch · Aufwand M*

**Beleg:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:36`, `WhisperM8/Views/AgentSessionDetailView.swift:66-86`, `WhisperM8/Views/AgentSessionDetailView.swift:514-518`, `WhisperM8/Views/Transcript/TranscriptEmptyStateView.swift:98`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:72-92`

**Szenario:** Laie ohne installierte Claude-CLI öffnet ein Projekt und klickt Neuer Chat. createSession legt die Session mit shouldLaunchOnOpen an, der Launch wirft commandNotFound. Sichtbar wird nur der 12-pt-Balken claude CLI is not installed. (Englisch, kein Link, keine Installationsanleitung, kein Login-Hinweis). Darunter steht der Leerzustand Klick Resume oben, obwohl Resume ohne CLI nicht funktionieren kann. Wer erneut Neuer Chat klickt, erzeugt jedes Mal einen weiteren persistierten Claude Chat. Der Balken verschwindet beim Tab-Wechsel. Verletzt W4 (App erkennt fehlende CLI und führt durch Installation und Login).

**Fix:** Vor dem Anlegen der Session (und im Fehlerpfad) die CLI per commandPath prüfen. Statt des Balkens einen Leerzustand im Detailbereich zeigen: lokalisiert, Titel Claude Code ist noch nicht installiert, offizieller Installationsweg (E5: geführte Installation mit Rückfrage), Button Erneut prüfen, Login-Hinweis. Keine Session anlegen, solange die CLI fehlt. Den Resume-Text im Leerzustand an den Fehlerzustand koppeln.

### LR-AK-034 (D4-01) · Abbruch-Merker (10 s) verschluckt ein echtes Turn-Ende und strandet vorgemerkte Folgeauftraege

*P2 · korrektheit · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:545-548`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:689-692`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:673-676`, `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:323-327`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:897-908`, `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:30-35`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:263-264`

**Szenario:** Der Merker entsteht allein aus einem ESC im Terminal oder aus `chats interrupt`, solange der Status noch `working` zeigt. Er wird nicht gegen das Transcript geprueft. Der User drueckt ESC kurz vor oder waehrend Claude fertig wird; der Registry-Wechsel kommt nach FSEvents-Latenz erst danach. Oder Jarvis unterbricht einen Chat, dessen Turn gerade endete. Oder ESC wirkt nicht, etwa waehrend nur delegierte Arbeit laeuft. Das folgende echte `idle` innerhalb von 10 s wird als Abbruch gewertet (`.idle(interrupted:true)` -> `.ready` ohne `.turnCompleted`). Die Folge: kein Ton, keine Fertig-Meldung, und `AgentPromptQueueDelivery.deliverNext` laeuft nur ueber `turnCompleted`. Ein per `chats enqueue` vorgemerkter Folgeauftrag bleibt bei einem ruhenden Chat dauerhaft offen, bis irgendein spaeterer Turn endet. Vor 17.10. war ein ESC ohne Aktivitaetsstille folgenlos (5-s-Verifikation).

**Fix:** Den Merker nur dann als Abbruch werten, wenn der Transcript-Decider den Abbruch bestaetigt (`decision.turnAborted` bzw. Marker `[Request interrupted by user]`) oder das Transcript nach dem Merker nicht mehr gewachsen ist. Alternativ bei verworfenem `turnCompleted` offene Queue-Auftraege trotzdem nach dem Settle-Delay zustellen, sobald der Status stabil `idle` ist. Den Merker beim ersten Hook- oder Registry-Wechsel nach `busy` verwerfen.

**Regressionstest:** Reducer/Coordinator-Test: Merker setzen, danach busy -> idle innerhalb 2 s ohne Transcript-Abbruch-Marker; erwartet turnCompleted oder Queue-Zustellung. Plus Test, dass ein bestaetigter Abbruch weiterhin still bleibt.

### LR-AK-035 (D4-03) · Reduzierter Hook-Satz ohne Versions- oder Registry-Gate: aeltere Claude-Versionen verlieren Status, Permission-Erkennung und ID-Nachbindung

*P2 · robustheit · Konfidenz niedrig · Aufwand M*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:162-164`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:258-276`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:47`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:385-390`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:1055-1068`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:379-383`

**Szenario:** `usesReducedHooks` prueft nur den Kill-Switch und `isBackground`, nicht die installierte Claude-Version und nicht, ob die CLI ueberhaupt `<config>/sessions/<pid>.json` schreibt. Eine aeltere oder angepinnte `claude`-Version erhaelt trotzdem nur SessionStart/SessionEnd. Dann fehlt jede Registry-Quelle, der Status kommt wie bei Codex nur aus dem Transcript. `PermissionRequest` entfaellt, ein Permission-Dialog wird nicht als `awaitingInput` erkannt. `resolvePendingBinding` loest eine nach `/clear` oder `/background` zurueckgestellte ID nie auf, weil es keine Turn-Hooks mehr gibt und `bindPendingExternalID` die Registry braucht. Der Chat bleibt an der alten ID, und `--resume` laedt den Verlauf von vor `/clear`; das ist die Klasse des Vorfalls vom 30.09. Die Hook-Datei ist beim Launch fixiert, ein spaeteres Erkennen hilft nicht. Das Mindestalter der Registry ist im Plan nicht belegt.

**Fix:** Beim Launch die Claude-Version lesen (`claude --version`, einmal gecacht ueber `AgentCommandBuilder.commandPath`) und den reduzierten Satz nur ab der Version waehlen, in der die Registry belegt ist (2.1.302 gemessen; kleinste funktionierende Version ermitteln). Sonst den vollen Hook-Satz nehmen. Ersatzweise `PermissionRequest` und `UserPromptSubmit` in den reduzierten Satz aufnehmen (kein Tool-Hook, nur seltene Events).

**Regressionstest:** Coordinator-Test mit injizierter Versionsabfrage: unter der Mindestversion muss `prepareLaunch` den vollen Satz schreiben und die Session als hook-live fuehren.

### LR-AK-037 (D4-05) · Registry-`busy` umfasst delegierte Arbeit: Send, Queue, Fertig-Meldung und `wait --until idle` haengen an Subagents und Hintergrund-Tasks

*P2 · ux · Konfidenz niedrig · Aufwand M*

**Beleg:** `docs/plans/claude-status-aus-registry.md:42-46`, `WhisperM8/Services/AgentChats/ClaudeSessionRegistry.swift:157-165`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:141`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:178-183`, `WhisperM8/CLI/ChatsStatusProbe.swift:54-86`

**Szenario:** Laut Plan steht `busy` auch fuer 'delegierte Arbeit (Subagents, Hintergrund-Tasks)'. Gemessen wurde nur Bash mit `run_in_background` (-> `shell`), nicht ein Task-Subagent im Hintergrund. Hat ein Chat die Antwort fertig geschrieben, delegierte Arbeit laeuft aber 30 Min weiter, zeigt die Sidebar 'arbeitet'. `chats send` meldet 'Ziel ist working' (Default erlaubt nur awaitingInput/idle). `enqueue` wird erst nach dem Ende der Hintergrundarbeit zugestellt, 'fertig' (Ton, Meldung) kommt erst dann, und `chats wait --until idle` bzw. Jarvis wartet entsprechend lange. Vorher setzte der Stop-Hook den Chat nach dem Turn auf idle. Der Plan nennt Send, Queue und `wait` als Folge nicht.

**Fix:** Mit einem Live-Test bestaetigen (Task-Subagent im Hintergrund, Registry-Wert mitschreiben). Falls bestaetigt: fuer die Sidebar eine eigene Anzeige 'wartet auf Hintergrundarbeit' (Registry busy + Transcript-Turn-Ende erkannt), die send/enqueue/Fertig-Meldung freigibt. Das Verhalten im Skill 'whisperm8-chats' dokumentieren.

**Regressionstest:** Live-Messung: Task-Subagent run_in_background starten, danach `chats list --json` und Registry-Datei alle 1 s protokollieren, bis der Subagent endet.

### LR-AU-004 (D1-01) · „Neuer Chat“ startet bei nur auto-importierten Projekten in einem unsichtbaren Projekt, während die Sidebar „Noch keine Projekte“ zeigt

*P2 · ux · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentChatsView.swift:427-429 (selectedProject fällt auf workspace.projects.first zurück, ohne isManuallyAdded zu prüfen)`, `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift:162-168 (Sidebar und hasManualProjects zählen nur isManuallyAdded)`, `WhisperM8/Views/AgentChatsView.swift:1513-1514 (sidebarEmptyState bei !hasManualProjects)`, `WhisperM8/Views/AgentChatsView.swift:2135-2137 (Neuer-Chat-Button nur bei selectedProject == nil deaktiviert; Hinweis „Erst ein Projekt hinzufügen“ steht nur im Hover-Tooltip)`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:33 (guard let selectedProject else { return } kehrt lautlos zurück)`, `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:173-175 (auto-importierte Pseudo-Projekte wie Home/Downloads sind bewusst nicht sichtbar)`

**Szenario:** Nutzer hat die Claude-CLI schon im Terminal benutzt und installiert WhisperM8. Der Indexer importiert ~/.claude/projects als Projekte ohne createdManually, zum Beispiel $HOME oder ein altes Repo. Die Sidebar zeigt „Noch keine Projekte – Füge ein Projekt hinzu“, der Button „Neuer Chat“ ist aber aktiv und trägt den Namen eines unsichtbaren Projekts. Ein Klick startet Claude in diesem zufälligen Verzeichnis (erste Trust-Abfrage dort), und der Chat erscheint in der gruppierten Sidebar unter keinem Projekt. Das ist eine Sackgasse in W4 (erster Agent-Chat).

**Fix:** selectedProject und die Aktivierung des Neuer-Chat-Buttons auf manuell hinzugefügte Projekte beschränken, also manualProjects statt workspace.projects als Fallback. Ohne manuelles Projekt den Button zum „Projekt hinzufügen…“-Pfad machen, mit sichtbarem Text statt Tooltip. reconcileSelection analog anpassen (selectedProjectID und prefix(3) der expandedProjectIDs).

**Regressionstest:** Unit-Test auf einen puren selectedProject-Resolver: Workspace mit nur createdManually == nil Projekten ergibt nil. UISnapshot-Fixture „nur importierte Projekte“.

### LR-AU-005 (D1-02) · Terminal schließen, Restart, Hintergrund-Agent entfernen und Projekt löschen beenden laufende Prozesse ohne Rückfrage; im Bulk-Archivieren sind Terminals schon weg, bevor der Chat-Dialog beantwortet ist

*P2 · datenintegritaet · Konfidenz hoch · Aufwand M*

**Beleg:** `WhisperM8/Views/AgentChatsView+Tabs.swift:129 (requestArchive schließt isTerminal-Sessions sofort)`, `WhisperM8/Views/AgentChatsView+Tabs.swift:171-176 (requestEndSession: Terminals vor jeder Bestätigung geschlossen)`, `WhisperM8/Views/AgentChatsView+Tabs.swift:216-229 (closeTerminalSession: terminate + deleteSession, Scrollback nicht wiederherstellbar)`, `WhisperM8/Views/AgentSessionDetailView.swift:346-347 und 608-611 (Restart = terminate + Neustart ohne Dialog)`, `WhisperM8/Views/AgentChatsView.swift:3361-3368 und WhisperM8/Views/AgentChatsView+SessionMenus.swift:127-137 (Header-Button und Kontextmenü „Restart“ bei laufendem Chat, auch mitten im Turn)`, `WhisperM8/Views/AgentChatsView+SessionMenus.swift:238-240 und WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:239-257 („Vom Supervisor entfernen“ ruft .rm direkt auf)`, `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:50-60 und WhisperM8/Views/AgentChatsView.swift:860-874 (Projekt löschen beendet laufende PTYs; der Dialogtext nennt das nicht)`

**Szenario:** (a) Nutzer markiert 3 Chats (1 laufend) und 2 Terminals mit einem laufenden Dev-Server und wählt „5 schließen/archivieren“. Die Terminals werden sofort beendet und gelöscht. Danach fragt der Dialog nach den Chats, und „Abbrechen“ stellt die Terminals nicht wieder her. (b) Ein Klick auf „Restart“ bei einem Chat mitten im Turn, oder mit Entwurf im Composer, bricht den Turn ab und verwirft den Entwurf, ohne Warnung. Das Label ist für Laien unklar. (c) „Projekt löschen“ beendet laufende Chats, der Dialog nennt nur die Anzahl der Chats. (d) „Vom Supervisor entfernen“ löscht einen laufenden Hintergrund-Agent ohne Rückfrage.

**Fix:** Terminals nach demselben Muster wie Chats behandeln: Rückfrage nur, wenn die Shell ein Kindprozess hat oder der Chat working oder awaitingInput ist. Die Terminal-Schließung erst im Commit-Pfad ausführen, damit „Abbrechen“ alles unangetastet lässt. Restart nur mit confirmationDialog, wenn Status ≠ idle. In den Dialogtext von „Projekt löschen“ die Zahl laufender Chats aufnehmen. Für .rm eine Bestätigung ergänzen.

**Regressionstest:** Pure Entscheidungsfunktion (needsConfirmation(session, status, hasChildProcess)) mit Tests; Test, dass requestArchive bei Abbruch keine Terminal-Session löscht.

### LR-AU-006 (D1-03) · Cmd+Q beendet alle laufenden Chats ohne Warnung und markiert den Lauf als sauber, sodass kein Chat automatisch wieder anläuft

*P2 · ux · Konfidenz mittel · Aufwand M*

**Beleg:** `WhisperM8/WhisperM8App.swift:440-455 (applicationShouldTerminate sendet allen laufenden Terminals zweimal Ctrl-C, schläft 80+180 ms und gibt .terminateNow zurück, ohne Dialog)`, `WhisperM8/WhisperM8App.swift:446 (AgentCrashRecoveryMarker.endRunCleanly entfernt den Wiederaufnahme-Marker)`, `WhisperM8/Views/AgentTerminalView.swift:448-456 (captureAllSnapshotsForAppQuit blockiert den Main Thread per usleep)`

**Szenario:** Nutzer hat 8 Chats, 3 davon arbeiten gerade an langen Aufgaben, und drückt Cmd+Q (oder tippt das Q versehentlich). Die App sendet Ctrl-C an alle Chats, bricht die laufenden Turns ab und beendet sich ohne Rückfrage. Beim nächsten Start stehen die Tabs da, aber kein Chat läuft. Der Recovery-Marker gilt nur für Abstürze, jeder Chat muss einzeln wieder aufgenommen werden. Das verletzt W5 („kein Datenverlust bei Neustart“) für laufende Arbeit. Das Anhalten der Turns ist zudem für den Nutzer unsichtbar.

**Fix:** Vor .terminateNow prüfen, ob Sessions working oder awaitingInput sind. Wenn ja, NSAlert „N Chats arbeiten noch – trotzdem beenden?“ mit Option „Beenden“ oder „Abbrechen“. Optional beim sauberen Beenden die zuletzt laufenden Chats für „beim nächsten Start fortsetzen“ vormerken, mit Einstellung. SIGTERM von make dev muss den Dialog umgehen, also nur den Cmd+Q- oder Menüpfad abfangen.

**Regressionstest:** Pure Funktion quitNeedsConfirmation(statuses) testen. Manuelle QA mit 2 working Chats.

### LR-AU-007 (D1-04) · Defekter oder nicht dekodierbarer agent-ui-state.json wird stillschweigend durch die Erst-Migration ersetzt, ohne Backup

*P2 · datenintegritaet · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStore.swift:65-78 (Dekodierfehler → AgentUIState.initialMigration(from: workspace), needsPersist = true, nur Logger.debug)`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:127-137 (Repair-Save überschreibt die Datei sofort)`, `WhisperM8/Models/AgentUIState.swift:291 (höheres schemaVersion wird nicht migriert, die Datei danach kanonisch neu kodiert; unbekannte Felder gehen verloren)`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:58-70 (der Workspace selbst legt vor dem Verwerfen ein Backup an, der UI-State nicht)`

**Szenario:** agent-ui-state.json enthält einen Typfehler (Teilschreiben, manuelle Änderung, Downgrade auf eine Version mit anderem Schema). Beim Start schlägt der Decode fehl. Die App baut die Tabs aus dem Workspace neu auf und überschreibt die Datei sofort. Pins, benannte Grid-Workspaces samt Slot-Layout, Sekundärfenster, Tab-Reihenfolge und Gruppen-Einklappzustand sind unwiederbringlich weg, und das Log zeigt nur eine Debug-Zeile (nicht persistiert). Bei W5 und W6 (Update ohne Datenverlust) ist das ein stiller Verlust von Nutzerzustand.

**Fix:** Vor dem Überschreiben die defekte Datei nach agent-ui-state.json.decode-failed-<zeit> kopieren (Muster AgentWorkspaceRepository.backup) und per Logger.notice loggen. Bei schemaVersion > current die Datei nicht anfassen, sondern in-memory arbeiten oder ebenfalls ein Backup anlegen.

**Regressionstest:** Test mit absichtlich kaputtem JSON: es entsteht eine .decode-failed-Kopie, und der Inhalt der Kopie entspricht dem Original.

### LR-AU-008 (D1-05) · Fenster-Verschieben (isMovable) kann dauerhaft aus bleiben: SidebarResizeHandle und Inspector setzen den Hover beim Verschwinden nicht zurück

*P2 · robustheit · Konfidenz niedrig · Aufwand S*

**Beleg:** `WhisperM8/Views/SidebarResizeHandle.swift:36-40 (onHover meldet onHoverChanged)`, `WhisperM8/Views/SidebarResizeHandle.swift:57-61 (onDisappear setzt nur den Cursor zurück, ruft onHoverChanged(false) nicht)`, `WhisperM8/Views/AgentChatsView.swift:749 und 777 (onHoverChanged → hostWindow?.isMovable = !hovering)`, `WhisperM8/Views/AgentChatsView.swift:1095-1100 und 2901 (Tab-Strip: isHoveringTabStrip → isMovable)`, `WhisperM8/Views/AgentChatsView.swift:355-363 (Kommentar räumt ein, dass ein hängendes Flag „höchstens das Fenster-Verschieben bis zum nächsten Hover“ kostet)`, `WhisperM8/Views/AgentChatsWindowAccessor.swift:46 und 60-67 (kein Zurücksetzen von isMovable bei didResignKey oder Fensterwechsel)`

**Szenario:** Maus steht über dem Sidebar-Resize-Rand oder einem Tab. Der Nutzer blendet per Tastenkürzel Sidebar oder Inspector aus, öffnet ein Kontextmenü oder wechselt per Cmd+Tab. onHover(false) kommt nie an, window.isMovable bleibt false. Das Fenster lässt sich über das Titelband nicht mehr verschieben, bis die Maus zufällig wieder über die Leiste oder den Rand fährt und sie verlässt. Für Laien wirkt das wie ein hängendes Fenster. Wahrscheinlichkeit gering (der Vorfall 23.08. betraf dasselbe Flag-Muster), Wirkung begrenzt.

**Fix:** isMovable zustandslos setzen. Im vorhandenen leftMouseDown-Monitor (installTitleBarZoomHandlerIfNeeded) vor jedem Mausklick isMovable = !(isPointerInTabStripBand(event) || Zeiger über Resize-Handle) berechnen. Zusätzlich in SidebarResizeHandle.onDisappear und im onResignKey-Callback hostWindow.isMovable = true setzen.

**Regressionstest:** Manuelle QA: Zeiger auf Resize-Rand, Sidebar per Shortcut ausblenden, danach Fenster am Titelband ziehen.

### LR-AU-009 (D1-06) · Chat-UI ist für VoiceOver und Farbfehlsichtigkeit kaum bedienbar: Status nur über Farbe plus Hover-Tooltip, Schließen-Aktionen als Image mit onTapGesture und nur bei Hover sichtbar

*P2 · ux · Konfidenz hoch · Aufwand M*

**Beleg:** `WhisperM8/Views/AgentStatusIndicator.swift:35-77 (kein accessibilityLabel; Bedeutung working, awaiting, idle nur über Farbe und .help-Tooltip)`, `WhisperM8/Views/AgentChatsSidebarViews.swift:886-893 und 1103-1110 (Close/Archiv/Wiederherstellen als Image + onTapGesture, kein Button, keine Accessibility-Trait)`, `WhisperM8/Views/AgentChatsSidebarViews.swift:1101-1103 (Aktion nur bei isHovered sichtbar, nicht bei Selektion)`, `WhisperM8/Views/AgentChatChromeViews.swift:355-368 (Tab-Schließen-X nur bei Hover oder Selektion, ebenfalls onTapGesture)`, `Anzahl accessibilityLabel in AgentChatsView*.swift, AgentChatsSidebarViews, AgentChatChromeViews: 2, 1, 1, in AgentStatusIndicator: 0`

**Szenario:** Ein VoiceOver-Nutzer hört bei Sidebar-Zeilen und Tabs weder, ob ein Chat arbeitet, auf Eingabe wartet oder bereit ist, noch findet er die Schließen- oder Archivieren-Aktion, weil sie kein Button ist und nur bei Hover existiert. Auch ein Nutzer mit Rot-Grün-Schwäche kann „arbeitet“ (grün) und „wartet“ (Amber) nur am Puls unterscheiden, und der entfällt im kompakten Tab-Punkt. Das widerspricht der Projektregel „kein Hover-only-UI“ und der Barrierefreiheit-Dimension.

**Fix:** AgentStatusIndicator mit accessibilityLabel und -value (Arbeitet, Wartet auf dich, Bereit, Fehler) versehen. Einen Fallback ergänzen, der auch ohne Farbe unterscheidbar ist (Form oder Symbol für awaiting). Die Close-Aktionen als Button mit accessibilityLabel (z. B. closeHelp) umsetzen und per .accessibilityAction im Zeilenelement anbieten. Der Zeile ein zusammengefasstes accessibilityElement mit Titel, Status und Projekt geben.

**Regressionstest:** Accessibility-Inspector-Lauf und ein Snapshot-Test, der prüft, dass jede Zeile einen nicht leeren accessibilityLabel hat.

### LR-AU-014 (D2-02) · UI-State: ein Decode-Fehler (auch im abgeleiteten, ungenutzten `layouts`-Feld) verwirft alle Tabs und Workspaces ohne Backup und ohne persistiertes Log

*P2 · datenintegritaet · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Models/AgentUIState.swift:255 (layouts per try decodeIfPresent, streng)`, `WhisperM8/Models/AgentUIState.swift:291-302 und :386 (layouts wird bei JEDEM Load aus gridWorkspaces neu abgeleitet und danach mitgeschrieben)`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:72-80 (catch → initialMigration(from:), needsPersist = true, nur Logger.debug)`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:135-145 (saveUIState überschreibt die Datei atomar ohne Sicherung der alten)`, `WhisperM8/Views/Workspace/WorkspaceLayoutView.swift und WhisperM8/Services/AgentChats/Layout/* (nirgends instanziiert, nur Tests)`, `CLAUDE.md: Logger.debug wird nicht persistiert`

**Szenario:** Eine spätere Version ändert die Struktur von `layouts` (S6 des Workspace-Umbaus, `gridWorkspaces` entfällt) und der User spielt per brew eine ältere Version ein, oder die Datei enthält einen Wert, den die Codable-Synthese ablehnt. JSONDecoder wirft, loadUIState fällt auf initialMigration zurück, speichert sofort und überschreibt agent-ui-state.json: offene Tabs, Fensteraufteilung und alle Grid-Workspaces sind weg. Im Log steht nichts Dauerhaftes (debug). Das ist exakt das dokumentierte „Tab-State-Totalverlust“-Muster, nur für ein Feld, das beim Laden ohnehin verworfen und neu berechnet wird.

**Fix:** `layouts` tolerant lesen: `(try? c.decodeIfPresent(...)) ?? []`, weil es ohnehin neu abgeleitet wird. Im Fallback-Pfad die kaputte Datei vor dem Überschreiben nach agent-ui-state.json.corrupt-<zeit> verschieben (wie JarvisBoardStore.loadForWriting) und mit Logger.info loggen. Mittelfristig: solange S6 offen ist, `layouts` gar nicht persistieren.

**Regressionstest:** Test: UI-State-JSON mit absichtlich defektem `layouts`-Eintrag laden → Tabs und gridWorkspaces bleiben erhalten; bei defektem Gesamtdokument entsteht eine .corrupt-Kopie.

### LR-AU-015 (D2-03) · Divider-Drag und Fenster-Resize erzeugen PTY-Resizes mit ~30 Hz je betroffener Pane (Dehn-Technik nur im ungenutzten Layout-Paket)

*P2 · performance · Konfidenz mittel · Aufwand M*

**Beleg:** `WhisperM8/Views/AgentGridSplitContainer.swift:285-317 (Sampler wendet alle 33 ms neue Fractions an, die Pane-Frames ändern sich real)`, `WhisperM8/Views/AgentGridSplitContainer.swift:94-114 (gridBody setzt .frame je Block aus colSizes/rowSizes)`, `WhisperM8/Services/AgentChats/Layout/LayoutDividerDrag.swift:5-14 (gemessen 02.08.2026: ~24 ms je Größenänderung bei 9 Flächen, davon SIGWINCH-Neuaufbau der TUI)`, `docs/plans/workspace-umbau/HANDOFF.md:54 (Dehn-Technik per scaleEffect, nur für WorkspaceLayoutView gebaut)`, `WhisperM8/Views/AgentTerminalView.swift:1056 (sizeChanged leer, keine Entprellung der PTY-Größe)`, `launch-definition.md DoD: kein main_thread_blocked_ongoing mit 6 Grid-Panes`

**Szenario:** 3×3-Workspace mit neun laufenden Claude-TUIs, Trenner ziehen: jeder 33-ms-Tick ändert die Breite von bis zu sechs Panes, jede Pane schickt ioctl(TIOCSWINSZ) und die TUI baut ihr Bild komplett neu auf. Gemessene ~24 ms pro Tick bei 33 ms Budget heißt: Main Thread zu über zwei Dritteln belegt, ruckelnder Trenner, Flackern und Scrollback-Reflow in den Terminals. Beim Ziehen am Fenster oder an der Sidebar passiert dasselbe ungedrosselt.

**Fix:** Das fertige Konzept aus dem Layout-Paket auf den aktiven Container übertragen: während des Drags die Panes nur per scaleEffect/Transform strecken und die echte Größe (und damit SIGWINCH) erst bei onDragEnded setzen. Alternativ die PTY-Größe im AgentTerminalContainerView um ~150 ms entprellen. Vorher mit `make dev-release` und scripts/perf-load.sh bei 6 Panes messen.

**Regressionstest:** Messlauf mit PerformanceCounters (.layoutSolved) und os_signpost grid.divider.layoutTick: Anzahl TIOCSWINSZ je Drag-Sekunde vor und nach der Änderung.

### LR-AU-016 (D2-04) · Pane-Fokus-Routing per Maus hängt am Hover-Flag ohne zustandslosen Gegencheck: ein verlorenes onHover(false) lässt Klicks außerhalb des Grids die Selektion verschieben

*P2 · race · Konfidenz niedrig · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentChatsView+Grid.swift:866-872 (onHover setzt/räumt hoveredGridPaneID)`, `WhisperM8/Views/AgentChatsView+Grid.swift:1052-1078 (handleGridPaneMouseDown: selectedSessionID = hovered bei JEDEM Linksklick im Fenster, kein Abgleich mit der Klickposition)`, `WhisperM8/Views/AgentChatsView+Shortcuts.swift:548-556 (leftMouseDown-Monitor)`, `WhisperM8/Views/AgentChatsView+Grid.swift:1063-1072 (Selbstheilung nur für hoveredNoteCardID, und die vergleicht gegen genau dieses Flag)`, `WhisperM8/Views/AgentChatsView+Grid.swift:276-283 (Selektionswechsel ruft controller.focusTerminal())`, `CLAUDE.md: Hover-Flag-Vorfall isHoveringTabStrip, Lösung dort: zustandsloser Hit-Test (isPointerInTabStripBand)`

**Szenario:** Maus steht über nicht fokussierter Pane X, ein Kontextmenü am Pane-Header, ein Drag oder ein Cmd+Tab verschluckt das onHover(false), das Flag bleibt auf X. Der User klickt danach in das Suchfeld der Sidebar oder auf einen Header-Button: der Monitor setzt zuerst selectedSessionID = X, der onChange ruft X.focusTerminal() und das Terminal reißt den Tastaturfokus aus dem Suchfeld. Folge: Tippen landet im Chat X. Nicht reproduziert, die Lücke ist aus dem Code und dem Vorfall abgeleitet.

**Fix:** Das Flag nicht allein vertrauen: im Monitor per Pane-Rechtecke (onGeometryChange in einen nicht beobachteten Dictionary-Cache) oder per hostWindow.contentView?.hitTest(event.locationInWindow) prüfen, dass der Klick wirklich in der Hover-Pane liegt (zustandslos wie isPointerInTabStripBand). Optional zusätzlich das Flag bei NSWindow.didResignKey/didBecomeKey und bei Drag-Ende räumen.

**Regressionstest:** Pure Funktion `GridPaneHitResolver.pane(at:frames:)` testen. Manuell: Header-Kontextmenü öffnen, schließen, Sidebar-Suchfeld anklicken, Fokus darf nicht in den Terminal springen.

### LR-AU-023 (D5-02) · ⌘Q/Menü-Beenden stoppt arbeitende Chats ohne Warnung; nach sauberem Quit kein automatisches Resume

*P2 · ux · Konfidenz hoch · Aufwand M*

**Beleg:** `WhisperM8/WhisperM8App.swift:440-453`, `WhisperM8/Views/AgentTerminalView.swift:448-456`

**Szenario:** Zehn Chats laufen, drei davon arbeiten. Laie drückt ⌘Q oder wählt im Dock Beenden. applicationShouldTerminate sendet 2x Ctrl+C an alle PTYs, löscht den Crash-Marker und gibt .terminateNow zurück. Der laufende Turn wird abgebrochen, es gibt keinen Dialog. Beim Neustart sind die Tabs zwar da, aber nicht gestartet: jeder Tab zeigt nur Verlauf plus Resume. Crash-Recovery greift nur nach einem unsauberen Ende. Berührt W5 (Tabs/Chats nach Neustart wieder da, ohne stille Verluste).

**Fix:** In applicationShouldTerminate bei laufenden/arbeitenden Chats einen Dialog zeigen (N Chats laufen, M arbeiten gerade, Beenden? mit Abbrechen). Zusätzlich eine Einstellung Laufende Chats beim nächsten Start fortsetzen (Default an), die den Marker auch bei sauberem Quit für die laufenden Chats behält.

**Regressionstest:** Pure Entscheidungsfunktion (Chats laufend/arbeitend zu Dialogtext) unit-testen; Quit-Pfad manuell prüfen.

### LR-AU-024 (D5-03) · Tab schließen (X, ⌘W, Mittelklick) lässt den Chat unsichtbar weiterlaufen, ohne Hinweis

*P2 · ux · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentChatsView+Tabs.swift:93-98`, `WhisperM8/Views/AgentChatsView+Shortcuts.swift:105-116`, `WhisperM8/Views/AgentChatChromeViews.swift:370-379`, `WhisperM8/Views/AgentChatsView.swift:2704-2708`

**Szenario:** Laie schließt wie im Browser einen Tab mit ⌘W oder dem X, während Claude arbeitet. closeTab entfernt nur den Tab, das PTY läuft weiter (kostet Tokens/CPU, darf ggf. Dateien ändern). Es gibt keine Rückfrage und keine Anzeige am Tab. Nur die Sidebar-Zeile zeigt noch einen Punkt. Das Modell Tab zu = Chat beendet gilt nicht. Das Beenden steht an anderer Stelle (Sidebar Beenden/Archivieren) und hat dort eine Bestätigung.

**Fix:** Beim Schließen eines Tabs mit laufendem Prozess dasselbe Muster wie Chat beenden anbieten (weiterlaufen lassen oder beenden), mindestens einen einmaligen Hinweis beim ersten Mal. Die Aktion im Tooltip benennen (Tab schließen, Chat läuft im Hintergrund weiter).

### LR-AU-025 (D5-04) · Header-Button Restart bricht einen laufenden Turn ohne Rückfrage ab; Beschriftung Englisch/Jargon

*P2 · ux · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentChatsView.swift:3363-3376`, `WhisperM8/Views/AgentSessionDetailView.swift:608-611`, `WhisperM8/Views/AgentChatsView+SessionMenus.swift:125-137`

**Szenario:** Bei laufendem Chat steht im Header neben dem Menü der Button Restart. Ein Klick (oder Fehlklick) ruft terminate und startet neu. Ein arbeitender Turn geht verloren, ohne Bestätigung. Bei beendeten Chats heißt derselbe Button Resume oder Start. Das ist Terminal-Jargon, und es ist die einzige sichtbare Möglichkeit, einen beendeten Chat fortzusetzen.

**Fix:** Restart nur mit Bestätigung, wenn der Status arbeitet oder wartet ist. Beschriftung lokalisieren und verständlich machen (Chat fortsetzen, Neu starten, Starten), im Tooltip erklären, dass der Verlauf erhalten bleibt.

### LR-AU-026 (D5-05) · Status-Punkte ohne Legende im Hauptfenster, nur Farbe/Hover; Legende versteckt auf englischer Settings-Seite

*P2 · ux · Konfidenz hoch · Aufwand M*

**Beleg:** `WhisperM8/Views/AgentStatusIndicator.swift:41-79`, `WhisperM8/Views/Settings/Pages/ClaudeHooksSettingsPage.swift:56-76`, `WhisperM8/Views/AgentChatsSidebarViews.swift:1100-1118`

**Szenario:** Laie sieht grün (arbeitet), grau (bereit), amber (wartet), roten Ring (Fehler). Die Bedeutung erscheint nur als help-Tooltip beim Hovern. Im Tab-Strip ist der Punkt 5 pt groß, ohne Puls und ohne Text: grün, grau und amber unterscheiden sich nur durch die Farbe (Rot-Grün-Schwäche). Die einzige Legende liegt in Settings, Claude Code, Hooks (working/awaiting/idle, Englisch, ohne Fehler- und Beendet-Zustand). Wartet auf dich ist der wichtigste Zustand und für Farbenblinde im Tab nicht erkennbar. Verletzt die Regel kein Hover-only und die Barrierefreiheit.

**Fix:** Zustände zusätzlich über Form oder Symbol unterscheiden (amber mit Glyphe, Fehler mit Kreuz). Eine kurze lokalisierte Legende im Hilfe-Popover der Sidebar oder in der Hilfe-Seite ergänzen. Auf dem Indikator accessibilityLabel setzen.

### LR-AU-027 (D5-06) · Schließen-Aktionen in Sidebar und Tabs sind hover-only Bilder mit onTapGesture: weder Tastatur noch VoiceOver; der aktive Chat verliert seinen Status-Punkt

*P2 · ux · Konfidenz hoch · Aufwand M*

**Beleg:** `WhisperM8/Views/AgentChatsSidebarViews.swift:885-893`, `WhisperM8/Views/AgentChatsSidebarViews.swift:1099-1110`, `WhisperM8/Views/AgentChatChromeViews.swift:370-378`

**Szenario:** Das Beenden/Archivieren/Schließen ist ein Image mit onTapGesture (kein Button, kein accessibilityLabel). Es erscheint nur bei Hover oder Auswahl. VoiceOver- und Tastaturnutzer erreichen es nicht. Für gepinnte/flache Zeilen (1099-1110) erscheint es ausschließlich beim Hover. Bei ausgewähltem Chat ersetzt das X den Status-Indikator in Sidebar-Zeile und Tab, sodass der aktive Chat dort nie wartet auf dich zeigt. Insgesamt gibt es nur ca. 48 accessibility-Modifier in Views/.

**Fix:** Als Button mit accessibilityLabel und Hint umsetzen. Status und Schließen-Aktion getrennt halten (Status bleibt sichtbar, X erscheint zusätzlich). Aktionen auch per accessibilityAction exponieren.

### LR-AU-028 (D5-07) · Technische, teils englische Fehlermeldungen mit Pfaden und Session-IDs im Chatstart

*P2 · ux · Konfidenz hoch · Aufwand M*

**Beleg:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:33-44`, `WhisperM8/Views/AgentSessionDetailView.swift:753-765`, `WhisperM8/Views/Transcript/TranscriptEmptyStateView.swift:63-77`

**Szenario:** Fehlt das Transcript, lautet die Meldung u. a.: Für Session UUID existiert weder unter ~/.claude/projects noch in einem Account-Profil (~/.claude-profiles/*/projects) eine Transcript-Datei. Fehler des Command-Builders sind englisch (Cannot resume X: the original agent session ID was not indexed yet. Refresh sessions or start a new chat explicitly.; no short ID stored yet. Spawn the agent first.). Laien lesen Pfade, UUIDs, Account-Profil, indexed, Short-ID, Spawn. Der Fehler erscheint nur im kleinen gelben Balken, ohne Handlungsknopf. Verletzt: Jede Fehlermeldung sagt, was passiert ist und was der Nutzer tun kann.

**Fix:** Meldungstexte laienverständlich und lokalisiert schreiben (Der Verlauf dieses Chats wurde von Claude gelöscht oder verschoben. Du kannst einen neuen Chat im selben Projekt starten.). Technische Details (Pfad, ID) hinter Details oder ins Log. Handlungsknopf im Fehlerzustand ergänzen.

### LR-AU-029 (D5-08) · Leerzustände ohne Anleitung; Markdown-Sternchen und widersprüchliche Begriffe

*P2 · ux · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentChatsView.swift:2511-2513`, `WhisperM8/Views/Transcript/TranscriptEmptyStateView.swift:82-98`, `WhisperM8/Views/AgentChatsView.swift:3270-3274`

**Szenario:** Nach dem Schließen des letzten Tabs bei vorhandenem Projekt zeigt der Hauptbereich nur Kein Agent Chat mit Terminal-Icon, ohne Beschreibung oder Aktion. Der Leerzustand einer neuen, nie gestarteten Session sagt Klick **Resume** oben, der Button heißt aber Start. Weil Text mit einer String-Property kein Markdown rendert, erscheinen die Sternchen wörtlich. Zusätzlich steht dort eine rohe Session-ID, und enthaelt ist mit Umlaut-Ersatz geschrieben. Das Fragezeichen-Symbol in der Sidebar öffnet nur das Onboarding, keine Hilfe.

**Fix:** ContentUnavailableView mit Beschreibung und Button Neuer Chat ausstatten. Die Leerzustandstexte je nach Button-Label bilden und als LocalizedStringKey bzw. AttributedString rendern. Die Session-ID hinter ein Detail legen.

### LR-AU-030 (D5-09) · Sprachmix Deutsch/Englisch (E1): konkrete Hotspots in Agent-Chats-UI und Settings

*P2 · ux · Konfidenz hoch · Aufwand L*

**Beleg:** `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:41-48`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:376-378`, `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:35`, `WhisperM8/Views/Settings/Pages/ClaudeHooksSettingsPage.swift:12-20`, `WhisperM8/Views/AgentChatsView.swift:3372`, `WhisperM8/Views/AgentChatsSidebarViews.swift:898`, `WhisperM8/Views/AgentChatsView.swift:2024`

**Szenario:** Hauptfenster (Sidebar, Dialoge, Menüs) ist Deutsch, die Agent-Chats-Settings komplett Englisch (Launch defaults, Rename chats automatically, Tabs Workspace/Notifications/Advanced). Der Systemdialog zum Projektwählen trägt Add Project. Die Test-Benachrichtigung hat den deutschen Titel Statusmaschine-Chat auf einer englischen Seite. Header-Buttons heißen Restart/Resume/Start. Die Zeitangaben sind 5m/3h/2d/3mo, der Tooltip Transkript von Claude gelöscht – nicht mehr resumebar mischt Deutsch und Jargon. Es gibt keine Localizable-Ressourcen; alle Strings sind hart codiert. Ergänzt LR-ONB-011 um die konkrete Fundliste.

**Fix:** E1 umsetzen: Strings in String Catalog (Englisch Basis, Deutsch Lokalisierung). Priorität: Agent-Chats-Settings, Header-/Sidebar-Aktionen, NSOpenPanel-Prompts, Test-Benachrichtigung. Relative Zeiten über RelativeDateTimeFormatter.

### LR-AU-031 (D5-10) · Erweitert/Labs-Funktionen und Entwicklerjargon im Standard-UI der Chats

*P2 · ux · Konfidenz mittel · Aufwand M*

**Beleg:** `WhisperM8/Views/AgentChatsView.swift:2962-2982`, `WhisperM8/Views/AgentChatsView.swift:3220-3237`, `WhisperM8/Views/AgentChatsSidebarViews.swift:845-855`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:98-106`, `WhisperM8/Views/BackgroundDispatchModal.swift:121`

**Szenario:** Das Plus-Menü neben den Tabs stellt Neuer Hintergrund-Agent, Neuer Claude Agent View und Sub-Agent-Bibliothek anzeigen gleichrangig neben Neuer Claude Chat. Codex steht dabei vor Claude. Sidebar und Header zeigen BG/VIEW/SUB/TERM-Pillen mit Tooltips wie vom Claude-Supervisor gehostet, Multi-Session-TUI, Short-ID. In den Settings ist New chat starts with Claude Agents eine normale Option. Der Dialog Hintergrund-Agent nutzt Permission Mode und Worktree. Ein Laie kann nicht erkennen, was davon er braucht oder was Kosten/Risiko hat.

**Fix:** Erweitert/Labs-Einträge hinter einen Untermenüpunkt Erweitert oder eine Einstellung Erweiterte Agent-Funktionen anzeigen (Default aus). Tooltips ohne Jargon formulieren. Claude vor Codex sortieren oder nach Nutzung.

### LR-AU-032 (D5-11) · Platzhalter --dangerously-skip-permissions im Feld für zusätzliche CLI-Argumente

*P2 · security · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:418-424`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:372-380`

**Szenario:** In Settings, Agent Chats, Advanced steht als Eingabebeispiel e.g. --dangerously-skip-permissions. Laien übernehmen Beispiele. Das Argument wird allen Claude-Starts (auch Resume) vorangestellt und schaltet die Rechteabfragen des Agenten für jeden Chat ab, ohne weitere Warnung oder Bestätigung. Ein Tippfehler im Feld lässt jeden Chat mit roher CLI-Fehlermeldung im Terminal scheitern; die Seite gibt keinen Hinweis zur Fehlersuche.

**Fix:** Neutrales Beispiel verwenden. Bei gefährlichen Flags (dangerously-skip-permissions, bypass) einen Warnhinweis oder eine Bestätigung zeigen. Ein Zurücksetzen-Button neben der Command-Preview.

### LR-CLI-001 (D3-01) · Prompt-Zustellung ist nicht gegen eingebettetes Paste-Ende (ESC[201~) und Steuerzeichen gesichert

*P2 · security · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentTerminalView.swift:742-758`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:195-201`, `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:61-67`

**Szenario:** Ein Chat (oder Jarvis) gibt Text aus einer Webseite, Datei oder Tool-Ausgabe per `whisperm8 chats send <ref> "..."` oder `enqueue` weiter. Der Text enthaelt die Bytes ESC [ 2 0 1 ~ gefolgt von `\n/exit\n`. pastePrompt sendet ESC[200~ + text + ESC[201~ unveraendert. Das eingebettete 201~ beendet den Bracketed-Paste-Modus in der Ziel-TUI vorzeitig, der Rest kommt als getippte Tasten an: Enter reicht fuer Slash-Befehle, `!`-Shell-Modus oder die Bestaetigung eines Permission-Dialogs. Das Ziel-Claude kann damit ohne die geforderte User-Bestaetigung Aktionen ausfuehren. Der Absender-Marker und das Zustell-Token schuetzen dagegen nicht.

**Fix:** In pastePrompt (und damit fuer send, Queue und jeden anderen Aufrufer) vor dem Senden alle C0-Steuerzeichen ausser \n und \t sowie ESC/CSI-Sequenzen und das 8-Bit-CSI (0x9B) entfernen oder durch sichtbaren Platzhalter ersetzen. Zusaetzlich serverseitig in session.send/queue.enqueue ablehnen, wenn der Prompt 0x1B enthaelt.

**Regressionstest:** Unit-Test auf einer reinen Sanitize-Funktion: Eingabe mit \u{1B}[201~ und \u{1B}[200~ liefert Text ohne ESC; \n und \t bleiben erhalten. Dazu ein Test, dass pastePrompt genau einmal ESC[200~ und einmal ESC[201~ sendet.

### LR-CLI-002 (D3-02) · send und Queue-Zustellung haengen den Agent-Prompt an einen vom User getippten Entwurf und schicken beides ab

*P2 · datenintegritaet · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:159-201`, `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:61-67`, `WhisperM8/Views/AgentTerminalView.swift:726-740`, `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift:92-130`

**Szenario:** Der User tippt im Terminal eines idle-Chats eine halbe Nachricht, schickt sie aber nicht ab. Jarvis ruft `chats send` auf, oder ein vorgemerkter Queue-Auftrag wird zugestellt (Status idle). Beide pruefen nur den Runtime-Status. pastePrompt fuegt den Text ans Ende des Entwurfs und sendet Enter. Claude bekommt Entwurf und Auftrag als eine verfaelschte Nachricht, und der Entwurf des Users ist verloren. shouldClearBeforeSubmit gibt bei mayHaveUnsentInput bewusst false zurueck, der Entwurf bleibt also stehen. Nur der Kontowechsel wertet mayHaveUnsentInput aus.

**Fix:** In sessionSend und deliverNow composerDraft.mayHaveUnsentInput pruefen. Bei Entwurf: send liefert conflict (neuer Code oder unsentInput, Ausweg enqueue). Die Queue-Zustellung bleibt mit retry zurueckgestellt und wird beim naechsten Turn-Ende erneut versucht. --force darf die Pruefung aufheben.

**Regressionstest:** Pure Entscheidungsfunktion mit (runtime, lifecycle, mayHaveUnsentInput): idle + Entwurf ergibt Ablehnung, idle ohne Entwurf ergibt allowed.

### LR-CLI-003 (D3-03) · `chats enqueue` stellt bei launching sofort zu und umgeht den Readiness-Guard, den die Fehlermeldung als Ausweg empfiehlt

*P2 · korrektheit · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:1064-1070`, `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:39-76`, `WhisperM8/Services/AgentChats/ChatsSendReadinessGuard.swift:4-55`

**Szenario:** Direkt nach `chats resume` meldet der Chat launching, was auf runtimeStatus idle abbildet. `send` lehnt korrekt mit notReady ab und rat zu `chats enqueue`. enqueue sieht runtime == .idle und ruft sofort AgentPromptQueueDelivery.deliverNow auf. deliverNow kennt ChatsSendReadinessGuard nicht, pastet blind in die noch ladende TUI und markiert den Auftrag als delivered. Es ist genau der stille Verlust aus dem Vorfall 2026-07-26, jetzt ueber den empfohlenen Umweg. Der Auftrag ist als zugestellt markiert, kommt aber nie an, und niemand bekommt eine Warnung.

**Fix:** Den lifecycleState-Check (ChatsSendReadinessGuard.decide) in deliverNow aufnehmen: bei .notReady retry zurueckstellen und beim ersten bestaetigten Turn-Ende oder nach Ablauf des launching-Fensters erneut zustellen. Die Sofortzustellung in queueMutation nur bei lifecycle != launching ausloesen.

**Regressionstest:** deliverNow gegen einen Fake mit lifecycle=.launching: erwartet markFailed(retry:true), kein sendPrompt, Eintrag bleibt offen.

### LR-CLI-004 (D3-04) · Steuerbefehle (open, resume, unarchive --open/--resume) holen die App per NSApp.activate in den Vordergrund und stehlen den Fokus waehrend der User tippt

*P2 · ux · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:318-319`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:1266`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:1467-1471`

**Szenario:** Jarvis oder ein Skript fuehrt waehrend einer Ueberwachungsrunde `chats resume <ref>` aus, der User tippt gerade in einer anderen App (Mail, Browser). NSApp.activate(ignoringOtherApps: true) holt WhisperM8 nach vorn. Die restlichen Tastenanschlaege, auch ein Enter, landen im Terminal eines Claude-Chats. Steht dort ein Permission-Dialog, kann ein getipptes 1/y/Enter eine Freigabe erteilen, die der User nie gesehen hat. Ein Aufruf aus der Mod (openChat) geschieht dagegen auf ausdruecklichen Klick des Users.

**Fix:** Fuer maschinell ausgeloeste Befehle (resume, unarchive --resume, new) nicht aktivieren, nur das Fenster ordnen und die Session fokussieren. Aktivierung nur fuer ausdrueckliches `open` oder per `--focus`. Alternativ eine Notification statt Aktivierung, wenn eine andere App im Vordergrund ist.

**Regressionstest:** Pure Entscheidung shouldActivate(method:, flags:). Tests: resume ergibt false, open ergibt true, open --background ergibt false.

### LR-CLI-008 (D3-08) · Handler-Timeout 10 s passt nicht zu move-account: Antwort `Zustand unklar` waehrend der Umzug weiterlaeuft

*P2 · robustheit · Konfidenz mittel · Aufwand M*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlServer.swift:297-309`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler+AccountMove.swift:93-100`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler+AccountMove.swift:237-251`, `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift:186-190`

**Szenario:** `chats move-account --stop-and-resume` auf mehrere laufende Chats: prefetch liest beim ersten Lauf ganze Transcripts (ClaudeBackgroundTaskMonitor, bei 100-MB-Dateien mehrere Sekunden), danach terminate-Wartezeit und ein Exit-Waiter bis 5 s, dann das Verschieben der Transcripts. Zusammen sind das leicht mehr als 10 s. serveConnection antwortet mit `Handler-Timeout — Zustand unklar` (Exit 4, conflict), der Task laeuft aber weiter und fuehrt den Umzug aus. Der Agent oder User wiederholt den Befehl und plant damit eine zweite Bewegung oder haelt den Chat fuer nicht umgezogen, obwohl er laeuft und im neuen Konto ist. Der Client-Read-Timeout von 12 s hat dasselbe Limit.

**Fix:** Lang laufende Methoden (session.moveAccount, close --stop mit vielen Zielen) als Job modellieren: sofort `accepted` mit jobID, dann pollbar. Alternativ methodenabhaengiges Server- und Client-Timeout (z. B. 45 s) und im Timeout-Pfad den echten Zustand liefern.

**Regressionstest:** Fake-Handler, der 11 s schlaeft: Client bekommt Timeout. Dann Pruefung des Job-Pfads, der ueber `jobs.get` das Endergebnis liefert.

### LR-CLI-009 (D3-09) · `chats watch` liest und dekodiert das komplette Status-Journal (bis 2 MB) alle 2 s je Jarvis-Session

*P2 · performance · Konfidenz mittel · Aufwand M*

**Beleg:** `WhisperM8/CLI/ChatsChangesCommand.swift:140-160`, `WhisperM8/Services/AgentChats/ChatsStatusJournal.swift:164-200`, `WhisperM8/Resources/claude-plugin/hooks/register.tsx:253-262`

**Szenario:** Die Mod startet je aktivem Board (Jarvis-Session) einen Dauerprozess `whisperm8 chats watch --interval 2`. Jede Runde ruft ChatsStatusJournal.changes auf: readAll liest die ganze Datei als String, splittet und JSON-dekodiert jede Zeile, danach wird gefiltert. Bei einem vollen Journal (2 MB, einige 10k Eintraege) sind das dauerhaft zweistellige Millisekunden CPU pro Runde, rund ein bis wenige Prozent Dauerlast je Watcher, auch wenn nichts passiert. Mit mehreren Jarvis-Sessions oder `since`-Pollern vervielfacht sich das. Das passt nicht zum Leerlauf-Ziel in der Definition of Done (<2 %). Die Zahl ist geschaetzt und nicht gemessen.

**Fix:** Stat-first: Groesse und mtime der Journal-Datei merken, bei Gleichstand ohne Lesen weiterschlafen. Sonst nur ab dem gemerkten Byte-Offset lesen, statt die Datei neu zu dekodieren. Alternativ den Watch ueber einen Vnode-FileEventSource wie den Runtime-Watcher aufwecken.

**Regressionstest:** Test: viele Journalzeilen und zwei changes()-Aufrufe ohne neue Zeilen. Der zweite darf die Datei nicht erneut dekodieren (Zaehler im injizierten Reader). Messung mit scripts/perf-report.sh.

### LR-DOK-009 (D5-13) · USER_GUIDE ohne Agent-Chats-Kapitel; Hooks-Seite beschreibt veralteten Statusweg

*P2 · doku · Konfidenz niedrig · Aufwand M*

**Beleg:** `docs/USER_GUIDE.md:10-293`, `WhisperM8/Views/Settings/Pages/ClaudeHooksSettingsPage.swift:12-30`

**Szenario:** Das Handbuch hat Kapitel zu Installation, Diktat, Settings-Tabs, Troubleshooting und Make-Befehlen, aber keines zu Agent Chats (Projekt hinzufügen, Chat starten, Status verstehen, Tab schließen vs. beenden vs. archivieren, Resume nach Neustart). Die Hooks-Seite (Use session hooks: ohne Hooks komme der Status only from the transcript) entspricht nicht mehr dem Registry-Modell vom 17.10., bei dem der Status aus Claudes eigener Registry kommt. Der Schalter ist ein reiner Jargon-Schalter, der Chat-Status und Benachrichtigungen verschlechtern kann.

**Fix:** Kapitel Agent Chats im USER_GUIDE ergänzen. Hooks-Seite an den Registry-Ist-Stand anpassen oder aus dem Standard-UI in Erweitert verschieben.

### LR-PJ-003 (D3-10) · Plugin-Mod verursacht in jedem WhisperM8-Chat CLI-Kaltstarts und stapelt bei jedem session.start einen weiteren 30-s-Timer

*P2 · performance · Konfidenz niedrig · Aufwand M*

**Beleg:** `WhisperM8/Resources/claude-plugin/hooks/register.tsx:436-460`, `WhisperM8/CLI/ChatsBoardCommand.swift:309-337`, `WhisperM8/CLI/ChatsWorkspaceReader.swift:49-67`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:96-99`

**Szenario:** (a) session.start wartet vor `return started` auf refresh() und damit auf einen `whisperm8 chats board --json`-Prozess. Er startet das ganze App-Binary im CLI-Modus und laedt per ChatsCommandContext.load() den kompletten Workspace von Disk, auch wenn kein Board existiert. Bei 5500 Sessions ist das mehrere MB JSON je Chatstart. Nach App-Neustart oder Crash-Recovery mit 20 Chats starten 20 solche Prozesse gleichzeitig. Dazu laeuft pro Prompt der Send-Guard-Hook `whisperm8 chats _prompt-guard` als eigener Kaltstart des Binarys. (b) Jedes session.start (Start, Resume, /clear, Compact) registriert ueber $.clock.every einen weiteren 30-s-Intervall, der nie beendet wird. Nach mehreren /clear laufen mehrere Timer je Chat, jeder loest ein Atom-Update und Re-Render aus. Messwerte fehlen, die Einschaetzung ist statisch.

**Fix:** In der Mod das Board-Lesen erst bei Bedarf starten (nach dem ersten Weck-Ereignis oder wenn Jarvis aktiviert wird) und nicht awaiten. In `chats board` bei @self und fehlender Boarddatei den Workspace-Load ueberspringen. Das Timer-Handle merken und vor einer erneuten Registrierung beenden oder die Registrierung per Flag auf einmal je Session beschraenken. Kaltstartzeit des Hooks messen.

**Regressionstest:** Mod-Test: zweimal session.start registriert genau einen Intervall. CLI-Test: `chats board --json` ohne Boarddatei liest die Workspace-Datei nicht.

### LR-TRM-002 (D4-02) · Composer-Clear (Ctrl+C) haengt an einem zustandslosen Flag und gilt fuer alle Provider und Wartezustaende

*P2 · datenintegritaet · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentTerminalView.swift:726-740`, `WhisperM8/Views/AgentTerminalView.swift:848-857`, `WhisperM8/Views/AgentTerminalView.swift:779-783`, `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift:98-108`, `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift:115-130`, `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift:148-153`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:141`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:263-264`

**Szenario:** `mayHoldRestoredPrompt` wird bei jedem ESC auf einem `working`-Chat gesetzt, auch bei Codex-Chats, und nur durch Enter, Ctrl+C oder einen programmatischen Versand geloescht, nie durch Zustandswechsel. Fall A: ESC bricht den Turn ab, der User sendet nichts. Spaeter startet Claude selbst einen Turn (Hintergrund-Shell endet, `/loop`/Wakeup) und stellt eine AskUserQuestion oder Permission-Frage. `chats send` erlaubt standardmaessig `awaitingInput` (Default `[awaitingInput, idle]`), `shouldClearBeforeSubmit` ist true, und `sendPrompt` schickt zuerst Ctrl+C in den offenen Dialog. Das bricht die Frage ab oder lehnt die Freigabe ab; die Antwort landet danach als neuer Prompt. Fall B: Das Flag ist gesetzt, der Composer enthaelt aber einen User-Entwurf, den der Tracker nie sah (Rechtsklick-Paste, System-Diktat/Services, Drag von Text, per Pfeil hoch zurueckgerufener Verlauf; Keycode 126 ist als Nicht-Eingabe eingestuft). Die Versandkette (`chats send`, Queue) loescht ihn per Ctrl+C. Der Effekt auf Codex ist ungeprueft. Doppeltes Ctrl+C bis zum Beenden von Claude ist nicht belegt: Der Guard-Block-Clear folgt ca. 0,5 s nach dem Block, nach Hook-Laufzeit rund 1 s nach dem ersten Ctrl+C, und liegt damit knapp ausserhalb des 800-ms-Doppelfensters.

**Fix:** Flag an Zustand und Provider koppeln: nur Claude, nur wenn der Status zum Versandzeitpunkt `idle` ist (nie bei `awaitingInput`/`working`), und das Flag beim ersten Statuswechsel nach `busy` oder `waiting` verwerfen. Zusaetzlich den Restore-Fall am Transcript pruefen (letzte Nutzerzeile im Composer-Zustand) und das Flag nach wenigen Sekunden ablaufen lassen. Rechtsklick-Paste und `paste(_:)` des Terminals in den Tracker aufnehmen.

**Regressionstest:** Tracker-/Controller-Test: ESC auf working, danach Status awaitingInput, dann sendPrompt(submit:true) darf keine 0x03 senden. Ausserdem: Codex-Controller darf nie Ctrl+C aus dem Restore-Flag senden.

### LR-AK-036 (D4-04) · Warte-Art aus Registry: veraltetes letztes Tool und vorlaeufige Art in der Benachrichtigung

*P3 · korrektheit · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:648-660`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:693-705`, `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:315-321`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:909-912`, `WhisperM8/Services/AgentChats/AgentTranscriptActivityExtractor.swift:21-24`

**Szenario:** `registryAwaitingKind` ordnet jedes `.tool`-Detail als `permission` ein (ausser ExitPlanMode), auch wenn `waitingFor` etwas anderes sagt (`input needed`, `dialog open`, `worker request`). Das Detail ist der letzte Tool-Aufruf des Turns und kann bereits abgeschlossen sein. Beispiel: MCP-Elicitation nach einem Bash-Aufruf wird als `permission` angezeigt, die Stand-Zeile lautet 'Freigabe: Bash ...'. Ausserdem feuert `.inputRequested(kind)` sofort beim Registry-Wechsel mit der vorlaeufigen Art, wenn der Transcript-Tail noch nicht gelesen wurde (Default permission). `refineRegistryAwaiting` zieht nur den Zustand nach; die Benachrichtigung bleibt falsch ('Freigabe' statt 'Frage' oder 'Plan').

**Fix:** `waitingFor == "input needed"` vor dem `.tool`-Detail auswerten. Nur ein offenes Tool (ohne Ergebniszeile) als Freigabe-Tool nehmen. Die Benachrichtigung um ca. 300 ms verzoegern oder bei Artwechsel nachschieben.

**Regressionstest:** Pure Tests fuer `registryAwaitingKind`: (waitingFor input needed, detail .tool Bash) -> question; Notification-Kind nach Tail-Nachzug.

### LR-AK-038 (D4-06) · Registry-FSEvents werden per exaktem Pfad-String den Profilen zugeordnet; Symlink-Config-Dirs liefern keine Live-Updates

*P3 · robustheit · Konfidenz niedrig · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeRegistryStatusSource.swift:32-40`, `WhisperM8/Services/AgentChats/ClaudeRegistryStatusSource.swift:194-206`, `WhisperM8/Services/AgentChats/ClaudeRegistryStatusSource.swift:211-215`

**Szenario:** `directoryProfiles` ist ein Dictionary mit `root.url.path` als Schluessel. FSEvents liefert kanonische (aufgeloeste) Pfade. Ist `~/.claude` oder ein Profil-Ordner ein Symlink (Dotfile-Manager, `/var` -> `/private/var`), findet `profiles[url.deletingLastPathComponent().path]` nichts, und jedes Event wird still verworfen. Der Status kommt dann nur noch im 10-s-Takt des Voll-Scans. Sidebar, Fertig-Ton und Queue-Zustellung reagieren bis zu 10 s spaeter; es gibt kein Log dazu. Der Voll-Scan nutzt die Originalpfade und funktioniert, deshalb faellt es nicht auf.

**Fix:** Beim Aufbau von `watchedRoots` zusaetzlich `realpath` je Ordner als Schluessel eintragen und beim Event den Schluessel ueber realpath oder Praefixvergleich aufloesen. Verworfene Events einmal pro Start mit `Logger.warning` melden.

**Regressionstest:** Test mit Symlink auf einen sessions-Ordner: Datei schreiben, `handleEventsOffMain` mit dem aufgeloesten Pfad aufrufen, `apply(pid:record:)` muss feuern.

### LR-AU-010 (D1-07) · ⌘⇧←/→ wird im ganzen Agent-Fenster als Tab-Wechsel konsumiert, auch bei Fokus in Textfeldern des Fensters (Sidebar-Filter, Archiv-Suche)

*P3 · korrektheit · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Views/TabNavShortcut.swift:19-22 (⌘⌥ und ⌘⇧ als Chords, nur Fenster-Gating)`, `WhisperM8/Views/AgentChatsView+Shortcuts.swift:155-162 (handleTabNavShortcut prüft nur event.window === hostWindow und prüft die firstResponder-Klasse nicht)`, `WhisperM8/Views/AgentChatsView.swift:2059 (TextField „Filter…“ im Hauptfenster)`

**Szenario:** Nutzer tippt im Sidebar-Filter und drückt ⌘⇧← („bis Zeilenanfang markieren“, macOS-Standard). Statt der Textmarkierung wechselt der aktive Chat, und der Filtertext bleibt unmarkiert. Dasselbe gilt für ⌘⌥←/→ im Archiv-Suchfeld.

**Fix:** In handleTabNavShortcut bei firstResponder als NSText oder NSTextView (Feldeditor) das Event durchreichen. Der Terminal-Responder bleibt ausgenommen, damit die Chords dort weiter wirken.

**Regressionstest:** Reine Funktion shouldHandleTabNav(firstResponder:) testen; manuelle QA mit fokussiertem Filterfeld.

### LR-AU-011 (D1-08) · Zwei-Finger-Horizontal-Swipe wechselt im ganzen Fenster den Tab, ist nicht abschaltbar und wird konsumiert

*P3 · ux · Konfidenz niedrig · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentChatsView+Shortcuts.swift:517-545 (handleTabSwipeScroll nur auf Fenster, Trackpad und außerhalb des Strip-Bandes gegated)`, `WhisperM8/Views/TabScrollSwipeRecognizer.swift:36-41 (Schwelle 60 pt, Dominanz 1.5, kein Opt-out)`, `Support/AppPreferences.swift: kein Schalter für den Swipe (grep tabSwipe: keine Treffer)`

**Szenario:** Beim Tippen berührt der Handballen das Trackpad mit horizontalem Versatz > 60 pt, oder der Nutzer scrollt horizontal über breiten Inhalt der Verlaufsansicht. Der aktive Chat wechselt, die restlichen Tastenanschläge und das Enter landen im anderen Chat. Das ist selten, aber ein Fehlrouting ohne Rückfrage, und es gibt keinen Schalter dagegen.

**Fix:** Einstellung „Tab-Wechsel per Wischgeste“ (Default aus oder an, entscheiden) ergänzen. Den Trigger unterdrücken, wenn in den letzten ~500 ms eine Taste getippt wurde.

**Regressionstest:** TabScrollSwipeRecognizer-Test mit Tipp-Sperrzeit.

### LR-AU-012 (D1-09) · Bulk-Pin und Bulk-Aktionen arbeiten in zufälliger Set-Reihenfolge; die Reihenfolge angepinnter Chats wird beim Mehrfach-Anpinnen vertauscht

*P3 · korrektheit · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentChatsView+BulkActions.swift:14-16 (actionGroup liefert Array(multiSelection), ein Set ohne Ordnung)`, `WhisperM8/Views/AgentChatsView+BulkActions.swift:71-82 (togglePinSelection iteriert group und hängt per pinSession an)`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:238-241 (pinSession hängt ans Ende an)`

**Szenario:** Nutzer markiert die Tabs A, B, C in dieser Reihenfolge und wählt „3 anpinnen“. pinnedSessionIDs bekommt sie in der Set-Reihenfolge (pro Prozesslauf zufällig), zum Beispiel C, A, B. Die Pin-Reihenfolge in Sidebar und Tabs ist nicht die sichtbare Reihenfolge und wechselt zwischen Starts.

**Fix:** actionGroup in sichtbarer Reihenfolge zurückgeben (visualTabOrderIDs oder die Sidebar-Reihenfolge gefiltert auf die Auswahl), IDs ohne Tab hinten anhängen. Dasselbe in togglePinSelection nutzen.

**Regressionstest:** Test mit 5 Auswahl-IDs: die Pin-Reihenfolge entspricht der Anzeige-Reihenfolge.

### LR-AU-017 (D2-05) · Jarvis-Board-Store: Lesefehler gilt als „keine Datei“ und überschreibt das Board; Quarantäne löscht vorherige Beweise; ein defekter Eintrag zerstört das ganze Board

*P3 · datenintegritaet · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/JarvisBoardStore.swift:402-410 (loadForWriting: try? Data(contentsOf:) → leeres JarvisBoardFile bei JEDEM Lesefehler, danach write)`, `WhisperM8/Services/AgentChats/JarvisBoardStore.swift:405-407 (removeItem(quarantine) vor moveItem: zweite Korruption überschreibt die erste Sicherung)`, `WhisperM8/Services/AgentChats/JarvisBoardStore.swift:75 (sessionID streng, Teilfehler eines Eintrags macht JarvisBoardFile unlesbar)`, `WhisperM8/Services/AgentChats/JarvisBoardStore.swift:117-119 (schema wird nie geprüft)`

**Szenario:** Ein transienter Lesefehler (z. B. EPERM durch Backup-/Sync-Tool, I/O-Fehler) trifft jarvis-board.json genau beim nächsten board.set: loadForWriting liefert ein leeres File, die App schreibt ein Board mit einem Eintrag und ersetzt damit alle Notizen und Meilensteine. Eine Datei mit einem einzigen Eintrag ohne gültige sessionID wird komplett in .corrupt verschoben, ein späterer zweiter Defekt löscht auch diese Sicherung.

**Fix:** Fehlt die Datei (ENOENT) → leeres Board; anderer Lesefehler → mutate wirft StoreError statt zu überschreiben. Quarantäne mit Zeitstempel im Namen statt removeItem. Entries/Boards einzeln tolerant dekodieren (kaputte überspringen).

**Regressionstest:** JarvisBoardTests: nicht lesbare Datei (chmod 000) → mutate wirft und lässt die Datei unverändert; zweimal korrupt → zwei .corrupt-Dateien.

### LR-AU-018 (D2-06) · Pro Grid-Pane und Sidebar-Slot O(Sessions)-Lookups im Body (selectedSession, projects.first, sessions.first), im Fallback sogar headerTabs über alle Sessions

*P3 · performance · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentChatsView+Grid.swift:811-812 (gridPane: selectedSession?.id und workspace.projects.first je Pane und Body-Eval)`, `WhisperM8/Views/AgentChatsView.swift:672-676 (selectedSession: sessions.first, Rückfall headerTabs.first baut ein Dictionary über alle Sessions)`, `WhisperM8/Views/AgentChatsView+Workspaces.swift:109 (workspace.sessions.first(where:) je Slot je Workspace)`, `WhisperM8/Views/AgentChatsView+Grid.swift:257-261 (gridWorkspaceContent baut sessionsByID bereits EINMAL, nutzt es aber nicht für isFocused/Projekt)`

**Szenario:** 9 Panes plus mehrere Workspaces in der Sidebar bei einigen tausend Sessions: jede Body-Auswertung (Status-Churn, Fokuswechsel) macht ~9 + 9·W lineare Suchen; zeigt selectedSessionID auf einen archivierten Chat, baut jede Pane zusätzlich das headerTabs-Dictionary über alle Sessions. Im Einzelnen klein (Sub-ms bis wenige ms), summiert sich aber im Hot-Path, den die Performance-Regeln aus CLAUDE.md schützen sollen.

**Fix:** selectedSession-ID und projectsByID einmal in gridWorkspaceContent berechnen und an gridSlot/gridPane durchreichen (sessionsByID liegt schon vor); in workspaceGroup eine einmal je Sektion gebaute ID→Session-Map verwenden.

**Regressionstest:** PerformanceCounters-Zähler oder signpost um gridWorkspaceContent; Vergleich der Body-Zeit bei 3000 Sessions und 9 Panes.

### LR-AU-019 (D2-07) · Shrink-Auswahlmodus ist nur per Maus abbrechbar (kein Esc) und nur per Maus bedienbar

*P3 · ux · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Views/GridShrinkSelectionViews.swift:134-146 (Abbrechen-Button ohne .keyboardShortcut(.cancelAction))`, `WhisperM8/Views/GridShrinkSelectionViews.swift:15-60 (PaneClickCaptureNSView, Auswahl nur per mouseUp; VoiceOver-Action existiert, Tastatur nicht)`, `WhisperM8/Views/AgentChatsView+Grid.swift:309,380 (einzige Abbruchwege)`, `WhisperM8/Views/GridSplitHandle.swift:37-80 (Trenner ohne Accessibility-Element, nur Maus-Drag und Doppelklick)`

**Szenario:** User wählt versehentlich eine kleinere Stufe, drückt Esc, nichts passiert. Esc geht weiter an das fokussierte Terminal und bricht dort ggf. die laufende Claude-Generation ab. Tastatur-Nutzer können weder Chats für das Verkleinern markieren noch Trenner verschieben.

**Fix:** Esc im Modus per lokalem Monitor oder .onExitCommand abfangen (konsumieren, Modus beenden). Auswahl per Leertaste/Pfeile ergänzen und den GridSplitHandle mit accessibilityAdjustableAction (Pfeile verschieben um 5 %) versehen.

**Regressionstest:** UI-Smoke: Shrink-Modus öffnen, Esc senden, gridShrinkSelection == nil und keine Eingabe im PTY.

### LR-AU-020 (D2-08) · Etwa 1.400 Zeilen Layout-Paket (WorkspaceLayout, LayoutEngine, WorkspaceLayoutView) sind nirgends eingebunden, ihre Ableitung läuft aber bei jedem Laden und wird mitpersistiert

*P3 · architektur · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Views/Workspace/WorkspaceLayoutView.swift (keine Instanziierung im Produktivcode)`, `WhisperM8/Services/AgentChats/Layout/* (nur von Tests und WorkspaceLayoutView genutzt)`, `WhisperM8/Models/AgentUIState.swift:302 und :386 (WorkspaceLayoutMigration.migrate bei jedem Load)`, `WhisperM8/Services/AgentChats/Layout/WorkspaceLayoutMigration.swift:156-163 (slotIndex bildet Kapazität 5/7/8 anders ab als AgentGridAutoLayout.cell, abgeleitetes Layout stimmt für diese Stufen nicht mit dem echten Grid überein)`

**Szenario:** Das Paket erzeugt keine sichtbare Wirkung, ändert aber das Persistenzformat und das Fehlerrisiko des UI-States (siehe Befund zum strengen Decode). Wer später S6 auf dieses Modell stützt, übernimmt für 5/7/8er-Workspaces eine falsche Anordnung, weil die Migration die Spezialzeilen (3+2, 3+3+1, 3+3+2) nicht kennt.

**Fix:** Bis S6 entweder das Persistieren von `layouts` abschalten oder die Migration um die Spezialzeilen aus AgentGridAutoLayout.cell(forSlot:) ergänzen. Feature-Erhalt: keine Löschung ohne Entscheidung zum Workspace-Umbau.

**Regressionstest:** WorkspaceLayoutMigrationTests um Kapazität 5, 7 und 8 erweitern (Geometrie gegen AgentGridSplitContainer.blocks vergleichen).

### LR-AU-021 (D4-07) · Statuspunkte nur per Farbe und Tooltip unterscheidbar, ohne VoiceOver-Label

*P3 · ux · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentStatusIndicator.swift:36-58`, `WhisperM8/Views/AgentStatusIndicator.swift:60-76`, `WhisperM8/Views/AgentChatChromeViews.swift:380-381`, `WhisperM8/Views/AgentChatChromeViews.swift:558-575`

**Szenario:** Tab-Punkt (kompakt, ohne Puls), Kachel- und Chat-Kopf (`SessionLiveStatusDot`) und Sidebar zeigen 'arbeitet' (gruen) und 'wartet auf dich' (orange) als gleich grosse gefuellte Kreise, unterscheidbar nur durch den Farbton. Die Bedeutung steht nur in `.help` (Tooltip bei Hover). Es gibt kein `accessibilityLabel`. Fuer Rot-Gruen-Schwache sind working und awaiting im Tab-Streifen kaum zu trennen, und ein VoiceOver-Nutzer hoert 'Bild' oder nichts. Die Projektregel 'kein Hover-only-UI' ist verletzt, weil der Zustand ohne Hover nicht lesbar ist. Seit 17.10. gilt dasselbe Muster auch in Kachelkopf und Tab-Leiste.

**Fix:** `.accessibilityLabel` je Status ('Arbeitet', 'Wartet auf dich', 'Bereit', 'Fehler') setzen. Awaiting im kompakten Punkt per Form unterscheiden (z. B. Ring statt Fuellung oder ein Ausrufezeichen-Glyph) und die Beschriftung nicht auf `.help` beschraenken.

**Regressionstest:** Snapshot-Fixture mit Graustufen/Deuteranopie-Filter; Accessibility-Inspector-Check der Labels.

### LR-AU-033 (D5-12) · Sehr kleine Schriften (8-10 pt) und Kontrastarmut in Chat-Chrome

*P3 · ux · Konfidenz mittel · Aufwand M*

**Beleg:** `WhisperM8/Views/AgentChatsView.swift:3304-3306`, `WhisperM8/Views/AgentChatsView.swift:3156-3160`, `WhisperM8/Views/AgentChatsSidebarViews.swift:640-650`, `WhisperM8/Views/AgentChatsSidebarViews.swift:895-897`

**Szenario:** Konto-/Art-Badges (8 pt), Laufzahlen (8,5 pt), Tooltip-Hinweise und Header-Metadaten (9-10 pt), Zeitangaben (9,5 pt) in textTertiary. Für Nutzer mit Sehschwäche kaum lesbar; die Größen sind fest codiert und folgen keiner Systemeinstellung. Betrifft vor allem Status- und Konto-Information, die der Laie braucht.

**Fix:** Mindestgröße 11 pt für informationstragende Texte; Tertiärfarbe nur für rein dekorative Zusätze. Wichtige Zustände nicht ausschließlich in textTertiary.

### LR-AU-034 (D5-14) · Warnsymbol für gelöschtes Transcript nur per Tooltip erklärt

*P3 · ux · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/Views/AgentChatsSidebarViews.swift:895-899`, `WhisperM8/Views/AgentChatsSidebarViews.swift:1112-1116`

**Szenario:** Chats ohne Transcript zeigen in der Sidebar ein graues Fragezeichen; die Erklärung (Transkript von Claude gelöscht, nicht mehr resumebar) steht nur im Hover-Tooltip. Der Titel wird abgeblendet. Der Laie versteht nicht, was zu tun ist. Ein Klick führt zu dem technischen Fehlerbalken.

**Fix:** Im Detailbereich einen dauerhaften Hinweis mit Aktion Neuen Chat im selben Projekt starten bzw. Chat archivieren zeigen. Das Symbol mit accessibilityLabel versehen.

### LR-BR-010 (D3-14) · Deinstallation hinterlaesst `~/.local/bin/whisperm8` als toten Symlink; laufende Chats behalten Hooks auf das entfernte Binary (W7)

*P3 · infra · Konfidenz mittel · Aufwand S*

**Beleg:** `scripts/update-cask.sh:49-53`, `WhisperM8/Services/Shared/CLISymlinkInstaller.swift:20-36`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:96-99`

**Szenario:** `brew uninstall --zap` entfernt Application Support, Caches und Preferences, aber nicht den von der App angelegten Symlink `~/.local/bin/whisperm8`. Er bleibt als toter Link im PATH, `whisperm8 ...` meldet dann `No such file`. Chats, die zum Zeitpunkt der Deinstallation noch laufen, rufen bei jedem Prompt den Hook `"/Applications/WhisperM8.app/Contents/MacOS/WhisperM8" chats _prompt-guard` mit absolutem Pfad auf. Er scheitert mit Exit 127 und Claude zeigt bei jedem Prompt einen Hook-Fehler. Der Schaden ist klein und passt zu W7 (keine Fremdaenderungen).

**Fix:** Den Symlink in die `zap`-Liste des Casks aufnehmen (`~/.local/bin/whisperm8`, loescht nur den Link). Den Hook-Befehl so bauen, dass ein fehlendes Binary still mit Exit 0 endet (`[ -x path ] && path ... || exit 0`).

**Regressionstest:** Test auf promptGuardCommand: fuehrt der Befehl mit nicht existentem Pfad zu Exit 0.

### LR-CLI-005 (D3-05) · Control-Token ist nur ein Label: kein Befehl erzwingt es, kein Widerruf, Token liegt im Env aller Kindprozesse

*P3 · security · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:1681-1706`, `WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift:32-56`, `WhisperM8/Views/AgentTerminalView.swift:928-937`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:166-170`

**Szenario:** Jeder Prozess des Users kann ohne Token send, interrupt, close --stop --force, archive oder new an den Socket schicken. Er erscheint nur als `extern` oder `unverified` im Audit. Laesst er actor.sessionID weg, entfallen Selbst-Send- und Selbst-Move-Schutz, denn actorID kommt aus dem unverifizierten Feld. AgentSessionTokenRegistry.revoke hat keinen einzigen Aufrufer: ein Token bleibt bis zum App-Ende gueltig, auch nach dem Ende der PTY. Es steht in der Umgebung jedes Kindprozesses (Claudes Bash-Tool, MCP-Server von Drittanbietern). Ein `env` im Chat landet im Transcript. Die Doku nennt das ehrlich Rechenschaft statt Boundary. Fuer Laien bleibt die Aussage `verified` im Audit aber schwaecher, als sie klingt.

**Fix:** revoke() beim PTY-Ende aufrufen. Mutierende Befehle mit actor.sessionID aber ungueltigem Token ablehnen statt als unverified auszufuehren. Das Token zusaetzlich aus dem Env der Subprozesse herausnehmen, die es nicht brauchen (Hook-Befehl hat es bereits ueber den Event-Pfad nicht noetig), oder in der Doku klar als Label ausweisen.

**Regressionstest:** Registry-Test: nach revoke(sessionID:) liefert verify false. Handler-Test: gesetzte sessionID mit falschem Token liefert invalid statt Ausfuehrung.

### LR-CLI-006 (D3-06) · Socket-Server: Slot-Erschoepfung durch langsamen Client, /tmp-Fallbackordner ohne Eigentuemerpruefung, Client prueft den Server-Owner nicht

*P3 · robustheit · Konfidenz niedrig · Aufwand M*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlServer.swift:30-34`, `WhisperM8/Services/AgentChats/AgentControlServer.swift:268-283`, `WhisperM8/Services/AgentChats/AgentControlServer.swift:409-418`, `WhisperM8/Services/AgentChats/AgentControlServer.swift:162-170`, `WhisperM8/CLI/ChatsControlClient.swift:44-60`

**Szenario:** (a) SO_RCVTIMEO gilt je read-Aufruf (5 s) und readLine liest byteweise. Ein Client, der alle 4 s ein Byte schickt, haelt einen der 4 Slots bis zu 1 MiB lang. Vier solche Verbindungen, etwa ein haengendes Skript, lassen jeden `chats`-Aufruf, die Mod und die Board-Steuerung mit `Keine Antwort` scheitern. (b) Der Fallbackpfad /private/tmp/whisperm8-<uid>/ wird mit try? angelegt und gechmodet. Existiert der Ordner schon und gehoert jemand anderem (Mehrbenutzer-Mac, Username >41 Zeichen), laeuft der Server trotzdem dort. Der fremde Besitzer kann den Socket austauschen, und die CLI, die den Pfad aus der Discovery-Datei liest, sendet Prompts und Token an ihn. Die CLI prueft weder Ordner- noch Socket-Owner (kein LOCAL_PEERCRED). Das ist selten und nur bei langem Pfad relevant.

**Fix:** Gesamtdeadline je Verbindung (z. B. 5 s ab accept) statt je read, blockweise lesen. Im Fallbackpfad Owner und Modus per lstat pruefen und bei Abweichung nicht binden. Client: Socket-Owner per fstat/getpeereid pruefen, bevor Daten gesendet werden.

**Regressionstest:** Server-Test mit Fake-Client, der 1 Byte/Sekunde schickt: Verbindung wird nach der Gesamtdeadline geschlossen und der Slot frei.

### LR-CLI-007 (D3-07) · `chats address` oeffnet Claudes native SendMessage-Bruecke ueber alle Konten, an Audit, Marker und Selbstschutz vorbei

*P3 · security · Konfidenz mittel · Aufwand S*

**Beleg:** `WhisperM8/CLI/ChatsAddressCommand.swift:1-20`, `WhisperM8/CLI/ChatsAddressCommand.swift:96-123`

**Szenario:** Ein Chat in Konto A liest per `chats address` die uds:-Adresse eines Chats in Konto B und schickt per nativem SendMessage Text. Diese Nachrichten laufen weder durch session.send (kein Selbst-Send-Schutz, kein [via whisperm8 chats]-Marker, kein Zustell-Token, kein Audit-Eintrag) noch durch die Ein-Hop-Regel. `address` ist ein reiner Lese-Befehl ohne App und ohne Audit-Zeile, es gibt also keine Spur, welcher Chat einen anderen angeschrieben hat. Die Bestaetigungsregel steht nur im Skill (Prompt-Ebene). Ein von Webinhalten gelenkter Chat kann sie ignorieren und andere Konten steuern.

**Fix:** Als bewusste Bruecke dokumentieren und mindestens einen Audit-Eintrag fuer `address` schreiben, sofern die App erreichbar ist (read-only Socket-Methode `audit.note`). Im Skill darauf hinweisen, dass Marker und Guards hier nicht greifen.

**Regressionstest:** Nach `chats address` erscheint ein Audit-Eintrag mit actor und target; Test auf die neue Methode ohne Prompt-Inhalt.

### LR-CLI-010 (D3-11) · `chats wait` pollt doppelt, probt jede Session zweimal beim Start und beobachtet bei leerem Scope alle Chats der letzten 14 Tage

*P3 · performance · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/CLI/ChatsWaitEngine.swift:121-122`, `WhisperM8/CLI/ChatsWaitEngine.swift:74-95`, `WhisperM8/CLI/ChatsWaitEngine.swift:364-370`

**Szenario:** Im Timer-Handler steht `reevaluateAll` zweimal hintereinander (Copy-Paste), jeder 10-s-Takt probt alle Sessions doppelt. Die initiale Aufnahme und die Watch-Armierung rufen ChatsStatusProbe.probe je Session zweimal. Ohne --ref nimmt der Befehl scopedEntries(all:false), also alle nicht archivierten Chats der letzten 14 Tage (bei grossem Workspace hunderte). Jeder Probe liest einen 64-KB-Tail. Dazu kommt ein Dauerlauf bis 30 min. Die Schleifen schreiben ausserdem watchedPaths und watchers aus dem Hauptthread, waehrend die Handler auf der Queue schon feuern (kleiner Data Race).

**Fix:** Doppelten Aufruf entfernen, die Probe-Ergebnisse der Startphase wiederverwenden, Watch-Armierung auf der Queue ausfuehren. Ohne --ref nur Sessions mit Status working/awaitingInput oder offenem Tab beobachten.

**Regressionstest:** Engine mit injiziertem Probe-Zaehler und 10 Fake-Sessions: ein Poll-Tick erzeugt genau 10 Probe-Aufrufe, nicht 20.

### LR-CLI-011 (D3-12) · Audit-Log fuehrt queue-deliver immer als verified: true, auch wenn der Auftrag von einem unverifizierten oder externen Aufrufer stammt

*P3 · datenintegritaet · Konfidenz hoch · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:72-77`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:1043-1048`

**Szenario:** queueMutation uebergibt enqueuedBy als Label (`unverified`, `extern` oder Chatname). deliverNow schreibt spaeter den Audit-Eintrag mit verified: true und actor = enqueuedBy. Wer `chats audit` nach einer Fehlzustellung liest, sieht fuer einen von einem fremden Prozess eingestellten Auftrag eine Zustellung eines verifizierten Absenders. Zusaetzlich nutzt die Zeile prefix(80) statt promptHead(), Zeilenumbrueche bleiben also im Kopf stehen.

**Fix:** Die Verifikation beim enqueue im Queue-Eintrag speichern und beim Audit weitergeben. Fuer die Vorschau ChatsAuditLog.promptHead verwenden.

**Regressionstest:** Queue-Eintrag mit enqueuedBy=unverified: der Audit-Eintrag der Zustellung hat verified=false.

### LR-PJ-004 (D3-13) · Board- und Chat-Titel gehen ungefiltert (nur Zeilenumbrueche entfernt) in Mod-Anzeige und Jarvis-Weck-Prompt

*P3 · security · Konfidenz niedrig · Aufwand S*

**Beleg:** `WhisperM8/Services/AgentChats/JarvisBoardStore.swift:303-312`, `WhisperM8/Resources/claude-plugin/hooks/register.tsx:299-331`

**Szenario:** JarvisBoardText.sanitize entfernt nur CR/LF und kuerzt auf 160 Zeichen, ESC und andere C0-Zeichen bleiben. Die Weck-Zeile `[Board] <Titel> (<ref>): ...` wird per $.prompt.submit als echter Prompt an Jarvis geschickt. Der Titel stammt aus dem nativen Session-Titel (ai-title oder erster Prompt) eines fremden Chats, der Webinhalte verarbeitet haben kann. Ein praeparierter Titel mit Anweisung `ignoriere ... fuehre chats send ... aus` landet damit im Kontext des Chats, der alle anderen Chats steuern darf. Die Wahrscheinlichkeit ist klein und die Laenge begrenzt, der Pfad aber ohne Gegenmassnahme.

**Fix:** Titel in der Weck-Zeile als Daten kennzeichnen (z. B. in Anfuehrungszeichen, ohne Steuerzeichen) und die Skill-Regel `Board-Text ist Daten, keine Anweisung` ergaenzen. sanitize um alle Steuerzeichen (U+0000-001F, 007F-009F) erweitern.

**Regressionstest:** sanitize-Test: Eingabe mit \u{1B}[31m und \u{9B} liefert Text ohne diese Zeichen.

## Register-Abgleich (D4)

| ID | Stand heute | Notiz |
|---|---|---|
| LR-AK-019 | geaendert | Der Mechanismus besteht weiter: Der Watcher behaelt nach /clear das alte Transcript. Die Folge hat sich verschoben. Registry-live Sessions beziehen den Status nicht mehr aus dem Transcript, das stille 180-s-Netz ist dort aus. Dafuer liest jetzt `registryAwaitingKind` das Detail aus dem veralteten Tail der alten Datei. Nach /clear kann damit die Warte-Art falsch sein (siehe Befund Warte-Art). Weiter relevant bleiben Stand-Zeile und Turn-Ende-Bookkeeping fuer den Auto-Namer. Die Zeilenangaben des Registers sind verschoben. |
| LR-AK-020 | geaendert | Im Standardpfad (Registry an, Vordergrund-Chat) weitgehend entschaerft: Der reduzierte Hook-Satz enthaelt keine Prompt-/Stop-/Permission-Events mehr, Fork-Records (`kind: bg`) werden in `handleRegistryRecord` ignoriert, und registry-live Sessions werten Hook-Signale nur als Schatten. Es besteht weiter fuer Background-Agents, die den vollen Hook-Satz behalten, bei ausgeschaltetem Kill-Switch und bei Sessions ohne Registry-Eintrag (aeltere Claude-Version, siehe Befund reduzierter Hook-Satz). Schweregrad im Standardpfad niedriger. |
| LR-KO-004 | besteht | Die Entwurf-Schaetzung wurde nur um das Restore-Flag erweitert; `mayHaveUnsentInput` und die fehlende Neupruefung vor terminate sind unveraendert. Untracked Eingaben (Rechtsklick-Paste, System-Diktat) bleiben fuer den Tracker unsichtbar (siehe Befund Composer-Clear). |

## Kritiker

Die fuenf Finder lieferten 52 Befunde mit dem einzigen P1-Absturz D2-01 (Range-Trap beim Entfernen des fokussierten Chats mit Slot-Luecken) und D5-01 (fehlende CLI beim Chatstart). Intern gibt es sieben Duplikat-Cluster; die groessten sind Cmd+Q ohne Warnung (D1-03/D5-02), Accessibility des Status (D1-06/D4-07/D5-05/D5-06) und der UI-State-Reset ohne Backup (D1-04/D2-02). Gegen das Register (140 Zeilen) gibt es kaum exakte Duplikate, aber viele Erweiterungen: LR-ONB-003/011/012/016, LR-AK-002/029, LR-KO-004 und LR-DOK-005; sie sollten als Evidenz angehaengt statt neu angelegt werden. Ungelesen sind vor allem AgentWindowStore (330-1000), der Grossteil von AgentControlRequestHandler, rund 12 CLI-Dateien, die Mod-Tests und das tote Layout-Paket; keiner prueft Persistenz-Schreibfehler, Handler-Validierung oder die Mod unter Fehlerbedingungen. Vor dem Launch fehlt vor allem ein Laien-Durchlauf von der leeren Installation bis zum ersten Chat und eine Klassenpruefung der Index-/Slot-Traps im Grid-Store.

### Lücken

- **hoch** · Datenverlust bei Chat-Persistenz: AgentWorkspaceStore/AgentWorkspaceRepository Schreibpfade, Crash waehrend Debounce-Save, Platte voll, Dateirechte; AgentSessionStore Zeilen ausserhalb des UI-State-Teils — D1/D2 lasen nur den Load-Fallback des UI-State; Schreibfehler-Behandlung, Teilschreibungen und Backup-Rotation des Workspace unter D1-D3 nicht geprueft (nur Register LR-AK-002/029 zum Schema).
- **hoch** · Control-Socket-Handler: Eingabevalidierung der restlichen Methoden (archive, group, rename, workspace add, board, queue) gegen boesartige/zu grosse Payloads, Pfad- und Ref-Aufloesung — D3 las nur send/enqueue/open/move-account tief; AgentControlRequestHandler ist >1700 Zeilen, Auth ist laut D3-05 nur ein Label, Wirkung auf destruktive Befehle (archive, close, unarchive) nicht bewertet.
- **hoch** · Plugin-Mod register.tsx und WhisperM8ClaudePlugin: Verhalten bei Claude-Code-Update, kaputter Mod, Ablage-Rollback, Plattenplatz, gleichzeitiger App-Start zweier Instanzen — D3 sagt selbst, Mod-Verhalten sei ohne Laufzeit nicht belegbar; Tests, types und Jarvis-Skill nicht gelesen. Eine fehlerhafte Mod laeuft in JEDEM Chat.
- **hoch** · Erststart-Laienpfad Agent Chats: leere Workspace-Datei, kein Projekt, erster Chat, Trust-Dialog, Login in der TUI, fehlende Berechtigungen (Ordnerzugriff Desktop/Dokumente) — D5 klammerte Trust/Login aus; D1-01 nur Projekt-Auswahl. Ein End-to-End-Durchlauf als Laie ohne Claude-Installation fehlt (nur Onboarding-Register).
- **hoch** · Grid-Mutationen im AgentWindowStore Zeilen 330-1000 (Slot-Move, swap, capacity-Aenderung, detach, Multi-Window) — D1 hat sie ausdruecklich nicht gelesen, D2 nur removeSession; D2-01 zeigt, dass dort Range-Traps existieren, gleiche Muster (Index gegen kompaktierte Slots) wahrscheinlich anderswo.
- **mittel** · Hänger/Main-Thread: synchrone Prozess- und Disk-Zugriffe in View-Bodies und Event-Monitoren (git, FileManager, jobs-Reader), Tab-Switcher, Sidebar mit sehr vielen Chats (1000+) — Body-Kosten wurden von D1/D2 nur geschaetzt und nicht gemeldet; Launch-DoD verlangt kein main_thread_blocked_ongoing; keine Last-Skalierung mit grosser Workspace-Datei geprueft.
- **mittel** · Drag-and-Drop und Datei-Drops: Pfade mit Sonderzeichen, grosse Dateien, Bild-Paste in Terminal, Terminal-Link-Klick auf fremde Schemes — +DragDrop, TerminalLinkResolver und Paste-Pfad nicht in D1-D5 abgedeckt (D3-01 nur Paste-Ende-Injektion beim Senden).
- **mittel** · Sicherheit: Hook-Event-File, Send-Token-Store, chats-audit.jsonl, Queue-Datei und Socket-Verzeichnis (Dateirechte, Symlink-Angriffe, /tmp-Fallback) — D3 prueft das nur oberflaechlich; Rechte der Sidecar-Dateien und Hook-Bridge wurden nicht gelesen.
- **mittel** · Mehrfenster und Mehrinstanz: zweites Fenster, Fensterschliessen mit laufenden Chats, Wiederherstellung offener Tabs nach Absturz im Zusammenspiel mit Crash-Recovery-Marker — D1 Cmd+Q-Befund beruehrt es, aber Fenster-Lebenszyklus, Detach/Tear-off und Marker-Interaktion wurden nicht bewertet.
- **niedrig** · Lokalisierung/Barrierefreiheit der Grid-, Switcher- und Notiz-Karten-Views (Tastatur, Fokus, VoiceOver) — D2-07 nur Shrink-Modus; Switcher, Notiz-Karten, Workspace-Zeilen blieben ungeprueft, D5 klammerte sie aus.
- **niedrig** · Chat-CLI Nebenbefehle: archive, unarchive, snapshot, tail, anomaly, move-account (CLI-Seite), Exit-Codes gegen Skill-Text — Etwa 12 CLI-Dateien nicht gelesen, Skill-Abgleich beschraenkt auf Exit-Codes.

### Vermutlich ungelesen

- `WhisperM8/Views/AgentTabGrouping.swift`
- `WhisperM8/Views/AgentTabReorderDrop.swift`
- `WhisperM8/Views/SidebarWidthResolver.swift`
- `WhisperM8/Views/SidebarMetrics.swift`
- `WhisperM8/Views/AgentChatsView+Subagents.swift / +SubagentChildren (nur gestreift)`
- `WhisperM8/Services/AgentChats/AgentWindowStore.swift (Zeilen 330-1000 ausser removeSession/setCapacity)`
- `WhisperM8/Services/AgentChats/Layout/{LayoutEngine,LayoutGeometry,LayoutDividerGeometry,LayoutDropResolver,LayoutDragState}.swift`
- `WhisperM8/Views/Workspace/WorkspaceLayoutView.swift (ab Zeile 80)`
- `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift (Methoden ausser send/enqueue/open/resume/unarchive/workspace remove)`
- `WhisperM8/CLI/ChatsArchiveCommands.swift`
- `WhisperM8/CLI/ChatsMoveAccountCommand.swift`
- `WhisperM8/CLI/ChatsSnapshotCommand.swift`
- `WhisperM8/CLI/ChatsOutput.swift`
- `WhisperM8/CLI/ChatsTailFormatter.swift`
- `WhisperM8/CLI/ChatsAnomalyDetector.swift`
- `WhisperM8/CLI/ChatsAttentionModel.swift`
- `WhisperM8/CLI/ChatsListPlanner.swift`
- `WhisperM8/CLI/ChatsSessionAxes.swift`
- `WhisperM8/CLI/ChatsAgentSnapshot.swift`
- `WhisperM8/CLI/ChatsQueueCommands.swift`
- `WhisperM8/CLI/ChatsQueueBlockExplainer.swift`
- `WhisperM8/CLI/ChatsLiveCommands.swift / ChatsLiveMerge.swift / ChatsWorkspaceViewSupport.swift / ChatsPromptGuardCommand.swift (nicht genannt)`
- `WhisperM8/Services/AgentChats/JarvisNotesStore.swift und Views/JarvisNoteViews.swift (nur ueberflogen)`
- `WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift, ChatsAuditLog, ChatsCloseStopGuard, ClaudeRecapReader (nur teilweise)`
- `WhisperM8/Resources/claude-plugin/ Tests (board.test.ts, callout.test.ts), types/index.d.ts, whisperm8-jarvis-skill.md`

## Positiv / bewusst gelöst

- **D1:** Event-Monitore sind sauber gekapselt: idempotente Installation, vollständiger Abbau in onDisappear, strenges Gating auf event.window === hostWindow, zustandsloser Koordinaten-Hit-Test (TabStripBand) statt Hover-Flag für alle Scroll- und Klick-Monitore (Lehre aus dem Vorfall 23.08.).
- **D1:** Ctrl+Tab-Switcher bricht bei Fensterverlust, Menü-Tracking und externer Selektion ab, es hängt kein Zustand (tabSwitcher, flagsChanged-Monitor, didResignKey).
- **D1:** AgentWindowStore: eine Quelle der Wahrheit, diff-gated mutate und prune, Debounce-Save mit dirtyRevision und Retry nach 5 s, flush in applicationWillTerminate, Close-Tracking per Suspend-Flag (Quit wirft keine Fenster aus dem Store), kein Create-on-mutate gegen Geisterfenster.
- **D1:** Offene Tabs werden nicht mehr gekappt, Reopen-History ist ephemer und LIFO. Tear-off und Cross-Window-Drag lesen die Auswahl live aus dem Store.
- **D1:** Archivieren und Beenden sind reversibel (Archiv-Modus, Zuletzt) und haben eine Bestätigung bei laufendem PTY. Der Archiv-Modus hat kein Hartlöschen. Das Projekt-Löschen-Dialogtext sagt klar, dass Repo und Transcripts bleiben.
- **D1:** Status-Punkt in Kopf, Tab und Sidebar nutzt dieselbe Quelle (AgentStatusIndicator, Grün nur bei „arbeitet“). Der Status-Publisher emittiert beim Abonnieren den aktuellen Wert, daher kein leerer Punkt.
- **D1:** Kontextmenü-Rebuilds sind I/O-arm: stempel-gecachte Konto-Daten, Einzelfall ohne Workspace-Scan, hasUndoableAccountMove über TTL-Cache.
- **D1:** Kontowechsel-Sheet nennt Vorschau, Trust-Warnung und fehlende MCP-Server vor der Ausführung und bietet Rückgängig über den Journal-Batch.
- **D1:** Tastenkürzel ⌘1–⌘9 sind per prefix(9) gegen Character-Traps abgesichert. Reine Logik (TabSelectionResolver, TabNavShortcut, TabStripBand, TabScrollSwipeRecognizer) ist von der UI getrennt und testbar.
- **D2:** Switcher-Performance-Regeln aus CLAUDE.md sind eingehalten: TabSwitcherRunState und TabSwitcherGridMarkingState entkoppeln den AgentChatsView-Body, die Activity-Stores werden nur in Overlay und Ziel-Chip beobachtet, in den Switcher-Views gibt es weder I/O noch .contextMenu.
- **D2:** Der Switcher bricht in allen Randfällen sauber ab: Verlust des Key-Status des Fensters, beginnendes Menü-Tracking, Selektionswechsel von außen und Tasten ohne Ctrl (cancelAndPassThrough). Ctrl+C und Esc erreichen die TUI nicht.
- **D2:** TabSwitcherScope, TabSwitcherModel, GridFocusNavigator, GridSplitResolver und WorkspaceSlotOps sind pure, getestete Bausteine. Die Mini-Map nutzt dieselbe Geometrie (blocks(inRow:), trackSizes) wie der Renderer, es gibt keine zweite Tabelle.
- **D2:** Jarvis-Notizen: JarvisNoteChevron und JarvisNoteCardOverlay rufen im onDisappear onHoverChanged(false), der Hover-Flag-Rest nach dem Zuklappen unter dem Cursor ist damit behoben. Das Overlay ist ein transparenter Container und blockiert Klicks ins Terminal nicht, nur die geöffnete Karte selbst fängt Klicks.
- **D2:** JarvisNotesStore nutzt Combine-Publisher je Session statt @Observable (kein Grid-Body-Rebuild), prüft Owner-lebt in einer puren Projektion und hält Handklicks flüchtig je Fenster. Der Board-Store ist App-einziger-Schreiber mit NSLock, atomarem Write, Quarantäne unlesbarer Dateien, additivem Entry-Schema (work/next doppelt geschrieben) und idempotenten No-op-Mutationen ohne Journal-Flut.
- **D2:** Der Shrink-Modus verhindert versehentlichen Chat-Verlust: bestätigte Eviction-Liste (expectedEvictedSessionIDs), reconcile bei externer Belegungsänderung, Kompaktierung ohne Rückfrage, wenn nichts evakuiert wird.
- **D2:** Der Slot-Drop läuft als eine Store-Mutation gegen frisch gelesene Daten. Die Render-Ownership-Guards (Orphan-Slot mit Übernahme-Button) verhindern Terminal-Stehlen zwischen Fenstern. Fokus-Reparatur (repairGridFocus) und Single-Owner-Aktivierung sind konsistent.
- **D2:** AgentGridWorkspace.init(from:) dekodiert tolerant (decodeIfPresent) und normalisiert Kapazität, Slots, Duplikate und Fractions; Altbestände mit abweichenden Stufen verlieren keine Chats.
- **D3:** Control-Socket-Haertung ist sauber umgesetzt: Ordner 0700, Socket 0600, getpeereid-Pruefung, flock fail-closed, Stale-Socket nur nach Owner-Check, inode-geprueftes unlink, close-on-exec auf Lock, Listen- und Client-FDs, SO_NOSIGPIPE, Zeilenlimit 1 MiB, Slot-Limit 4.
- **D3:** Board und Speak verlangen ein verifiziertes Token. Der Owner ist immer der aufrufende Chat, ein fremdes Board laesst sich nicht beschreiben. Der Ansagetext wird nie geloggt.
- **D3:** Alle Guards von send, interrupt und close laufen in einem synchronen MainActor-Block (kein TOCTOU), close --stop ist all-or-nothing mit Working-Schutz, und move-account schuetzt die eigene Session.
- **D3:** Das Audit-Log speichert nur Laenge und 80 Zeichen des Prompts, rotiert bei 5 MB und hat eine einzige Schreibstelle (die App). Das Journal erkennt abgelaufene Cursor ueber journalId und gap, statt still weiterzumachen.
- **D3:** Der Plugin-Zusammenbau legt je Inhalts-Hash einen Versionsordner an, schreibt ueber Staging und Rename und biegt den Symlink per rename(2) um, damit laufende Sessions nicht neu laden. Tests werden nicht ausgeliefert, Pfad-Traversal ist ausgeschlossen.
- **D3:** Der Prompt-Guard ist konsequent fail-open, liest nur den Transcript-Tail und gibt Exit 2 nur bei belegter Wiedervorlage.
- **D3:** ClaudeRecapReader sucht rueckwaerts blockweise, ohne Riesenzeilen zu laden, und ist fail-soft.
- **D3:** Die CLI-Lesepfade (Workspace direkt von Disk, Registry-Overlay, onlyActive-Antwort der App) sind bereits auf grosse Workspaces ausgelegt.
- **D4:** ClaudeRegistryStatusSource: Grabstein-Logik (`eventTouchedAt`) gegen das Rennen Voll-Scan/FSEvents, `DispatchQueue.main.async` statt Task fuer garantierte Reihenfolge busy -> idle, Lesen und Parsen off-main, Slow-Scan-Warnung bei >50 ms. Nicht anfassen.
- **D4:** ClaudeSessionRegistry.isProcessAlive: kill(0) plus sysctl-Startzeit mit UTC- und Lokalzeit-Kandidaten und Cache des DateFormatters; kein Subprozess, PID-Wiederverwendung wird abgefangen.
- **D4:** handleRegistryRecord-Gates: `kind: bg` ignoriert, kein Status ohne eigenes PTY, 5-s-Sperre nach Prozessende, `sessionLaunched` setzt den Registry-Zustand zurueck. Das verhindert Geister-Working und Fertig-Toene fuer fremde Terminals.
- **D4:** Resume- und Kontowechsel-Pfad: `handleRegistryRecordRemoved` vergleicht die PID, sodass das Ende des alten Prozesses mit gleicher Session-ID den neuen Prozess nicht zuruecksetzt.
- **D4:** Unreadable-Behandlung im FSEvents-Pfad: Eine gerade beschriebene, unlesbare Datei ist kein Ende; nur fehlende Datei oder toter Prozess entfernen den Eintrag.
- **D4:** bindPendingExternalID: `/clear` und `/background` binden die zurueckgestellte ID ueber den ersten Registry-Turn und ersetzen die weggefallenen Turn-Hooks (Commit e11b5a6).
- **D4:** ChatsStatusProbe-Overlay: Registry schlaegt die Transcript-Schaetzung und behaelt Revision und Pfad fuer `wait --since`; ChatsRegistryCache begrenzt Scans auf 1 s.
- **D4:** `ChatsControlClient.readLine` liest blockweise (64 KB) statt je Byte; `sessions.live` mit `onlyActive` verkleinert die Antwort. Die Aenderung ist klein, wirksam und bleibt abwaertskompatibel (`omittedDetached`).
- **D4:** Hook-Reduktion (nur SessionStart/SessionEnd plus Send-Guard) spart zwei Prozessstarts je Tool-Aufruf; der Kill-Switch stellt den vollen Satz fuer neue Chats wieder her.
- **D4:** Schatten-Log ist billig: ein Task je Abweichung (`shadowDiffSince`-Guard), nur `Logger.info`, keine Schleifen.
- **D5:** Archivieren und Beenden sind sauber getrennt, der Dialog nennt bei laufenden Prozessen die Folgen und dass der Chat wiederherstellbar bleibt (AgentChatsView.swift:860-920).
- **D5:** Resume-Schutz: ein Chat wird nie ohne reales Transcript fortgesetzt, die Bindung bleibt erhalten und der Verlust wird sichtbar statt still (AgentSessionDetailView.swift:560-585).
- **D5:** Terminal-Tabs werden ohne Archiv-Geist geschlossen, Löschen von Projekten und Workspaces nennt klar, dass Repo und Transcripts erhalten bleiben.
- **D5:** Leerzustand der Sidebar bei fehlenden Projekten mit klarem Button, und der Scope-Hinweis Alle Chats zeigen verhindert das Gefühl, Chats seien verloren.
- **D5:** Grün ist nur arbeitet, einheitlich zwischen Sidebar, Tab und Kopf (AgentStatusIndicator). Die Verlaufsansicht hat Nachlade-Feedback.
- **D5:** Notification-Settings erklären den Zusammenhang mit der Glocke in der Sidebar und führen bei verweigerter Erlaubnis direkt in die Systemeinstellungen.
- **D5:** Der Dialog zum Kontowechsel ist bewusst ein Sheet mit vorheriger Information; Bestätigungen vor Chat-Aktionen nennen Ziel und Wirkung.
