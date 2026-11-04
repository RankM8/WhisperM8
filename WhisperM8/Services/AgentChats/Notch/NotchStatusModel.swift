import Foundation

/// Eingabe pro Chat für die Notch-Anzeige: alles, was `NotchStatusModel`
/// braucht, schon aufgelöst (Titel, Projektname, Status, Zeiten). Kein Store-
/// Zugriff im Modell, damit es ohne App und ohne Fenster testbar bleibt.
struct NotchChatInput: Equatable {
    var id: UUID
    var title: String
    var project: String?
    var status: AgentSessionRuntimeStatus?
    /// Seit wann der Chat in diesem Status ist (`AgentSessionActivityStore`).
    var statusSince: Date?
    var lastTurnAt: Date?
    var lastActivityAt: Date
    /// Stand-Zeile; nur gesetzt, solange die Liste aufgeklappt ist.
    var activity: AgentSessionActivity?
}

/// Eine Zeile der aufgeklappten Liste.
struct NotchRow: Equatable, Identifiable {
    var id: UUID
    var title: String
    var project: String?
    var status: AgentSessionRuntimeStatus?
    var category: ChatsAttentionCategory
    var rank: Int
    /// „arbeitet · 2 min", „bereit · vor 12 min": gleiche Wörter wie der Tab-Switcher.
    var headline: String
    var activityLine: String?
}

/// Zähler für die Ruhe-Anzeige.
struct NotchSummary: Equatable {
    var working = 0
    var waiting = 0
    var errored = 0
    var freshDone = 0
    var idle = 0

    /// Wie viele Zähler die Ruhe-Anzeige zeigt (arbeitet, wartet, Fehler, frisch fertig).
    var chipCount: Int {
        [working, waiting, errored, freshDone].filter { $0 > 0 }.count
    }

    /// „Braucht dich" im weiten Sinn: Warten und Fehler.
    var needsYou: Int { waiting + errored }

    /// Lohnt sich eine sichtbare Anzeige? Nur bereite Chats allein nicht: sie
    /// würden das Element den ganzen Tag einblenden.
    var hasActivity: Bool { working + waiting + errored + freshDone > 0 }

    static let empty = NotchSummary()
}

enum NotchSectionKind: Equatable {
    case needsYou, freshDone, working, ready
}

struct NotchSection: Equatable, Identifiable {
    var kind: NotchSectionKind
    var rows: [NotchRow]
    var id: String { String(describing: kind) }
}

/// Reine Anzeige-Logik der Notch: Zeilen, Sortierung, Zähler, Abschnitte.
/// Die Einteilung (braucht dich, frisch fertig, arbeitet, bereit) kommt aus
/// `AttentionModelBuilder.classify`, derselben Quelle wie die CLI.
enum NotchStatusModel {
    /// Zeilen aller lebenden Chats, nach Aufmerksamkeit sortiert: Rang aufsteigend,
    /// innerhalb des Rangs der jüngste Statuswechsel zuerst.
    static func rows(
        from inputs: [NotchChatInput],
        now: Date,
        showFreshDone: Bool
    ) -> [NotchRow] {
        struct Ranked { var row: NotchRow; var sortDate: Date }
        var ranked: [Ranked] = []
        for input in inputs {
            // Gestoppte und unbekannte Chats haben nichts anzuzeigen.
            guard let status = input.status, status != .stopped else { continue }
            var (category, rank) = AttentionModelBuilder.classify(
                status: status, lastTurnAt: input.lastTurnAt, since: input.statusSince, now: now)
            if category == .freshDone, !showFreshDone {
                category = .idle
                rank = 5
            }
            let tile = TabSwitcherTileModel(
                title: input.title, status: status, activity: input.activity,
                statusSince: input.statusSince, lastActivityAt: input.lastActivityAt, now: now)
            ranked.append(Ranked(
                row: NotchRow(
                    id: input.id, title: input.title, project: input.project, status: status,
                    category: category, rank: rank,
                    headline: tile.header(detail: .full), activityLine: tile.activityLine),
                sortDate: input.statusSince ?? input.lastActivityAt))
        }
        ranked.sort { lhs, rhs in
            if lhs.row.rank != rhs.row.rank { return lhs.row.rank < rhs.row.rank }
            if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
            return lhs.row.id.uuidString < rhs.row.id.uuidString
        }
        return ranked.map(\.row)
    }

    static func summary(of rows: [NotchRow]) -> NotchSummary {
        var summary = NotchSummary()
        for row in rows {
            switch row.category {
            case .needsYou:
                if row.status == .errored { summary.errored += 1 } else { summary.waiting += 1 }
            case .freshDone: summary.freshDone += 1
            case .working: summary.working += 1
            case .idle: summary.idle += 1
            }
        }
        return summary
    }

    /// Abschnitte der aufgeklappten Liste in Anzeigereihenfolge; leere fehlen.
    static func sections(of rows: [NotchRow]) -> [NotchSection] {
        let order: [(NotchSectionKind, ChatsAttentionCategory)] = [
            (.needsYou, .needsYou), (.freshDone, .freshDone), (.working, .working), (.ready, .idle),
        ]
        return order.compactMap { kind, category in
            let matching = rows.filter { $0.category == category }
            return matching.isEmpty ? nil : NotchSection(kind: kind, rows: matching)
        }
    }

    /// Zeitpunkt, an dem der früheste „frisch fertig"-Chat zu „bereit" wird.
    /// Die Anzeige plant daran einen einzigen Neuaufbau, statt zu pollen.
    static func nextFreshDoneExpiry(in inputs: [NotchChatInput], now: Date) -> Date? {
        inputs.compactMap { input -> Date? in
            guard input.status == .idle, let reference = input.lastTurnAt ?? input.statusSince else { return nil }
            let expiry = reference.addingTimeInterval(AttentionModelBuilder.freshDoneWindow)
            return expiry > now ? expiry : nil
        }.min()
    }

    /// Soll das Element sichtbar sein? Aufgeklappt bleibt es immer, damit es
    /// sich nicht unter dem Mauszeiger wegblendet.
    static func isVisible(summary: NotchSummary, isExpanded: Bool, alert: NotchAlert?) -> Bool {
        isExpanded || alert != nil || summary.hasActivity
    }
}

// MARK: - „Braucht dich"-Auslöser

enum NotchAlertKind: Equatable {
    case awaitingInput
    case errored
    case finished
}

/// Auslöser der kurzen Verbreiterung.
struct NotchAlert: Equatable {
    var sessionID: UUID
    var title: String
    var kind: NotchAlertKind
    /// Weitere Chats, die im selben Takt dazukamen („+2").
    var extraCount: Int = 0
}

/// Erkennt aus Status-Schnappschüssen, wann die Anzeige „braucht dich" melden
/// soll. Reiner Wert, der Aufrufer reicht `now` herein.
///
/// - Der erste Schnappschuss ist nur die Ausgangslage: ein beim Start bereits
///   wartender Chat blitzt nicht auf (er steht ohnehin als Amber-Zähler da).
/// - Ausgelöst wird beim Wechsel nach `awaitingInput`, nach `errored` und
///   bei `working → idle` (frisch fertig).
/// - Derselbe Chat mit derselben Art löst höchstens alle `cooldown` Sekunden
///   erneut aus (Status, der zwischen Warten und Arbeiten flattert).
struct NotchAlertTracker {
    static let cooldown: TimeInterval = 20

    private var previous: [UUID: AgentSessionRuntimeStatus]?
    private var lastFired: [String: Date] = [:]

    init() {}

    mutating func reset() {
        previous = nil
        lastFired = [:]
    }

    mutating func ingest(
        statuses: [UUID: AgentSessionRuntimeStatus],
        titles: [UUID: String],
        showFreshDone: Bool,
        appIsActive: Bool,
        now: Date
    ) -> NotchAlert? {
        defer { previous = statuses }
        guard let previous else { return nil }

        var fired: [(kind: NotchAlertKind, id: UUID)] = []
        for (id, status) in statuses where previous[id] != status {
            let kind: NotchAlertKind?
            switch status {
            case .awaitingInput: kind = .awaitingInput
            case .errored: kind = .errored
            case .idle:
                // Frisch fertig nur, wenn der Chat vorher wirklich gearbeitet hat,
                // und nicht, solange man ohnehin in WhisperM8 arbeitet.
                kind = (previous[id] == .working && showFreshDone && !appIsActive) ? .finished : nil
            case .working, .stopped: kind = nil
            }
            guard let kind else { continue }
            let key = "\(id.uuidString)|\(kind)"
            if let last = lastFired[key], now.timeIntervalSince(last) < Self.cooldown { continue }
            lastFired[key] = now
            fired.append((kind, id))
        }
        guard !fired.isEmpty else { return nil }

        func priority(_ kind: NotchAlertKind) -> Int {
            switch kind {
            case .errored: return 0
            case .awaitingInput: return 1
            case .finished: return 2
            }
        }
        fired.sort { lhs, rhs in
            if priority(lhs.kind) != priority(rhs.kind) { return priority(lhs.kind) < priority(rhs.kind) }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let best = fired[0]
        return NotchAlert(
            sessionID: best.id,
            title: titles[best.id] ?? "",
            kind: best.kind,
            extraCount: fired.count - 1)
    }
}
