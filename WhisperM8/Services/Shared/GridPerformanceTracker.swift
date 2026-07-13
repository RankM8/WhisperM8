import Foundation

/// Verfolgt die beiden Grid-Intervalle, deren Begin und End über View- und
/// Runloop-Grenzen laufen (`grid.build`, `grid.focusSwitch`) — das manuelle
/// Token-Muster von `PerformanceBudget` (Begin im SwiftUI-Handler, End im
/// AppKit-Attach bzw. nach `makeFirstResponder`).
///
/// Geleakte Tokens (Pane attached nie, Fokus-Terminal existiert nicht) beendet
/// ein Safety-Timeout als Budget-Verletzung — sonst hinge das Intervall offen
/// in Instruments und die nächste Messung würde verschluckt.
@MainActor
final class GridPerformanceTracker {
    static let shared = GridPerformanceTracker()

    /// Safety-Timeout für geleakte Tokens (Plan: 500 ms).
    private static let timeout: Duration = .milliseconds(500)

    private var buildToken: PerformanceBudget.Token?
    private var pendingAttachIDs: Set<UUID> = []
    private var buildTimeout: Task<Void, Never>?

    private var focusToken: PerformanceBudget.Token?
    private var focusTimeout: Task<Void, Never>?

    private init() {}

    // MARK: - grid.build

    /// Grid-Aufbau beginnt: `expectedPaneIDs` sind die Sessions, deren
    /// Terminal-View tatsächlich attachen wird (nur Panes mit lebendem
    /// Controller — Offline-Panes rendern Transcript-Views und attachen nie).
    /// Leere Erwartung misst nur den SwiftUI-Aufbau bis zum nächsten
    /// Runloop-Turn.
    func beginBuild(expectedPaneIDs: Set<UUID>) {
        // Laufende Messung sauber schließen (Grid schnell zu/auf).
        if let token = buildToken { PerfBudgets.gridBuild.end(token) }
        buildTimeout?.cancel()

        PerfSignposts.grid.emitEvent("grid.build.requested")
        buildToken = PerfBudgets.gridBuild.begin()
        pendingAttachIDs = expectedPaneIDs

        if expectedPaneIDs.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.finishBuild() }
        } else {
            buildTimeout = Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                guard !Task.isCancelled else { return }
                self?.finishBuild()
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
        // Ende erst nach dem folgenden Runloop-Turn — der Attach selbst ist
        // billig, das anschließende Layout gehört zur gefühlten Aufbauzeit.
        DispatchQueue.main.async { [weak self] in self?.finishBuild() }
    }

    private func finishBuild() {
        guard let token = buildToken else { return }
        buildToken = nil
        buildTimeout?.cancel()
        buildTimeout = nil
        pendingAttachIDs = []
        PerfBudgets.gridBuild.end(token)
    }

    // MARK: - grid.focusSwitch

    /// Fokuswechsel im Grid beginnt (Selektions-Handler). Ende meldet
    /// `focusApplied()` aus `focusTerminal()` nach `makeFirstResponder`.
    func beginFocusSwitch() {
        if let token = focusToken { PerfBudgets.gridFocusSwitch.end(token) }
        focusTimeout?.cancel()

        focusToken = PerfBudgets.gridFocusSwitch.begin()
        focusTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.finishFocusSwitch()
        }
    }

    /// Fokus ist angewendet. Aufrufe ohne laufende Messung (Einzelansicht,
    /// onAppear-Fokus) sind no-ops.
    func focusApplied() {
        guard focusToken != nil else { return }
        PerfSignposts.grid.emitEvent("grid.focus.applied")
        finishFocusSwitch()
    }

    private func finishFocusSwitch() {
        guard let token = focusToken else { return }
        focusToken = nil
        focusTimeout?.cancel()
        focusTimeout = nil
        PerfBudgets.gridFocusSwitch.end(token)
    }
}
