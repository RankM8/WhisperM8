import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsFeedbackState {
    var isActive = false

    @ObservationIgnored private let duration: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(
        duration: Duration = .seconds(1.2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.duration = duration
        self.sleep = sleep
    }

    func trigger() {
        resetTask?.cancel()
        generation += 1
        let currentGeneration = generation
        isActive = true

        resetTask = Task { [duration, sleep, currentGeneration, weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.generation == currentGeneration else { return }
                self.isActive = false
                self.resetTask = nil
            }
        }
    }

    func reset() {
        resetTask?.cancel()
        generation += 1
        resetTask = nil
        isActive = false
    }

    deinit {
        resetTask?.cancel()
    }
}
