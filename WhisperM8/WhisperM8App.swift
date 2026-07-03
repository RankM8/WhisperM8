import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin
import UserNotifications
import AVFoundation
import ApplicationServices

// `@main` liegt bewusst NICHT hier, sondern auf `WhisperM8EntryPoint`
// (CLI/CLIEntryPoint.swift): das Binary multiplext zwischen CLI- und GUI-Modus.
// `WhisperM8App.main()` wird vom Dispatcher für den GUI-Pfad aufgerufen.
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
        // Agent-Chats-Primaerfenster: bewusst eine Single-`Window`-Scene als
        // ERSTE Scene. SwiftUI oeffnet sie beim Launch automatisch (sofern der
        // AppDelegate nicht Onboarding routet) — und eine `Window`-Scene kann
        // sich, anders als eine WindowGroup, niemals duplizieren. Das war die
        // Ursache des Doppelfenster-Bugs beim Wechsel auf Multi-Window.
        Window("Agent Chats", id: WindowRequest.agentChats.targetWindowID) {
            AgentChatsPrimaryWindowRoot()
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
                Button("Output & History") {
                    WindowRequestCenter.shared.request(.settingsOutput)
                }
                Button("Settings") {
                    WindowRequestCenter.shared.request(.settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        // Agent-Chats-Sekundaerfenster (abgeloeste Tabs). Als NICHT-erste
        // Scene oeffnet SwiftUI hier beim Launch KEIN Fenster automatisch —
        // ein Sekundaerfenster entsteht nur durch openWindow(id:value:) aus
        // dem Detach- bzw. Restore-Pfad.
        WindowGroup("Agent Chat Window", id: WindowRequest.agentChatWindowGroupID, for: UUID.self) { $windowID in
            AgentChatsSecondaryWindowRoot(windowID: $windowID)
                .preferredColorScheme(themeManager.override.preferredColorScheme)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)

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

/// Root des Primaerfensters. Loest die primaryWindowID einmalig auf — bewusst
/// OHNE Binding: die `Window`-Scene hat keinen praesentierten Wert, und genau
/// das fruehere Zurueckschreiben eines nil→UUID-Bindings einer WindowGroup
/// erzeugte das Doppelfenster.
private struct AgentChatsPrimaryWindowRoot: View {
    @State private var windowID: UUID?
    @State private var didEvaluateGate = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let windowID {
                AgentChatsView(windowID: windowID)
            } else {
                // Kein sichtbarer ProgressView, bis das Profil-Gate entschieden hat —
                // in Menüleisten-Profilen soll hier gar kein Fenster aufblitzen.
                Color.clear
                    .frame(minWidth: 1, minHeight: 1)
                    .task { resolveIfNeeded() }
            }
        }
    }

    @MainActor
    private func resolveIfNeeded() {
        guard !didEvaluateGate else { return }
        didEvaluateGate = true

        // Menüleisten-Profile (Dictation-only / Enrichment): das automatisch geöffnete
        // Primärfenster nicht anzeigen. Ein expliziter `.agentChats`-Request gibt es via
        // `allowsAgentChatsPrimaryWindow` frei (Menüleiste, Profilwechsel).
        guard WindowRequestCenter.shared.allowsAgentChatsPrimaryWindow else {
            dismiss()
            return
        }

        // Live aus dem Store (Single Source of Truth), nicht von Platte —
        // sonst koennte eine noch nicht geschriebene primaryWindowID divergieren.
        windowID = AgentWindowStore.shared.primaryWindowID
    }
}

/// Root eines Sekundaerfensters (abgeloester Tab). Bekommt seine ID als
/// praesentierten WindowGroup-Wert. Kommt ausnahmsweise kein Wert an (etwa ein
/// leeres Auto-Fenster), schliesst es sich selbst, statt das Primaerfenster zu
/// duplizieren.
private struct AgentChatsSecondaryWindowRoot: View {
    @Binding var windowID: UUID?
    @State private var resolvedWindowID: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let resolvedWindowID {
                AgentChatsView(windowID: resolvedWindowID)
            } else {
                ProgressView()
                    .frame(minWidth: 640, minHeight: 420)
                    .task { resolveIfNeeded() }
            }
        }
    }

    @MainActor
    private func resolveIfNeeded() {
        guard resolvedWindowID == nil else { return }
        // Nur Fenster aufbauen, die der Store wirklich kennt. Ein Sekundaer-
        // fenster ohne ID oder ohne Store-Eintrag ist ein verwaistes Restore-
        // Artefakt (oder ein leeres Auto-Fenster) → sofort schliessen, statt
        // ein Geister-/Duplikat-Fenster zu rendern.
        guard let id = windowID, AgentWindowStore.shared.hasWindow(id) else {
            dismiss()
            return
        }
        resolvedWindowID = id
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Onboarding nötig, wenn eine der zwei essenziellen System-Permissions
    /// (Mikrofon + Accessibility) fehlt. Bewusst permission-basiert statt Flag —
    /// siehe Kommentar in `applicationDidFinishLaunching`.
    private var needsOnboarding: Bool {
        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibilityGranted = AXIsProcessTrusted()
        return !micGranted || !accessibilityGranted
    }

    /// Aktivierungs-Policy so früh wie möglich setzen (vor dem ersten Fenster), damit
    /// Menüleisten-Profile ohne Dock-Icon-Flackern starten. Während des Onboardings und
    /// im Voll-Profil bleibt es eine reguläre Dock-App.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Onboarding immer als reguläre App (fokussierbares Setup-Fenster). Sonst richtet
        // sich die Policy nach dem Profil: Voll = Dock-App, sonst reine Menüleisten-App.
        let wantsDock = needsOnboarding || AppPreferences.shared.usageProfile.wantsAgentChats
        NSApp.setActivationPolicy(wantsDock ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent-Notifications: Delegate VOR der Permission-Anfrage setzen,
        // damit Banner auch im Vordergrund erscheinen und Klicks zum
        // richtigen Chat routen (siehe UNUserNotificationCenterDelegate unten).
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermission()

        // Update-Check gegen GitHub Releases (verzögert + alle 24 h). Zeigt
        // nur ein Footer-Badge mit dem brew-Befehl — kein Selbst-Update.
        Task { @MainActor in
            AppUpdateChecker.shared.scheduleAutomaticChecks()
        }

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

        // CLI-Symlink (~/.local/bin/whisperm8) idempotent anlegen, damit
        // `whisperm8 transcribe …` aus Claude Code / Terminal sofort verfügbar
        // ist und denselben Keychain-Eintrag wie die App nutzt.
        Task.detached(priority: .background) {
            CLISymlinkInstaller.installIfNeeded()
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
        if needsOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WindowRequestCenter.shared.request(.onboarding)
            }
        }
    }

    /// Re-Activate (Klick auf Dock-Icon, wenn die App schon läuft). Nur wenn
    /// KEIN sichtbares Fenster mehr offen ist, oeffnen wir das Primaerfenster
    /// neu. Sind bereits Fenster da (`flag == true`), bringt AppKit die App
    /// selbst nach vorn — ein zusaetzliches openWindow wuerde sonst ein
    /// Duplikat des Primaerfensters erzeugen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Nur im Voll-Profil das Agent-Chats-Primärfenster auf Reopen neu öffnen.
        // Menüleisten-Profile haben ohnehin kein Dock-Icon; Agent Chats bleibt dort ein
        // bewusster, manueller Aufruf über die Menüleiste.
        if !flag && AppPreferences.shared.usageProfile.wantsAgentChats {
            WindowRequestCenter.shared.request(.agentChats)
        }
        return true
    }

    /// Halten der App am Leben, wenn der User das letzte Window schließt —
    /// die Menubar-Funktionen (Hotkey-Recording, Output-Modes) sollen weiter
    /// funktionieren, auch ohne offenes Hauptfenster.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Quit-Erkennung fuers Fenster-Close-Tracking: Beim Terminate raeumt
    /// AppKit alle Fenster ab — ob deren `willClose` dabei feuert, ist
    /// versionsabhaengig undokumentiert. Das Suspend-Flag wird hier gesetzt,
    /// weil `applicationShouldTerminate` der FRUEHESTE Terminate-Hook ist
    /// (vor jedem Fenster-Teardown): Quit-Closes duerfen die Sekundaerfenster
    /// nicht aus dem Store werfen, sonst waere der Launch-Restore nach jedem
    /// Neustart leer. Nie zurueckgenommen — der Prozess endet.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AgentWindowStore.shared.suspendCloseTracking() }
        return .terminateNow
    }

    /// Sicherheitsnetz: Falls die App waehrend einer aktiven Ducking-Session
    /// beendet wird (Cmd+Q oder System-Shutdown), Volume sofort zurueckstellen
    /// — sonst bleibt das System-Audio leise bis manueller Slider-Eingriff.
    func applicationWillTerminate(_ notification: Notification) {
        AudioDuckingManager.shared.endCaptureImmediate()
        // Letzten (debounced) Fenster-/Tab-State noch festschreiben.
        MainActor.assumeIsolated { AgentWindowStore.shared.flush() }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Logger.transcription.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Agent-Notifications (Stop-/Rückfrage-Banner + Klick-Routing)

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Banner auch zeigen, wenn WhisperM8 im Vordergrund ist — bewusst so
    /// gewollt: der User arbeitet oft in einem anderen Chat/Fenster derselben
    /// App, während ein Agent fertig wird.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Klick auf die Notification → zugehörigen Chat fokussieren (richtiges
    /// Fenster + Tab, siehe `WindowRequestCenter.requestSessionFocus`).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let raw = userInfo[UNAgentUserNotificationPoster.localSessionIDUserInfoKey] as? String,
           let sessionID = UUID(uuidString: raw) {
            Task { @MainActor in
                WindowRequestCenter.shared.requestSessionFocus(sessionID: sessionID)
            }
        }
        completionHandler()
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
