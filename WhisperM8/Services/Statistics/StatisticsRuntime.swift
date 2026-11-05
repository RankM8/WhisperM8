import Foundation

/// Lose Kopplung zwischen Statistik-Seite und Hintergrund-Diensten.
///
/// Die Seite kennt nur diese Aufrufe; die Dienste (Protokoll-Leser, Limit- und
/// Git-Sammler) tragen beim Start ihre Implementierung ein. Ohne laufenden
/// Dienst passiert schlicht nichts — die Seite bleibt bedienbar.
@MainActor
enum StatisticsRuntime {
    /// Seite geöffnet oder „Neu einlesen“ ohne Reset: neue Protokollzeilen jetzt lesen.
    static var requestScan: () -> Void = {}
    /// Einlesen der Historie pausieren (`true`) oder fortsetzen (`false`).
    static var setBackfillPaused: (Bool) -> Void = { _ in }
    /// „Neu einlesen“: Cursor verwerfen und alle Protokolle von vorn zählen.
    static var rescanAll: () -> Void = {}
    /// Statistik ein- oder ausgeschaltet: jeder Dienst trägt sich hier ein
    /// und startet bzw. hält an.
    private(set) static var enabledHandlers: [(Bool) -> Void] = []

    static func onEnabledChanged(_ handler: @escaping (Bool) -> Void) {
        enabledHandlers.append(handler)
    }

    /// Zuletzt gemeldeter Stand. Seite und Defaults-Beobachter melden
    /// denselben Wechsel beide; gemeldet wird nur ein echter Wechsel.
    private(set) static var lastEnabled: Bool?

    /// Stand beim Start, damit die erste Meldung nur bei echtem Wechsel läuft.
    static func setInitialEnabled(_ enabled: Bool) {
        lastEnabled = enabled
    }

    /// Ruft die Seite nach dem Umlegen des Schalters auf, ebenso der
    /// Beobachter für `defaults write … statisticsEnabled`. Doppelte Meldungen
    /// desselben Stands sind harmlos.
    static func notifyEnabledChanged(_ enabled: Bool) {
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled
        for handler in enabledHandlers { handler(enabled) }
    }

    /// Nur für Tests: Handler und Stand zurücksetzen.
    static func resetForTesting() {
        enabledHandlers = []
        lastEnabled = nil
    }
}
