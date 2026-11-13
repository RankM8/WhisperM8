import Foundation

// MARK: - debug.terminal (`whisperm8 debug terminal <ref> --text [--lines N]`)

/// Text eines laufenden Terminals für Tests (Dauerlauf, Fehler-Szenarien):
/// Bildschirm plus Rücklauf als reiner UTF-8-Text, ohne Farben und
/// Steuerzeichen. Hinter `debugControlEnabled`; der Inhalt geht weder ins Log
/// noch ins Audit, denn ein Terminal kann Klartext und Geheimnisse zeigen.
extension AgentControlRequestHandler {
    func debugTerminal(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let ref = request.params["ref"]?.stringValue?.lowercased(), !ref.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "ref nötig")
        }
        let lines = request.params["lines"]?.intValue
        let found: (id: UUID, text: String)?? = await MainActor.run {
            let ids = AgentWorkspaceUIModel.shared.workspace.sessions.map(\.id)
                .filter { $0.uuidString.lowercased().hasPrefix(ref) }
            guard ids.count == 1, let id = ids.first else { return nil }
            guard let controller = AgentTerminalRegistry.shared.controller(for: id) else { return .some(nil) }
            return (id, controller.plainText(lastLines: lines))
        }
        switch found {
        case .none:
            return .failure(requestID: request.requestID, code: .notFound, message: "Kein eindeutiger Chat für \(ref)")
        case .some(.none):
            return .failure(requestID: request.requestID, code: .noPty, message: "Kein Terminal für \(ref) (Tab nie angezeigt oder beendet)")
        case .some(.some(let hit)):
            return .success(requestID: request.requestID, result: .object([
                "session": hit.id.uuidString, "text": hit.text,
            ]))
        }
    }
}

extension AgentTerminalController {
    /// Bildschirm plus Rücklauf als Text; Leerzeichen am Zeilenende und leere
    /// Zeilen am Schluss fallen weg. `lastLines` begrenzt auf die letzten N Zeilen.
    func plainText(lastLines: Int? = nil) -> String {
        let raw = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
        return Self.trimmedTerminalText(raw, lastLines: lastLines)
    }

    nonisolated static func trimmedTerminalText(_ raw: String, lastLines: Int?) -> String {
        var lines = raw.components(separatedBy: "\n").map { line -> String in
            var line = Substring(line)
            while let last = line.last, last == " " || last == "\r" || last == "\0" { line.removeLast() }
            return String(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if let lastLines, lastLines > 0, lines.count > lastLines {
            lines = Array(lines.suffix(lastLines))
        }
        return lines.joined(separator: "\n")
    }
}
