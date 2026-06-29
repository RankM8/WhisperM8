import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Transferable-Payload für einen Session-Drag in der Sidebar oder im
/// Tab-Strip. Die `sourceProjectID` lässt uns beim Drop unterscheiden:
///
/// - Source == Target Project → Reorder innerhalb des Projekts
/// - Source ≠ Target Project → Cross-Project-Move
///
/// **Wichtig zur UTI-Registrierung**: Custom UTIs via
/// `UTType(exportedAs:)` müssen zusätzlich in der `Info.plist` als
/// `UTExportedTypeDeclarations` deklariert sein, sonst registriert
/// LaunchServices die UTI nicht und SwiftUI behandelt `.draggable(...)`
/// stillschweigend als no-op (kein Cursor-Feedback, kein Drop). Siehe
/// `WhisperM8/Info.plist` — beide UTIs sind dort registriert.
struct DraggableSession: Codable, Transferable {
    let sessionID: UUID
    let sourceProjectID: UUID
    let sourceWindowID: UUID?

    init(sessionID: UUID, sourceProjectID: UUID, sourceWindowID: UUID? = nil) {
        self.sessionID = sessionID
        self.sourceProjectID = sourceProjectID
        self.sourceWindowID = sourceWindowID
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .agentChatSession)
    }
}

struct DraggableProject: Codable, Transferable {
    let projectID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .agentProject)
    }
}

extension UTType {
    /// Eigene UTI für In-App Session-Drags. Conformt zu `.data`, damit das
    /// System sie als opaken Datenblock behandelt.
    static let agentChatSession = UTType(exportedAs: "com.whisperm8.app.agent-chat-session", conformingTo: .data)
    /// Eigene UTI für In-App Project-Drags.
    static let agentProject = UTType(exportedAs: "com.whisperm8.app.agent-project", conformingTo: .data)
}
