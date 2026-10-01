import Foundation

/// Plattendaten für die Konto-Untermenüs im Session-Kontextmenü.
///
/// SwiftUI baut `.contextMenu`-Inhalte bei JEDEM Body-Rebuild mit, nicht erst
/// beim Öffnen — pro sichtbarer Zeile (Sidebar, Tabs, Grid, Workspaces). Jeder
/// Aufruf von `ClaudeAccountProfiles().profiles()` / `GPTAccountProfiles()
/// .profiles()` listet ein Verzeichnis und stat'et jedes Profil; dazu kam pro
/// Zeile ein `stat` aufs Account-Move-Journal. Gemessen 30.09.2026 im Scope
/// „Alle" (~500 Zeilen, 13 laufende Chats): Main Thread zu 94 % ausgelastet,
/// knapp 3 s pro 11 s allein im Kontextmenü-Bau, die App fror sekundenlang.
///
/// Deshalb liest das Menü diese Werte aus einem kurzlebigen Cache: einmal pro
/// `ttl` statt einmal pro Zeile und Render. Eigene Änderungen (Umzug,
/// Rückgängig) invalidieren sofort; externe (Login im Terminal) greifen nach
/// spätestens `ttl`.
@MainActor
enum AccountMenuData {
    static let claudeProfiles = MenuValueCache { ClaudeAccountProfiles().profiles() }
    static let gptProfiles = MenuValueCache { GPTAccountProfiles().profiles() }
    static let hasUndoableAccountMove = MenuValueCache { AccountMoveJournal().hasUndoableBatch() }

    static func invalidateAll() {
        claudeProfiles.invalidate()
        gptProfiles.invalidate()
        hasUndoableAccountMove.invalidate()
    }
}

/// Wert mit Ablaufzeit — lädt höchstens einmal pro `ttl` neu.
@MainActor
final class MenuValueCache<Value> {
    private let ttl: TimeInterval
    private let now: () -> Date
    private let load: () -> Value
    private var cached: (value: Value, loadedAt: Date)?

    init(ttl: TimeInterval = 2, now: @escaping () -> Date = Date.init, load: @escaping () -> Value) {
        self.ttl = ttl
        self.now = now
        self.load = load
    }

    var value: Value {
        let current = now()
        if let cached, current.timeIntervalSince(cached.loadedAt) < ttl {
            return cached.value
        }
        let fresh = load()
        cached = (fresh, current)
        return fresh
    }

    func invalidate() {
        cached = nil
    }
}
