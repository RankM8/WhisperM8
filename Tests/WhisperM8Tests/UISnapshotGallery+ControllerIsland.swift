import AppKit
import SwiftUI
@testable import WhisperM8

extension UISnapshotGallery {
    /// Dynamic Island am Controller, Insel-Paket: zwei Rauten unter R1 (an der
    /// Notch und als Pille), Bestätigung eines Schalters, Konto im Kopf,
    /// Limits-Karte mit vielen Konten und Fehlerzeile, L2 mit Markierung auf
    /// dem aktuellen Chat und „vorher“, Reiter „Workspaces & Projekte“.
    @MainActor
    static func islandPackageFixtures() -> [Fixture] {
        let notch = ControllerIslandDisplay.Style.notch(width: 184, height: 32)
        let session = UUID()
        var chatInfo = ControllerChatActionInfo(title: "Controller Insel")
        chatInfo.accounts = [
            ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "konto-2", label: "konto-2", isCurrent: false, isLoggedIn: true),
        ]
        chatInfo.usageAccount = ControllerUsageAccount(kind: .claude, name: "main")
        let setup = ControllerMenuSetup(
            acceptsInput: true, profile: .claude, sessionID: session, target: .chat(session), chat: chatInfo)

        func quickDraw(
            title: String = "Controller Insel", status: ControllerIslandStatus = .idle,
            setup: ControllerMenuSetup = setup, account: ControllerIslandAccountBadge?,
            app: ControllerAppToggles = ControllerAppToggles(alert: .all, nextAlert: .soundOff, awake: .whileWorking),
            confirmation: ControllerToggleConfirmation? = nil, hit: ControllerAppSlot? = nil,
            card: ControllerLimitsCard? = nil
        ) -> ControllerIslandModel {
            var slots = ControllerQuickDrawSlots(setup: setup)
            slots.app = app
            slots.account = account
            slots.confirmation = confirmation
            slots.appHit = hit
            slots.card = card
            return ControllerIslandModel(
                target: ControllerIslandTarget(title: title, status: status), content: .quickDraw(slots))
        }

        let mainBadge = ControllerIslandAccountBadge(name: "main", fiveHourUsed: 42)
        let duo = quickDraw(account: mainBadge)
        var busySetup = setup
        busySetup.chatBusy = true
        let duoBusy = quickDraw(
            title: "Kampagnen Import", status: .working, setup: busySetup,
            account: ControllerIslandAccountBadge(name: "konto-3", fiveHourUsed: 88))
        let duoGPT = quickDraw(
            title: "Lead Varianten", account: ControllerIslandAccountBadge(name: "gpt-main", fiveHourUsed: 57),
            app: ControllerAppToggles(alert: .soundOff, nextAlert: .off, awake: .off))
        let alertConfirm = quickDraw(
            account: mainBadge,
            app: ControllerAppToggles(alert: .soundOff, nextAlert: .off, awake: .whileWorking),
            confirmation: .alert(.soundOff, next: .off), hit: .alerts)
        let awakeConfirm = quickDraw(
            title: "Kampagnen Import", status: .working, setup: busySetup,
            account: ControllerIslandAccountBadge(name: "konto-3", fiveHourUsed: 88),
            app: ControllerAppToggles(alert: .all, nextAlert: .soundOff, awake: .always),
            confirmation: .awake(.always, next: .off), hit: .stayAwake)
        let awakePermission = quickDraw(
            account: mainBadge,
            app: ControllerAppToggles(alert: .all, nextAlert: .soundOff, awake: .off, awakeNeedsPermission: true),
            confirmation: .awakeNeedsPermission)
        var dictatingSetup = busySetup
        dictatingSetup.dictationRunning = true
        let duoDictating = quickDraw(title: "→ Controller Insel", status: .working, setup: dictatingSetup, account: mainBadge)

        let now = Date()
        func limitRow(
            _ kind: ControllerAccountChoice.Kind, _ name: String, _ five: Double?, _ fiveIn: TimeInterval,
            _ week: Double?, _ weekIn: TimeInterval, current: Bool = false, problem: String? = nil
        ) -> ControllerAccountLimitRow {
            ControllerAccountLimitRow(
                kind: kind, name: name, fiveHour: five, week: week,
                fiveHourResetsAt: now.addingTimeInterval(fiveIn), weekResetsAt: now.addingTimeInterval(weekIn),
                problem: problem, problemReplacesNumbers: problem != nil, isCurrentChat: current)
        }
        let hour: TimeInterval = 3600
        let fewAccounts = [
            limitRow(.claude, "main", 42, 2 * hour + 600, 61, 3 * 24 * hour, current: true),
            limitRow(.claude, "konto-2", 12, 4 * hour + 2100, 28, 5 * 24 * hour),
            limitRow(.claude, "konto-3", 88, 3000, 73, 30 * hour),
            limitRow(.gpt, "gpt-main", 23, 3 * hour + 300, 47, 4 * 24 * hour),
        ]
        let manyAccounts = [
            limitRow(.claude, "main", 42, 2 * hour + 600, 61, 3 * 24 * hour),
            limitRow(.claude, "konto-2", 12, 4 * hour + 2100, 28, 5 * 24 * hour),
            limitRow(.claude, "konto-3", nil, 0, nil, 0,
                     problem: ClaudeUsageFetchProblem.loginExpired.displayText),
            limitRow(.claude, "konto-4", 54, hour + 1200, 91, 2 * 24 * hour),
            limitRow(.claude, "konto-5", 3, 4 * hour, 15, 6 * 24 * hour),
            limitRow(.gpt, "gpt-main", 57, 3 * hour + 300, 47, 4 * 24 * hour, current: true),
            limitRow(.gpt, "gpt-2", 3, 4 * hour + 3480, 9, 6 * 24 * hour),
            limitRow(.gpt, "gpt-3", nil, 0, nil, 0, problem: AccountLimitsStore.Problem.gptFetchFailed.displayText),
        ]
        let card = quickDraw(
            account: mainBadge,
            card: ControllerLimitsCard(rows: fewAccounts, updatedAt: now.addingTimeInterval(-70), isLoading: false))
        // Während eines Diktats: Karte ohne „✕ aktualisieren“ (dort „geht nicht“).
        var dictatingCard = ControllerLimitsCard(rows: fewAccounts, updatedAt: now.addingTimeInterval(-70), isLoading: false)
        dictatingCard.canRefresh = false
        let cardDictating = quickDraw(
            title: "→ Controller Insel", status: .working, setup: dictatingSetup, account: mainBadge, card: dictatingCard)
        let cardMany = quickDraw(
            title: "Lead Varianten", account: ControllerIslandAccountBadge(name: "gpt-main", fiveHourUsed: 57),
            card: ControllerLimitsCard(rows: manyAccounts, updatedAt: now, isLoading: true))

        // L2: Markierung auf dem aktuellen Chat, „vorher“ einen Schritt darunter.
        let current = UUID()
        func chat(_ title: String, _ project: String, _ status: ControllerIslandStatus?, _ detail: String,
                  id: UUID = UUID()) -> ControllerIslandChatRow {
            ControllerIslandChatRow(id: id, title: title, project: project, status: status, detail: detail,
                                    isCurrent: id == current)
        }
        let previousChat = UUID()
        let chats = [
            chat("Controller Insel", "WhisperM8", .working, "jetzt", id: current),
            chat("Jarvis: Supervisor WhisperM8", "WhisperM8", .awaiting, "wartet · 2 min", id: previousChat),
            chat("E2E Befunde Raster", "WhisperM8", .idle, "bereit"),
            chat("Kampagnen Import", "ListM8", .working, "arbeitet · 6 min"),
            chat("Lead Varianten", "ListM8", .errored, "Fehler"),
        ]
        let projectView = UUID()
        let places = [
            ControllerWorkspaceChoice(id: UUID(), name: "WhisperM8", colorHex: "#5E6AD2", chatCount: 6,
                                      hasWaitingChat: false, isCurrent: true),
            ControllerWorkspaceChoice(id: UUID(), name: "ListM8", colorHex: "#3FA873", chatCount: 4,
                                      hasWaitingChat: true, isCurrent: false),
            ControllerWorkspaceChoice(id: UUID(), name: "WhisperM8", colorHex: "#5E6AD2", chatCount: 5,
                                      hasWaitingChat: true, isCurrent: false, kind: .project, viewWorkspaceID: projectView),
            ControllerWorkspaceChoice(id: UUID(), name: "DealSupply", colorHex: "#C9962A", chatCount: 2,
                                      hasWaitingChat: false, isCurrent: false, kind: .project),
        ]
        let target = ControllerIslandTarget(title: "Controller Insel", status: .working)
        let whereChats = ControllerIslandModel(target: target, content: .whereTo(ControllerWhereToState(
            chats: chats, currentChatID: current, workspaces: places, gridActive: false, previous: .chat(previousChat))))
        var placesState = ControllerWhereToState(
            chats: chats, currentChatID: current, workspaces: places, gridActive: true, previous: .workspace(projectView))
        // Die Projekt-Ansicht ist der vorige Ort: Ihre Zeile rückt gleich unter
        // den aktuellen Workspace, ein Schritt bis dorthin.
        placesState.move(1)
        let wherePlaces = ControllerIslandModel(target: target, content: .whereTo(placesState))

        func island(_ model: ControllerIslandModel, style: ControllerIslandDisplay.Style = notch) -> AnyView {
            let display = ControllerIslandDisplay(style: style, model: model)
            return AnyView(ControllerIslandView(display: display)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppTheme.sidebar))
        }
        let wide = CGSize(width: 760, height: 280)
        let wideNote = CGSize(width: 760, height: 320)
        let tall = CGSize(width: 760, height: 420)
        let list = CGSize(width: 620, height: 400)
        return [
            Fixture(name: "controller-insel-paket-rauten", size: wide) { island(duo) },
            Fixture(name: "controller-insel-paket-rauten-pille", size: wide) { island(duoGPT, style: .pill) },
            Fixture(name: "controller-insel-paket-rauten-arbeitet", size: wideNote) { island(duoBusy) },
            Fixture(name: "controller-insel-paket-rauten-diktat", size: wideNote) { island(duoDictating) },
            Fixture(name: "controller-insel-paket-glocke", size: wideNote) { island(alertConfirm) },
            Fixture(name: "controller-insel-paket-wach-pille", size: wideNote) { island(awakeConfirm, style: .pill) },
            Fixture(name: "controller-insel-paket-wach-freigabe", size: wideNote) { island(awakePermission) },
            Fixture(name: "controller-insel-paket-limits", size: tall) { island(card) },
            Fixture(name: "controller-insel-paket-limits-diktat", size: tall) { island(cardDictating) },
            Fixture(name: "controller-insel-paket-limits-viele-pille", size: tall) { island(cardMany, style: .pill) },
            Fixture(name: "controller-insel-paket-wohin-aktuell", size: list) { island(whereChats) },
            Fixture(name: "controller-insel-paket-wohin-projekte", size: list) { island(wherePlaces) },
            Fixture(name: "controller-insel-paket-wohin-projekte-pille", size: list) { island(wherePlaces, style: .pill) },
        ]
    }
}
