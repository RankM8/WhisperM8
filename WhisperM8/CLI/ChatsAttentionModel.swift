import Foundation

// MARK: - Attention-Modell (aus Jarvis-Plan Rev 2 übernommen)

enum ChatsAttentionCategory: String, CaseIterable {
    case needsYou
    case freshDone
    case working
    case idle

    var boardTitle: String {
        switch self {
        case .needsYou: return "BRAUCHT DICH"
        case .freshDone: return "FRISCH FERTIG"
        case .working: return "ARBEITET"
        case .idle: return "IDLE"
        }
    }
}

struct ChatsAttentionItem: Equatable {
    var entry: ChatsSessionEntry
    var runtime: ChatsRuntimeInfo
    var category: ChatsAttentionCategory
    /// 1 = awaitingInput, 2 = errored, 3 = frisch fertig, 4 = working, 5 = Rest.
    var rank: Int
}

struct ChatsAttentionBoard: Equatable {
    /// Attention-sortiert: Rang aufsteigend, innerhalb des Rangs jüngste zuerst.
    var items: [ChatsAttentionItem]
    var counts: [ChatsAttentionCategory: Int]
}

/// Purer Builder: Sessions + Runtime rein, Board-Struktur raus. `now`
/// injizierbar für Tests; kein I/O.
enum AttentionModelBuilder {
    /// „Frisch fertig" = Turn endete innerhalb dieses Fensters. Ersetzt das
    /// isRead-Flag aus Rev 2 (bewusste Vereinfachung).
    static let freshDoneWindow: TimeInterval = 15 * 60

    static func build(
        items: [(entry: ChatsSessionEntry, runtime: ChatsRuntimeInfo)],
        now: Date = Date()
    ) -> ChatsAttentionBoard {
        var ranked: [ChatsAttentionItem] = items.map { entry, runtime in
            let (category, rank) = classify(entry: entry, runtime: runtime, now: now)
            return ChatsAttentionItem(entry: entry, runtime: runtime, category: category, rank: rank)
        }
        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let lhsDate = lhs.runtime.since ?? lhs.entry.session.lastActivityAt
            let rhsDate = rhs.runtime.since ?? rhs.entry.session.lastActivityAt
            return lhsDate > rhsDate
        }
        var counts: [ChatsAttentionCategory: Int] = [:]
        for item in ranked {
            counts[item.category, default: 0] += 1
        }
        return ChatsAttentionBoard(items: ranked, counts: counts)
    }

    private static func classify(
        entry: ChatsSessionEntry,
        runtime: ChatsRuntimeInfo,
        now: Date
    ) -> (ChatsAttentionCategory, Int) {
        switch runtime.status {
        case .awaitingInput:
            return (.needsYou, 1)
        case .errored:
            return (.needsYou, 2)
        case .idle:
            let reference = entry.session.lastTurnAt ?? runtime.since
            if let reference, now.timeIntervalSince(reference) <= freshDoneWindow {
                return (.freshDone, 3)
            }
            return (.idle, 5)
        case .working:
            return (.working, 4)
        case .stopped, nil:
            return (.idle, 5)
        }
    }
}
