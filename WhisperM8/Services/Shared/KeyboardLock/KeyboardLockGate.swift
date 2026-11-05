import Foundation
import os

/// Geteilter Zustand der Sperre zwischen Main Thread (Sperren, Entsperren,
/// Lebenszeichen) und Tap-Thread (Entscheidung je Ereignis). Alles liegt unter
/// einem Unfair-Lock; kein Aufruf hält ihn länger als eine Set-Operation.
///
/// `clock` wird auf dem Tap-Thread gerufen und muss threadsicher sein (live:
/// `ProcessInfo.systemUptime`; Tests rufen alles auf dem Main Thread).
final class KeyboardLockGate: @unchecked Sendable {
    private struct State {
        /// `nil` = nicht gesperrt, alles geht durch.
        var policy: KeyboardLockPolicy?
        /// Lebenszeichen zuletzt ausgeblieben (nur für das Log der Übergänge).
        var stale = false
        /// Ereignisse, die während des Ausbleibens durchgingen.
        var passedWhileStale = 0
    }

    private enum Transition {
        case stale(age: TimeInterval)
        case recovered(passed: Int)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval) {
        self.clock = clock
    }

    var isActive: Bool {
        state.withLock { $0.policy != nil }
    }

    func activate(keysDownAtLock: Set<Int64>) {
        let now = clock()
        state.withLock { $0 = State(policy: KeyboardLockPolicy(keysDownAtLock: keysDownAtLock, startedAt: now)) }
    }

    func deactivate() {
        state.withLock { $0 = State() }
    }

    /// Lebenszeichen vom Main Thread.
    func heartbeat() {
        let now = clock()
        state.withLock { $0.policy?.heartbeat(at: now) }
    }

    /// Entscheidung für ein Ereignis; läuft auf dem Tap-Thread.
    func decide(_ event: KeyboardLockPolicy.Event) -> KeyboardLockPolicy.Decision {
        let now = clock()
        let (decision, transition) = state.withLock { state -> (KeyboardLockPolicy.Decision, Transition?) in
            guard var policy = state.policy else { return (.pass, nil) }
            let fresh = policy.isHeartbeatFresh(at: now)
            var transition: Transition?
            if !fresh, !state.stale {
                state.stale = true
                state.passedWhileStale = 0
                transition = .stale(age: now - policy.lastHeartbeat)
            } else if fresh, state.stale {
                state.stale = false
                transition = .recovered(passed: state.passedWhileStale)
            }
            let decision = policy.decide(event, at: now)
            if !fresh, decision != .swallow, Self.isKeyboardInput(event) {
                state.passedWhileStale += 1
            }
            state.policy = policy
            return (decision, transition)
        }
        // Loggen außerhalb des Locks.
        switch transition {
        case let .stale(age):
            Logger.keyboardLock.notice("keyboard_lock_heartbeat_stale age_ms=\(Int(age * 1000), privacy: .public) keys_pass=true")
        case let .recovered(passed):
            Logger.keyboardLock.notice("keyboard_lock_heartbeat_recovered passed_events=\(passed, privacy: .public)")
        case nil:
            break
        }
        return decision
    }

    private static func isKeyboardInput(_ event: KeyboardLockPolicy.Event) -> Bool {
        switch event {
        case .keyDown, .keyUp, .flagsChanged: return true
        case .systemDefined, .tapDisabled, .other: return false
        }
    }
}
