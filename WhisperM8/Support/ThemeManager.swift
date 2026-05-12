import AppKit
import Combine
import SwiftUI

/// Single Source of Truth für das aktuell aufgelöste Theme. Beobachtet
/// `NSApp.effectiveAppearance` (wenn der User auf „System" steht) und den
/// persisted `AppearanceOverride`. Views binden sich via `@StateObject` /
/// `@ObservedObject` und rendern bei Wechsel sofort neu.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    /// User-gewählter Override. `system` (default) folgt macOS.
    @Published var override: AppearanceOverride

    /// Das aktuell aufgelöste Color-Scheme — d. h. was Views jetzt rendern
    /// sollen. `light` wenn `override == .light` oder macOS hell ist;
    /// `dark` analog. Wird bei jedem Override- oder System-Wechsel neu
    /// berechnet.
    @Published private(set) var resolvedColorScheme: ColorScheme = .dark

    private var appearanceObserver: NSKeyValueObservation?

    private init() {
        // Persisted Override aus AppPreferences laden.
        let stored = AppPreferences.shared.appearanceOverride
        self.override = stored
        // Initial-Auflösung anhand des aktuellen NSApp-Appearance.
        self.resolvedColorScheme = Self.resolve(
            override: stored,
            systemAppearance: NSApp?.effectiveAppearance
        )
        // Initial NSApp.appearance setzen, damit AppKit-Sub-Views (Menubar,
        // RecordingPanel) gleich beim Start passen.
        if let nsAppearance = stored.nsAppearance {
            NSApp?.appearance = nsAppearance
        }

        // KVO auf NSApp.effectiveAppearance — feuert wenn der User in
        // macOS-Settings das Erscheinungsbild ändert (oder bei Auto-Modus
        // Sonnenuntergang).
        if let app = NSApp {
            appearanceObserver = app.observe(
                \.effectiveAppearance,
                options: [.new]
            ) { [weak self] _, change in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.recompute(systemAppearance: change.newValue)
                }
            }
        }
    }

    /// Wird vom Settings-Picker aufgerufen. Persistiert + rechnet neu.
    func setOverride(_ value: AppearanceOverride) {
        guard value != override else { return }
        override = value
        AppPreferences.shared.appearanceOverride = value
        // Globale AppKit-Appearance anpassen — `.preferredColorScheme` auf
        // den Scenes deckt nur Windows ab. NSPanel / MenuBarExtra erben
        // sonst nicht.
        NSApp?.appearance = value.nsAppearance
        recompute(systemAppearance: NSApp?.effectiveAppearance)
    }

    private func recompute(systemAppearance: NSAppearance?) {
        let scheme = Self.resolve(override: override, systemAppearance: systemAppearance)
        if scheme != resolvedColorScheme {
            resolvedColorScheme = scheme
            // Subscriber außerhalb des SwiftUI-Reaktivitätsbaums (z. B.
            // AgentTerminalController, der ein NSView verwaltet) bekommen
            // den Schema-Wechsel via Notification — Color-Bindings allein
            // updaten ein NSViewRepresentable nicht.
            NotificationCenter.default.post(
                name: Notification.Name("AgentTerminalController.themeDidChange"),
                object: nil,
                userInfo: ["scheme": scheme]
            )
            // Claude-Code-Theme synchron halten (`~/.claude.json`),
            // debounced — schnelle Toggles erzeugen nur einen Write.
            ClaudeThemeWriter.shared.syncIfNeeded(scheme: scheme)
        }
    }

    /// Vom App-Start einmalig aufgerufen: stellt sicher, dass `~/.claude.json`
    /// beim ersten Launch zum aktuellen Theme passt, auch wenn das Schema
    /// noch nie geändert wurde.
    func performInitialClaudeThemeSync() {
        ClaudeThemeWriter.shared.syncIfNeeded(scheme: resolvedColorScheme, debounceSeconds: 0.2)
    }

    /// Reine Auflösungs-Funktion — testbar ohne NSApp.
    nonisolated static func resolve(override: AppearanceOverride, systemAppearance: NSAppearance?) -> ColorScheme {
        switch override {
        case .light: return .light
        case .dark: return .dark
        case .system:
            // `bestMatch` gegen [.aqua, .darkAqua] gibt uns „was rendert
            // gerade tatsächlich". Funktioniert auch wenn der User in
            // macOS-Settings auf „Auto" steht (dann ist effectiveAppearance
            // mal Aqua, mal DarkAqua je nach Tageszeit).
            guard let appearance = systemAppearance else { return .dark }
            let best = appearance.bestMatch(from: [.aqua, .darkAqua])
            return best == .darkAqua ? .dark : .light
        }
    }
}
