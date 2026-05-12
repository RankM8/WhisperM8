import Foundation
import SwiftUI

/// Schreibt den Claude-Code-Theme-Key in `~/.claude.json` synchron mit unserem
/// `ThemeManager`. Damit folgt Claude Codes interne Render-Palette dem
/// macOS-Theme bzw. dem User-Override aus WhisperM8.
///
/// **Wichtige Eigenheiten** (siehe Recherche-Notizen):
///
/// 1. **Datei: `~/.claude.json`, nicht `settings.json`** — Anthropic hat
///    Issue #6962 als "not planned" geschlossen; der `/theme`-Command
///    persistiert in den Runtime-State, der auch OAuth-Tokens, MCP-Server
///    und Projekt-State enthält. Wir mutieren NUR den `theme`-Key.
/// 2. **Anthropic schreibt parallel ohne Locking** (Issue-Cluster #28847,
///    #28922, #29217). Wir lesen → mutieren → atomar via `replaceItemAt`
///    schreiben. Bei Parse-Fehler **niemals überschreiben** — die Datei
///    ist dann gerade mid-write von Claude.
/// 3. **POSIX 0600** der bestehenden Datei beibehalten (sie enthält
///    OAuth-Tokens).
/// 4. **Idempotent**: wenn `theme` schon den Zielwert hat, kein Write.
/// 5. **Debounced**: schnelle Theme-Toggles erzeugen nur einen Write.
/// 6. **One-time `.bak`** im App-Support-Verzeichnis, bevor wir das erste
///    Mal schreiben.
@MainActor
final class ClaudeThemeWriter {
    static let shared = ClaudeThemeWriter()

    /// Mapping ColorScheme → von Claude akzeptierter Theme-String.
    ///
    /// **Dark** → `dark-ansi`: lässt Claude die Host-(SwiftTerm-)Palette
    /// verwenden. Funktioniert gut, weil unsere Dark-Palette eine
    /// klassische ANSI-Farbtabelle ist und Claude's UI-Chrome auf dunklem
    /// Background sauber rendert.
    ///
    /// **Light** → `light`: nutzt Claude's eigene Light-Theme-Farben für
    /// Input-Box, Status-Pills und Highlights. `light-ansi` führte dazu,
    /// dass Claude für UI-Chrome ANSI-Indizes verwendet, die in jeder
    /// Light-Palette zwangsläufig dunkel rendern (z. B. inverse Video
    /// gegen den hellen Background → schwarzer Balken). Mit `light`
    /// rendert Claude die Chrome-Elemente in den vorgesehenen hellen
    /// Grautönen — das ist das Verhalten, das der User in iTerm sieht.
    nonisolated static func claudeThemeName(for scheme: ColorScheme) -> String {
        switch scheme {
        case .light: return "light"
        default:     return "dark-ansi"
        }
    }

    private let claudeStateURL: URL
    private let backupURL: URL
    private var pendingWorkItem: DispatchWorkItem?
    private let writeQueue = DispatchQueue(label: "com.whisperm8.app.claude-theme-writer", qos: .utility)
    private var hasCreatedInitialBackup = false

    init(
        claudeStateURL: URL? = nil,
        backupURL: URL? = nil
    ) {
        self.claudeStateURL = claudeStateURL ?? ClaudeThemeWriter.defaultClaudeStateURL()
        self.backupURL = backupURL ?? ClaudeThemeWriter.defaultBackupURL()
    }

    /// Debounced Aufruf vom ThemeManager. Mehrere Aufrufe innerhalb
    /// `debounceSeconds` werden zu einem Write koalesziert.
    func syncIfNeeded(scheme: ColorScheme, debounceSeconds: TimeInterval = 0.5) {
        let target = Self.claudeThemeName(for: scheme)
        pendingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performWrite(target: target)
        }
        pendingWorkItem = item
        writeQueue.asyncAfter(deadline: .now() + debounceSeconds, execute: item)
    }

    // MARK: - Atomic merge

    private func performWrite(target: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeStateURL.path) else {
            // Frischer User ohne Claude-Code-Login: kein File, kein Schreiben.
            Logger.agentPerformance.debug("claude_theme_write_skipped reason=no_state_file")
            return
        }

        guard let data = try? Data(contentsOf: claudeStateURL) else {
            Logger.agentPerformance.warning("claude_theme_write_skipped reason=read_failed")
            return
        }

        // Strict JSON. Bei Parse-Fehler: Datei ist gerade mid-write von
        // Claude (Anthropic-Bug, kein File-Lock). Niemals überschreiben.
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              var json = obj as? [String: Any] else {
            Logger.agentPerformance.warning("claude_theme_write_skipped reason=parse_failed bytes=\(data.count)")
            return
        }

        if let current = json["theme"] as? String, current == target {
            // Schon korrekt — kein churn-Write.
            return
        }

        // Einmaliges Backup, bevor wir das erste Mal mutieren.
        if !hasCreatedInitialBackup {
            createInitialBackupIfNeeded(originalData: data)
            hasCreatedInitialBackup = true
        }

        json["theme"] = target

        guard let outData = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            Logger.agentPerformance.warning("claude_theme_write_skipped reason=serialize_failed")
            return
        }

        // Original-POSIX-Permissions ermitteln (0600 mit OAuth-Tokens).
        let originalPermissions = (try? fm.attributesOfItem(atPath: claudeStateURL.path))?[.posixPermissions] as? NSNumber

        // Temp-File im selben Verzeichnis → echter rename(2), kein Cross-FS-Copy.
        let directory = claudeStateURL.deletingLastPathComponent()
        let tmpURL = directory.appendingPathComponent(".claude.json.tmp.\(UUID().uuidString)")
        do {
            try outData.write(to: tmpURL, options: .atomic)
            if let perms = originalPermissions {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmpURL.path)
            }
            _ = try fm.replaceItemAt(claudeStateURL, withItemAt: tmpURL)
            Logger.agentPerformance.info("claude_theme_written target=\(target, privacy: .public)")
        } catch {
            try? fm.removeItem(at: tmpURL)
            Logger.agentPerformance.warning("claude_theme_write_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func createInitialBackupIfNeeded(originalData: Data) {
        let fm = FileManager.default
        // Nur einmal pro App-Lifetime. Wenn Backup schon existiert, skip.
        if fm.fileExists(atPath: backupURL.path) { return }
        do {
            try fm.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try originalData.write(to: backupURL, options: .atomic)
            Logger.agentPerformance.info("claude_theme_backup_created path=\(self.backupURL.path, privacy: .public)")
        } catch {
            Logger.agentPerformance.warning("claude_theme_backup_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Default paths

    nonisolated private static func defaultClaudeStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    nonisolated private static func defaultBackupURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("claude-state-pre-theme-sync.json")
    }
}
