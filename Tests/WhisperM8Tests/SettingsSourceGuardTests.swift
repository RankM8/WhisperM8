import Foundation
import XCTest
@testable import WhisperM8

final class SettingsSourceGuardTests: XCTestCase {
    func testAllAppStorageStringKeysAreDeclaredPreferenceKeysOrDocumentedUIStateExceptions() throws {
        let root = repositoryRoot()
        let sourceDirectory = root.appendingPathComponent("WhisperM8", isDirectory: true)
        let appPreferencesURL = sourceDirectory.appendingPathComponent("Support/AppPreferences.swift")
        let declaredPreferenceKeys = try extractPreferenceKeyRawValues(from: appPreferencesURL)
        let documentedUIStateKeys: Set<String> = [
            "agentPinnedSectionCollapsed",
            "agentWorkspacesSectionCollapsed",
            "agentChatsSectionCollapsed",
            "agentProjectOpenTarget",
            "agentSidebarScope",
            "agentSidebarLayout",
            "agentSidebarWidth",
            // Die früheren Grid-Split-Keys (agentGridColumnFraction/-Row)
            // sind keine @AppStorage mehr — Splits leben seit Schema v4 am
            // Workspace-Entity; die v3→v4-Migration liest die Alt-Keys nur
            // noch direkt aus UserDefaults (AgentSessionStore.loadUIState).
            "agentTranscriptViewMode"
        ]
        let allowedKeys = declaredPreferenceKeys.union(documentedUIStateKeys)
        let appStorageKeys = try extractAppStorageStringKeys(in: sourceDirectory)
        let undeclaredKeys = appStorageKeys.subtracting(allowedKeys).sorted()

        XCTAssertFalse(appStorageKeys.isEmpty)
        XCTAssertTrue(
            undeclaredKeys.isEmpty,
            "Undeklarierte @AppStorage-Keys: \(undeclaredKeys.joined(separator: ", "))"
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func extractPreferenceKeyRawValues(from fileURL: URL) throws -> Set<String> {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        // Nur der PreferenceKeys-Enum-Block zählt als Deklaration — sonst würden
        // beliebige andere String-Konstanten in AppPreferences.swift den Guard
        // stillschweigend aufweichen (Review-Befund Phase 0).
        guard let enumRange = source.range(of: "enum PreferenceKeys {") else {
            XCTFail("PreferenceKeys-Enum nicht in AppPreferences.swift gefunden")
            return []
        }
        let tail = source[enumRange.lowerBound...]
        guard let closingRange = tail.range(of: "\n}") else {
            XCTFail("Ende des PreferenceKeys-Enums nicht gefunden")
            return []
        }
        let enumBlock = String(tail[..<closingRange.lowerBound])
        return Set(matches(in: enumBlock, pattern: #"static\s+let\s+[A-Za-z0-9_]+\s*=\s*"([^"]+)""#))
    }

    private func extractAppStorageStringKeys(in directory: URL) throws -> Set<String> {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        var keys = Set<String>()

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            let source = try String(contentsOf: fileURL, encoding: .utf8)
            keys.formUnion(matches(in: source, pattern: #"@AppStorage\s*\(\s*"([^"]+)""#))
        }

        return keys
    }

    private func matches(in source: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Ungueltiges Regex-Pattern: \(pattern)")
            return []
        }

        let nsSource = source as NSString
        return regex.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        ).compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            return nsSource.substring(with: match.range(at: 1))
        }
    }
}
