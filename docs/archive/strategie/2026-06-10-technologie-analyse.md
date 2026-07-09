# WhisperM8 — Abschlussbericht Technologie-Strategie

**Für:** Gründer WhisperM8 · **Stand:** 10. Juni 2026 · **Frage:** Haben wir auf die falsche Technologie gesetzt, und wie werden wir deutlich performanter und besser als Superset, Wispr Flow und der Rest des Markts?

---

## 1. Antwort in drei Sätzen

Nein — der native Swift/SwiftUI-Stack mit SwiftTerm ist für diese App-Klasse (eingebettete PTY-Terminals, Datei-Watching, latenzkritisches Diktat mit CGEvent/AX/CoreAudio) nachweislich die richtige Wahl, und genau die Electron-Konkurrenz liefert den Beleg: Supersets Terminals sind laut offenem Issue #1517 bei 10+ Workspaces auf einem M3 Max „borderline unusable", Wispr Flows Windows-Client idlet bei ~800 MB RAM, während native Terminal-Apps mit 14–100 MB auskommen. Deine echten Probleme sind keine Stack-Probleme, sondern Implementierungsmuster — Polling statt Events, synchrones Disk-I/O auf dem Main-Thread, Voll-Load/Voll-Save-Persistenz pro Klick — plus eine einzige strategische Fehlwette: Cloud-only-Transkription, während der gesamte Markt (Superwhisper, VoiceInk, MacWhisper, Handy) lokale Modelle als Standard etabliert hat. Deutlich besser als der Markt wirst du, indem du den nativen Vorteil endlich ausspielst (event-getriebene 0%-Idle-Architektur, In-Memory-Store, lokale STT via Parakeet/FluidAudio) und den Keil schärfst, den niemand sonst hat: die Integration von Diktat und Agent-Session-Manager in einer App.

---

## 2. Was WhisperM8 heute kann

### 2.1 Diktat-Pipeline

| Bereich | Features (Stand heute) |
|---|---|
| **Aufnahme** | Globaler Push-to-Hold-Hotkey; AVAudioEngine (M4A, 16 kHz mono); Bluetooth-robust (überlebt A2DP→HFP-Profilwechsel mit Retry-Logik); Mikrofon-Picker; Audio-Ducking mit Multi-Device-Tracking und Restore bei App-Quit |
| **Overlay** | Non-activating NSPanel in zwei Stilen (Full 590×56 / Mini 220×46), verschiebbar mit persistierter Position, Audio-Level-Bars, Mode-Dropdown während der Aufnahme, ESC-Cancel |
| **Transkription** | OpenAI (gpt-4o-transcribe, whisper-1) oder Groq (whisper-large-v3/-turbo); Sprachwahl DE/EN/Auto; API-Keys im Keychain; 25-MB-Limit-Check; dynamische Timeouts; verständliche Fehlertexte |
| **Output-Modi** | 9 Built-ins (Raw, Clean, Prompt, Chat, Task, Email, Slack, WhatsApp, Notes) + Custom-Modes; pro Modus Template, Kontext-Policy und Codex-Overrides (Modell, Reasoning, Tier) |
| **Post-Processing** | `codex exec` als Subprocess (sandboxed, stdin-Prompt, Output-Datei); 9 editierbare Templates mit Platzhalter-System; Globalvertrag-Prompt mit Halluzinations-Verboten; Keyword-basierter Intent-Router (rewrite / contextAnswer / agenticReply / …) |
| **Kontext-Erfassung** | Selected Text (AX-API + Clipboard-Fallback mit Pasteboard-Restore); Clipboard-Watcher während der Aufnahme (Bilder + Text automatisch in den Prompt); Screenshot-Import; Screen-Clips via ScreenCaptureKit mit Frame-Extraktion; Agent-Chat-Tail (~600 Zeichen aus der Session-JSONL); granulare Kontext-Bearbeitung im Overlay mit Thumbnails |
| **Delivery** | Clipboard + Auto-Paste via CGEvent inkl. sequentieller Bild-Attachments; Chat-Modus (Diktat → neuer Codex-Agent-Chat); Task-Modus (Diktat → ausgeführter `codex exec` im Projekt) |
| **Robustheit & Tooling** | Cancel-Pfade für Aufnahme und Codex-Lauf; Raw- und Cautious-Fallback; vollständige Run-Reports (Prompt, Command-Preview, Outputs, Retention-Policy); Test Lab für Preview ohne Aufnahme; Onboarding-Wizard; Permissions-Center |

### 2.2 Agent Chats

| Bereich | Features (Stand heute) |
|---|---|
| **Projekte** | Sidebar mit Farben, Auto-/Custom-Icons, Git-Branch-Anzeige, Auto-Import externer Sessions, Worktree-Kanonisierung |
| **Sessions** | Codex-/Claude-Chats pro Projekt, Tab-Strip, Rename, Tab-Farben, KI-Auto-Naming (headless `claude -p`), UI-State-Sidecar (Tabs/Selection getrennt von Session-Daten) |
| **Terminals** | SwiftTerm-PTYs mit Live-Theme-Swap, Scroll-Lock beim Streaming, macOS-Edit-Shortcuts → Readline, Shift+Enter-Profile pro TUI, Finder-Drag&Drop, graceful Terminate |
| **Background-Agents** | `claude --bg`-Dispatch mit Permission-Mode und Sub-Agent-Auswahl, `claude attach` im PTY, Logs/Stop/Respawn/Remove, Zombie-Health-Check |
| **Discovery & Status** | Indexer über `~/.claude/projects` und `~/.codex/sessions` (mtime+size-Cache); Runtime-Status pro Session (working/awaitingInput/idle); event-getriebene Claude-Hook-Bridge (Session-Binding, „Needs Input" in Echtzeit) |
| **Transcripts** | Streaming-Parser für Claude/Codex-JSONL (>50 MB-fähig), Chat-Ansicht mit 300er-Message-Windowing, Tool-/Thinking-Rendering |
| **Extras** | Resume mit ID-Repair und Ambiguitäts-Picker, Ressourcen-Monitor (CPU/RAM-Prozessbaum), Sub-Agent-Bibliothek, Projekt-Inspector mit Git-Diff-Summary, Sidebar-Suche, „Stop all running chats" |
| **Integration** | Aktiver Chat als Diktat-Kontext (Tail-Injection); Diktat öffnet/füttert Agent-Chats — **das hat kein anderes Produkt am Markt** |

### 2.3 Shell & Infrastruktur

| Bereich | Stand |
|---|---|
| **Stack** | Pure SwiftPM (kein .xcodeproj), nur 4 direkte Dependencies (KeyboardShortcuts, Defaults, LaunchAtLogin, SwiftTerm 1.13.0), Makefile-Bundle-Assemblierung |
| **Deployment** | TCC-erhaltendes rsync-In-Place-Deployment + persistente Codesign-Identity (durchdacht, ungewöhnlich sauber gelöst) |
| **Tests** | ~313 XCTest-Tests, Closure-basierte DI — stark bei Agent Chats, blind bei TranscriptionService, PasteService, AudioRecorder, Hook-Bridge |
| **Lücken** | Kein CI, kein Auto-Update (Sparkle), Notarisierung nur optional, `codesign --deep` deprecated, Reports-UI (`OutputDashboardView`) nirgends instanziiert und damit unerreichbar |

---

## 3. Marktbild

### 3.1 Diktat: gegen Wispr Flow und das lokale Lager

Wispr Flow ist der kommerzielle Maßstab ($81M Funding, $700M Bewertung, 4 Plattformen, $15/Monat) — aber mit drei dokumentierten offenen Flanken: **Cloud-Zwang** (kein Offline-Modus, meistgenannter Kritikpunkt), **Privacy-Vertrauensbruch** (Screenshot-Affäre April 2026 inkl. Bannen des aufdeckenden Nutzers) und **Ressourcenhunger** (~800 MB RAM idle auf Windows/Electron). Die Messlatte, die Wispr setzt: <700 ms p99 End-to-End-Latenz, Cleanup ohne Stimmverfälschung, App-Kontext mit transparentem Privacy-Modell.

Das lokale Lager (Superwhisper, VoiceInk, MacWhisper, Handy) ist durchgehend natives Swift bzw. Rust und hat **On-Device-Transkription via whisper.cpp/NVIDIA Parakeet als Standard** — Parakeet v3 via FluidAudio/CoreML gilt als „near-instant and accurate enough". Apples SpeechAnalyzer (macOS 26) ist in Benchmarks ~55 % schneller als Whisper Large V3 Turbo und erhöht den Druck zusätzlich (Sherlocking-Risiko für reine Diktat-Apps).

**WhisperM8s Position:** Bei Output-Modi, Templates und Kontext-Tiefe (Screenshots, Screen-Clips, Agent-Chat-Tail) bist du konkurrenzfähig bis voraus. Die Lücken sind hart: **(a)** Cloud-only-STT — verifiziert: `TranscriptionService.swift` kennt nur OpenAI/Groq, keinen lokalen Pfad, **keinen Cancel-Pfad** während des bis zu 900 s langen API-Calls, und lädt die Audiodatei komplett als `Data` statt per Stream-Upload. **(b)** Latenz-Stack: synchroner Tail-Extract im Hotkey-Pfad, ~220 ms Clipboard-Sleeps, ein synchroner `codex login status`-Roundtrip vor jedem Lauf, Disk-I/O im 100-ms-Overlay-Tick. **(c)** Datenverlust: Ein Netz-Timeout nach einem 5-Minuten-Diktat löscht die Aufnahme unwiederbringlich (`RecordingCoordinator.swift:731`).

### 3.2 Agent-Manager: gegen Superset, Conductor & Co.

Wichtig zur Einordnung: Gemeint ist **superset.sh** (YC P26, „Code Editor for the AI Agents Era"), nicht Apache Superset. Das Feld ist 2026 explodiert (~50 Parallel-Runner) und konsolidiert brutal: Crystal deprecated (Feb 2026), Vibe Kanban trotz 26,9k Stars dicht (Apr 2026, kein Geschäftsmodell), Omnara-Repo archiviert. Der größte strukturelle Druck kommt von den Plattformen selbst: Anthropic hat im April 2026 die Claude-Code-Desktop-App komplett um parallele Sessions herum neu gebaut.

Commodity-Features sind inzwischen: Worktree-Isolation, parallele Sessions mit Status, Diff-Review, Multi-Agent-Support. Differenziert wird über Mobile/Remote (Happy, E2E-verschlüsselt), Review-Tiefe, Container-Isolation und Automation.

**Supersets dokumentierte Schwäche ist deine Chance:** Electron 40 + xterm.js 6.1-beta + node-pty (verifiziert in deren `package.json`); offenes Issue #1517 mit wörtlich „terminals are borderline unusable in terms of their interaction latency" bei 10+ Workspaces auf einem M3 Max mit 128 GB RAM; ein Nutzer im HN-Launch-Thread berichtet ~2 GB RAM. WhisperM8 hat als natives SwiftTerm-Produkt strukturell den besseren Deckel — verschenkt ihn aber derzeit durch eigene Muster (1,5-s-Polling pro Session, `/bin/ps`-Forks, Voll-JSON-Rewrite pro Klick).

### 3.3 Alleinstellung und Lücken auf einen Blick

| | WhisperM8 | Markt |
|---|---|---|
| **USP** | Einziges Produkt mit Diktat ↔ Agent-Manager-Integration (Chat-Tail als Diktat-Kontext, Diktat → Codex-Chat/-Task) | Wispr hat keinen Agent-Manager; Superset/Conductor kein Diktat |
| **USP** | Native App, 4 Dependencies, event-fähige Architektur (Hook-Bridge beweist 0 % Idle-CPU) | Electron-Konkurrenz: 800 MB–2 GB RAM, Latenz-Klagen |
| **Lücke** | Keine lokale Transkription | Bei allen 4 relevanten Mac-Diktat-Apps Standard |
| **Lücke** | Kein Auto-Update, kein CI, Notarisierung optional | Konkurrenz shippt wöchentlich |
| **Lücke** | Sidebar-Drag&Drop auf HEAD entfernt, stille 20-Session-Kappung, Reports-UI unerreichbar | Conductor/Superset: Organisation ist Kernfeature |
| **Risiko** | Plattform-Absorption (Anthropic-Desktop-App, Apple-Systemdiktat) | Trifft alle — Differenzierung über Integration + Privacy nötig |

---

## 4. Technologie-Urteil

### 4.1 Konsens der drei Gutachten

Alle drei Gutachter — der macOS-Engineer, der bewusst als Advocatus Diaboli angetretene Migrations-CTO und der Staff-Engineer für inkrementelle Evolution — kommen unabhängig zum selben Kernurteil:

1. **Der Stack ist richtig.** Eine Migration zu Electron/Tauri hätte klar negativen ROI: ~6–12 Personenmonate Rewrite, Verlust der ~313 Tests, und der wertschöpfende Kern (AX-API, CGEvent, ScreenCaptureKit, CoreAudio, TCC, PTYs) müsste als nativer Helper ohnehin neu gebaut werden. Man würde auf die dokumentiert schlechtere Baseline der Konkurrenz wechseln. Auch der Diktat-Markt hat entschieden: Alle ernsthaften Mac-Apps sind nativ.
2. **Die Schmerzen sind Muster, nicht Technologie.** Verifiziert im Code: `AgentSessionRuntimeWatcher.swift` pollt jede Session alle 1,5 s mit 64-KB-Tail-Reads (Kommentar: „Bewusst kein FSEventStream"), während `ClaudeHookBridge.swift` im selben Repo bereits event-getrieben mit 0 % Idle-CPU arbeitet — das richtige Muster existiert, es wird nur nicht überall angewendet. Jede Workspace-Mutation ist ein synchrones Voll-Load+Voll-Rewrite der kompletten `AgentSessions.json` ohne Lock (26 `loadWorkspace()`-Callsites in `AgentChatsView.swift`, reale Last-Writer-Wins-Race). Der Overlay-Tick dekodiert 10×/Sekunde JSON von Platte. Der Hotkey-Pfad blockiert den Main-Thread mit synchronem JSONL-Parsing — bei einem Kommentar, der fälschlich das Gegenteil behauptet.
3. **Die einzige echte Fehlwette ist Cloud-only-STT** — strategisch, nicht technisch, und als zusätzlicher Provider hinter dem existierenden `TranscriptionServiceProtocol` reparierbar, ohne irgendetwas wegzuwerfen.

### 4.2 Wo sich die Gutachten widersprechen

- **Framing:** Der CTO nennt das Urteil „teilweise falsche Technologie" (wegen Cloud-STT und SwiftUI-List-Patterns), die anderen beiden „Nein, nur falsche Muster". Inhaltlich ist das dieselbe Diagnose mit anderer Überschrift.
- **Sidebar-Strategie:** Der macOS-Engineer will direkt auf eine NSOutlineView-Bridge (löst Drag&Drop strukturell, ~300–500 Zeilen AppKit); der Staff-Engineer empfiehlt zweistufig — erst die belegten SwiftUI-Regeln ausreizen (Inlining im ForEach, `Equatable`-Rows, per-Item-Observable), NSOutlineView nur als Fallback. Pragmatische Auflösung: Stufe 1 ist Tage statt Wochen und sollte zuerst gemessen werden.
- **Reihenfolge:** Der Staff-Engineer besteht darauf, den In-Memory-Store **vor** Sidebar und Event-Watching zu bauen (sonst schreiben die neuen Komponenten auf eine blockierende, race-anfällige Persistenzschicht) — die anderen priorisieren sichtbare Wins zuerst. Der Abhängigkeitsgraph gibt dem Staff-Engineer recht; die Diktat-Fixes sind davon aber unabhängig und können parallel laufen.

### 4.3 Korrekturen aus der Faktenprüfung (wichtig)

Drei Behauptungen aus den Gutachten wurden in der adversarialen Prüfung **widerlegt** und sind hier korrigiert:

1. **SwiftTerm-Durchsatz:** Die in zwei Gutachten suggerierte Erwartung „+58–69 % Durchsatz durch Aktivierung des Metal-GPU-Backends" ist **falsch attribuiert**. Die +58 % (v1.9.0) und +69 % (v1.11.0) stammen aus CPU-Parser-Optimierungen und sind in der gepinnten Version 1.13.0 **bereits enthalten** — WhisperM8 profitiert davon heute schon. Richtig bleibt: Das Metal-Backend (eingeführt in v1.12.0, „inspired by the Ghostty GPU engine", Opt-in via `setUseMetal`) wird in WhisperM8 nicht aktiviert; es ist eine Evaluation wert, aber **ohne quantifizierte Gewinnerwartung** — die Release-Notes nennen dafür keine Zahlen.
2. **Commit 60ca683:** Der Commit (27.05.2026) hat die `.draggable`-Modifier **ersatzlos entfernt**, nicht „hinter einen Escape-Hatch gelegt". Auf HEAD ist Sidebar-Drag&Drop damit tatsächlich funktionslos (Drop-Ziele ohne Drag-Quellen). Der Escape-Hatch (`sidebarDraggable()` mit `agentSidebarDragEnabled`, **Default: an**) existiert nur als **uncommittete Working-Tree-Änderung** — d. h. der Fix ist bereits in Arbeit, aber nicht gesichert. Erste Sofortmaßnahme: committen und testen. Die stille `prefix(20)`-Kappung (Sessions ab Platz 21 unsichtbar) ist davon unabhängig bestätigt und weiterhin offen.
3. **Apple-Forum-Referenz:** Thread 767585 dokumentiert **nicht** „List-Rows werden nicht lazy geladen", sondern einen macOS-spezifischen Scroll-Performance-Defekt bei in Subviews extrahierten List-Rows (FB15645433, bestätigt bis macOS 15.4). Korrekt referenziert bleibt Thread 730367 / FB12980427 (`.dropDestination` innerhalb von `List` feuert nicht). Die Stoßrichtung — SwiftUI-List/DnD auf macOS ist objektiv defekt und erfordert Workarounds oder AppKit-Bridging — bleibt voll gültig.

### 4.4 Urteil

**Du hast nicht auf die falsche Technologie gesetzt — du hast die richtige Technologie an fünf Stellen falsch benutzt und an einer Stelle (lokale STT) eine Marktentwicklung verpasst.** Beides ist inkrementell behebbar, ohne Rewrite, mit den vorhandenen 313 Tests als Netz. Ein Stack-Wechsel wäre die teuerste mögliche Antwort auf Probleme, die er nicht löst. Re-Evaluations-Trigger für diese Entscheidung (als ADR festhalten): erstes getaggtes libghostty-Release samt Swift-Surface-Framework als SwiftTerm-Alternative; strategische Windows-Nachfrage in relevanter Größenordnung.

---

## 5. Top-Empfehlungen

### Sofort (diese 1–2 Wochen)

| # | Maßnahme | Aufwand | Impact |
|---|---|---|---|
| S1 | **Diktat-Hot-Path entschlacken:** Tail-Extract und Clipboard-Fallback aus dem `@MainActor`-`startRecording` in einen parallelen Task (Aufnahme startet sofort, Kontext kommt nach); `codex login status` mit TTL cachen statt pro Diktat synchron spawnen; Overlay-Tick ohne Disk-I/O (OutputModeStore cachen, Invalidierung per Notification) | 3–5 Tage | Keine verlorenen ersten Silben; ~0,5–1 s weniger Latenz pro Diktat — direkter Angriff auf Wisprs <1-s-Messlatte |
| S2 | **Nie wieder Datenverlust:** M4A bei Transkriptionsfehler aufbewahren + Retry-Button statt sofortigem Löschen; Cancel während der Transcribing-Phase (URLSession-Task-Cancellation); `uploadTask(fromFile:)` statt doppelter Data-Allokation | 1–2 Tage | „Verliert nie eine Aufnahme" — ein Vertrauens-Feature, das Wispr Flow nicht hat |
| S3 | **Working-Tree-Fix committen:** Den bereits gebauten, uncommitteten Sidebar-Drag-Fix (`sidebarDraggable` + Preference) absichern und mergen; `prefix(20)`-Kappung durch „Mehr anzeigen" oder echtes Lazy-Loading ersetzen | 1–2 Tage | Stellt verlorene Kernfunktion wieder her; macht Sessions ab Platz 21 sichtbar |
| S4 | **CI + Messbarkeit:** GitHub-Actions-Workflow (`swift test` als Merge-Gate — heute existiert keinerlei CI); os_signpost-Budgets auf Hot-Paths (Hotkey→Aufnahme <50 ms, Store-Mutation <5 ms, Idle-CPU <1 % bei 20 Sessions); 134-KB-Test-Monolith aufteilen | 2–3 Tage | Regressions-Netz für alle folgenden Umbauten; Performance-Claims werden belegbar statt anekdotisch |

### Dieses Quartal

| # | Maßnahme | Aufwand | Impact |
|---|---|---|---|
| Q1 | **In-Memory-Workspace-Store (Fundament zuerst):** Actor-basiertes Modell mit serialisierter, debounced Persistenz statt Voll-Load+Voll-Rewrite pro Mutation; behebt die Last-Writer-Wins-Race; git-Spawns off-main | 2–3 Wochen | Jeder Klick O(1) statt O(Workspace); keine verlorenen Mutationen mehr; Voraussetzung für Q2/Q3 |
| Q2 | **Events statt Polling:** FSEventStream auf `~/.claude/projects` + `~/.codex/sessions` (ersetzt 30-s-Scan); DispatchSource pro aktiver Transcript-JSONL mit Delete/Rename-Re-Arm und mtime-Fallback (ersetzt 1,5-s-Polling); Supervisor-Tracking und ps-Forks reduzieren. Das Muster existiert bereits produktiv in der Hook-Bridge | 1–2 Wochen | Idle-CPU gegen 0, Status-Latenz von 1,5 s auf Millisekunden — der härteste messbare Kontrast zu Supersets Polling-/Latenz-Reputation |
| Q3 | **Sidebar zweistufig sanieren:** Stufe 1: belegte SwiftUI-Regeln (ForEach-Inlining, Equatable-Rows, kein `.id()`, per-Item-Observable für Status-Dots), dann mit Instruments 26 messen; Stufe 2 nur bei Bedarf: NSOutlineView-Bridge (Multi-Select-Drag, Tausende Rows) | Stufe 1: 3–5 Tage; Stufe 2: +1–2 Wochen | Scroll-Hang ursächlich statt symptomatisch gefixt; Sidebar skaliert auf Jahre an Session-Historie |
| Q4 | **Transcript-Index + inkrementelle Reads:** sessionID→Pfad-Map statt rekursivem `~/.codex`-Walk pro Tick; Byte-Offset-Cursor mit synchronen Chunk-Reads off-main (async `.lines` ist gemessen ~2× langsamer); die zwei divergierenden cwd-Encoder vereinheitlichen; AutoNamer von `String(contentsOf:)` auf den vorhandenen LineStream | ~1 Woche | Transcript-Zugriffe O(neue Bytes) statt O(Dateigröße); Main-Thread-Blocker nach Launch und beim Auto-Naming verschwinden |
| Q5 | **Terminal-Feinschliff:** Einen geteilten NSEvent-Monitor statt zwei app-weiter Monitore pro Controller (auch für beendete Prozesse); SwiftTerm-Metal-Backend als Opt-in benchmarken — ohne Zahlenversprechen, die +58–69 % aus den Release-Notes sind bereits in 1.13.0 enthalten; libghostty nur beobachten (kein getaggtes Release, API instabil) | 2–4 Tage + Messung | Input-Latenz konstant statt linear mit Tab-Anzahl; Rendering-Headroom dort, wo Superset dokumentiert einbricht |
| Q6 | **Ship-Infrastruktur:** Sparkle-Auto-Update, Developer-ID + Notarisierung als Standard, `codesign --deep` ersetzen; Reports-UI wieder erreichbar machen (OutputDashboard ist fertig gebaut, aber nirgends instanziiert) | ~1 Woche | Verbesserungen erreichen Nutzer kontinuierlich; Gatekeeper-Blockade auf fremden Macs fällt |

### Strategisch (6–12 Monate)

| # | Maßnahme | Aufwand | Impact |
|---|---|---|---|
| L1 | **Lokale Transkription als dritter Provider:** NVIDIA Parakeet v3 via FluidAudio/CoreML auf der Neural Engine hinter dem existierenden `TranscriptionServiceProtocol`; Cloud bleibt für Sprachen-Langschwanz; SpeechAnalyzer-Pfad vormerken, sobald das Target macOS 26 erlaubt | 3–6 Wochen | Schließt die größte strategische Lücke: Offline, ~1 s gefühlt instant, null Grenzkosten, Privacy-first-Positionierung exakt gegen Wisprs wundesten Punkt (Cloud-Zwang, Screenshot-Affäre) — und Absicherung gegen Apples Systemdiktat |
| L2 | **Den Integrations-Keil zum Produktkern machen:** Diktat ↔ Agent-Chats ist dein einziges Feature, das weder Wispr noch Superset/Conductor noch Anthropic selbst haben. Ausbauen: Voice-Dispatch von Background-Agents, gesprochene Reviews, Status-Ansagen — und so vermarkten | laufend | Verteidigungslinie gegen Plattform-Absorption (Anthropic-Desktop-App, Apple-Diktat); aus zwei guten Tools wird ein unkopierbares Produkt |
| L3 | **ADR „kein Stack-Wechsel" + Performance-Budget veröffentlichen:** Entscheidung mit Re-Evaluations-Triggern dokumentieren (libghostty-Release, Windows-Nachfrage); gemessene Zahlen (Idle-CPU, RAM bei N Terminals, Hotkey-Latenz) als Marketing-Claims gegen die Electron-Konkurrenz nutzen | 1–2 Tage + laufend | Beendet die Migrationsdebatte produktiv; macht „nativ schlägt Electron" zur belegbaren Produkteigenschaft statt Bauchgefühl |

**Realistisches Zielbild nach einem Quartal:** Hotkey→Aufnahme verzögerungsfrei, Diktat-Roundtrip ~1–2 s schneller, kein Datenverlust mehr, Idle-CPU nahe 0 bei Dutzenden Sessions, Sidebar mit funktionierendem Drag&Drop ohne Kappung — messbar dokumentiert. Nach zwei Quartalen mit lokaler STT: schneller als Wispr Flow bei Diktat-Latenz, leichter als Superset um eine Größenordnung beim Footprint, und als einziges Produkt mit der Diktat-Agent-Integration.

---

## 6. Quellen

**Codebase (verifiziert per Faktenprüfung):**
- `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/AgentSessionRuntimeWatcher.swift` (Z. 39, 46–47: 1,5-s-Polling, 64-KB-Tail-Reads, „Bewusst kein FSEventStream")
- `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/ClaudeHookBridge.swift` (event-getrieben via DispatchSource, 0 % Idle-CPU)
- `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/AgentSessionStore.swift` (Z. 730–743: Voll-Load+Voll-Rewrite) · `AgentChatsView.swift` (26× `loadWorkspace()`)
- `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/RecordingCoordinator.swift` (Z. 75–82: synchroner Tail-Extract mit falschem Kommentar; Z. 731: Audio-Löschung bei Fehler)
- `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/TranscriptionService.swift` (cloud-only, kein Cancel, `Data(contentsOf:)`-Upload)
- `/Users/giulianocosta/repos/whisperm8/WhisperM8/Windows/RecordingPanel.swift` (Z. 328–347: Disk-I/O im 100-ms-Tick)
- `git show 60ca683` + Working-Tree-Diff (`AgentChatsSidebarViews.swift`, `AppPreferences.swift`) · `/Users/giulianocosta/repos/whisperm8/Package.resolved` (SwiftTerm 1.13.0)

**Markt — Diktat:** wisprflow.ai (Features/Pricing/Tech-Blog) · baseten.co/customers/wispr-flow · techcrunch.com (Wispr-Funding 06+11/2025, Android 02/2026) · news.ycombinator.com/item?id=47781148 (Screenshot-Affäre) · superwhisper.com · github.com/Beingpax/VoiceInk · github.com/cjpais/Handy · goodsnooze.gumroad.com/l/macwhisper · macrumors.com + macstories.net (SpeechAnalyzer-Benchmarks) · techbuzz.ai (Apple-Systemdiktat WWDC 2026)

**Markt — Agent-Manager:** superset.sh (+ Pricing/Changelog) · github.com/superset-sh/superset (`apps/desktop/package.json`, Issue #1517) · news.ycombinator.com/item?id=48236770 (Launch HN) · conductor.build · github.com/stravu/crystal (deprecated) · vibekanban.com/blog/shutdown · github.com/slopus/happy · github.com/kbwo/ccmanager · github.com/smtg-ai/claude-squad · claude.com/blog/claude-code-desktop-redesign · github.com/andyrewlee/awesome-agent-orchestrators

**Technologie:** github.com/migueldeicaza/SwiftTerm (Releases v1.8–v1.13, Issues #202/#479) · libghostty.tip.ghostty.org · mitchellh.com/writing/libghostty-is-coming · ghostty.org (Release-Notes 1.3.0) · kean.blog/post/not-list · developer.apple.com/forums (Threads 767585, 730367, 664469; FB15645433, FB12980427) · forums.swift.org/t/66244 (async `.lines`-Performance) · alexwlchan.net/2026/watch-files-on-macos · gethopp.app/blog/tauri-vs-electron · warp.dev/blog/how-warp-works · blog.luminoid.dev/Terminal-Emulator-Comparison-2026 · devtoolreviews.com (Terminal-RAM-Benchmarks 2026)