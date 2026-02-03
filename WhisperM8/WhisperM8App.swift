import SwiftUI
import KeyboardShortcuts

@main
struct WhisperM8App: App {
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    init() {
        // Single instance check - quit if already running
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if runningApps.count > 1 {
            // Another instance is already running - activate it and quit this one
            for app in runningApps where app != NSRunningApplication.current {
                app.activate(options: .activateIgnoringOtherApps)
            }
            NSApp.terminate(nil)
        }

        setupHotkeys()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(AppState.shared)
        } label: {
            Image(systemName: AppState.shared.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)

        // Settings Window
        Window("WhisperM8 Einstellungen", id: "settings") {
            SettingsView()
                .environment(AppState.shared)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Onboarding window
        Window("WhisperM8 Setup", id: "onboarding") {
            OnboardingView()
                .environment(AppState.shared)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func setupHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
            Task { @MainActor in
                await AppState.shared.startRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            Task { @MainActor in
                await AppState.shared.stopRecording()
            }
        }
    }
}

// MARK: - KeyboardShortcuts Extension

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}
