import SwiftUI
import KeyboardShortcuts

@main
struct WhisperM8App: App {
    @State private var appState = AppState()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    init() {
        setupHotkeys()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)

        // Settings Window
        Window("WhisperM8 Einstellungen", id: "settings") {
            SettingsView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Onboarding window
        Window("WhisperM8 Setup", id: "onboarding") {
            OnboardingView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func setupHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [self] in
            Task { @MainActor in
                await appState.startRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [self] in
            Task { @MainActor in
                await appState.stopRecording()
            }
        }
    }
}

// MARK: - KeyboardShortcuts Extension

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}
