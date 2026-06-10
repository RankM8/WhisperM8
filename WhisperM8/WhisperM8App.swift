import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin
import UserNotifications
import AVFoundation
import ApplicationServices

@main
struct WhisperM8App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var themeManager = ThemeManager.shared

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
                .preferredColorScheme(themeManager.override.preferredColorScheme)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("WhisperM8") {
                Button("Agent Chats") {
                    WindowRequestCenter.shared.request(.agentChats)
                }
                Button("Output & Templates") {
                    WindowRequestCenter.shared.request(.outputDashboard)
                }
                Button("Settings") {
                    WindowRequestCenter.shared.request(.settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(AppState.shared)
                .preferredColorScheme(themeManager.override.preferredColorScheme)
        } label: {
            MenuBarIcon()
                .environment(AppState.shared)
                .background(AppWindowRequestHost())
        }
        .menuBarExtraStyle(.menu)

        // Settings-/Control-Center-Window — manuell geöffnet via Menubar oder
        // Cmd+, , nicht mehr Default-Startansicht.
        Window("WhisperM8", id: "settings") {
            SettingsView()
                .environment(AppState.shared)
                .preferredColorScheme(themeManager.override.preferredColorScheme)
        }
        .defaultSize(width: 900, height: 640)
        .defaultPosition(.center)

        // P8: Reports-Dashboard (Transcript-Run-Reports). War fertig gebaut,
        // aber nirgends instanziiert — der Menü-Eintrag landete bisher in
        // den Settings statt im Dashboard.
        Window("Output Reports", id: "output-dashboard") {
            OutputDashboardView()
                .environment(AppState.shared)
                .preferredColorScheme(themeManager.override.preferredColorScheme)
        }
        .defaultSize(width: 980, height: 680)
        .defaultPosition(.center)

        // Onboarding window
        Window("WhisperM8 Setup", id: "onboarding") {
            OnboardingView()
                .environment(AppState.shared)
                .preferredColorScheme(themeManager.override.preferredColorScheme)
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

        // Claude-Code-Theme einmalig synchron mit unserem aufgelösten
        // Color-Scheme — falls der User WhisperM8 nach einem manuellen
        // `/theme dark` in Claude öffnet, ziehen wir das passend nach.
        Task { @MainActor in
            ThemeManager.shared.performInitialClaudeThemeSync()
        }

        // Retention: verwaiste Snapshot- und Hook-Files raeumen. Wird nicht
        // im UI-Thread blockierend — schreibt nur Logs.
        Task.detached(priority: .background) {
            let workspace = AgentSessionStore().loadWorkspace()
            let liveIDs = Set(workspace.sessions.map(\.id))
            _ = AgentSessionRetentionService().prune(liveLocalSessionIDs: liveIDs)
        }

        // Sessions-Scan automatisch: einmal direkt beim Launch, danach bei
        // jeder Foreground-Reaktivierung (mit 30 s Cooldown). Der ScanCoordinator
        // installiert seinen eigenen `didBecomeActive`-Observer.
        AgentScanCoordinator.shared.installLifecycleHooks()
        AgentScanCoordinator.shared.requestScan(reason: .launch)
        // P2: FSEvents auf ~/.claude/projects + ~/.codex/sessions — extern
        // gestartete Sessions tauchen damit nach Sekunden auf statt erst beim
        // nächsten Foreground-Scan.
        AgentDirectoryEventMonitor.shared.start()

        // Routing: Onboarding nur, wenn die zwei essenziellen System-Permissions
        // (Mikrofon + Accessibility) noch nicht erteilt sind. Ohne diese ist die
        // App funktional kaputt — alles andere kann der User aus den Settings
        // heraus konfigurieren. Den alten `onboardingCompleted`-Flag-Pfad haben
        // wir bewusst aufgegeben, weil er nur durch den "Done"-Button gesetzt
        // wurde und beim Schließen des Wizards stehen blieb → Auto-Onboarding
        // beim nächsten Launch, auch wenn das Setup faktisch abgeschlossen war.
        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibilityGranted = AXIsProcessTrusted()
        let needsOnboarding = !micGranted || !accessibilityGranted

        if needsOnboarding {
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

    /// Sicherheitsnetz: Falls die App waehrend einer aktiven Ducking-Session
    /// beendet wird (Cmd+Q oder System-Shutdown), Volume sofort zurueckstellen
    /// — sonst bleibt das System-Audio leise bis manueller Slider-Eingriff.
    func applicationWillTerminate(_ notification: Notification) {
        AudioDuckingManager.shared.endCaptureImmediate()
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
