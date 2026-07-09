import Foundation
import Observation

@MainActor
@Observable
final class CodexConnectionModel {
    struct Snapshot: Equatable, Sendable {
        var status: CodexConnectionStatus
        var version: String
    }

    var status: CodexConnectionStatus = .unknown
    var codexVersion = "Unknown"
    var isRefreshing = false

    @ObservationIgnored private let probe: @Sendable () async -> Snapshot
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var refreshTask: Task<Snapshot, Never>?

    init(
        probe: @escaping @Sendable () async -> Snapshot = {
            let probe = CodexStatusProbe()
            return Snapshot(status: probe.status(), version: probe.version())
        }
    ) {
        self.probe = probe
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        isRefreshing = true

        let task = Task { await probe() }
        refreshTask = task
        let snapshot = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        guard generation == refreshGeneration, !Task.isCancelled else {
            if generation == refreshGeneration {
                refreshTask = nil
                isRefreshing = false
            }
            return
        }

        status = snapshot.status
        codexVersion = snapshot.version
        isRefreshing = false
        refreshTask = nil
    }

    var statusTone: SettingsStatusTone {
        switch status {
        case .signedIn:
            return .ok
        case .notInstalled, .notSignedIn:
            return .warn
        case .installed, .unknown:
            return .off
        }
    }
}
