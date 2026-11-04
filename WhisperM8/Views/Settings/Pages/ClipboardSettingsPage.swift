import AppKit
import SwiftUI

/// Was die Seite von außen braucht: Anzahl, Leeren, laufende Apps. Snapshots
/// und Tests setzen eigene Werte; `.live` greift auf Store und Workspace zu.
struct ClipboardSettingsDependencies {
    var entryCount: () -> Int
    var clearHistory: () -> Void
    var runningApps: () -> [ClipboardRunningApp]

    static let live = ClipboardSettingsDependencies(
        entryCount: { ClipboardHistoryController.shared.store.snapshot().count },
        clearHistory: { ClipboardHistoryController.shared.store.clear(keepPinned: false) },
        runningApps: {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in
                    guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                    return ClipboardRunningApp(bundleID: id, name: name)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    )
}

struct ClipboardRunningApp: Hashable {
    let bundleID: String
    let name: String
}

struct ClipboardSettingsPage: View {
    @AppStorage(ClipboardPreferenceKeys.enabled) private var enabled = false
    @AppStorage(ClipboardPreferenceKeys.paused) private var paused = false
    @AppStorage(ClipboardPreferenceKeys.maxItems) private var maxItems = 200
    @AppStorage(ClipboardPreferenceKeys.autoPaste) private var autoPaste = true
    @AppStorage(ClipboardPreferenceKeys.windowPosition) private var windowPosition = ClipboardWindowPosition.cursor.rawValue
    @AppStorage(ClipboardPreferenceKeys.excludedApps) private var excludedAppsJSON = ClipboardSettings.defaultExcludedAppsJSON
    @AppStorage(ClipboardPreferenceKeys.agentAccess) private var agentAccess = true
    @AppStorage(ClipboardPreferenceKeys.maskSecrets) private var maskSecrets = true
    @AppStorage(ClipboardPreferenceKeys.clearOnQuit) private var clearOnQuit = false

    let dependencies: ClipboardSettingsDependencies
    @State private var entryCount = 0
    @State private var confirmClear = false
    @State private var newBundleID = ""

    init(dependencies: ClipboardSettingsDependencies = .live) {
        self.dependencies = dependencies
    }

    private var excludedApps: [String] { ClipboardSettings.decodeApps(excludedAppsJSON) }

    var body: some View {
        SettingsPageContainer(
            title: "Clipboard",
            subtitle: "A searchable history of what you copy, with a hotkey and access for Claude."
        ) {
            SettingsSection("History") {
                SettingsToggleRow(
                    title: "Keep a clipboard history",
                    subtitle: "Remembers text, images and files you copy. Off by default. Passwords from password managers are never stored.",
                    isOn: $enabled
                )
                SettingsToggleRow(
                    title: "Pause",
                    subtitle: "Stops recording for now. Also in the menu bar.",
                    isOn: $paused
                )
                .disabled(!enabled)
                SettingsHelpText("WhisperM8 can replace Maccy. Turn Maccy off afterwards: both use the shortcut ⇧⌘C by default, so only one of them should be running.")
            }

            SettingsSection("Window") {
                SettingsKeyRecorderRow(
                    title: "Open history",
                    subtitle: "Global shortcut. Default ⇧⌘C, like Maccy.",
                    name: .clipboardHistory
                )
                .disabled(!enabled)
                SettingsPickerRow(
                    title: "Position",
                    subtitle: "Where the window appears.",
                    selection: $windowPosition,
                    options: ClipboardWindowPosition.allCases.map(\.rawValue)
                ) { raw in
                    Text(settingsLocalized: raw == ClipboardWindowPosition.center.rawValue
                         ? String(localized: "Center of screen")
                         : String(localized: "Near the mouse pointer"))
                }
                SettingsToggleRow(
                    title: "Paste automatically",
                    subtitle: "Enter pastes into the app you came from. Off: the entry is only copied.",
                    isOn: $autoPaste
                )
            }

            SettingsSection("Storage") {
                SettingsStepperRow(
                    title: "Entries to keep",
                    subtitle: "Pinned entries do not count and stay.",
                    value: $maxItems,
                    in: ClipboardSettings.maxItemsRange,
                    format: .number
                )
                SettingsToggleRow(
                    title: "Clear when WhisperM8 quits",
                    subtitle: "Pinned entries stay.",
                    isOn: $clearOnQuit
                )
                SettingsButtonRow(
                    title: "Clear history",
                    subtitle: String(localized: "\(entryCount) entries are stored on this Mac.")
                ) {
                    Button("Clear history…") { confirmClear = true }
                        .buttonStyle(SettingsButtonStyle.destructive)
                }
            }

            SettingsSection("Excluded apps") {
                SettingsHelpText("Copies from these apps are never stored (bundle identifiers). Anything marked confidential by an app is skipped anyway.")
                ForEach(excludedApps, id: \.self) { bundleID in
                    SettingsRow(title: bundleID) {
                        Button("Remove") { removeApp(bundleID) }
                            .buttonStyle(SettingsButtonStyle.standard)
                    }
                }
                SettingsRow(title: "Add app", subtitle: "Pick a running app or type a bundle identifier.") {
                    HStack(spacing: 6) {
                        TextField("com.example.app", text: $newBundleID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                            .onSubmit(addTypedApp)
                        Menu("Running apps") {
                            ForEach(dependencies.runningApps(), id: \.bundleID) { app in
                                Button(app.name) { addApp(app.bundleID) }
                            }
                        }
                        .fixedSize()
                        Button("Add", action: addTypedApp)
                            .buttonStyle(SettingsButtonStyle.standard)
                            .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                SettingsButtonRow(title: "Reset list", subtitle: "Back to password managers and the Keychain.") {
                    Button("Reset") { excludedAppsJSON = ClipboardSettings.defaultExcludedAppsJSON }
                        .buttonStyle(SettingsButtonStyle.standard)
                }
            }

            SettingsSection("Access for Claude") {
                SettingsToggleRow(
                    title: "Let agents read the history",
                    subtitle: "Allows `whisperm8 clipboard` and the clipboard tool in Claude chats, so \"the error I copied earlier\" works.",
                    isOn: $agentAccess
                )
                SettingsToggleRow(
                    title: "Mask secrets for agents",
                    subtitle: "API keys, tokens, JWTs and private keys are replaced by a placeholder in what agents see.",
                    isOn: $maskSecrets
                )
                .disabled(!agentAccess)
            }
        }
        .onAppear { entryCount = dependencies.entryCount() }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) {
                dependencies.clearHistory()
                entryCount = 0
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All stored entries are deleted, pinned ones too. This cannot be undone.")
        }
    }

    private func addTypedApp() {
        let id = newBundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        addApp(id)
        newBundleID = ""
    }

    private func addApp(_ bundleID: String) {
        var apps = excludedApps
        guard !apps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return }
        apps.append(bundleID)
        excludedAppsJSON = ClipboardSettings.encodeApps(apps)
    }

    private func removeApp(_ bundleID: String) {
        excludedAppsJSON = ClipboardSettings.encodeApps(excludedApps.filter { $0 != bundleID })
    }
}
