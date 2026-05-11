import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Transferable-Payload für einen Session-Drag in der Sidebar oder im
/// Tab-Strip. Die `sourceProjectID` lässt uns beim Drop unterscheiden:
///
/// - Source == Target Project → Reorder innerhalb des Projekts
/// - Source ≠ Target Project → Cross-Project-Move
struct DraggableSession: Codable, Transferable {
    let sessionID: UUID
    let sourceProjectID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .agentChatSession)
    }
}

/// Transferable-Payload für einen Project-Drag (Sidebar-Header).
struct DraggableProject: Codable, Transferable {
    let projectID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .agentProject)
    }
}

extension UTType {
    /// Eigene UTI, damit SwiftUI Session- und Project-Drags unterscheidet
    /// und Finder-/Browser-Drags (`.fileURL`, `.url`) hier nicht einklinken.
    static let agentChatSession = UTType(exportedAs: "com.whisperm8.app.agent-chat-session")
    static let agentProject = UTType(exportedAs: "com.whisperm8.app.agent-project")
}
