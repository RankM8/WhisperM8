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
    private func cliModel(_ cli: AgentCLI, command: String?, brew: String?) -> AgentCLIInstallModel {
        let resolver = AgentCLIResolver(commandResolver: { _ in command }, brewResolver: { brew })
        return AgentCLIInstallModel(cli: cli, initialState: resolver.state(of: cli), resolver: resolver)
    }

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

        let noteNow = Date(timeIntervalSince1970: 1_792_000_000)
        func jarvisNoteEntry(light: JarvisBoardLight = .running, work: String, needs: String = "",
                             blocker: String = "", milestones: [String]) -> JarvisBoardEntry {
            JarvisBoardEntry(
                sessionID: UUID(), light: light, mission: "Prüfdienst wählen und Ticket für Richard schreiben",
                needs: needs, work: work, blocker: blocker,
                milestones: milestones.enumerated().map { index, text in
                    JarvisBoardMilestone(at: noteNow.addingTimeInterval(Double(-(index + 1) * 1_500)), text: text)
                },
                updatedAt: noteNow.addingTimeInterval(-120))
        }
        func noteTask(_ id: String, _ subject: String, _ status: AgentChatTask.Status, activeForm: String? = nil,
                      owner: String? = nil, blockedBy: [String] = [], links: [(String, String)] = []) -> AgentChatTask {
            AgentChatTask(id: id, subject: subject, activeForm: activeForm, status: status, owner: owner,
                          blockedBy: blockedBy, links: links.map { .init(label: $0.0, url: URL(string: $0.1)!) })
        }
        let noteTasks = [
            noteTask("1", "Release-Notizen für 2.23 schreiben und mit dem Changelog der letzten drei Wochen abgleichen", .completed),
            noteTask("2", "Tests grün", .completed),
            noteTask("3", "Sequenzen G in die App übernehmen", .inProgress, activeForm: "Baut die Sequenz-Seite",
                     owner: "bau-78-g", links: [("App", "https://listm8.test/campaigns/3799/setup"), ("Design", "https://www.figma.com/file/abc")]),
            noteTask("4", "Versand und MCP nachziehen", .pending),
            noteTask("5", "PR vorbereiten", .pending, blockedBy: ["4"]),
        ]
        func jarvisNoteFixture(_ name: String, entry: JarvisBoardEntry?, tasks: [AgentChatTask] = [],
                               focused: Bool = false) -> Fixture {
            Fixture(name: name, size: CGSize(width: 560, height: 420)) {
                let headerHeight = AgentChatsView.gridPaneHeaderHeight
                let opacity = AgentChatsView.gridPaneHeaderOpacity(isFocused: focused)
                return AnyView(
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Circle().fill(AgentTheme.statusWorking).frame(width: 7, height: 7)
                            Text("5 Eli · SMTP-Verifizierung: Ticket für Richard")
                                .font(.system(size: 12, weight: focused ? .semibold : .regular))
                                .foregroundStyle(focused ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(90)).foregroundStyle(AgentTheme.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: headerHeight)
                        .background(AgentTheme.header.opacity(opacity))
                        Text(String(repeating: "● Bash(git log --oneline -15 -- client/src/pages/admin)\n  ⎿ feat(designs): E-Mail-Agent neben der Mail\n", count: 12))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(14)
                    }
                    .background(AgentTheme.background)
                    .overlay(alignment: .topLeading) {
                        JarvisNoteCard(entry: entry, tasks: tasks, width: 400, maxHeight: 300, headerOpacity: opacity,
                                       isOwnNote: focused, now: noteNow)
                            .padding(.leading, JarvisNoteCardOverlay.leadingInset)
                            .padding(.top, headerHeight)
                    }
                    .overlay { if focused { Rectangle().strokeBorder(AgentTheme.accent.opacity(0.8), lineWidth: 2) } }
                )
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

        // Status-Punkte im Ruhig-Modus (LR-AU-002): working muss ohne Bewegung
        // von idle/Rückfrage unterscheidbar sein.
        func statusDots() -> Fixture {
            Fixture(name: "status-punkte", size: CGSize(width: 360, height: 150)) {
                func row(_ label: String, _ status: AgentSessionRuntimeStatus) -> some View {
                    HStack(spacing: 12) {
                        AgentStatusIndicator(status: status).frame(width: 18, height: 18)
                        AgentStatusIndicator(status: status, compact: true)
                        Text(label).font(.system(size: 11))
                    }
                }
                return AnyView(VStack(alignment: .leading, spacing: 8) {
                    row("arbeitet", .working)
                    row("wartet", .awaitingInput)
                    row("bereit", .idle)
                    row("Fehler", .errored)
                    HStack(spacing: 8) {
                        SubagentRoad(barCount: 4)
                        Text("4 Subagents").font(.system(size: 11))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(AppTheme.sidebar))
            }
        }

        return [
            statusDots(),
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
            // MCP-Angleich über Konten: vollständig, fehlend, Konflikt.
            Fixture(name: "mcp-sync-section", size: CGSize(width: 640, height: 420)) {
                let snapshot = ClaudeMCPSync.Snapshot(
                    profileNames: ["main", "ai", "ai2"],
                    servers: [
                        "atlassian": ["main": "{}", "ai": "{}", "ai2": "{}"],
                        "figma": ["ai2": "{\"url\":\"a\"}"],
                        "playwright": ["main": "{\"cmd\":\"x\"}", "ai2": "{\"cmd\":\"y\"}"],
                    ])
                return AnyView(ClaudeMCPSyncSection(dependencies: ClaudeMCPSyncDependencies(
                    snapshot: { snapshot }, apply: { _ in ClaudeMCPSync.Outcome() }))
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
            // Jarvis-Notiz: Karte hängt am Kachelkopf über Terminal-Text.
            jarvisNoteFixture("jarvis-notiz-eingriff", entry: jarvisNoteEntry(
                light: .needsYou, work: "Wartet auf dich: Ticket für Richard erstellen",
                needs: "Entscheidung: Chat ansehen und das Ticket mit ihm erstellen",
                milestones: ["Empfehlung steht: MillionVerifier zuerst, Apify als zweite Meinung",
                             "Beide Dienste an 80 Adressen verglichen"])),
            jarvisNoteFixture("jarvis-notiz-meilensteine", entry: jarvisNoteEntry(
                work: "Schließt die Intro-Regeln ab: Push von ListM8 und Plugin",
                blocker: "Deploy auf Prod: der Weg ist deine Entscheidung",
                milestones: ["Intro-Regeln gelockert, 1.090 Tests grün, committet (dd83dbd, ee4a1c4)",
                             "Prüf-Agent im Plugin nachgeschärft", "Auftrag übernommen: Intros aus dem Dump auswerten",
                             "Dump ausgewertet", "Erster Entwurf"])),
            jarvisNoteFixture("jarvis-notiz-eigene", entry: jarvisNoteEntry(
                work: "Baut die letzte Variante der Lead-Ansicht (L22)",
                milestones: ["L21 „Zwei Spalten mit Sinn“ fertig und im Vorschau-Fenster"]), focused: true),
            // Tasks des Chats in der Karte: allein (ohne Jarvis) und unter einer Notiz.
            jarvisNoteFixture("notiz-tasks", entry: nil, tasks: noteTasks),
            jarvisNoteFixture("notiz-tasks-mit-jarvis", entry: jarvisNoteEntry(
                work: "Sequenzen G, Versand und MCP in die App",
                milestones: ["Kampagnen und Dashboard ohne KI-Verbindung fertig (da0af1f)"]), tasks: noteTasks),
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
            Fixture(name: "onboarding-test-fehlgeschlagen", size: onboardingSize) {
                let gate = OnboardingCompletionGate(
                    micGranted: true, accessibilityGranted: true, hotkeySet: true,
                    credentialsSatisfied: true,
                    testOutcome: .failed("Groq: 401 invalid API key")
                )
                return AnyView(TestStep(gate: gate).environment(AppState.shared))
            },
            Fixture(name: "onboarding-test-ungetestet", size: onboardingSize) {
                let gate = OnboardingCompletionGate(
                    micGranted: true, accessibilityGranted: true, hotkeySet: true,
                    credentialsSatisfied: true
                )
                return AnyView(TestStep(gate: gate).environment(AppState.shared))
            },
            Fixture(name: "onboarding-claude-schritt", size: onboardingSize) {
                AnyView(ClaudeCLIStep())
            },
            // Recording-Pill: „Mikrofon verbindet …" (AirPods-Profilwechsel) neben der laufenden Aufnahme.
            Fixture(name: "pill-verbindet", size: CGSize(width: 320, height: 80)) {
                let controller = OverlayController()
                controller.overlayStyle = .mini
                controller.isConnecting = true
                return AnyView(RecordingPillView(controller: controller).padding(20))
            },
            Fixture(name: "pill-aufnahme", size: CGSize(width: 320, height: 80)) {
                let controller = OverlayController()
                controller.overlayStyle = .mini
                controller.levelModel.level = 0.5
                return AnyView(RecordingPillView(controller: controller).padding(20))
            },
            // CLI-Installation (LR-ONB-003/DIK-015/AU-022): feste Zustände, kein echtes brew.
            Fixture(name: "cli-claude-fehlt-brew", size: CGSize(width: 480, height: 320)) {
                AnyView(AgentCLIInstallPanel(model: self.cliModel(.claude, command: nil, brew: "/opt/homebrew/bin/brew")).padding(24))
            },
            Fixture(name: "cli-codex-fehlt-ohne-brew", size: CGSize(width: 480, height: 280)) {
                AnyView(AgentCLIInstallPanel(model: self.cliModel(.codex, command: nil, brew: nil)).padding(24))
            },
            Fixture(name: "cli-claude-installiert", size: CGSize(width: 480, height: 220)) {
                AnyView(AgentCLIInstallPanel(
                    model: self.cliModel(.claude, command: "/Users/demo/.local/bin/claude", brew: nil),
                    loginHint: Text("The first time you start a chat, Claude Code opens right inside WhisperM8 and walks you through signing in with your Claude account.")
                ).padding(24))
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
