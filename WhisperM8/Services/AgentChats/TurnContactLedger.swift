import Foundation

/// War ein Turn eine kurze Antwort auf einen anderen Chat, und an wen hat ein
/// Chat in seinem Turn geschrieben? Für das Journal beim Turn-Ende (WM8-119).
///
/// Am 16.11.2026 kamen 55 Board-Hinweise „fertig – prüfen“ an den Supervisor,
/// 37 davon ohne Neuigkeit: 12 von Chats, die im selben Turn schon per
/// Warteschlange an ihn gemeldet hatten, 25 von Chats, die nur auf seine
/// eigene Nachricht antworteten („Verstanden, ich warte auf die Bahn“).
/// Entscheidung Giuliano 16.11.2026: beide still. Die Board-Mod liest dafür
/// `repliedTo` und `messaged` aus dem Journal. Als Antwort gilt nur ein Turn
/// von höchstens 2 Minuten: Die Antworten am 16.11. dauerten fast alle unter
/// zwei Minuten; ein „Commit und push“ oder ein kleiner Fix dauert auch nur
/// ein paar Minuten und soll am Ende weiter wecken, falls der Chat vergisst zu
/// melden. Ebenso zählt eine Meldung nur in den letzten 2 Minuten vor dem
/// Turn-Ende: Nach einer frühen Zwischenmeldung und langer Arbeit ohne
/// Schlussmeldung soll der Supervisor weiter geweckt werden (Prüferin zu WM8-119).
///
/// Nur Speicher, nur auf dem Main Thread, je Senden ein Eintrag; nichts wird
/// über alle Chats gezählt.
@MainActor
final class TurnContactLedger {
    static let shared = TurnContactLedger()

    struct Delivery: Equatable {
        var sender: UUID
        var at: Date
    }

    struct Message: Equatable {
        var target: UUID
        var at: Date
    }

    /// Ziel → letzte Zustellung mit bekanntem Absender (`send`, Warteschlange).
    private(set) var lastDelivery: [UUID: Delivery] = [:]
    /// Absender → zuletzt angeschriebene Chats.
    private(set) var messages: [UUID: [Message]] = [:]

    /// So lange vor dem gesehenen Turn-Start darf die Zustellung liegen: Das
    /// Enter wartet bis zu 3 s auf den Text im Feld, Claude und die Registry
    /// melden den Turn danach mit ein paar Sekunden Verzug.
    nonisolated static let startWindowBefore: TimeInterval = 15
    /// Uhren von Zustellung und Statuswechsel laufen getrennt.
    nonisolated static let startWindowAfter: TimeInterval = 1
    nonisolated static let maxMessagesPerSender = 20
    /// Länger dauert eine Antwort nicht; ein längerer Turn ist Arbeit.
    nonisolated static let replyMaxSeconds: TimeInterval = 120
    /// Nur eine Meldung so kurz vor dem Turn-Ende zählt als Schlussmeldung.
    nonisolated static let messagedWithinSeconds: TimeInterval = 120

    /// Ein Prompt mit bekanntem, geprüftem Absender wurde eingefügt (Zeitpunkt des Einfügens).
    func noteDelivered(to target: UUID, from sender: UUID?, at: Date = Date()) {
        guard let sender, sender != target else { return }
        lastDelivery[target] = Delivery(sender: sender, at: at)
    }

    /// Ein Chat hat an einen anderen gesendet oder bei ihm vorgemerkt.
    func noteMessaged(from sender: UUID?, to target: UUID, at: Date = Date()) {
        guard let sender, sender != target else { return }
        var list = messages[sender] ?? []
        list.append(Message(target: target, at: at))
        messages[sender] = Array(list.suffix(Self.maxMessagesPerSender))
    }

    /// Angaben fürs Journal beim Turn-Ende eines Chats.
    func turnContext(for sessionID: UUID, turnStartedAt: Date?, endedAt: Date = Date())
        -> (repliedTo: UUID?, messaged: [UUID]) {
        Self.context(delivery: lastDelivery[sessionID], messages: messages[sessionID] ?? [],
                     turnStartedAt: turnStartedAt, endedAt: endedAt)
    }

    /// Pur: War der Turn eine kurze Antwort auf die Zustellung, die ihn anstieß,
    /// und wen hat der Chat kurz vor dem Turn-Ende angeschrieben (seit dem
    /// Turn-Start und höchstens `messagedWithinSeconds` vorher)? Ohne bekannten
    /// Turn-Start: nichts.
    nonisolated static func context(delivery: Delivery?, messages: [Message], turnStartedAt: Date?, endedAt: Date)
        -> (repliedTo: UUID?, messaged: [UUID]) {
        guard let turnStartedAt else { return (nil, []) }
        var repliedTo: UUID?
        if let delivery,
           delivery.at >= turnStartedAt.addingTimeInterval(-startWindowBefore),
           delivery.at <= turnStartedAt.addingTimeInterval(startWindowAfter),
           endedAt.timeIntervalSince(turnStartedAt) <= replyMaxSeconds {
            repliedTo = delivery.sender
        }
        var messaged: [UUID] = []
        let recent = max(turnStartedAt, endedAt.addingTimeInterval(-messagedWithinSeconds))
        for message in messages where message.at >= recent && !messaged.contains(message.target) {
            messaged.append(message.target)
        }
        return (repliedTo, messaged)
    }
}
