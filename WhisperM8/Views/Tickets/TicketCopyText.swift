import AppKit
import Foundation

// MARK: - Link und Liste kopieren (pur)

/// Text, den „Link kopieren“ und „Liste kopieren“ in die Zwischenablage legen.
/// Lesbar für Menschen (Slack, Team-Chat) und eindeutig für jeden Chat:
/// Nummer und Titel, darunter die Adresse. Ticket-Text kommt nicht mit, nur
/// Nummer, Titel und Adresse.
enum TicketCopyText {
    /// `WM8-104 Titel` und darunter die Adresse; ohne sichere Adresse nur die erste Zeile.
    static func link(_ ticket: Ticket) -> String {
        let head = "\(ticket.key) \(flat(ticket.title))"
        guard let url = safeURL(ticket) else { return head }
        return head + "\n" + url
    }

    /// Abschnitt der Liste: Überschrift (Status oder Projekt) und Tickets.
    struct Section: Equatable {
        var title: String?
        var tickets: [Ticket]
    }

    /// Die gezeigten Tickets in ihrer Reihenfolge, je Ticket eine Zeile mit
    /// Adresse. Leere Abschnitte fallen weg.
    static func list(title: String, sections: [Section]) -> String {
        var lines = [flat(title)]
        for section in sections where !section.tickets.isEmpty {
            lines.append("")
            if let heading = section.title { lines.append(flat(heading)) }
            for ticket in section.tickets {
                let url = safeURL(ticket).map { " " + $0 } ?? ""
                lines.append("- \(ticket.key) \(flat(ticket.title))\(url)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Nur `https`-Adressen, wie „In Linear öffnen“.
    private static func safeURL(_ ticket: Ticket) -> String? {
        guard let raw = ticket.url, let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return raw
    }

    /// Ein Titel ist eine Zeile, und zwar eine harmlose. Titel stammen von
    /// anderen, und eingefügt wird oft in ein Terminal: Ein ESC käme in der
    /// Eingabe eines Chats als Taste an (dort „Abbrechen“), `ESC[201~` beendete
    /// ein Bracketed Paste vorzeitig, Bidi-Zeichen (U+202E) drehten die Anzeige
    /// um. Deshalb wird jedes Steuer- und Formatzeichen (Kategorien Cc und Cf,
    /// dazu Zeilen- und Absatztrenner) zu einem Leerzeichen; Leerraum wird zusammengefasst.
    static func flat(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Schreibt in die allgemeine Zwischenablage und beansprucht den Schreibvorgang,
/// damit kopierte Links nicht im Zwischenablage-Verlauf landen.
enum TicketClipboard {
    @MainActor static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardInternalWrites.claim(pasteboard)
    }
}
