import Foundation

/// TTL-Cache um `codex login status` — der Subprocess kostet jeden
/// Diktat-Lauf mit Post-Processing 100–400 ms, obwohl sich der Login-Zustand
/// praktisch nie ändert.
///
/// Bewusst asymmetrisch: `.signedIn` wird für die volle TTL gecacht,
/// Negativ-Status (.notSignedIn/.notInstalled/.installed) nur für eine
/// Mini-TTL. Grund: `openLoginInTerminal()` öffnet nur ein Terminal-Script —
/// der eigentliche Login passiert Minuten später. Würden Negativ-Status lange
/// gecacht, degradierte Post-Processing nach erfolgreichem Login bis zu
/// 5 Minuten still auf Raw.
final class CodexStatusCache {
    static let shared = CodexStatusCache()

    private let ttl: TimeInterval
    private let negativeTTL: TimeInterval
    private let now: () -> Date
    private let probe: () -> CodexConnectionStatus
    private let lock = NSLock()
    private var cached: (status: CodexConnectionStatus, at: Date)?

    init(
        ttl: TimeInterval = 300,
        negativeTTL: TimeInterval = 5,
        now: @escaping () -> Date = Date.init,
        probe: @escaping () -> CodexConnectionStatus = { CodexStatusProbe().status() }
    ) {
        self.ttl = ttl
        self.negativeTTL = negativeTTL
        self.now = now
        self.probe = probe
    }

    func status() -> CodexConnectionStatus {
        lock.lock()
        if let cached {
            let age = now().timeIntervalSince(cached.at)
            let limit = cached.status == .signedIn ? ttl : negativeTTL
            if age < limit {
                let value = cached.status
                lock.unlock()
                return value
            }
        }
        lock.unlock()

        // Probe bewusst NICHT unter dem Lock — sie spawnt einen Subprocess.
        let fresh = probe()
        lock.lock()
        cached = (fresh, now())
        lock.unlock()
        return fresh
    }

    /// Erzwingt beim nächsten `status()` einen frischen Probe. Wird gerufen,
    /// wenn ein Codex-Lauf an fehlender Anmeldung scheitert.
    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
