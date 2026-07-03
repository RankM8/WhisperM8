import SwiftUI
import UserNotifications

/// Settings-Bereich für die Claude-Code-Integration: Hook-Status + Master-
/// Schalter, Legende der Sidebar-Indikatoren, Notifications (Stop +
/// Rückfragen) mit Test-Button, Fertig-Ton mit Sound-Picker, Erkennung
/// konkurrierender User-Hooks und eine transparente Vorschau der erzeugten
/// Hook-Settings. UX-Muster analog zur „CLI & Skill"-Seite.
struct ClaudeCodeSettingsView: View {
    @AppStorage(PreferenceKeys.claudeHooksEnabled) private var hooksEnabled = true
    @AppStorage(PreferenceKeys.agentStopNotificationEnabled) private var stopNotificationEnabled = true
    @AppStorage(PreferenceKeys.agentAwaitingNotificationEnabled) private var awaitingNotificationEnabled = true
    @AppStorage(PreferenceKeys.agentStopSoundEnabled) private var stopSoundEnabled = true
    @AppStorage(PreferenceKeys.agentStopSoundName) private var stopSoundName = SystemSoundCatalog.fallbackSoundName

    @State private var notificationAuthStatus: UNAuthorizationStatus?
    @State private var availableSounds: [String] = []
    @State private var externalHookFindings: [ExternalClaudeHooksInspector.Finding] = []
    @State private var isExplainerExpanded = false
    @State private var hookSettingsPreview: String = ""
    @State private var feedback: String?

    var body: some View {
        Form {
            liveStatusSection
            notificationSection
            soundSection
            if !externalHookFindings.isEmpty {
                externalHooksSection
            }
            explainerSection
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    // MARK: - Live-Status

    private var liveStatusSection: some View {
        Section("Live-Status") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: hooksEnabled ? "checkmark.circle.fill" : "bolt.slash.circle")
                    .foregroundStyle(hooksEnabled ? .green : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hooksEnabled ? "Session-Hooks aktiv" : "Session-Hooks deaktiviert")
                        .font(.headline)
                    Text(hooksEnabled
                        ? "Jeder Claude-Chat wird mit einer temporären Hook-Konfiguration gestartet — Status, Rückfragen und Turn-Enden kommen in Echtzeit. Deine globale ~/.claude/settings.json bleibt unangetastet."
                        : "Chats starten ohne Hook-Bridge. Der Status kommt nur noch aus dem Transkript (gröber, keine Rückfrage-Erkennung, keine Notifications).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Session-Hooks verwenden", isOn: $hooksEnabled)
            Text("Gilt für neu gestartete Chats. Laufende Sessions behalten ihre aktuelle Konfiguration bis zum Neustart des Chats.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                legendRow(status: .working, text: "Arbeitet — ein Turn läuft (Prompt gesendet, Tools laufen)")
                legendRow(status: .awaitingInput, text: "Wartet auf dich — Berechtigung, Frage oder Plan-Freigabe")
                legendRow(status: .idle, text: "Bereit — Chat offen, kein Turn aktiv (auch direkt nach dem Start)")
            }
            .padding(.vertical, 2)
        }
    }

    private func legendRow(status: AgentSessionRuntimeStatus, text: String) -> some View {
        HStack(spacing: 10) {
            AgentStatusIndicator(status: status)
                .frame(width: 14)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Benachrichtigungen

    private var notificationSection: some View {
        Section("Benachrichtigungen") {
            if notificationAuthStatus == .denied {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("macOS-Mitteilungen sind für WhisperM8 deaktiviert.")
                        .font(.caption)
                    Spacer()
                    Button("Systemeinstellungen öffnen") {
                        openNotificationSystemSettings()
                    }
                }
            }

            Toggle("Wenn ein Agent fertig ist", isOn: $stopNotificationEnabled)
            Toggle("Bei Rückfragen (Berechtigung, Frage, Plan-Freigabe)", isOn: $awaitingNotificationEnabled)

            HStack(spacing: 8) {
                Button {
                    sendTestNotification()
                } label: {
                    Label("Test-Notification senden", systemImage: "bell.badge")
                }
                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            Text("Banner erscheinen auch, wenn WhisperM8 im Vordergrund ist. Ein Klick auf die Notification öffnet den betreffenden Chat im richtigen Fenster und Tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ton

    private var soundSection: some View {
        Section("Ton") {
            Toggle("Ton, wenn ein Agent fertig ist", isOn: $stopSoundEnabled)

            HStack(spacing: 8) {
                Picker("Sound", selection: $stopSoundName) {
                    ForEach(soundChoices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .frame(maxWidth: 260)
                .disabled(!stopSoundEnabled)
                .onChange(of: stopSoundName) { _, newValue in
                    SystemSoundCatalog.play(newValue)
                }

                Button {
                    SystemSoundCatalog.play(stopSoundName)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .disabled(!stopSoundEnabled)
                .help("Sound anspielen")
            }

            Text("Der Ton spielt beim Turn-Ende (Stop-Hook), unabhängig davon, ob die App im Vordergrund ist. Rückfragen sind bewusst lautlos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var soundChoices: [String] {
        if availableSounds.isEmpty {
            return [stopSoundName]
        }
        // Aktuellen (evtl. verwaisten) Namen anbieten, damit der Picker nie leer selektiert.
        return availableSounds.contains(stopSoundName)
            ? availableSounds
            : [stopSoundName] + availableSounds
    }

    // MARK: - Externe Hooks

    private var externalHooksSection: some View {
        Section("Eigene Claude-Hooks erkannt") {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("In deiner globalen Claude-Konfiguration sind eigene Hooks auf Events registriert, die WhisperM8 jetzt selbst abdeckt. Wenn diese Skripte ebenfalls benachrichtigen, bekommst du Meldungen doppelt. WhisperM8 ändert diese Dateien nie — entferne die Einträge bei Bedarf manuell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(externalHookFindings) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(finding.eventName)
                            .font(.caption.weight(.semibold))
                        if let matcher = finding.matcher, !matcher.isEmpty {
                            Text("matcher: \(matcher)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("~/.claude/\(finding.source)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(finding.commandPreview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - Erklärung

    private var explainerSection: some View {
        Section {
            DisclosureGroup("Wie funktioniert das?", isExpanded: $isExplainerExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Beim Start eines Chats übergibt WhisperM8 `claude --settings <datei>` mit genau dieser Hook-Konfiguration. Jeder Hook hängt sein Event an eine Session-eigene Datei an, die die App live beobachtet. Globale oder Projekt-Settings werden dabei nicht verändert — Claude merged additiv.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(hookSettingsPreview)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 240)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Aktionen

    private func refresh() {
        availableSounds = SystemSoundCatalog.availableSoundNames()
        externalHookFindings = ExternalClaudeHooksInspector.inspectUserSettings()
        if hookSettingsPreview.isEmpty {
            let examplePath = "~/Library/Application Support/WhisperM8/claude-session-events/<session>.jsonl"
            if let data = try? ClaudeHookSettingsBuilder.serializedSettings(eventFilePath: examplePath),
               let json = String(data: data, encoding: .utf8) {
                hookSettingsPreview = json
            }
        }
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationAuthStatus = settings.authorizationStatus
        }
    }

    /// Probe-Banner ohne Session-Bezug (Klick routet bewusst nirgendwohin).
    private func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Statusmaschine-Chat"
        content.subtitle = "WhisperM8 · Test"
        content.body = "Agent ist fertig und wartet auf dich."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in
                showFeedback(error == nil ? "Gesendet ✓" : "Fehler: \(error!.localizedDescription)")
            }
        }
    }

    private func openNotificationSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showFeedback(_ text: String) {
        withAnimation { feedback = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { feedback = nil }
        }
    }
}
