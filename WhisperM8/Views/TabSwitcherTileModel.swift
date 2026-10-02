import Foundation

/// Größenstufe einer Switcher-Kachel (`TabSwitcherTile`) — EINE Definition
/// für alle drei Situationen (A Grid-Markierung, B Mini-Map, C Projekt-Liste).
/// Die Mini-Map leitet die Stufe aus der Kachelgröße ab
/// (`TabSwitcherMiniMapGeometry.tileDetail(for:)`), die Liste nutzt `.full`.
///
/// Weggelassen wird von oben nach unten: erst die Stand-Zeile, dann die
/// Dauer — der Status (Symbol + Wort) und der Titel bleiben in jeder Stufe.
enum TabSwitcherTileDetail: Equatable {
    /// Status, Titel, Stand-Zeile, Dauer.
    case full
    /// Status, Titel, Dauer — ohne Stand-Zeile.
    case withoutActivity
    /// Nur Status + Titel.
    case statusAndTitle

    var showsActivity: Bool { self == .full }
    var showsDuration: Bool { self != .statusAndTitle }
}

/// Pure Anzeige-Daten einer Switcher-Kachel: Statuswort, Symbol, Dauer und
/// Stand-Zeile aus Session-Titel + Status + Activity + `statusSince` + `now`.
/// Window-frei → unit-testbar (`TabSwitcherTileModelTests`).
///
/// Kein I/O, kein Store-Zugriff: Der Aufrufer (das Overlay) reicht die Werte
/// aus seinen Dictionary-Lookups herein.
struct TabSwitcherTileModel: Equatable {
    let title: String
    let status: AgentSessionRuntimeStatus?
    /// Status als Wort — Farbe allein trägt keine Bedeutung.
    let statusWord: String
    /// SF-Symbol zum Status (zweiter, farbunabhängiger Träger).
    let symbolName: String
    /// „2 min" (laufend) bzw. „vor 12 min" (ruhend); `nil` = unbekannt.
    let durationText: String?
    /// Stand-Zeile („› Edit Store.swift"); `nil`, wenn es nichts zu sagen
    /// gibt oder sie nur das Statuswort wiederholen würde.
    let activityLine: String?

    init(
        title: String,
        status: AgentSessionRuntimeStatus?,
        activity: AgentSessionActivity?,
        statusSince: Date?,
        lastActivityAt: Date?,
        now: Date
    ) {
        self.title = title
        self.status = status
        self.statusWord = Self.statusWord(for: status)
        self.symbolName = Self.symbolName(for: status)
        self.durationText = Self.durationText(
            status: status,
            statusSince: statusSince,
            lastActivityAt: lastActivityAt,
            now: now
        )
        // „gestoppt"/„Fehler" liefert die Activity selbst als Zeile — neben
        // dem gleichlautenden Statuswort wäre das doppelt.
        let line = activity?.line(for: status)
        self.activityLine = (line?.isEmpty ?? true) || line == statusWord ? nil : line
    }

    /// Kopfzeile der Kachel: „arbeitet · 2 min", „fertig · vor 12 min" bzw.
    /// nur das Statuswort, wenn die Dauer fehlt oder die Stufe sie weglässt.
    func header(detail: TabSwitcherTileDetail) -> String {
        guard detail.showsDuration, let durationText else { return statusWord }
        return "\(statusWord) · \(durationText)"
    }

    // MARK: - Statuswort und Symbol

    /// `nil` (kein Prozess bekannt) gilt wie `.stopped` — gleiche Semantik
    /// wie `AgentStatusIndicator`.
    static func statusWord(for status: AgentSessionRuntimeStatus?) -> String {
        switch status {
        case .working: return "arbeitet"
        case .awaitingInput: return "wartet"
        case .idle: return "fertig"
        case .errored: return "Fehler"
        case .stopped, nil: return "gestoppt"
        }
    }

    /// ● arbeitet · ◐ wartet · ○ fertig (wie die Plan-Skizze), dazu eigene
    /// Formen für gestoppt/Fehler.
    static func symbolName(for status: AgentSessionRuntimeStatus?) -> String {
        switch status {
        case .working: return "circle.fill"
        case .awaitingInput: return "circle.lefthalf.filled"
        case .idle: return "circle"
        case .errored: return "exclamationmark.circle.fill"
        case .stopped, nil: return "stop.circle"
        }
    }

    // MARK: - Dauer

    /// Laufende Zustände (arbeitet/wartet) zeigen, wie lange sie schon
    /// andauern („2 min") — nur mit bekanntem `statusSince`, ein geratener
    /// Startpunkt wäre falsch. Ruhende Zustände zeigen, wie lange das Ende
    /// her ist („vor 12 min"), notfalls ab der letzten Aktivität der Session.
    static func durationText(
        status: AgentSessionRuntimeStatus?,
        statusSince: Date?,
        lastActivityAt: Date?,
        now: Date
    ) -> String? {
        switch status {
        case .working, .awaitingInput:
            guard let statusSince else { return nil }
            return elapsed(now.timeIntervalSince(statusSince))
        case .idle, .stopped, .errored, nil:
            guard let since = statusSince ?? lastActivityAt else { return nil }
            return ago(now.timeIntervalSince(since))
        }
    }

    /// „30 s", „2 min", „3 h", „2 d" — abgerundet, negative Spannen
    /// (Uhrsprung) zählen als 0.
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        return "\(hours / 24) d"
    }

    /// „gerade eben" unter einer Minute, sonst „vor 12 min" / „vor 3 h".
    static func ago(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "gerade eben" }
        return "vor \(elapsed(interval))"
    }
}
