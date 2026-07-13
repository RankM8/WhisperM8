import Foundation

/// Verfolgt die beiden Grid-Intervalle, deren Begin und End über View- und
/// Runloop-Grenzen laufen (`grid.build`, `grid.focusSwitch`) — das manuelle
/// Token-Muster von `PerformanceBudget` (Begin im SwiftUI-Handler, End im
/// AppKit-Attach bzw. nach `makeFirstResponder`).
///
/// Jede Messung trägt eine GENERATION: verspätete Completions (alte
/// `DispatchQueue.main.async`-Callbacks, Timeouts, ein spätes
/// `focusApplied`) können nur die Messung beenden, zu der sie gehören —
/// nie eine später gestartete. Überschriebene Messungen werden ABGEBROCHEN
/// (Signpost schließt ohne Budget-Bewertung), nicht als reguläre Messung
/// beendet. Geleakte Tokens (Pane attached nie) beendet ein Safety-Timeout
/// als Budget-Verletzung.
@MainActor
final class GridPerformanceTracker {
    static let shared = GridPerformanceTracker()

    /// Safety-Timeout für geleakte Tokens (Plan: 500 ms). Test-Hook.
    var timeout: Duration = .milliseconds(500)
    /// Budgets injizierbar (Tests: `onViolation`-Hook statt Logging).
    var buildBudget = PerfBudgets.gridBuild
    var focusBudget = PerfBudgets.gridFocusSwitch

    private var buildToken: PerformanceBudget.Token?
    private var buildGeneration = 0
    private var pendingAttachIDs: Set<UUID> = []
    private var buildTimeout: Task<Void, Never>?

    private var focusToken: PerformanceBudget.Token?
    private var focusGeneration = 0
    private var focusTimeout: Task<Void, Never>?

    init() {}

    // MARK: - grid.build

    /// Grid-Aufbau beginnt — VOR dem Mount aufrufen (beim
    /// `showsGrid`-Übergang, nicht erst in `onAppear`: Kinder attachen
    /// während `makeNSView`, also bevor das Parent-`onAppear` feuert).
    /// `expectedPaneIDs` sind die Sessions, deren Terminal-View tatsächlich
    /// attachen wird (nur Panes mit lebendem Controller — Offline-Panes
    /// rendern Transcript-Views und attachen nie). Leere Erwartung misst
    /// nur den SwiftUI-Aufbau bis zum nächsten Runloop-Turn.
    func beginBuild(expectedPaneIDs: Set<UUID>) {
        // Laufende Messung ABBRECHEN (Grid schnell zu/auf) — sie als
        // reguläre Messung zu beenden ergäbe eine falsche Dauer.
        if let token = buildToken { buildBudget.cancel(token) }
        buildTimeout?.cancel()
        buildGeneration += 1
        let generation = buildGeneration

        PerfSignposts.grid.emitEvent("grid.build.requested")
        buildToken = buildBudget.begin()
        pendingAttachIDs = expectedPaneIDs

        if expectedPaneIDs.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.finishBuild(generation: generation)
            }
        } else {
            let timeout = timeout
            buildTimeout = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finishBuild(generation: generation)
            }
        }
    }

    /// Attach-Hook (`AgentTerminalView.attach`): eine erwartete Pane hängt in
    /// der Hierarchie. Attaches außerhalb einer Messung sind no-ops.
    func didAttach(sessionID: UUID) {
        guard buildToken != nil else { return }
        pendingAttachIDs.remove(sessionID)
        guard pendingAttachIDs.isEmpty else { return }
        PerfSignposts.grid.emitEvent("grid.build.allAttached")
        let generation = buildGeneration
        // Ende erst nach dem folgenden Runloop-Turn — der Attach selbst ist
        // billig, das anschließende Layout gehört zur gefühlten Aufbauzeit.
        DispatchQueue.main.async { [weak self] in
            self?.finishBuild(generation: generation)
        }
    }

    private func finishBuild(generation: Int) {
        guard generation == buildGeneration, let token = buildToken else { return }
        buildToken = nil
        buildTimeout?.cancel()
        buildTimeout = nil
        pendingAttachIDs = []
        buildBudget.end(token)
    }

    // MARK: - grid.focusSwitch

    /// Fokuswechsel im Grid beginnt (Selektions-Handler). Nur aufrufen, wenn
    /// die Ziel-Session ein lebendes Terminal HAT — sonst endet die Messung
    /// zwangsläufig im Timeout und produziert Fake-Verletzungen. Ende meldet
    /// `focusApplied()` aus `focusTerminal()` nach erfolgreichem
    /// `makeFirstResponder`; Fehlschläge brechen via `abortFocusSwitch()` ab.
    func beginFocusSwitch() {
        if let token = focusToken { focusBudget.cancel(token) }
        focusTimeout?.cancel()
        focusGeneration += 1
        let generation = focusGeneration

        focusToken = focusBudget.begin()
        let timeout = timeout
        focusTimeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finishFocusSwitch(generation: generation)
        }
    }

    /// Fokus ist angewendet. Aufrufe ohne laufende Messung (Einzelansicht,
    /// onAppear-Fokus) sind no-ops — und verspätete Aufrufe können dank
    /// Generation-Bindung keine neuere Messung schließen.
    func focusApplied() {
        guard focusToken != nil else { return }
        PerfSignposts.grid.emitEvent("grid.focus.applied")
        finishFocusSwitch(generation: focusGeneration)
    }

    /// Fokusziel nicht anwendbar (kein Window, `makeFirstResponder`
    /// abgelehnt): Messung verwerfen statt in den Timeout zu laufen.
    func abortFocusSwitch() {
        guard let token = focusToken else { return }
        focusToken = nil
        focusTimeout?.cancel()
        focusTimeout = nil
        focusBudget.cancel(token)
    }

    private func finishFocusSwitch(generation: Int) {
        guard generation == focusGeneration, let token = focusToken else { return }
        focusToken = nil
        focusTimeout?.cancel()
        focusTimeout = nil
        focusBudget.end(token)
    }

    // MARK: - Test-Einblicke

    var hasActiveBuildMeasurement: Bool { buildToken != nil }
    var hasActiveFocusMeasurement: Bool { focusToken != nil }
}
