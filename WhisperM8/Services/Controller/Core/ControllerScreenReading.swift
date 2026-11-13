import Foundation

// Was der Controller am unteren Rand eines Claude-Terminals ablesen kann
// (Runde 5, R2): ob eine Ansicht offen ist, die Escape selbst abfängt, und wie
// das Eingabefeld aussieht. Pur; die Zeilen liest der Live-Adapter nur bei
// einer Controller-Eingabe und nur, wenn die Ansicht ganz unten steht.

/// Ansicht von Claude Code, die Escape abfängt (schließen, zurück), statt den
/// laufenden Turn abzubrechen. Die Hinweistexte stammen aus Claude Code
/// 2.1.322 (Hinweis-Komponente `${key} to ${action}`, getrennt mit „ · “; der
/// knappe Stil schreibt sie klein und ohne „to“). Claude zeichnet diese
/// Hinweise abgeblendet (SGR 2); gesucht wird deshalb nur im abgeblendeten
/// Text der untersten Zeilen — normale Ausgabe, die dieselben Wörter enthält,
/// zählt nie.
///
/// Bewusst nicht dabei: die Subagent-/Teammate-Ansicht. Sie hat keinen festen
/// Hinweis, und während der Agent läuft steht dort „esc to interrupt“ —
/// Escape bräche den Chat ab.
enum ControllerOpenView: String, CaseIterable, Sendable {
    /// Ausführliches Transkript (Ctrl+O): „Showing detailed transcript · ctrl+o to toggle“.
    case transcript
    /// `/workflows`: „↑/↓ to select · Enter to view · x to stop · s to save · Esc to close“.
    case workflows
    /// `/tasks` (Dialog „Background“): „↑/↓ to select · Enter to view · x to stop · Esc to close“,
    /// im Detail „… Esc to go back“.
    case tasks
    /// Zurückspulen und andere Dialoge mit „Enter to continue · Esc to cancel“.
    case rewind
    /// Auswahl in der Fußzeile: „… Esc to collapse · ctrl+x ctrl+k to stop all agents“.
    case footerSelection
}

/// Eine Bildschirmzeile in drei Fassungen, Zeichen für Zeichen gleich lang.
struct ControllerScreenLine: Equatable, Sendable {
    /// Alles, was dasteht (Trennlinien, Prompt-Zeichen — Claude blendet „❯“ ab).
    var full: String
    /// Ohne abgeblendete und unsichtbare Zellen (Platzhalter zählen nicht als Text).
    var plain: String
    /// Nur die abgeblendeten Zellen (Hinweise), alles andere als Leerzeichen.
    var dim: String

    init(full: String, plain: String, dim: String) {
        self.full = full
        self.plain = plain
        self.dim = dim
    }

    /// Für Tests: ganze Zeile in einer Fassung.
    static func plain(_ text: String) -> ControllerScreenLine {
        ControllerScreenLine(full: text, plain: text, dim: String(repeating: " ", count: text.count))
    }

    static func dimmed(_ text: String) -> ControllerScreenLine {
        ControllerScreenLine(full: text, plain: String(repeating: " ", count: text.count), dim: text)
    }
}

/// Das Eingabefeld von Claude oder Codex, wie es am Bildschirm steht.
struct ControllerPromptField: Equatable, Sendable {
    /// Zeilen des Felds (mehrzeiliger Entwurf: mehr als eine).
    var rows: Int
    /// Zeile des Cursors im Feld (0 = erste); `nil`, wenn der Terminal-Cursor
    /// nicht im Feld steht oder unbekannt ist.
    var cursorRow: Int?
    /// Der Cursor steht ganz am Anfang des Felds (direkt hinter dem Prompt).
    var cursorAtStart: Bool
    /// Im Feld steht kein (nicht abgeblendeter) Text.
    var isEmpty: Bool

    /// Sicher Text im Feld: Text steht da, und der Cursor steht nicht am
    /// Anfang eines einzeiligen Felds. Ein grauer Platzhalter, der nicht als
    /// abgeblendet markiert ist, steht im leeren Feld mit dem Cursor am
    /// Anfang — er zählt so nicht als Text.
    var hasText: Bool {
        guard !isEmpty, let cursorRow else { return false }
        return rows > 1 || cursorRow > 0 || !cursorAtStart
    }
}

/// Ergebnis einer Ablesung.
struct ControllerScreenSnapshot: Equatable, Sendable {
    var openView: ControllerOpenView?
    var promptField: ControllerPromptField?
}

enum ControllerScreenReading {
    /// So viele Zeilen von unten liest der Live-Adapter.
    static let lineCount = 16
    /// Ohne Eingabefeld zählen nur so viele unterste nicht leere Zeilen als
    /// Hinweiszeilen (Dialoge stehen ganz unten, ein Hinweis bricht höchstens
    /// einmal um).
    static let hintLineCount = 2

    /// - Parameters:
    ///   - lines: die unteren Zeilen des lebendigen Bildschirms, oben zuerst.
    ///   - cursor: Cursor in diesen Zeilen (Zeile, Spalte), sofern bekannt.
    ///   - detectViews: nur bei Claude (Codex hat diese Ansichten nicht).
    static func read(lines: [ControllerScreenLine], cursor: (row: Int, col: Int)?, detectViews: Bool) -> ControllerScreenSnapshot {
        let box = promptBox(in: lines.map(\.full))
        var snapshot = ControllerScreenSnapshot()
        if let box {
            snapshot.promptField = field(in: lines, box: box, cursor: cursor)
        }
        if detectViews {
            // Mit sichtbarem Eingabefeld zählen nur die Zeilen darunter (die
            // Fußzeile); ohne nur die untersten nicht leeren Zeilen. Gesucht
            // wird nur im abgeblendeten Text.
            let candidates = box.map { Array(lines[($0.lower + 1)...]) } ?? lines
            let hintLines = candidates
                .filter { !$0.full.trimmingCharacters(in: .whitespaces).isEmpty }
                .suffix(box == nil ? hintLineCount : lineCount)
                .map(\.dim)
            snapshot.openView = openView(dimHintLines: hintLines, hasPromptBox: box != nil)
        }
        return snapshot
    }

    /// ← im Claude-Feld: eine Ansicht fängt es ab; sichtbar leeres Feld
    /// sperrt, sichtbarer Text gibt frei; sonst die Schätzung des Trackers.
    static func fieldMayHaveText(screen: ControllerScreenSnapshot?, tracker: Bool) -> Bool {
        if screen?.openView != nil { return true }
        return fieldHasText(screen: screen, tracker: tracker)
    }

    /// Steht Text im Eingabefeld (R1 + Kreuz)? Wie `fieldMayHaveText`, aber
    /// ohne die Ansicht: Eine offene Ansicht sagt nichts über das Feld.
    static func fieldHasText(screen: ControllerScreenSnapshot?, tracker: Bool) -> Bool {
        if let field = screen?.promptField {
            if field.isEmpty { return false }
            if field.hasText { return true }
        }
        return tracker
    }

    // MARK: - Ansichten

    /// Muster der Hinweiszeilen. Jede Ansicht braucht mehrere Teile desselben
    /// Hinweises, jeweils in der ausführlichen oder der knappen Schreibweise.
    static func openView(dimHintLines: [String], hasPromptBox: Bool) -> ControllerOpenView? {
        // Bindestriche und Mehrfach-Leerzeichen vereinheitlichen; alles klein.
        let text = dimHintLines.map { $0.lowercased() }.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        func has(_ needles: String...) -> Bool { needles.allSatisfy { text.contains($0) } }
        // Die Auswahl in der Fußzeile lässt das Eingabefeld stehen.
        if has("to stop all agents"), has("esc to collapse") || has("esc collapse") { return .footerSelection }
        // Die übrigen Ansichten ersetzen das Eingabefeld.
        guard !hasPromptBox else { return nil }
        if has("showing detailed transcript"), has("ctrl+o to toggle") || has("ctrl+o toggle") { return .transcript }
        if has("x to stop", "s to save", "esc to close") || has("x stop", "s save", "esc close") { return .workflows }
        if has("enter to continue", "esc to cancel") || has("enter continue", "esc cancel") { return .rewind }
        if has("enter to view", "x to stop", "esc to close") || has("enter view", "x stop", "esc close")
            || has("x to stop", "esc to go back") || has("x stop", "esc go back") {
            return .tasks
        }
        return nil
    }

    // MARK: - Eingabefeld

    /// Trennlinien über und unter dem Feld (Zeilen-Indizes).
    struct PromptBox: Equatable {
        var upper: Int
        var lower: Int
    }

    /// Sucht von unten das Feld: zwei Trennlinien, dazwischen mindestens eine
    /// Zeile, die erste beginnt mit dem Prompt (`❯` oder `>`, auch im alten
    /// Rahmen mit `│`).
    static func promptBox(in lines: [String]) -> PromptBox? {
        let rules = lines.indices.filter { isRule(lines[$0]) }
        guard rules.count >= 2 else { return nil }
        for index in stride(from: rules.count - 1, through: 1, by: -1) {
            let lower = rules[index]
            let upper = rules[index - 1]
            guard lower - upper >= 2 else { continue }
            if promptStart(lines[upper + 1]) != nil { return PromptBox(upper: upper, lower: lower) }
        }
        return nil
    }

    static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10 else { return false }
        let ruleCharacters: Set<Character> = ["─", "━", "╭", "╮", "╰", "╯"]
        let ruleCount = trimmed.filter { ruleCharacters.contains($0) }.count
        return ruleCount * 10 >= trimmed.count * 9
    }

    /// Spalte, an der der Text nach dem Prompt-Zeichen beginnt.
    static func promptStart(_ line: String) -> Int? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " " || characters[index] == "│" { index += 1 }
        guard index < characters.count, characters[index] == "❯" || characters[index] == ">" else { return nil }
        index += 1
        if index < characters.count, characters[index] == " " { index += 1 }
        return index
    }

    private static func field(in lines: [ControllerScreenLine], box: PromptBox, cursor: (row: Int, col: Int)?) -> ControllerPromptField {
        let firstRow = box.upper + 1
        let rows = box.lower - box.upper - 1
        // Wo der Text beginnt, sagt die volle Zeile (das „❯“ ist abgeblendet);
        // ob Text dasteht, die Fassung ohne Abgeblendetes.
        let start = promptStart(lines[firstRow].full) ?? 0
        var content = String(Array(lines[firstRow].plain).dropFirst(start))
        for row in (firstRow + 1)..<box.lower { content += " " + lines[row].plain }
        let isEmpty = content.replacingOccurrences(of: "│", with: " ")
            .trimmingCharacters(in: .whitespaces).isEmpty
        var cursorRow: Int?
        var cursorAtStart = false
        if let cursor, cursor.row >= firstRow, cursor.row < box.lower {
            cursorRow = cursor.row - firstRow
            cursorAtStart = cursorRow == 0 && cursor.col <= start
        }
        return ControllerPromptField(rows: rows, cursorRow: cursorRow, cursorAtStart: cursorAtStart, isEmpty: isEmpty)
    }
}
