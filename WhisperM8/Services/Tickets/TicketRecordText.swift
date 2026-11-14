import Foundation

// MARK: - Entscheidung und Abschluss am Ticket

/// Fester Aufbau für die zwei Kommentare, die am Ticket nachlesbar machen, was
/// sonst nur in einem Chat-Verlauf stünde: eine Entscheidung und der Abschluss
/// beim Abgeben. Beide sind kurz, enthalten keine Rohdaten aus dem Chat und
/// sehen immer gleich aus.
enum TicketRecordText {
    struct Decision: Equatable {
        var question: String
        var options: [String]
        var chosen: String
        /// Wer entschieden hat.
        var by: String
        var note: String?
    }

    struct Completion: Equatable {
        /// Rufname des Chats, der abgibt.
        var chat: String
        var built: String
        var commit: String?
        var notIncluded: String?
        /// Schritte für den Handtest; stehen als Kästchen da.
        var testSteps: [String] = []
        /// Adresse eines hochgeladenen Bildes.
        var imageURL: String?
    }

    static func decision(_ decision: Decision, at date: Date, calendar: Calendar = .current) -> String {
        var lines = ["**Entscheidung · \(stamp(date, calendar))**", "", "**Frage:** \(flat(decision.question))", "", "**Möglichkeiten:**"]
        lines += decision.options.map { "* \(flat($0))" }
        lines += ["", "**Gewählt:** \(flat(decision.chosen))", "", "**Entschieden von:** \(flat(decision.by))"]
        if let note = decision.note.map(flat), !note.isEmpty { lines += ["", "**Anmerkung:** \(note)"] }
        return lines.joined(separator: "\n")
    }

    static func completion(_ completion: Completion, at date: Date, calendar: Calendar = .current) -> String {
        var lines = ["**Abschluss · \(stamp(date, calendar)) · \(flat(completion.chat))**", "", "**Gebaut:** \(flat(completion.built))"]
        if let commit = completion.commit.map(flat), !commit.isEmpty { lines += ["", "**Commit:** \(commit)"] }
        if let not = completion.notIncluded.map(flat), !not.isEmpty { lines += ["", "**Nicht Teil davon:** \(not)"] }
        if !completion.testSteps.isEmpty {
            lines += ["", "**Handtest:**"]
            lines += completion.testSteps.map { "- [ ] \(flat($0))" }
        }
        if let image = completion.imageURL { lines += ["", "![Bild](\(image))"] }
        return lines.joined(separator: "\n")
    }

    /// `14.11.2026, 05:15 Uhr`
    static func stamp(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.day, .month, .year, .hour, .minute], from: date)
        return String(format: "%02d.%02d.%04d, %02d:%02d Uhr", c.day ?? 0, c.month ?? 0, c.year ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// Ein Feld ist eine Zeile: Umbrüche würden den festen Aufbau sprengen.
    private static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
