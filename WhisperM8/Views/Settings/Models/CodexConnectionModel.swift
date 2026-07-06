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

    init(
        probe: @escaping @Sendable () async -> Snapshot = {
            let probe = CodexStatusProbe()
            return Snapshot(status: probe.status(), version: probe.version())
        }
    ) {
        self.probe = probe
    }

    func refresh() async {
        isRefreshing = true
        let snapshot = await probe()
        status = snapshot.status
        codexVersion = snapshot.version
        isRefreshing = false
    }

    func shouldWarnAboutGPT55(selectedModelRaw: String) -> Bool {
        CodexPostProcessingModel.resolve(selectedModelRaw) == .gpt55
            && codexVersion.contains("0.120.")
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
