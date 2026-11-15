import SwiftTerm
import XCTest
@testable import WhisperM8

/// WM8-85, Paket 2a/2b: Chats schicken sich Nachrichten nativ; die App trägt
/// jede native Nachricht an einen ihrer Chats ins Audit ein. Jeder Claude-Chat
/// startet mit festem Namen (2b), den Claude in die Linie über dem
/// Eingabefeld zeichnet.
final class NativeMessagingTests: XCTestCase {
    // MARK: Native Nachrichten im Audit

    /// Zeile wie im Verlauf eines echten Empfängers (Claude Code 2.1.325, gekürzt).
    private let peerLine = #"{"type":"user","isMeta":true,"timestamp":"2026-11-13T16:54:11.495Z","origin":{"kind":"peer","from":"uds:/tmp/cc-socks/30051.sock","verifiedPeerPid":30051,"msg_id":"ffeb3f07","name":"Jarvis","fromMode":"bypass","body":"Jarvis an Ana: zur Info"},"message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/cc-socks/30051.sock\">…"}}"#

    func testPeerMessagesAreReadFromTheTail() {
        let tail = [
            #"{"type":"assistant","message":{"content":[]}}"#,
            peerLine,
            #"{"type":"user","isMeta":true,"origin":null,"message":{"content":"<cross-session-message from=\"…\"> im Skill-Text"}}"#,
        ].joined(separator: "\n")
        let messages = ClaudePeerMessageScan.messages(inTail: tail)
        XCTAssertEqual(messages.count, 1, "Skill-Text mit dem Wort zählt nicht, nur origin.kind = peer")
        XCTAssertEqual(messages.first?.messageID, "ffeb3f07")
        XCTAssertEqual(messages.first?.name, "Jarvis")
        XCTAssertEqual(messages.first?.verifiedPeerPid, 30051)
        XCTAssertEqual(messages.first?.body, "Jarvis an Ana: zur Info")
        XCTAssertNotNil(messages.first?.timestamp)
        XCTAssertTrue(ClaudePeerMessageScan.messages(inTail: #"{"type":"user"}"#).isEmpty)
    }

    func testEachMessageIsReportedOnceAndNothingOnTheFirstLook() {
        let a = ClaudePeerMessage(messageID: "a", from: "uds:x", name: nil, verifiedPeerPid: nil, body: "1", timestamp: nil)
        let b = ClaudePeerMessage(messageID: "b", from: "uds:x", name: nil, verifiedPeerPid: nil, body: "2", timestamp: nil)
        let first = ClaudePeerMessageScan.newMessages([a], seen: nil)
        XCTAssertTrue(first.new.isEmpty, "nach dem App-Start nichts doppelt ins Audit")
        let second = ClaudePeerMessageScan.newMessages([a, b], seen: first.seen)
        XCTAssertEqual(second.new.map(\.messageID), ["b"])
        XCTAssertTrue(ClaudePeerMessageScan.newMessages([a, b], seen: second.seen).new.isEmpty)
    }

    func testAuditEntryNamesSenderAndTarget() {
        let message = ClaudePeerMessageScan.messages(inTail: peerLine)[0]
        let entry = ClaudePeerMessageScan.auditEntry(message, target: "ListM8/Ana")
        XCTAssertEqual(entry.method, "native-message")
        XCTAssertEqual(entry.target, "ListM8/Ana")
        XCTAssertTrue(entry.actor.contains("Jarvis") && entry.actor.contains("uds:/tmp/cc-socks/30051.sock"), entry.actor)
        XCTAssertTrue(entry.verified)
        XCTAssertEqual(entry.promptChars, "Jarvis an Ana: zur Info".count)
    }

    // MARK: Veraltete Anfragen (Vorfall 15.11.2026)

    private func request(_ method: String, sentAgo: Double?) -> ChatsControlRequest {
        ChatsControlRequest(actor: ChatsControlActor(sessionID: nil, token: nil), method: method,
                            sentAt: sentAgo.map { Date().timeIntervalSince1970 - $0 })
    }

    func testARequestOlderThanItsClientsDeadlineIsExpired() {
        let deadline = Double(ChatsControlProtocol.clientReadTimeoutSeconds(for: "queue.enqueue"))
        XCTAssertFalse(request("queue.enqueue", sentAgo: 1).isExpired())
        XCTAssertTrue(request("queue.enqueue", sentAgo: deadline + 1).isExpired(), "Client hat schon aufgegeben")
        XCTAssertFalse(request("queue.enqueue", sentAgo: nil).isExpired(), "ältere Clients ohne Zeitstempel: nichts verwerfen")
        // Lange Methoden haben eine längere Frist.
        XCTAssertFalse(request("session.moveAccount", sentAgo: deadline + 1).isExpired())
    }

    func testTheTimestampTravelsAndOldRequestsStillDecode() throws {
        let sent = request("session.send", sentAgo: 0)
        let decoded = try JSONDecoder().decode(ChatsControlRequest.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(decoded.sentAt ?? 0, sent.sentAt ?? -1, accuracy: 0.001)
        let old = #"{"protocolVersion":1,"requestID":"r","actor":{},"method":"ping","params":{}}"#
        XCTAssertNil(try JSONDecoder().decode(ChatsControlRequest.self, from: Data(old.utf8)).sentAt)
    }

    func testExpiredIsNotRetryableAndUnclearOutcomeHasItsOwnExitCode() {
        XCTAssertFalse(ChatsControlErrorCode.expired.isRetryable)
        XCTAssertNil(ChatsControlErrorCode.expired.alternative, "nie automatisch vormerken")
        XCTAssertEqual(AgentControlRequestHandler.expiredResponse(request("session.send", sentAgo: 20)).error?.code, "expired")
        XCTAssertNotEqual(ChatsCLIExit.outcomeUnknown, ChatsCLIExit.appUnreachable)
        XCTAssertTrue(ChatsControlClient.outcomeUnknownMessage.contains("Nicht wiederholen"))
        XCTAssertTrue(ChatsControlClient.outcomeUnknownMessage.contains("chats queue"))
    }

    // MARK: Fester Name

    private func session(_ title: String, id: UUID = UUID(uuidString: "F0D79F2C-A760-4303-A014-71B548B0A122")!) -> AgentChatSession {
        AgentChatSession(id: id, provider: .claude, projectID: UUID(), title: title)
    }

    func testNativeNameIsTheTitleHeadPlusTheShortID() {
        XCTAssertEqual(AgentCommandBuilder.nativeName(for: session("WM8-100 Gus · Nachrichten härten")), "wm8-100-gus-f0d79f2c")
        XCTAssertEqual(AgentCommandBuilder.nativeName(for: session("Jarvis: Supervisor WhisperM8")), "jarvis-f0d79f2c")
        XCTAssertEqual(AgentCommandBuilder.nativeName(for: session("Überprüfung Größe")), "uberprufung-grosse-f0d79f2c")
        XCTAssertEqual(AgentCommandBuilder.nativeName(for: session("· leer")), "chat-f0d79f2c")
        let long = AgentCommandBuilder.nativeName(for: session("Ein sehr langer Titel ohne jeden Trenner darin"))
        XCTAssertLessThanOrEqual(long.count, 24 + 9)
        XCTAssertTrue(long.hasSuffix("-f0d79f2c"))
        XCTAssertFalse(long.contains("--"))
    }

    private func builder(nameEnabled: Bool, extra: [String] = []) -> AgentCommandBuilder {
        var builder = AgentCommandBuilder(commandResolver: { "/usr/local/bin/\($0)" })
        builder.extraArgumentsResolver = { _ in extra }
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { false }
        builder.gptProfileHeaderResolver = { _ in nil }
        builder.runningSessionProcessResolver = { _ in nil }
        builder.nativeNameEnabled = nameEnabled
        return builder
    }

    func testClaudeChatsStartWithTheirNameBeforeResume() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var chat = session("Ole · Board-Schleife")
        chat.externalSessionID = "resume-1"
        chat.hasLaunchedInitialPrompt = true
        chat.projectID = project.id
        let named = try builder(nameEnabled: true).command(for: chat, project: project)
        XCTAssertEqual(named.arguments, ["--name", "ole-f0d79f2c", "--resume", "resume-1"])
        let plain = try builder(nameEnabled: false).command(for: chat, project: project)
        XCTAssertEqual(plain.arguments, ["--resume", "resume-1"], "ab Werk aus, nur der Startweg der App schaltet es ein")
        let own = try builder(nameEnabled: true, extra: ["--name", "eigener"]).command(for: chat, project: project)
        XCTAssertEqual(own.arguments.filter { $0 == "--name" }.count, 1, "ein eigener Name aus den Einstellungen gewinnt")
    }

    // MARK: Eingabefeld mit Namen in der Linie

    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func screen(_ text: String, cols: Int) -> ControllerScreenSnapshot {
        let terminal = Terminal(delegate: Sink(), options: TerminalOptions(cols: cols, rows: 12))
        terminal.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
        let capture = ControllerScreenCapture.bottomLines(of: terminal)
        return ControllerScreenReading.read(lines: capture.lines, cursor: capture.cursor, detectViews: true)
    }

    /// Gemessen an Claude Code 2.1.325: „──── gus-probe-a1c8e3b6 ─“ als obere
    /// Linie. Ohne die Ausnahme fiel sie bei 160 Spalten auf 88 % Linien-
    /// zeichen; Freigabe-Schutz, Startprüfung und Controller sähen kein Feld.
    func testTheFieldIsFoundWhenClaudeWritesTheSessionNameIntoTheRule() {
        let (dim, reset, save, restore) = ("\u{1b}[2m", "\u{1b}[0m", "\u{1b}[s", "\u{1b}[u")
        for cols in [40, 80, 160] {
            let name = "gus-probe-a1c8e3b6"
            let top = String(repeating: "─", count: cols - name.count - 3) + " \(name) ─"
            let bottom = String(repeating: "─", count: cols)
            let empty = screen("⏺ OK\n\(top)\n\(dim)❯ \(reset)\(save)\n\(bottom)\(restore)", cols: cols)
            XCTAssertEqual(empty.promptField?.isEmpty, true, "\(cols) Spalten")
            let typed = screen("\(top)\n\(dim)❯ \(reset)bitte testen\(save)\n\(bottom)\(restore)", cols: cols)
            XCTAssertEqual(typed.promptField?.hasText, true, "\(cols) Spalten")
        }
    }

    /// Gemessen an Claude Code 2.1.325 mit dem längsten Namen, den die App
    /// vergibt (24 Zeichen Kopf plus ID), in einem echten Terminal.
    func testMeasuredRulesAtNarrowWidths() {
        XCTAssertTrue(ControllerScreenReading.isRule("───── wm8-100-gus-nachrichten-f0d79f2c ─"), "40 Spalten")
        XCTAssertTrue(ControllerScreenReading.isRule(" wm8-100-gus-nachrichten-f0… ─"), "30 Spalten, gekürzt")
        let (dim, reset, save, restore) = ("\u{1b}[2m", "\u{1b}[0m", "\u{1b}[s", "\u{1b}[u")
        let field = screen("⏺ OK\n wm8-100-gus-nachrichten-f0… ─\n\(dim)❯ \(reset)\(save)\n\(String(repeating: "─", count: 30))\(restore)",
                           cols: 30).promptField
        XCTAssertEqual(field?.isEmpty, true, "Feld auch in einer 30 Spalten schmalen Kachel")
        XCTAssertFalse(ControllerScreenReading.isRule(" Ausgabe mit Text … ─"), "gekürzt nur ohne Leerzeichen im Namen")
        // Zwischenbreiten (Vic): gemessen bei 35, 36, 37 Spalten (Name 32 Zeichen).
        let measured = [35: " wm8-100-gus-nachrichten-f0d79f2c ─", 36: "─ wm8-100-gus-nachrichten-f0d79f2c ─",
                        37: "── wm8-100-gus-nachrichten-f0d79f2c ─", 38: "─── wm8-100-gus-nachrichten-f0d79f2c ─",
                        33: " wm8-100-gus-nachrichten-f0d79… ─", 34: " wm8-100-gus-nachrichten-f0d79f… ─"]
        for (cols, line) in measured.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(ControllerScreenReading.isRule(line), "\(cols) Spalten")
            let field = screen("⏺ OK\n\(line)\n\(dim)❯ \(reset)\(save)\n\(String(repeating: "─", count: cols))\(restore)",
                               cols: cols).promptField
            XCTAssertEqual(field?.isEmpty, true, "Feld bei \(cols) Spalten")
        }
        XCTAssertFalse(ControllerScreenReading.isRule("─ zwei Wörter ─"), "links knapp nur ohne Leerzeichen im Text")
        XCTAssertFalse(ControllerScreenReading.isRule("ausgabe… ─"), "links weder Linie noch Leerzeichen")
    }

    func testNamedRuleStaysNarrow() {
        XCTAssertTrue(ControllerScreenReading.isRule("──────────── gus-f0d79f2c ─"))
        XCTAssertTrue(ControllerScreenReading.isRule(String(repeating: "─", count: 20)))
        XCTAssertFalse(ControllerScreenReading.isRule("─── zwei ─── Teile ─"), "nur ein Text in der Linie")
        XCTAssertFalse(ControllerScreenReading.isRule("Ergebnis ──────────────"), "links keine Linie")
        XCTAssertFalse(ControllerScreenReading.isRule("───" + " " + String(repeating: "x", count: 60) + " ─"), "zu langer Text")
    }

    // MARK: Vics Befunde zu Paket 2b

    /// `claude --name` schreibt den Namen als `custom-title` in den Verlauf.
    /// Die Titel-Übernahme nahm ihn als Titel; der Chat hieß dann
    /// `neue-session-1a2b3c4d` statt des generierten Titels.
    func testOwnNameNeverBecomesTheChatTitle() {
        let id = UUID(uuidString: "F0D79F2C-A760-4303-A014-71B548B0A122")!
        let own = { (value: String) in AgentCommandBuilder.isOwnNativeName(value, sessionID: id) }
        let lines = [
            #"{"type":"custom-title","customTitle":"neue-session-f0d79f2c"}"#,
            #"{"type":"ai-title","aiTitle":"Startbereitschaft nach Resume messen"}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(NativeSessionTitle.claudeTitle(fromJSONL: lines, ignoringCustomTitle: own),
                       "Startbereitschaft nach Resume messen")
        // Ohne Chat-ID (Indexer) greift das Namensmuster.
        XCTAssertEqual(NativeSessionTitle.claudeTitle(fromJSONL: lines), "Startbereitschaft nach Resume messen")
        // Ein echtes /rename gewinnt weiter, auch nach dem Namen.
        let renamed = lines + "\n" + #"{"type":"custom-title","customTitle":"Review Startfenster"}"#
        XCTAssertEqual(NativeSessionTitle.claudeTitle(fromJSONL: renamed, ignoringCustomTitle: own), "Review Startfenster")
        let renamedBefore = #"{"type":"custom-title","customTitle":"Review Startfenster"}"# + "\n" + lines
        XCTAssertEqual(NativeSessionTitle.claudeTitle(fromJSONL: renamedBefore, ignoringCustomTitle: own), "Review Startfenster",
                       "der eigene Name setzt einen früheren Titel nicht zurück")
    }

    func testTheNameDoesNotGrowFromATitleThatAlreadyIsTheName() {
        let id = UUID(uuidString: "F0D79F2C-A760-4303-A014-71B548B0A122")!
        let chat = AgentChatSession(id: id, provider: .claude, projectID: UUID(), title: "neue-session-f0d79f2c")
        XCTAssertEqual(AgentCommandBuilder.nativeName(for: chat), "neue-session-f0d79f2c")
        XCTAssertTrue(AgentCommandBuilder.isOwnNativeName("Gus-F0D79F2C", sessionID: id))
        XCTAssertFalse(AgentCommandBuilder.isOwnNativeName("gus-1a2b3c4d", sessionID: id), "Name eines anderen Chats")
        XCTAssertFalse(AgentCommandBuilder.looksLikeNativeName("Review Startfenster"))
        XCTAssertTrue(AgentCommandBuilder.looksLikeNativeName("wm8-100-gus-f0d79f2c"))
    }

    func testFreshChatsAreCalledChatID() {
        let id = UUID(uuidString: "F0D79F2C-A760-4303-A014-71B548B0A122")!
        for title in ["Neue Session", "Claude Chat", "Codex Chat", "", "Terminal"] {
            XCTAssertEqual(AgentCommandBuilder.nativeName(for: AgentChatSession(id: id, provider: .claude, projectID: UUID(), title: title)),
                           "chat-f0d79f2c", title)
        }
    }

    func testOnlyAMeasuredClaudeVersionGetsTheName() {
        XCTAssertFalse(ClaudeCLIVersion.supportsNativeName(nil), "unbekannte Version: kein Name, sicher starten")
        XCTAssertFalse(ClaudeCLIVersion.supportsNativeName(ClaudeCLIVersion(components: [2, 1, 324])))
        XCTAssertTrue(ClaudeCLIVersion.supportsNativeName(ClaudeCLIVersion(components: [2, 1, 325])))
        XCTAssertTrue(PreferenceBedienweg.killSwitches.contains { $0.key == "claudeNativeNameEnabled" })
    }
}

