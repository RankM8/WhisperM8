import Foundation

@MainActor
final class RecordingTimer {
    private var task: Task<Void, Never>?

    func start(interval: Duration = .milliseconds(100), tick: @escaping @MainActor () -> Void) {
        stop()

        task = Task { @MainActor in
            while !Task.isCancelled {
                tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
