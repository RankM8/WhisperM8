import Foundation

// MARK: - Einstellungen des Zwischenablage-Verlaufs

/// Schlüssel liegen bewusst hier und nicht in `PreferenceKeys`: das Feature
/// ist in sich geschlossen, und die CLI liest sie über die App-Domain.
/// Jeder Schlüssel hat einen Schalter auf der Seite „Clipboard“ der
/// Einstellungen (Pause zusätzlich in der Menüleiste).
enum ClipboardPreferenceKeys {
    /// Hauptschalter und Notbremse zugleich:
    /// `defaults write com.whisperm8.app clipboardHistoryEnabled -bool NO`
    static let enabled = "clipboardHistoryEnabled"
    static let paused = "clipboardHistoryPaused"
    static let maxItems = "clipboardHistoryMaxItems"
    static let autoPaste = "clipboardHistoryAutoPaste"
    static let windowPosition = "clipboardHistoryWindowPosition"
    static let excludedApps = "clipboardHistoryExcludedApps"
    static let agentAccess = "clipboardHistoryAgentAccess"
    static let maskSecrets = "clipboardHistoryMaskSecrets"
    static let clearOnQuit = "clipboardHistoryClearOnQuit"
}

enum ClipboardWindowPosition: String, CaseIterable, Sendable {
    case cursor
    case center
}

/// Gelesene Werte; Standardwerte stehen an genau einer Stelle.
struct ClipboardSettings: Equatable, Sendable {
    var enabled = false
    var paused = false
    var maxItems = 200
    var autoPaste = true
    var windowPosition: ClipboardWindowPosition = .cursor
    var excludedApps: [String] = ClipboardSettings.defaultExcludedApps
    var agentAccess = true
    var maskSecrets = true
    var clearOnQuit = false

    static let maxItemsRange = 20...2000
    static let hotkeyDefaultDescription = "⇧⌘C"

    /// Passwort-Manager und ähnliche Apps, deren Kopien nie in den Verlauf sollen.
    static let defaultExcludedApps: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "org.keepassxc.keepassxc",
        "org.keepassx.keepassxc",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop",
        "com.nordsec.nordpass",
        "com.proton.pass.macos",
    ]

    /// Liest aus beliebiger Quelle (App: Defaults, CLI: App-Domain, Tests: Wörterbuch).
    static func read(_ value: (String) -> Any?) -> ClipboardSettings {
        var settings = ClipboardSettings()
        if let v = value(ClipboardPreferenceKeys.enabled) as? Bool { settings.enabled = v }
        if let v = value(ClipboardPreferenceKeys.paused) as? Bool { settings.paused = v }
        if let v = value(ClipboardPreferenceKeys.maxItems) as? Int {
            settings.maxItems = min(max(v, maxItemsRange.lowerBound), maxItemsRange.upperBound)
        }
        if let v = value(ClipboardPreferenceKeys.autoPaste) as? Bool { settings.autoPaste = v }
        if let raw = value(ClipboardPreferenceKeys.windowPosition) as? String,
           let v = ClipboardWindowPosition(rawValue: raw) { settings.windowPosition = v }
        if let raw = value(ClipboardPreferenceKeys.excludedApps) as? String {
            settings.excludedApps = decodeApps(raw)
        }
        if let v = value(ClipboardPreferenceKeys.agentAccess) as? Bool { settings.agentAccess = v }
        if let v = value(ClipboardPreferenceKeys.maskSecrets) as? Bool { settings.maskSecrets = v }
        if let v = value(ClipboardPreferenceKeys.clearOnQuit) as? Bool { settings.clearOnQuit = v }
        return settings
    }

    /// Aus der echten App-Domain (auch aus der CLI heraus).
    static func readLive() -> ClipboardSettings {
        read { CFPreferencesCopyAppValue($0 as CFString, AppInstance.defaultsDomain as CFString) }
    }

    // MARK: Liste der ausgeschlossenen Apps (als JSON-Text in einem Schlüssel)

    static func encodeApps(_ apps: [String]) -> String {
        guard let data = try? JSONEncoder().encode(apps) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeApps(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let apps = try? JSONDecoder().decode([String].self, from: data) else {
            return defaultExcludedApps
        }
        return apps
    }

    static var defaultExcludedAppsJSON: String { encodeApps(defaultExcludedApps) }

    static let disabledMessage =
        "Der Zwischenablage-Verlauf ist aus (Einstellungen, Seite Clipboard, oder defaults write com.whisperm8.app clipboardHistoryEnabled -bool YES)."
    static let agentAccessDeniedMessage =
        "Agents dürfen den Zwischenablage-Verlauf nicht lesen (Einstellungen, Seite Clipboard, Schalter „Let agents read the history“)."
}
