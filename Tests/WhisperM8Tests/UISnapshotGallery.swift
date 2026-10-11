import SwiftUI
import XCTest
@testable import WhisperM8

/// UI-Snapshot-Galerie: rendert ausgewählte Ansichten in festen Zuständen als
/// PNG (hell + dunkel), damit man Layout, Texte und Zustände ansehen kann,
/// ohne die App zu starten. Läuft nur mit `WHISPERM8_SNAPSHOT_DIR` — Aufruf
/// über `scripts/ui-snapshots.sh` bzw. `make snapshots`.
///
/// Neue Ansicht aufnehmen: Eintrag in `fixtures` ergänzen. Liest die Ansicht
/// Keychain, Proxy oder andere Subprozesse, bekommt sie vorher eine
/// Abhängigkeits-Struktur mit `.live`-Default (Muster:
/// `TranscriptionSettingsDependencies`) — im Snapshot darf nichts Echtes
/// passieren. `@AppStorage`-Werte kommen aus einer Wegwerf-Suite
/// (`.defaultAppStorage`), nie aus den echten Preferences.
final class UISnapshotGallery: XCTestCase {
    struct Fixture {
        let name: String
        let size: CGSize
        /// Startwerte für `@AppStorage` (Wegwerf-Suite je Fixture).
        var storage: [String: Any] = [:]
        let view: @MainActor () -> AnyView
    }

    // MARK: - Galerie

    @MainActor
    private var fixtures: [Fixture] {
        let settingsSize = CGSize(width: 700, height: 900)
        let onboardingSize = CGSize(width: 520, height: 560)

        func transcription(
            _ name: String,
            provider: TranscriptionProvider,
            model: TranscriptionModel,
            hasKey: Bool = false,
            backendEnabled: Bool = true,
            chatGPTEnabled: Bool = true,
            account: String = "main",
            auth: ClaudeCodeProxyAuthStatus? = .authenticated(account: "acct-demo", expires: "2026-10-18")
        ) -> Fixture {
            Fixture(
                name: name,
                size: settingsSize,
                storage: [
                    "selectedProvider": provider.rawValue,
                    "selectedModel": model.rawValue,
                    "language": "de",
                    PreferenceKeys.claudeGPTBackendEnabled: backendEnabled,
                    PreferenceKeys.chatGPTTranscriptionEnabled: chatGPTEnabled,
                ]
            ) {
                AnyView(TranscriptionSettingsPage(dependencies: TranscriptionSettingsDependencies(
                    storedSelection: { (provider.rawValue, model.rawValue) },
                    hasSavedKey: { _ in hasKey },
                    chatGPTStatus: { enabled in (account, enabled ? auth : nil) }
                )))
            }
        }

        func sidebarAlertLevel(_ level: AgentAlertLevel) -> Fixture {
            Fixture(
                name: "sidebar-glocke-\(level.rawValue)",
                size: CGSize(width: 260, height: 60),
                storage: [PreferenceKeys.agentAlertLevel: level.rawValue]
            ) {
                AnyView(HStack(spacing: 8) {
                    SidebarAlertLevelButton()
                    Text(SidebarAlertLevelButton.title(for: level))
                        .font(.system(size: 11))
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(AppTheme.sidebar))
            }
        }

        return [
            transcription("transcription-groq-ohne-key", provider: .groq, model: .groq_whisper_v3),
            transcription("transcription-groq-mit-key", provider: .groq, model: .groq_whisper_v3, hasKey: true),
            transcription("transcription-openai-mit-key", provider: .openai, model: .openai_gpt4o, hasKey: true),
            transcription("transcription-chatgpt-angemeldet", provider: .chatgpt, model: .chatgpt_transcribe, account: "office"),
            transcription("transcription-chatgpt-nicht-angemeldet", provider: .chatgpt, model: .chatgpt_transcribe, auth: .notAuthenticated),
            transcription("transcription-chatgpt-backend-aus", provider: .chatgpt, model: .chatgpt_transcribe, backendEnabled: false),
            // Kill-Switch aus: gespeichertes „ChatGPT-Abo" erscheint als Groq, nur zwei Segmente.
            transcription("transcription-chatgpt-killswitch-aus", provider: .chatgpt, model: .chatgpt_transcribe, chatGPTEnabled: false),
            // CLI & Skills: die drei Kartenzustände nebeneinander (Plugin an +
            // nichts lose, Plugin an + lose Kopie = doppelt, Plugin aus).
            Fixture(name: "cli-skills-karten", size: CGSize(width: 700, height: 640)) {
                @MainActor func card(_ title: String, _ definition: CLISkillExporter.SkillDefinition, plugin: Bool, state: CLISkillExporter.InstallState) -> CLISkillSettingsCard {
                    CLISkillSettingsCard(
                        title: title,
                        definition: definition,
                        summary: "Kurzbeschreibung des Skills.",
                        dependencies: CLISkillCardDependencies(pluginEnabled: { plugin }, installState: { _ in state })
                    )
                }
                return AnyView(VStack(alignment: .leading, spacing: 12) {
                    card("Jarvis Supervisor Skill", .jarvis, plugin: true, state: .notInstalled)
                    card("GPT Coworker Skill", .gptCoworker, plugin: true, state: .modifiedLocally)
                    card("GPT Workflow Skill (Plugin aus)", .gptWorkflow, plugin: false, state: .notInstalled)
                }
                .padding(24))
            },
            // Kontowechsel ohne Stoppen: alle Gruppen und Hinweise auf einmal.
            Fixture(name: "konto-wechsel-vorschau", size: CGSize(width: 520, height: 600)) {
                func candidate(_ title: String) -> AccountMovePlanner.Candidate {
                    AccountMovePlanner.Candidate(
                        sessionID: UUID(), title: title, currentProfile: nil, provider: .claude,
                        kind: .chat, isRunning: false, hasTargetConflict: false)
                }
                var decision = AccountSwitchPlanner.Decision(targetProfile: "ai2")
                decision.moveNow = [candidate("Alte Recherche"), candidate("Doku-Review")]
                decision.switchNow = [candidate("Login-Bug")]
                decision.waitForTurn = [(candidate("Refactor Sidebar"), .turnRunning), (candidate("Plan Schritt 3"), .awaitingInput)]
                decision.blocked = [(candidate("Kunde XY"), .trustMissing)]
                decision.skipped = [.init(candidate: candidate("Hintergrund-Job"), reason: .backgroundAgent)]
                let pending = PendingAccountMove(
                    plan: AccountMovePlanner.Plan(targetProfile: "ai2", movable: [], skipped: []),
                    decision: decision,
                    targetDisplayName: "ai2",
                    untrustedTitles: ["Login-Bug"],
                    missingMCPServers: ["atlassian", "meta-ads"])
                return AnyView(AgentMoveToAccountSheet(
                    pending: pending, phase: .constant(.preview),
                    onConfirm: {}, onCancelRun: {}, onUndo: {}, onClose: {}))
            },
            // Glocken-Schalter im Sidebar-Footer: eine Fixture je Ruhe-Stufe.
            sidebarAlertLevel(.all),
            sidebarAlertLevel(.soundOff),
            sidebarAlertLevel(.off),
            Fixture(name: "onboarding-welcome", size: onboardingSize) {
                AnyView(WelcomeStep().padding(24))
            },
            Fixture(name: "onboarding-profil", size: onboardingSize) {
                AnyView(ProfileStep(selectedProfile: .constant(.full)).padding(24))
            },
        ]
    }

    // MARK: - Lauf

    @MainActor
    func testRenderGallery() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["WHISPERM8_SNAPSHOT_DIR"], !outputPath.isEmpty else {
            throw XCTSkip("UI-Snapshots nur mit WHISPERM8_SNAPSHOT_DIR (scripts/ui-snapshots.sh)")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Optionaler Teilstring-Filter auf den Fixture-Namen.
        let only = ProcessInfo.processInfo.environment["WHISPERM8_SNAPSHOT_ONLY"].flatMap { $0.isEmpty ? nil : $0 }

        var written: [String] = []
        for fixture in fixtures where only.map({ fixture.name.contains($0) }) ?? true {
            let suiteName = "whisperm8-snapshot-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            for (key, value) in fixture.storage {
                defaults.set(value, forKey: key)
            }
            for appearance in ViewSnapshotRenderer.Appearance.allCases {
                let view = fixture.view()
                    .defaultAppStorage(defaults)
                let png = try ViewSnapshotRenderer.pngData(view, size: fixture.size, appearance: appearance)
                let file = output.appendingPathComponent("\(fixture.name)-\(appearance.rawValue).png")
                try png.write(to: file)
                written.append(file.path)
            }
        }
        XCTAssertFalse(written.isEmpty, "Kein Fixture passt auf WHISPERM8_SNAPSHOT_ONLY=\(only ?? "")")
        print(written.map { "UI-SNAPSHOT| \($0)" }.joined(separator: "\n"))
    }
}
