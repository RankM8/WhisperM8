import Foundation

/// Bündelt PTY-Größenänderungen (LR-AU-015).
///
/// Beim Ziehen eines Grid-Trenners oder Fenster-Resize ändert sich die Pane-
/// Größe mit ~30 Hz; jede Änderung ging bisher als `ioctl(TIOCSWINSZ)` an die
/// PTY, und die TUI baute bei jedem SIGWINCH ihr Bild komplett neu auf
/// (gemessen ~24 ms je Änderung bei 9 Panes). Jetzt: die ERSTE Änderung nach
/// Ruhe geht sofort durch (kein spürbarer Verzug bei Einzel-Resizes), weitere
/// innerhalb von `quietInterval` werden gesammelt — gesendet wird erst, wenn
/// `quietInterval` lang nichts mehr kam (also am Ende der Geste) mit der
/// LETZTEN Größe. Das lokale Terminal-Buffer-Layout bleibt unberührt.
@MainActor
final class PTYResizeCoalescer {
    private let quietInterval: TimeInterval
    private let now: () -> TimeInterval
    /// Plant `work` nach `delay` und liefert eine Abbruch-Closure.
    private let schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
    private let forward: (Int, Int) -> Void
    private let onRequested: () -> Void
    private let onForwarded: () -> Void

    private var lastForwardAt: TimeInterval = -.infinity
    private var pending: (cols: Int, rows: Int)?
    private var cancelTrailing: (() -> Void)?

    init(
        quietInterval: TimeInterval = 0.15,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void = { delay, work in
            let item = DispatchWorkItem(block: work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        },
        onRequested: @escaping () -> Void = {},
        onForwarded: @escaping () -> Void = {},
        forward: @escaping (Int, Int) -> Void
    ) {
        self.quietInterval = quietInterval
        self.now = now
        self.schedule = schedule
        self.onRequested = onRequested
        self.onForwarded = onForwarded
        self.forward = forward
    }

    func request(cols: Int, rows: Int) {
        onRequested()
        let current = now()
        if cancelTrailing == nil, current - lastForwardAt >= quietInterval {
            send(cols, rows, at: current)
            return
        }
        pending = (cols, rows)
        cancelTrailing?()
        cancelTrailing = schedule(quietInterval) { [weak self] in
            MainActor.assumeIsolated { self?.flushPending() }
        }
    }

    private func flushPending() {
        cancelTrailing = nil
        guard let pending else { return }
        self.pending = nil
        send(pending.cols, pending.rows, at: now())
    }

    private func send(_ cols: Int, _ rows: Int, at time: TimeInterval) {
        lastForwardAt = time
        onForwarded()
        forward(cols, rows)
    }
}
