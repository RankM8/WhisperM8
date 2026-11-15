import Foundation
import os

/// Signpost-Schienen für die drei instrumentierten Hot-Paths (Plan P7).
/// Sichtbar im Instruments-Template "os_signpost" und als
/// `perf_budget_exceeded`-Warnungen via:
///   log stream --predicate 'subsystem == "com.whisperm8.app"'
enum PerfSignposts {
    private static let subsystem = "com.whisperm8.app"
    static let recording = OSSignposter(subsystem: subsystem, category: "perf.recording")
    static let index = OSSignposter(subsystem: subsystem, category: "perf.index")
    static let store = OSSignposter(subsystem: subsystem, category: "perf.store")
    static let sidebar = OSSignposter(subsystem: subsystem, category: "perf.sidebar")
    static let grid = OSSignposter(subsystem: subsystem, category: "perf.grid")
    static let statistics = OSSignposter(subsystem: subsystem, category: "perf.statistics")
    static let controller = OSSignposter(subsystem: subsystem, category: "perf.controller")
    static let chats = OSSignposter(subsystem: subsystem, category: "perf.chats")
}

/// Wie dicht ein Messpunkt sitzt — und damit, ob er im Normalbetrieb mitläuft.
///
/// **Warum es diese Unterscheidung gibt (gemessen 01.08.2026, M-Serie):** Ein
/// os_signpost-Intervall (`begin` + `end`) kostet **~686 ns**, und zwar immer.
/// `OSSignposter.isEnabled` ist auf macOS dauerhaft `true` — die Daten laufen
/// in den Ringpuffer des Systems, auch ohne laufendes Instruments. Ein
/// `guard isEnabled` bringt exakt nichts (683 vs. 686 ns). Die Zeitmessung via
/// `Date()` ist mit 61 ns dagegen der billige Teil; sie zu optimieren wäre
/// Beschäftigungstherapie.
///
/// Die Kosten skalieren also allein mit der **Dichte**:
/// 100 Messpunkte/s ≈ 0,007 %, 10.000/s ≈ 0,7 %, 100.000/s ≈ 7 % CPU.
///
/// **Harte Regel: niemals pro Byte, pro Zeichen oder pro Zeile messen.** Dort
/// gehören Zähler hin (`PerfCounters`, ~1 ns pro Ereignis), die einmal pro
/// Sekunde aggregiert ausgegeben werden — aus 10.000 Messpunkten wird einer.
enum PerfTier {
    /// Sitzt an einem von Natur aus seltenen Ereignis (Klick, Fensterwechsel,
    /// Speichervorgang, gebündelter Flush). Läuft immer mit.
    case always
    /// Dichter oder nur für Untersuchungen interessant. Läuft nur bei
    /// `defaults write com.whisperm8.app agentPerfDetailEnabled -bool YES`.
    case detail
}

/// Prozessweites Gate für die Detail-Stufe. Einmal gelesen — Umschalten
/// erfordert einen App-Neustart, genau wie beim Metal-Schalter.
enum PerfDetailGate {
    /// Überschreibbar für Tests; im Produktivbetrieb aus den Preferences.
    nonisolated(unsafe) static var isEnabled: Bool = AppPreferences.shared.isAgentPerfDetailEnabled
}

/// Budget-Überwachung um ein os_signpost-Intervall: misst die Dauer, emittiert
/// Begin/End für Instruments und loggt eine Warnung, wenn das Budget gerissen
/// wird.
///
/// WICHTIG: Im Violation-Pfad läuft ausschließlich `os.Logger` — niemals
/// `Logger.debug()` (das hat optionales File-Logging und gehört nicht in
/// einen Hot-Path).
///
/// Bevorzugt `withInterval` verwenden — beendet das Intervall strukturell auf
/// allen Pfaden, auch bei `throw` und Early-Returns. Das manuelle
/// `begin()`/`end(_:)`-Token nur dort, wo Begin und End über Methoden- oder
/// Task-Grenzen laufen (z. B. `pollOne`). `end` ist idempotent, ein
/// zusätzliches Safety-`defer` ist damit ausdrücklich erlaubt.
struct PerformanceBudget {
    /// Token einer laufenden Messung. Referenztyp, damit `end` die Messung
    /// idempotent abschließen kann.
    ///
    /// `state == nil` heißt: abgeschalteter Detail-Messpunkt. Dann entfällt
    /// auch die Zeitmessung, der Token ist eine leere Hülle und `end` kehrt
    /// sofort zurück.
    final class Token {
        fileprivate let state: OSSignpostIntervalState?
        fileprivate let startedAt: TimeInterval?
        /// Auf dem Main Thread begonnen: dann führt `MainThreadIntervalLedger`
        /// Buch, damit Hänger-Meldungen ihren Verursacher nennen (WM8-101).
        fileprivate let onMain: Bool
        fileprivate let name: StaticString?
        fileprivate var ended = false

        fileprivate init(state: OSSignpostIntervalState?, startedAt: TimeInterval?, onMain: Bool = false,
                         name: StaticString? = nil) {
            self.state = state
            self.startedAt = startedAt
            self.onMain = onMain
            self.name = name
        }

        /// Ein Token, das nie beendet wurde (verworfene Messung, Task
        /// abgebrochen), schließt sich im Register. Sonst stünde sein Name
        /// für immer in `open=` und die Liste wüchse (WM8-101, Uli).
        deinit {
            guard onMain, !ended, let name else { return }
            MainThreadIntervalLedger.shared.didEnd(name, start: nil, end: nil)
        }

        /// EIN geteiltes Token für alle abgeschalteten Detail-Messpunkte.
        ///
        /// Bewusst `static let`, nicht berechnet: sonst allokierte jeder
        /// abgeschaltete `begin()` ein neues Objekt samt ARC-Verkehr — bei
        /// einem `.detail`-Messpunkt in einem dichten Pfad also zehntausende
        /// Allokationen pro Sekunde für Messungen, die gar nicht stattfinden.
        /// Das Teilen ist nur zulässig, weil `end`/`cancel` bei fehlendem
        /// `state` zurückkehren, BEVOR sie `ended` schreiben — dieses Token
        /// wird also nie verändert und ist damit über Threads hinweg sicher.
        fileprivate static let inactive = Token(state: nil, startedAt: nil)
    }

    let name: StaticString
    /// Budget in Sekunden. Startwerte — nach Realdaten-Abgleich nachziehen.
    let budget: TimeInterval
    let signposter: OSSignposter
    /// Messdichte-Stufe. Default `.always`, damit bestehende Messpunkte sich
    /// nicht ändern; neue dichte Messpunkte müssen `.detail` explizit setzen.
    var tier: PerfTier = .always
    /// `true` für Intervalle, die Wartezeit messen statt Arbeit (Latenz bis
    /// zur Rückkehr auf den Main Thread, „bis die Pane eingehängt ist“). Sie
    /// sind die Folge eines Hängers, nicht die Ursache, und kommen deshalb
    /// nicht ins `MainThreadIntervalLedger` (WM8-101).
    var measuresWaiting = false
    /// Test-Hook: deterministische Uhr. Liefert Sekunden seit Systemstart.
    ///
    /// Bewusst `DispatchTime` und nicht `Date`: Eine Wanduhr springt bei
    /// Zeitumstellung und NTP-Korrektur — vorwaerts ergaebe das erfundene
    /// Budget-Verletzungen, rueckwaerts negative Dauern, die jede echte
    /// Verletzung verschlucken. Sie laeuft ausserdem waehrend des Systemschlafs
    /// weiter, sodass eine Messung ueber einen Schlaf hinweg Stunden meldete.
    /// Nebeneffekt: `DispatchTime` ist mit ~21 ns auch dreimal billiger als
    /// `Date` (~61 ns) — beides verschwindet allerdings neben den ~686 ns des
    /// Signposts.
    var now: () -> TimeInterval = {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
    /// Test-Hook: ersetzt das Default-Logging. Parameter: Name, gemessene Dauer.
    var onViolation: ((String, TimeInterval) -> Void)?

    /// `false`, wenn dieser Messpunkt zur Detail-Stufe gehört und die
    /// abgeschaltet ist. Öffentlich, damit Aufrufer teure Vorbereitung
    /// (Zählen, Zusammenstellen von Werten) davon abhängig machen können.
    ///
    /// **Pflicht für Aufrufer, die um `begin`/`end` herum eigene Verwaltung
    /// betreiben** — `GridPerformanceTracker` etwa hält Tokens, startet
    /// Timeout-Tasks und zählt Generationen. Ein inaktives Token ist nicht
    /// `nil`; solcher Code liefe also weiter, als gäbe es eine Messung, und
    /// verursachte genau die Kosten, die die Detail-Stufe vermeiden soll.
    /// Wer ein Budget auf `.detail` umstellt, muss die umgebende Verwaltung
    /// deshalb hiermit absichern. Solange alle produktiven Budgets `.always`
    /// sind, ist das ein Zukunfts-, kein Ist-Problem.
    var isActive: Bool {
        tier == .always || PerfDetailGate.isEnabled
    }

    func begin() -> Token {
        guard isActive else { return .inactive }
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        let onMain = !measuresWaiting && Thread.isMainThread
        if onMain { MainThreadIntervalLedger.shared.didBegin(name) }
        return Token(state: state, startedAt: now(), onMain: onMain, name: name)
    }

    func end(_ token: Token) {
        // Reihenfolge ist wichtig: erst auf „inaktiv" prüfen, DANN `ended`
        // schreiben. Sonst würde das geteilte `Token.inactive` beschrieben —
        // aus mehreren Threads und mit der Folge, dass es nach dem ersten
        // Gebrauch global als beendet gälte.
        guard let state = token.state, let startedAt = token.startedAt else { return }
        guard !token.ended else { return }
        token.ended = true
        signposter.endInterval(name, state)

        let endedAt = now()
        if token.onMain {
            MainThreadIntervalLedger.shared.didEnd(name, start: startedAt, end: endedAt)
        }
        let duration = endedAt - startedAt
        guard duration > budget else { return }
        if let onViolation {
            onViolation("\(name)", duration)
        } else {
            Logger.agentPerformance.warning(
                "perf_budget_exceeded name=\("\(name)", privacy: .public) durationMs=\(Int(duration * 1000), privacy: .public) budgetMs=\(Int(budget * 1000), privacy: .public)"
            )
        }
    }

    /// Bricht eine Messung ab: schließt das Signpost-Intervall, OHNE die
    /// Dauer gegen das Budget zu bewerten — für überholte/verworfene
    /// Messungen (z. B. ein Fokusziel, das nie anwendbar wurde). Idempotent
    /// wie `end`.
    func cancel(_ token: Token) {
        // Gleiche Reihenfolge wie in `end` — siehe Begründung dort.
        guard let state = token.state else { return }
        guard !token.ended else { return }
        token.ended = true
        signposter.endInterval(name, state)
        if token.onMain {
            MainThreadIntervalLedger.shared.didEnd(name, start: nil, end: nil)
        }
    }

    func withInterval<T>(_ body: () throws -> T) rethrows -> T {
        let token = begin()
        defer { end(token) }
        return try body()
    }

    func withInterval<T>(_ body: () async throws -> T) async rethrows -> T {
        let token = begin()
        defer { end(token) }
        return try await body()
    }
}

/// Konkrete Budgets der instrumentierten Hot-Paths. Begründung der Werte und
/// Treiber: docs/archive/strategie/2026-06-10-refactor-plan.md, Paket P7.
enum PerfBudgets {
    // Diktat-Pipeline
    static let recordingStart = PerformanceBudget(name: "recording.start", budget: 0.400, signposter: PerfSignposts.recording)
    static let recordingStop = PerformanceBudget(name: "recording.stop", budget: 0.300, signposter: PerfSignposts.recording)
    static let contextCapture = PerformanceBudget(name: "recording.contextCapture", budget: 0.150, signposter: PerfSignposts.recording)
    static let chatTail = PerformanceBudget(name: "recording.chatTail", budget: 0.100, signposter: PerfSignposts.recording)
    static let engineStart = PerformanceBudget(name: "recording.engineStart", budget: 0.250, signposter: PerfSignposts.recording)

    /// Abbau der Audio-Engine: `removeTap` + `stop`.
    ///
    /// **Warum eigens gemessen (02.08.2026):** Der laengste beobachtete
    /// Main-Thread-Stillstand — 3034 ms — hatte im Log unmittelbar davor
    /// CoreAudio-/AVAudioEngine-Teardown stehen und keinerlei Scan-, Merge-
    /// oder Store-Ereignis. Das ist ein ZWEITER, vom Indexer unabhaengiger
    /// Blockadetyp: `AVAudioEngine.stop()` und `removeTap` sind synchron und
    /// koennen auf die CoreAudio-HAL warten, etwa wenn ein Geraet gerade
    /// wechselt. Ohne eigenen Messpunkt bleibt das Ratearbeit.
    static let engineStop = PerformanceBudget(name: "recording.engineStop", budget: 0.100, signposter: PerfSignposts.recording)

    // Transcript-Index
    static let indexCacheLoad = PerformanceBudget(name: "index.cacheLoad", budget: 0.250, signposter: PerfSignposts.index)
    static let indexCacheSave = PerformanceBudget(name: "index.cacheSave", budget: 0.500, signposter: PerfSignposts.index)
    static let indexScan = PerformanceBudget(name: "index.scan", budget: 2.000, signposter: PerfSignposts.index)
    static let indexMerge = PerformanceBudget(name: "index.merge", budget: 0.030, signposter: PerfSignposts.index)

    // Workspace-Store
    static let storeMutate = PerformanceBudget(name: "store.mutate", budget: 0.030, signposter: PerfSignposts.store)
    static let storeNormalize = PerformanceBudget(name: "store.normalize", budget: 0.015, signposter: PerfSignposts.store)
    static let storeEquality = PerformanceBudget(name: "store.equality", budget: 0.010, signposter: PerfSignposts.store)
    static let storeLoad = PerformanceBudget(name: "store.load", budget: 0.015, signposter: PerfSignposts.store)
    static let storeSave = PerformanceBudget(name: "store.save", budget: 0.020, signposter: PerfSignposts.store)
    static let saveUIState = PerformanceBudget(name: "store.saveUIState", budget: 0.010, signposter: PerfSignposts.store)

    // Sidebar / Status-Pipeline
    static let sidebarWorkspaceLoad = PerformanceBudget(name: "sidebar.workspaceLoad", budget: 0.050, signposter: PerfSignposts.sidebar)
    /// Selbstheilung toter Session-Zeiger (Event-Files lesen), off-main.
    static let externalIDRecovery = PerformanceBudget(name: "sidebar.externalIDRecovery", budget: 0.500, signposter: PerfSignposts.sidebar)
    static let sidebarBackgroundIndex = PerformanceBudget(name: "sidebar.backgroundIndex", budget: 2.000, signposter: PerfSignposts.sidebar)
    /// Die tatsächliche Arbeit eines Status-Polls: `stat` und, falls nötig,
    /// das Lesen des Transcript-Endes. Läuft im Hintergrund-Task, misst also
    /// reine Rechen- und I/O-Zeit.
    ///
    /// **Korrigiert am 01.08.2026** — vorher lief die Messung von `begin()` auf
    /// dem MainActor bis `end()` nach der Rückkehr aus dem Hintergrund-Task und
    /// enthielt damit Einplanungs- und MainActor-Wartezeit. Belegt durch die
    /// Logs: Am 01.08. um 16:38:08 endeten **zehn** Polls mit exakt 150 ms, um
    /// 16:37:35 acht mit 173 ms. Unabhängige Dateizugriffe enden nicht
    /// millisekundengleich — gemessen wurde eine gemeinsame Blockade, nicht die
    /// Arbeit. Der Messpunkt schlug damit auf einen fremden Verursacher an und
    /// stand fälschlich als größter Ausreißer der App da.
    ///
    /// Budget ist ein Startwert und gehört gegen Realdaten nachgezogen.
    static let sidebarStatusPoll = PerformanceBudget(name: "sidebar.statusPoll", budget: 0.050, signposter: PerfSignposts.sidebar)

    /// Die Gesamtstrecke eines Polls inklusive Einplanung des Hintergrund-Tasks
    /// und Rückkehr auf den MainActor. Das ist eine **Latenz**, keine
    /// Main-Thread-Kosten: ein hoher Wert heißt „das Ergebnis kam spät", nicht
    /// „die App stand". Genau deshalb Detail-Stufe — im Alltag sagt die Zahl
    /// wenig, bei einer Untersuchung zeigt sie zusammen mit
    /// `MainThreadStallMonitor`, ob der MainActor der Engpass war.
    static let sidebarStatusPollLatency = PerformanceBudget(
        name: "sidebar.statusPollLatency", budget: 0.250, signposter: PerfSignposts.sidebar, tier: .detail,
        measuresWaiting: true
    )
    static let sidebarModelBuild = PerformanceBudget(name: "sidebar.modelBuild", budget: 0.0167, signposter: PerfSignposts.sidebar)

    /// Ein Abruf der Ticket-Ansicht bei Linear (zwei Abfragen, bis zu fünf
    /// Seiten). Netz-Latenz, keine Main-Thread-Kosten; läuft alle 30 Sekunden,
    /// solange die Ansicht sichtbar ist. Startwert, gegen Realdaten nachziehen.
    static let ticketsFetch = PerformanceBudget(name: "tickets.fetch", budget: 3.0, signposter: PerfSignposts.store, tier: .detail)
    /// Liste der Chats für den Abgleich lesen: einmal je neuem Abzug, auf dem
    /// Main Thread, über alle Sitzungen des Workspace.
    static let ticketsChats = PerformanceBudget(name: "tickets.chats", budget: 0.004, signposter: PerfSignposts.store, tier: .detail)
    /// Abgleich des Abzugs mit den Chats der App (wer sitzt woran), abseits des
    /// Main Threads. Startwert für bis zu 500 Tickets.
    static let ticketsBuild = PerformanceBudget(name: "tickets.build", budget: 0.030, signposter: PerfSignposts.store, tier: .detail)

    /// Die Arbeit, die JEDER abgeschlossene Scan auf dem Main Thread nach sich
    /// zieht: Workspace neu laden, Projekt-Icons erkennen, Auto-Benennung
    /// anstossen — pro offenem Fenster.
    ///
    /// **Warum eigens gemessen (02.08.2026):** Der Main Thread stand mehrfach
    /// pro Minute ueber eine Sekunde, ohne dass ein einziger Messpunkt es
    /// zeigte. Genau dafuer ist der `MainThreadStallMonitor` da — und diese
    /// Kette ist der konkreteste Verdaechtige, den die Analyse uebrig liess:
    /// sie haengt an `scanDidCompleteNotification`, laeuft also auch nach
    /// Scans, die nichts geaendert haben, und iteriert dabei ueber den
    /// gesamten Workspace. Ob sie die Sekunden erklaert, ist damit ab dem
    /// naechsten Lauf keine Vermutung mehr.
    static let sidebarScanFollowUp = PerformanceBudget(name: "sidebar.scanFollowUp", budget: 0.050, signposter: PerfSignposts.sidebar)

    /// Die Folgearbeit bei jeder Workspace-Aenderung: aktiven Chat abgleichen,
    /// tote IDs aus allen Fenstern raeumen, Selektion pruefen — pro offenem
    /// Fenster und jeweils ueber alle Sessions.
    ///
    /// **Warum eigens gemessen (02.08.2026):** Die Log-Korrelation eines
    /// 1241-ms-Stillstands zeigt, dass der Main Thread erst NACH der
    /// Workspace-Publikation blockiert — der Merge selbst ist als Ursache
    /// widerlegt (keine Verletzung von `index.merge`, `store.mutate`,
    /// `store.normalize`). Die Zeit steckt in der Reaktionsphase, und dies ist
    /// deren einziger uninstrumentierter Teil neben SwiftUIs eigenem Diff.
    /// Reisst dieses Budget, haben wir den Verursacher; reisst es nicht,
    /// bleibt SwiftUIs View-Auswertung uebrig und braucht Instruments.
    static let workspaceChangeFollowUp = PerformanceBudget(name: "sidebar.workspaceChangeFollowUp", budget: 0.050, signposter: PerfSignposts.sidebar)

    // Grid-Workspace (Budgets aus docs/plans/grid-workspace-plan.html, Abschnitt 05;
    // Freigabe-Gates sind p95-Werte, Einzelverletzungen sind Hinweise, keine Fehler).
    /// Grid-Aufbau: showsGrid → alle erwarteten Terminal-Panes attached.
    static let gridBuild = PerformanceBudget(name: "grid.build", budget: 0.050, signposter: PerfSignposts.grid,
                                             measuresWaiting: true)
    /// Pane-Fokuswechsel: Selektionsänderung → makeFirstResponder angewendet.
    static let gridFocusSwitch = PerformanceBudget(name: "grid.focusSwitch", budget: 0.033, signposter: PerfSignposts.grid,
                                                   measuresWaiting: true)
    /// Ein ANGEWANDTER (coalesced) Divider-Layout-Tick inkl. Folge-Layout —
    /// nicht jeder Maus-Event (die werden gesammelt).
    static let gridDividerTick = PerformanceBudget(name: "grid.dividerTick", budget: 0.016, signposter: PerfSignposts.grid)
    /// Ein Streaming-Flush einer Pane (Parser + Render-Scheduling, keine GPU-Zeit).
    static let gridStreamingFrame = PerformanceBudget(name: "grid.streamingFrame", budget: 0.0167, signposter: PerfSignposts.grid)

    // Chatwechsel und Start (WM8-101). Der Chatwechsel ist der größte Posten
    // der Hängerzeit (15.11.2026: 54 %), war aber ohne Messpunkt.

    /// Auswahlwechsel im Fenster-Store bis nach dem nächsten Core-Animation-
    /// Commit: Body-Auswertung, Layout und Zeichnen des ganzen Fensters samt
    /// Seitenleiste. Ein Klick ist selten, deshalb immer an.
    static let chatSwitch = PerformanceBudget(name: "chat.switch", budget: 0.100, signposter: PerfSignposts.chats)
    /// Umhängen einer Terminal-Ansicht in ihren Container bis nach dem
    /// nächsten Commit. Im Raster mehrere je Wechsel, deshalb Detail-Stufe.
    static let paneAttach = PerformanceBudget(name: "pane.attach", budget: 0.050, signposter: PerfSignposts.chats, tier: .detail)
    /// Größenänderung einer Terminal-Ansicht samt Umbruch des Puffers. Läuft
    /// beim Ziehen des Fensterrands in jedem Bild, deshalb Detail-Stufe.
    static let terminalResize = PerformanceBudget(name: "terminal.resize", budget: 0.016, signposter: PerfSignposts.chats, tier: .detail)
    /// Ende von `applicationDidFinishLaunching` bis nach dem ersten Commit
    /// des Agent-Chats-Fensters. Einmal je Start.
    static let launchFirstWindow = PerformanceBudget(name: "launch.firstWindow", budget: 0.500, signposter: PerfSignposts.chats)
    /// Änderung des Workspace-Stands (`AgentWorkspaceUIModel.workspace`) bis
    /// nach dem nächsten Commit: der Fensterbody läuft neu, ohne dass sich die
    /// Auswahl ändert. Messlauf 15.11.: 8 von 9 unbenannten Hängern im Betrieb
    /// lagen so. Häufig (jede Store-Mutation), deshalb Detail-Stufe.
    static let workspaceApply = PerformanceBudget(name: "workspace.apply", budget: 0.050, signposter: PerfSignposts.chats, tier: .detail)

    // Statistik
    /// Ein inkrementeller Lauf des Protokoll-Lesers (`StatisticsLogScanner`):
    /// alle Protokolle auflisten und `stat`en, neue Bytes lesen, einmal in den
    /// Store schreiben. Läuft auf eigener Queue, ist also Hintergrund-, keine
    /// Main-Thread-Zeit. Der Backfill (erstes Einlesen der Historie) wird nicht
    /// gemessen, er ist gewollt langsam. Läufe mit Diktat-Pause zählen nicht.
    static let statisticsScan = PerformanceBudget(name: "statistics.scan", budget: 1.500, signposter: PerfSignposts.statistics)

    // Vereinte Pille
    /// Diktat-Fenster an seiner Stelle aufbauen (nach der Bildschirmsuche,
    /// auf dem Main Thread). Nur in der Detail-Stufe.
    static let unifiedPillShow = PerformanceBudget(
        name: "pill.unifiedShow", budget: 0.016, signposter: PerfSignposts.recording, tier: .detail)
    /// Übergang Ruhe-Pille ↔ Diktat (`UnifiedPillMorph`): vom Start der
    /// Breitenanimation (0,35 s) bis ihr Ende auf dem Main Thread ankommt.
    /// Überschreitung heißt: Der Main Thread hing während des Übergangs.
    /// Nur in der Detail-Stufe.
    static let unifiedPillMorph = PerformanceBudget(
        name: "pill.morph", budget: 0.450, signposter: PerfSignposts.recording, tier: .detail,
        measuresWaiting: true)
    /// Status-Pille neu zeichnen (Zustandswechsel, gedrosselt). Nur in der Detail-Stufe.
    static let unifiedPillRender = PerformanceBudget(
        name: "pill.unifiedRender", budget: 0.008, signposter: PerfSignposts.sidebar, tier: .detail)

    // Controller
    /// Controller-Insel einblenden: Modell im Ereignis-Pfad bauen (bei „Wohin“
    /// die Zeilen der Liste und die Workspaces), Fenster auf Größe bringen und
    /// zeigen. Zwei Bilder bei 60 Hz; die Animation selbst zählt nicht.
    static let controllerIslandShow = PerformanceBudget(
        name: "controller.islandShow", budget: 0.033, signposter: PerfSignposts.controller)
}
