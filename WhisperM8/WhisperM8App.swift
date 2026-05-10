import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin
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
            WindowRequestCenter.notifyRunningInstanceToOpenAgentChats()
            NSApp.terminate(nil)
        }

        setupHotkeys()
    }

    var body: some Scene {
        // Agent-Chats ist die Hauptansicht der App und das erste Window in
        // dieser Scene-Liste — SwiftUI öffnet das oberste Window beim
        // Launch, es sei denn der AppDelegate routet was anderes (Onboarding).
        Window("Agent Chats", id: "agent-chats") {
            AgentChatsView()
        }
        .defaultSize(width: 1100, height: 720)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarView()
                .environment(AppState.shared)
        } label: {
            MenuBarIcon()
                .environment(AppState.shared)
                .background(WindowRequestHandler())
        }
        .menuBarExtraStyle(.menu)

        // Settings-/Control-Center-Window — manuell geöffnet via Menubar oder
        // Cmd+, , nicht mehr Default-Startansicht.
        Window("WhisperM8", id: "settings") {
            SettingsView()
                .environment(AppState.shared)
        }
        .defaultSize(width: 900, height: 640)
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions for error alerts
        requestNotificationPermission()

        // Routing: Onboarding wenn nötig, sonst Agent-Chats als Default-Hub.
        // Settings ist nicht mehr die Default-Startansicht — es wird nur noch
        // explizit über Menubar oder Cmd+, geöffnet.
        if !AppPreferences.shared.onboardingCompleted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WindowRequestCenter.shared.request(.onboarding)
            }
        } else if !LaunchAtLogin.wasLaunchedAtLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WindowRequestCenter.shared.request(.agentChats)
            }
        }
    }

    /// Re-Activate (Klick auf Dock-Icon, wenn die App schon läuft). Wir öffnen
    /// das Agent-Chats-Window — sei es weil alle Windows zu sind oder weil
    /// der User explizit zur Hauptansicht zurück will.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowRequestCenter.shared.request(.agentChats)
        return true
    }

    /// Halten der App am Leben, wenn der User das letzte Window schließt —
    /// die Menubar-Funktionen (Hotkey-Recording, Output-Modes) sollen weiter
    /// funktionieren, auch ohne offenes Hauptfenster.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Logger.transcription.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Menu Bar Icon

struct MenuBarIcon: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.isRecording {
            // Recording: show red dot
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
        } else if appState.isTranscribing {
            // Transcribing: show spinner
            Image(systemName: "ellipsis.circle")
        } else {
            // Ready: show logo as template (auto white/black based on theme)
            if let imageURL = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
               let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: makeTemplate(image))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "mic")
            }
        }
    }

    private func makeTemplate(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        return image
    }
}

// MARK: - KeyboardShortcuts Extension

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}
