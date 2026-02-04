import SwiftUI
import KeyboardShortcuts
import UserNotifications

@main
struct WhisperM8App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Single instance check - quit if already running
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if runningApps.count > 1 {
            // Another instance is already running - activate it and quit this one
            for app in runningApps where app != NSRunningApplication.current {
                app.activate()
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
            MenuBarIcon()
        }
        .menuBarExtraStyle(.menu)

        // Settings Window
        Window("Settings", id: "settings") {
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions for error alerts
        requestNotificationPermission()

        // Check if onboarding needs to be shown
        let onboardingCompleted = UserDefaults.standard.bool(forKey: "onboardingCompleted")

        if !onboardingCompleted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showOnboardingWindow()
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Logger.transcription.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    private func showOnboardingWindow() {
        let onboardingView = OnboardingView()
            .environment(AppState.shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperM8 Setup"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false

        self.onboardingWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Menu Bar Icon

struct MenuBarIcon: View {
    @State private var appState = AppState.shared

    var body: some View {
        if appState.isRecording {
            // Recording: show red dot
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
        } else if appState.isTranscribing {
            // Transcribing: show spinner
            Image(systemName: "ellipsis.circle")
        } else {
            // Ready: show logo
            if let imageURL = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
               let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "mic")
            }
        }
    }
}

// MARK: - KeyboardShortcuts Extension

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}
