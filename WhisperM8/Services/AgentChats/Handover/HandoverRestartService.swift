import AppKit
import Darwin
import Foundation

// MARK: - Neustart, Chats laufen weiter

/// Einstieg für `whisperm8 app handover` (`make dev`, Test-Instanz
/// `restart --keep-chats`) und später den Menüpunkt „Neu starten, Chats laufen
/// weiter“. Entscheidet, gibt ab und beendet die App nach geglückter Abgabe
/// selbst. Bei „heutiger Weg“ oder gescheiterter Abgabe beendet sie sich nicht:
/// Der Aufrufer macht weiter wie bisher (das Makefile mit SIGTERM).
@MainActor
final class HandoverRestartService {
    static let shared = HandoverRestartService()

    /// Ergebnis, wie es an die CLI zurückgeht.
    struct Result: Equatable {
        enum Kind: String, Equatable {
            /// Abgegeben (oder nichts abzugeben); die App beendet sich gleich.
            case handedOver
            /// Keine Übergabe, die App läuft weiter (heutiger Weg folgt).
            case classic
            /// Abgabe gescheitert, alle Chats laufen weiter in der App.
            case failed
        }

        var kind: Kind
        var reason: String?
        var runID: String?
        var keeperPID: Int32?
        var handedOver: [UUID] = []
        var notHandedOver: [UUID] = []
    }

    /// Gesetzt, sobald die Abgabe durch ist: `applicationShouldTerminate`
    /// zeigt dann keinen Dialog, schickt den übergebenen Chats kein Ctrl+C und
    /// lässt den Marker „übergeben“ stehen.
    private(set) var isTerminatingAfterHandover = false
    private var isRunning = false

    var isEnabled: () -> Bool = { AppPreferences.shared.isRestartKeepsChatsEnabled }
    var paths = HandoverPaths.default
    var registry: AgentTerminalRegistry { .shared }

    func requestRestart(trigger: HandoverQuitTrigger, terminate: Bool = true) -> Result {
        guard !isRunning, !isTerminatingAfterHandover else {
            return Result(kind: .failed, reason: "busy")
        }
        isRunning = true
        defer { isRunning = false }

        let running = registry.runningControllers
        let sessions = Dictionary(
            AgentSessionStore().loadWorkspace().sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let candidates = running.map { controller -> HandoverQuitCandidate in
            let kind = sessions[controller.sessionID].flatMap {
                HandoverChatKind.of(kind: $0.effectiveKind, provider: $0.provider, command: controller.command)
            }
            return HandoverQuitCandidate(sessionID: controller.sessionID, kind: kind,
                                         hasLiveProcess: controller.processID != nil)
        }
        let plan = HandoverPlanning.quitPlan(
            featureEnabled: isEnabled(), trigger: trigger,
            keeper: Self.keeperPresence(paths: paths), candidates: candidates)

        switch plan {
        case .classic(let reason):
            Logger.agentStore.notice("handover_restart_classic reason=\(reason.rawValue, privacy: .public)")
            return Result(kind: .classic, reason: reason.rawValue)
        case .restart(let handOver, _):
            let byID = Dictionary(running.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
            let items = handOver.compactMap { id -> HandoverDepositCoordinator.Item? in
                guard let controller = byID[id], let session = sessions[id] else { return nil }
                return HandoverDepositCoordinator.Item(source: controller) { detached in
                    HandoverManifestFactory.manifest(for: controller, session: session, detached: detached)
                }
            }
            let result: Result
            if items.isEmpty {
                AgentCrashRecoveryMarker.shared.endRunCleanly()
                result = Result(kind: .handedOver, reason: "noChats")
            } else {
                switch makeCoordinator().deposit(items) {
                case .nothingToHandOver:
                    AgentCrashRecoveryMarker.shared.endRunCleanly()
                    result = Result(kind: .handedOver, reason: "noChats")
                case .failed(let reason):
                    return Result(kind: .failed, reason: reason)
                case let .handedOver(runID, keeperPID, keeperStartTime, chats, notHandedOver):
                    AgentCrashRecoveryMarker.shared.markHandedOver(
                        .init(keeperPID: keeperPID, keeperStartTime: keeperStartTime, runID: runID,
                              chats: chats.map { .init(sessionID: $0.sessionID, pid: $0.pid,
                                                       pidStartTime: $0.pidStartTime) }),
                        alsoResume: Set(notHandedOver))
                    result = Result(kind: .handedOver, runID: runID, keeperPID: keeperPID,
                                    handedOver: chats.map(\.sessionID), notHandedOver: notHandedOver)
                }
            }
            // Router-Dienst und Proxys laufen weiter (Paket 3).
            ClaudeGPTBackendHandover.setRequested(true)
            isTerminatingAfterHandover = true
            if terminate {
                // Erst die Antwort an die CLI rausgehen lassen, dann beenden.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
            return result
        }
    }

    private func makeCoordinator() -> HandoverDepositCoordinator {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "/Applications/WhisperM8.app/Contents/MacOS/WhisperM8")
        return HandoverDepositCoordinator(dependencies: .init(
            paths: paths,
            keeperExecutable: executable,
            appBinaries: [executable.path],
            secretStore: HandoverSecretStore.live(paths: paths),
            holdSeconds: nil))
    }

    /// Lebt schon ein Aufbewahrer mit Chats, die keiner übernommen hat?
    static func keeperPresence(paths: HandoverPaths) -> HandoverKeeperPresence {
        do {
            let client = try HandoverClient.connect(paths: paths, timeout: 0.3)
            defer { client.close() }
            client.timeout = 1
            let status = try client.status()
            return status.chats.isEmpty ? .none : .holdingUntakenChats
        } catch HandoverWireError.io(let code) where code == ENOENT || code == ECONNREFUSED {
            return .none
        } catch {
            return .unknown
        }
    }
}

// MARK: - Manifest aus dem laufenden Chat

@MainActor
enum HandoverManifestFactory {
    static func manifest(
        for controller: AgentTerminalController,
        session: AgentChatSession,
        detached: HandoverDetachedChat
    ) -> HandoverManifest {
        let kind = HandoverChatKind.of(kind: session.effectiveKind, provider: session.provider,
                                       command: controller.command) ?? .terminal
        var manifest = HandoverManifest(
            chatID: session.id.uuidString,
            kind: kind.rawValue,
            pid: detached.handle.pid,
            pidStartTime: ProcessStartTime.of(pid: detached.handle.pid)?.timeIntervalSince1970,
            cols: detached.cols,
            rows: detached.rows,
            sendsInterruptOnStop: controller.command.sendsInterruptOnStop)
        manifest.launchCommand = try? HandoverJSONValue(encoding: HandoverLaunchCommandSnapshot(controller.command))
        manifest.controlToken = controller.issuedControlToken
        manifest.title = session.title
        manifest.hookCursor = AgentSessionStatusCoordinator.shared.hookCursor(sessionID: session.id)
        manifest.hasComposerDraft = controller.composerDraft.fieldMayHaveText
        if let pending = AccountSwitchCoordinator.shared.pending[session.id] {
            manifest.pendingAccountSwitch = try? HandoverJSONValue(encoding: HandoverPendingAccountSwitch(pending))
        }
        manifest.accountProfile = session.claudeProfileName
        manifest.gptProfile = session.gptProfileName
        manifest.externalSessionID = session.externalSessionID
        manifest.terminalColors = detached.colors
        return manifest
    }
}
