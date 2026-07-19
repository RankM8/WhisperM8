import Foundation

// MARK: - Live-Merge des App-Status über den Control-Socket

/// Der autoritative Live-Status der App für eine Session (aus `sessions.live`).
struct ChatsLiveStatus {
    var runtimeStatus: AgentSessionRuntimeStatus?
    var isAttachedPTY: Bool
    var canSend: Bool
    var canInterrupt: Bool
}

/// Fragt die laufende App EINMAL pro CLI-Aufruf nach dem Live-Status aller
/// Sessions und merged ihn über die Transcript-Schätzung. Läuft die App nicht,
/// bleibt es beim Schätzer (`live: false`).
enum ChatsLiveMerge {
    /// `nil`, wenn die App nicht erreichbar ist.
    static func fetch() -> [UUID: ChatsLiveStatus]? {
        guard let response = try? ChatsControlClient.send(method: "sessions.live", params: [:]),
              response.ok,
              let sessions = response.result?["sessions"]?.arrayValue else {
            return nil
        }
        var map: [UUID: ChatsLiveStatus] = [:]
        for session in sessions {
            guard let idString = session["sessionID"]?.stringValue,
                  let id = UUID(uuidString: idString) else { continue }
            let statusRaw = session["runtimeStatus"]?.stringValue
            map[id] = ChatsLiveStatus(
                runtimeStatus: statusRaw.flatMap(AgentSessionRuntimeStatus.init(rawValue:)),
                isAttachedPTY: session["isAttachedPTY"]?.boolValue ?? false,
                canSend: session["canSend"]?.boolValue ?? false,
                canInterrupt: session["canInterrupt"]?.boolValue ?? false
            )
        }
        return map
    }

    /// Überschreibt die geschätzten Runtime-Felder mit den autoritativen
    /// App-Werten. `source: "app"` NUR, wenn die App wirklich einen Status
    /// liefert — sonst bliebe das Label „app" auf einer reinen Transcript-
    /// Schätzung kleben (GPT-Review).
    static func merge(estimate: ChatsRuntimeInfo, live: ChatsLiveStatus?) -> ChatsRuntimeInfo {
        guard let live, let status = live.runtimeStatus else { return estimate }
        var merged = estimate
        merged.source = "app"
        merged.status = status
        return merged
    }
}
