import Foundation

/// Kanonisches Format der lokal erzeugten Subagent-Job-IDs.
enum AgentJobID {
    static func isValid(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 8 && bytes.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}
