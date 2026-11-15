import XCTest
@testable import WhisperM8

/// WM8-85, Paket 2a: Chats schicken sich Nachrichten nativ; die App trägt
/// jede native Nachricht an einen ihrer Chats ins Audit ein.
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
}

