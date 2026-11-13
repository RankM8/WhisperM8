import Darwin
import Foundation
import SwiftTerm

// MARK: - Abgabe beim Neustart

/// Ein Chat, den die App abgeben kann. Produktiv der Terminal-Controller;
/// Tests nehmen PTY-Kinder ohne Fenster.
@MainActor
protocol HandoverDepositSource: AnyObject {
    var sessionID: UUID { get }
    func detachForHandoverDeposit() -> HandoverDetachedChat?
    @discardableResult func reattachAfterFailedHandover() -> Bool
    func completeHandover()
}

extension AgentTerminalController: HandoverDepositSource {
    func detachForHandoverDeposit() -> HandoverDetachedChat? { detachForHandover() }
}

/// Führt die Abgabe aus: Aufbewahrer starten, Chats ablösen und abgeben,
/// Geheimnis in den Schlüsselbund, `COMMIT`. Erst nach einem fehlerfreien
/// `COMMIT` schließt die App ihre Kopien (`completeHandover`). Scheitert
/// irgendetwas davor, holt sie alle Leitungen ans Terminal zurück, und die App
/// läuft weiter wie vorher — der Aufrufer endet dann auf dem heutigen Weg.
///
/// Läuft auf dem Main Thread und blockiert ihn für die Dauer der Abgabe:
/// Ablösen muss dort passieren, und während der Abgabe darf kein `forkpty`
/// dazwischenkommen (close-on-exec der Kopien).
@MainActor
final class HandoverDepositCoordinator {
    struct Item {
        var source: HandoverDepositSource
        var makeManifest: (HandoverDetachedChat) -> HandoverManifest
    }

    struct Dependencies {
        var paths: HandoverPaths
        var keeperExecutable: URL
        /// Binaries, die als neue App gelten (Peer-Prüfung des Aufbewahrers).
        var appBinaries: [String]
        var secretStore: HandoverSecretStoring
        var holdSeconds: TimeInterval?
        var launch: (URL, [String], String) throws -> Process = { executable, arguments, secret in
            try HandoverKeeperLauncher.launch(executable: executable, arguments: arguments, secret: secret)
        }
        /// Wie lange auf den Socket des frisch gestarteten Aufbewahrers warten.
        var startTimeout: TimeInterval = 3
        /// Frist je Telegramm.
        var ioTimeout: TimeInterval = 5
        /// Läuft der Aufruf auf dem Main Thread? Nur dort entstehen Socket und
        /// Kopien der Leitungen, denn dort laufen auch alle `forkpty`; macOS
        /// kennt kein `SOCK_CLOEXEC`, ein Kind von einem anderen Thread könnte
        /// sonst den Socket erben (Urteil zur Absender-Bindung, 13.11.2026).
        var isMainThread: () -> Bool = { Thread.isMainThread }
    }

    enum Outcome: Equatable {
        /// Der Aufbewahrer hält `chats`. `notHandedOver` liefen weiter in der App
        /// (Ablösen ging nicht) und enden auf dem heutigen Weg.
        case handedOver(runID: String, keeperPID: Int32, keeperStartTime: Double?,
                        chats: [HandedOverChat], notHandedOver: [UUID])
        /// Nichts abzugeben.
        case nothingToHandOver
        /// Abgabe gescheitert; alle Chats laufen weiter in der App.
        case failed(String)
    }

    struct HandedOverChat: Equatable {
        var sessionID: UUID
        var pid: Int32
        var pidStartTime: Double?
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func deposit(_ items: [Item]) -> Outcome {
        guard !items.isEmpty else { return .nothingToHandOver }
        // Nicht auf dem Main Thread: keine Übergabe, der heutige Weg greift.
        guard dependencies.isMainThread() else { return fail("nicht auf dem Main Thread") }
        let started = Date()
        let secret = HandoverSecret.make()
        let runID = UUID().uuidString.lowercased()
        let process: Process
        do {
            process = try dependencies.launch(
                dependencies.keeperExecutable,
                HandoverKeeperLauncher.arguments(
                    paths: dependencies.paths, runID: runID,
                    holdSeconds: dependencies.holdSeconds,
                    appBinaries: dependencies.appBinaries),
                secret)
        } catch {
            return fail("Aufbewahrer startet nicht: \(error)")
        }
        let keeperPID = process.processIdentifier

        guard let client = connect(until: started.addingTimeInterval(dependencies.startTimeout)) else {
            kill(keeperPID, SIGTERM)
            return fail("Aufbewahrer antwortet nicht")
        }
        client.timeout = dependencies.ioTimeout
        defer { client.close() }

        var detached: [(item: Item, chat: HandoverDetachedChat)] = []
        func rollback(_ reason: String) -> Outcome {
            try? client.abort()
            for entry in detached { entry.item.source.reattachAfterFailedHandover() }
            // Vor COMMIT schließt der Aufbewahrer seine Kopien still.
            client.terminateKeeperIfStillTheSame()
            dependencies.secretStore.remove()
            return fail(reason)
        }

        do {
            try client.helloDeposit(secret: secret, expectedRunID: runID, expectedPID: keeperPID)
        } catch {
            return rollback("HELLO gescheitert: \(error)")
        }

        var notHandedOver: [UUID] = []
        for item in items {
            guard let chat = item.source.detachForHandoverDeposit() else {
                notHandedOver.append(item.source.sessionID)
                continue
            }
            detached.append((item, chat))
            do {
                try client.deposit(manifest: item.makeManifest(chat),
                                   descriptor: chat.handle.fileDescriptor, image: chat.image)
            } catch {
                return rollback("DEPOSIT gescheitert: \(error)")
            }
        }
        guard !detached.isEmpty else { return rollback("keine Leitung abgelöst") }

        guard dependencies.secretStore.store(secret) else {
            return rollback("Schlüsselbund nimmt das Geheimnis nicht an")
        }
        do {
            try client.commit()
        } catch {
            // `commit()` hat den Aufbewahrer schon per SIGTERM beendet; seine
            // Kopien schließt er (geordnet, falls er schon hielt). Die Originale
            // kommen zurück ans Terminal.
            for entry in detached { entry.item.source.reattachAfterFailedHandover() }
            dependencies.secretStore.remove()
            return fail("COMMIT gescheitert: \(error)")
        }

        let chats = detached.map { entry -> HandedOverChat in
            entry.item.source.completeHandover()
            return HandedOverChat(
                sessionID: entry.chat.sessionID,
                pid: entry.chat.handle.pid,
                pidStartTime: ProcessStartTime.of(pid: entry.chat.handle.pid)?.timeIntervalSince1970)
        }
        let duration = Int(Date().timeIntervalSince(started) * 1000)
        Logger.agentStore.notice(
            "handover_deposit_committed chats=\(chats.count) skipped=\(notHandedOver.count) ms=\(duration) run=\(runID, privacy: .public)")
        return .handedOver(runID: runID, keeperPID: keeperPID,
                           keeperStartTime: client.keeperStartTime?.timeIntervalSince1970,
                           chats: chats, notHandedOver: notHandedOver)
    }

    private func connect(until deadline: Date) -> HandoverClient? {
        repeat {
            if let client = try? HandoverClient.connect(paths: dependencies.paths, timeout: 0.5) {
                return client
            }
            usleep(20_000)
        } while Date() < deadline
        return nil
    }

    private func fail(_ reason: String) -> Outcome {
        Logger.agentStore.error("handover_deposit_failed reason=\(reason, privacy: .public)")
        return .failed(reason)
    }
}
