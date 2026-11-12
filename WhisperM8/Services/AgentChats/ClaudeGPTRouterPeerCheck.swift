import Darwin
import Foundation
import Security

/// Ist die Gegenseite eines Unix-Sockets dasselbe Programm wie dieser Prozess?
///
/// Geprüft wird die Code-Signatur des Peers (Audit-Token aus `LOCAL_PEERTOKEN`)
/// gegen die designierte Anforderung des eigenen Programms. Mit der festen
/// Signatur von `make dev` („WhisperM8 Local Dev“) und der Developer ID der
/// Releases gilt das über Builds hinweg; ein ad-hoc signierter Build passt nur
/// zu sich selbst.
///
/// Ein Pfadvergleich reicht nicht: Er lässt sich mit einem anderen Programm am
/// selben Ort oder per fork+exec nach dem Verbinden unterlaufen. Das Audit-Token
/// trägt die Prozessversion; nach einem exec passt es nicht mehr zum Prozess,
/// und die Prüfung schlägt fehl. Deshalb prüft der Dienst bei jeder Nachricht.
enum ClaudeGPTRouterPeerCheck {
    /// Designierte Anforderung des eigenen Programms, einmal gelesen.
    static let ownRequirement: SecRequirement? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    static func isSameProgram(_ fd: Int32, requirement: SecRequirement? = ownRequirement) -> Bool {
        guard let requirement else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &guest
        ) == errSecSuccess, let guest else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}
