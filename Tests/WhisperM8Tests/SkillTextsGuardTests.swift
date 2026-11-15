import XCTest
@testable import WhisperM8

/// Prüft die mitgelieferten Skill-Texte gegen die Kommandozeile: Jeder Befehl
/// von `whisperm8 chats` und `whisperm8 tickets`, den ein Skill nennt, muss es
/// samt Schaltern in der Hilfe geben. Dazu zwei Muster, die in Skills nichts
/// verloren haben: `pgrep -f … xctest` (eine Warteschleife trifft damit ihre
/// eigene Shell) und echte Ticket-Nummern (die Skills gehen an jeden Nutzer).
final class SkillTextsGuardTests: XCTestCase {

    // MARK: Befehle gegen die Hilfe

    func testEveryChatsAndTicketsCommandInSkillsExistsInHelp() throws {
        let chats = HelpIndex(help: ChatsCLIHelp.text, tool: "chats")
        let tickets = HelpIndex(help: TicketsCLICommand.help, tool: "tickets")
        var problems: [String] = []
        var checked = 0

        for file in try Self.skillFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let bareDomain: HelpIndex?
            switch file.lastPathComponent {
            case "whisperm8-chats-skill.md", "whisperm8-jarvis-skill.md": bareDomain = chats
            case "whisperm8-tickets-skill.md": bareDomain = tickets
            default: bareDomain = nil
            }
            for snippet in Self.codeSnippets(in: text) {
                for mention in Self.mentions(in: snippet, chats: chats, tickets: tickets, bareDomain: bareDomain) {
                    checked += 1
                    if let problem = mention.index.problem(command: mention.command, flags: mention.flags) {
                        problems.append("\(file.lastPathComponent): `\(snippet)` — \(problem)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 50, "Der Prüfer findet kaum Befehle; stimmt das Einlesen noch?")
        XCTAssertTrue(problems.isEmpty, "Befehle oder Schalter, die die Hilfe nicht kennt:\n" + problems.joined(separator: "\n"))
    }

    func testHelpIndexFindsDeadCommandsAndFlags() {
        let chats = HelpIndex(help: ChatsCLIHelp.text, tool: "chats")
        let tickets = HelpIndex(help: TicketsCLICommand.help, tool: "tickets")
        // Der Fall aus WM8-77: --if-status kennt nur send.
        let dead = Self.mentions(in: "interrupt X --if-status working", chats: chats, tickets: tickets, bareDomain: chats)
        XCTAssertEqual(dead.count, 1)
        XCTAssertNotNil(dead.first.flatMap { $0.index.problem(command: $0.command, flags: $0.flags) })
        let alive = Self.mentions(in: "whisperm8 chats send <ref> --if-status working", chats: chats, tickets: tickets, bareDomain: nil)
        XCTAssertNil(alive.first.flatMap { $0.index.problem(command: $0.command, flags: $0.flags) })
        let unknown = Self.mentions(in: "whisperm8 chats explode <ref>", chats: chats, tickets: tickets, bareDomain: nil)
        XCTAssertNotNil(unknown.first.flatMap { $0.index.problem(command: $0.command, flags: $0.flags) })
        let twoLevel = Self.mentions(in: "whisperm8 chats workspace remove <name> <ref> --keep-slot", chats: chats, tickets: tickets, bareDomain: nil)
        XCTAssertEqual(twoLevel.first?.command, "workspace remove")
        XCTAssertNil(twoLevel.first.flatMap { $0.index.problem(command: $0.command, flags: $0.flags) })
        let ticketFlag = Self.mentions(in: "whisperm8 tickets done ABC-12 --built x --frobnicate", chats: chats, tickets: tickets, bareDomain: nil)
        XCTAssertNotNil(ticketFlag.first.flatMap { $0.index.problem(command: $0.command, flags: $0.flags) })
    }

    // MARK: Verbotene Muster

    func testNoSelfMatchingPgrepForXctest() throws {
        let pattern = try NSRegularExpression(pattern: #"pgrep\s+-[A-Za-z]*f[A-Za-z]*[^\n`]*xctest"#)
        var hits: [String] = []
        for file in try Self.skillFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                hits.append("\(file.lastPathComponent): \(Self.substring(text, match.range))")
            }
        }
        XCTAssertTrue(hits.isEmpty, "Mit -f trifft die Warteschleife ihre eigene Shell; `pgrep -x xctest` nehmen:\n" + hits.joined(separator: "\n"))
    }

    func testNoRealTicketKeysInSkills() throws {
        // ABC-12 ist das vereinbarte Beispiel; GPT-5.4 und Co. sind Modellnamen.
        let allowedPrefixes: Set<String> = ["ABC", "GPT"]
        let pattern = try NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]{1,9})-[0-9]+\b"#)
        var hits: [String] = []
        for file in try Self.skillFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let prefix = Self.substring(text, match.range(at: 1))
                if !allowedPrefixes.contains(prefix) {
                    hits.append("\(file.lastPathComponent): \(Self.substring(text, match.range))")
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, "Skills gehen an jeden Nutzer; Ticket-Nummern gehören in Doku und Pläne:\n" + hits.joined(separator: "\n"))
    }

    // MARK: Einlesen der Skills

    static func skillFiles() throws -> [URL] {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WhisperM8/Resources", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("whisperm8-") && $0.pathExtension == "md" && $0.lastPathComponent.contains("-skill") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 9, "Skill-Dateien nicht gefunden unter \(resources.path)")
        return files
    }

    /// Inline-Code außerhalb von Blöcken und jede Zeile in Code-Blöcken.
    /// Fortsetzungszeilen (`\`) werden verbunden, Kommentare (`  # …`) entfernt.
    static func codeSnippets(in text: String) -> [String] {
        var snippets: [String] = []
        var inFence = false
        var pending = ""
        let inline = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
        let comment = try! NSRegularExpression(pattern: #"\s{2,}#.*$"#)
        for rawLine in text.components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence, !pending.isEmpty { snippets.append(pending); pending = "" }
                inFence.toggle()
                continue
            }
            if inFence {
                var line = rawLine
                line = comment.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("\\") {
                    pending += String(trimmed.dropLast()) + " "
                } else {
                    let joined = (pending + trimmed).trimmingCharacters(in: .whitespaces)
                    if !joined.isEmpty { snippets.append(joined) }
                    pending = ""
                }
                continue
            }
            for match in inline.matches(in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine)) {
                snippets.append(substring(rawLine, match.range(at: 1)))
            }
        }
        return snippets
    }

    struct Mention {
        let index: HelpIndex
        let command: String
        let flags: [String]
    }

    /// Befehle in einem Schnipsel: ausdrücklich mit `chats`/`tickets` davor,
    /// oder (nur im eigenen Skill) ein Schnipsel, der mit einem bekannten
    /// Unterbefehl beginnt und Schalter trägt, etwa `close <ref> --stop`.
    static func mentions(in snippet: String, chats: HelpIndex, tickets: HelpIndex, bareDomain: HelpIndex?) -> [Mention] {
        let prefixed = try! NSRegularExpression(pattern: #"(?:^|[\s(|;&])(?:whisperm8\s+)?(chats|tickets)\s+([a-z][a-z-]*)"#)
        let matches = prefixed.matches(in: snippet, range: NSRange(snippet.startIndex..., in: snippet))
        var result: [Mention] = []
        if !matches.isEmpty {
            for (position, match) in matches.enumerated() {
                let index = substring(snippet, match.range(at: 1)) == "chats" ? chats : tickets
                let start = match.range(at: 2).location
                let end = position + 1 < matches.count ? matches[position + 1].range.location : (snippet as NSString).length
                let tail = (snippet as NSString).substring(with: NSRange(location: start, length: end - start))
                if let mention = index.mention(fromTail: tail) { result.append(mention) }
            }
            return result
        }
        guard let index = bareDomain else { return [] }
        let trimmed = snippet.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.split(separator: " ").first.map(String.init),
              index.firstLevel.contains(first),
              trimmed.contains(" --") else { return [] }
        if let mention = index.mention(fromTail: trimmed) { result.append(mention) }
        return result
    }

    static func substring(_ text: String, _ range: NSRange) -> String {
        guard let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    // MARK: Hilfe als Nachschlagewerk

    /// Zerlegt einen Hilfetext in Abschnitte je Unterbefehl („workspace add“,
    /// „close“, „setup“ …). Ein Abschnitt reicht von seiner Zeile
    /// `whisperm8 <tool> <befehl>` bis zur nächsten solchen Zeile oder
    /// Überschrift; mehrere Zeilen desselben Befehls werden zusammengelegt.
    struct HelpIndex {
        static let twoLevel: Set<String> = ["board", "workspace", "window"]
        /// Bekannt, auch wenn sie keine eigene Zeile in der Hilfe haben.
        static let alwaysKnown: Set<String> = ["help"]
        let tool: String
        private(set) var segments: [String: String] = [:]

        var firstLevel: Set<String> {
            Set(segments.keys.map { String($0.split(separator: " ").first ?? "") })
        }

        init(help: String, tool: String) {
            self.tool = tool
            var current: [String] = []
            let prefix = "whisperm8 \(tool) "
            for line in help.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(prefix) {
                    let rest = String(trimmed.dropFirst(prefix.count))
                    current = Self.keys(for: rest)
                    for key in current { segments[key, default: ""] += " " + rest }
                } else if Self.isHeading(trimmed) {
                    current = []
                } else if !current.isEmpty {
                    for key in current { segments[key, default: ""] += " " + trimmed }
                }
            }
        }

        private static func isHeading(_ line: String) -> Bool {
            guard let first = line.first, first.isLetter else { return false }
            let letters = line.filter(\.isLetter)
            return !letters.isEmpty && letters == letters.uppercased()
        }

        private static func keys(for rest: String) -> [String] {
            let tokens = rest.split(separator: " ").map(String.init)
            guard let first = tokens.first else { return [] }
            if twoLevel.contains(first), tokens.count > 1,
               tokens[1].range(of: #"^[a-z][a-z|-]*$"#, options: .regularExpression) != nil {
                return tokens[1].split(separator: "|").map { "\(first) \($0)" }
            }
            return first.split(separator: "|").map(String.init)
        }

        func mention(fromTail tail: String) -> Mention? {
            let tokens = tail.split(separator: " ").map(String.init)
            // Nur der Name zählt: aus `snapshot:*)` (Freigabe-Schreibweise) wird `snapshot`.
            guard let first = tokens.first?.prefix(while: { $0.isLowercase || $0 == "-" }).description,
                  !first.isEmpty else { return nil }
            var command = first
            if Self.twoLevel.contains(first), tokens.count > 1, segments["\(first) \(tokens[1])"] != nil {
                command = "\(first) \(tokens[1])"
            }
            let flagPattern = try! NSRegularExpression(pattern: #"(?<![\w-])--[a-z][a-z-]*"#)
            let flags = flagPattern.matches(in: tail, range: NSRange(tail.startIndex..., in: tail))
                .map { SkillTextsGuardTests.substring(tail, $0.range) }
            return Mention(index: self, command: command, flags: flags)
        }

        func problem(command: String, flags: [String]) -> String? {
            if Self.alwaysKnown.contains(command) { return nil }
            guard let segment = segments[command] else {
                return "`whisperm8 \(tool) \(command)` steht nicht in der Hilfe"
            }
            let unknown = flags.filter { $0 != "--json" && !segment.contains($0) }
            guard !unknown.isEmpty else { return nil }
            return "`\(command)` kennt laut Hilfe nicht: " + unknown.joined(separator: ", ")
        }
    }
}
