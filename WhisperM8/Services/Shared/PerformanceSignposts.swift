import Foundation
import os

/// Signpost-Schienen für die drei instrumentierten Hot-Paths (Plan P7).
/// Sichtbar im Instruments-Template "os_signpost" und als
/// `perf_budget_exceeded`-Warnungen via:
///   log stream --predicate 'subsystem == "com.whisperm8.app"'
enum PerfSignposts {
    private static let subsystem = "com.whisperm8.app"
    static let recording = OSSignposter(subsystem: subsystem, category: "perf.recording")
    static let store = OSSignposter(subsystem: subsystem, category: "perf.store")
    static let sidebar = OSSignposter(subsystem: subsystem, category: "perf.sidebar")
    static let grid = OSSignposter(subsystem: subsystem, category: "perf.grid")
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
    final class Token {
        fileprivate let state: OSSignpostIntervalState
        fileprivate let startedAt: Date
        fileprivate var ended = false

        fileprivate init(state: OSSignpostIntervalState, startedAt: Date) {
            self.state = state
            self.startedAt = startedAt
        }
    }

    let name: StaticString
    /// Budget in Sekunden. Startwerte — nach Realdaten-Abgleich nachziehen.
    let budget: TimeInterval
    let signposter: OSSignposter
    /// Test-Hook: deterministische Uhr.
    var now: () -> Date = Date.init
    /// Test-Hook: ersetzt das Default-Logging. Parameter: Name, gemessene Dauer.
    var onViolation: ((String, TimeInterval) -> Void)?

    func begin() -> Token {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        return Token(state: state, startedAt: now())
    }

    func end(_ token: Token) {
        guard !token.ended else { return }
        token.ended = true
        signposter.endInterval(name, token.state)

        let duration = now().timeIntervalSince(token.startedAt)
        guard duration > budget else { return }
        if let onViolation {
            onViolation("\(name)", duration)
        } else {
            Logger.agentPerformance.warning(
                "perf_budget_exceeded name=\("\(name)", privacy: .public) durationMs=\(Int(duration * 1000), privacy: .public) budgetMs=\(Int(budget * 1000), privacy: .public)"
            )
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

    // Workspace-Store
    static let storeMutate = PerformanceBudget(name: "store.mutate", budget: 0.030, signposter: PerfSignposts.store)
    static let storeLoad = PerformanceBudget(name: "store.load", budget: 0.015, signposter: PerfSignposts.store)
    static let storeSave = PerformanceBudget(name: "store.save", budget: 0.020, signposter: PerfSignposts.store)
    static let saveUIState = PerformanceBudget(name: "store.saveUIState", budget: 0.010, signposter: PerfSignposts.store)

    // Sidebar / Status-Pipeline
    static let sidebarWorkspaceLoad = PerformanceBudget(name: "sidebar.workspaceLoad", budget: 0.050, signposter: PerfSignposts.sidebar)
    static let sidebarBackgroundIndex = PerformanceBudget(name: "sidebar.backgroundIndex", budget: 2.000, signposter: PerfSignposts.sidebar)
    static let sidebarStatusPoll = PerformanceBudget(name: "sidebar.statusPoll", budget: 0.100, signposter: PerfSignposts.sidebar)

    // Grid-Workspace (Budgets aus docs/plans/grid-workspace-plan.html, Abschnitt 05;
    // Freigabe-Gates sind p95-Werte, Einzelverletzungen sind Hinweise, keine Fehler).
    /// Grid-Aufbau: showsGrid → alle erwarteten Terminal-Panes attached.
    static let gridBuild = PerformanceBudget(name: "grid.build", budget: 0.050, signposter: PerfSignposts.grid)
    /// Pane-Fokuswechsel: Selektionsänderung → makeFirstResponder angewendet.
    static let gridFocusSwitch = PerformanceBudget(name: "grid.focusSwitch", budget: 0.033, signposter: PerfSignposts.grid)
    /// Ein ANGEWANDTER (coalesced) Divider-Layout-Tick inkl. Folge-Layout —
    /// nicht jeder Maus-Event (die werden gesammelt).
    static let gridDividerTick = PerformanceBudget(name: "grid.dividerTick", budget: 0.016, signposter: PerfSignposts.grid)
    /// Ein Streaming-Flush einer Pane (Parser + Render-Scheduling, keine GPU-Zeit).
    static let gridStreamingFrame = PerformanceBudget(name: "grid.streamingFrame", budget: 0.0167, signposter: PerfSignposts.grid)
}
