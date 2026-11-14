import Foundation
import os

// Nutzungslimit eines Chats (WM8-69): merken, zum Ende aufheben und
// Vorgemerktes zustellen, Turn-Enden erst nach frischem Poll melden. Aus dem
// Koordinator ausgelagert (Größen-Grenze).

extension AgentSessionStatusCoordinator {
    /// Nutzungslimit eines Chats erkannt oder vorbei (WM8-69): am Chat merken.
    func handleUsageLimit(sessionID: UUID, limit: AgentUsageLimit?) {
        let stored = store.loadWorkspace().sessions.first(where: { $0.id == sessionID })
        var stamped = limit
        if let limit {
            // Konto beim ersten Erkennen stempeln. Meldet der Watcher dieselbe
            // Zeile erneut (Neustart, Resume nach Kontowechsel), bleibt der alte
            // Stempel: dann gilt das Limit für den Chat nicht mehr (Review H3).
            let previous = stored?.usageLimit
            let sameLine = previous.map { $0.since == limit.since && $0.resetsAt == limit.resetsAt && $0.kind == limit.kind } ?? false
            stamped?.account = sameLine ? previous?.account : AgentUsageLimit.accountKey(stored?.claudeProfileName)
            if !sameLine {
                Logger.claudeBinding.notice(
                    "usage_limit_detected sessionID=\(sessionID.uuidString, privacy: .public) kind=\(limit.kind, privacy: .public) resetsAt=\(limit.resetsAt?.timeIntervalSince1970 ?? 0, privacy: .public) autoContinues=\(String(describing: limit.autoContinues), privacy: .public)")
            }
        }
        do {
            try store.setUsageLimit(stamped, for: sessionID)
        } catch {
            Logger.debug("Failed to record usage limit: \(error.localizedDescription)")
        }
        scheduleUsageLimitEnd(sessionID: sessionID)
        // Ende über den Verlauf (Claude macht von selbst weiter, der Normalfall):
        // Vorgemerktes bei den anderen Chats des Kontos anstoßen, die das
        // kontoweite Limit mit aufgehalten hat (Vic). Den Chat selbst bedient
        // sein Turn-Ende.
        if limit == nil, let previous = stored?.usageLimit, previous.blocksAccount, let account = previous.account {
            deliverQueuedToSiblings(of: sessionID, account: account, in: store.loadWorkspace().sessions)
        }
    }

    /// Stößt die Warteschlange der anderen Claude-Chats eines Kontos an.
    func deliverQueuedToSiblings(of sessionID: UUID, account: String, in sessions: [AgentChatSession]) {
        for other in sessions where other.id != sessionID && other.provider == .claude
            && AgentUsageLimit.accountKey(other.claudeProfileName) == account {
            deliverQueued(other.id)
        }
    }

    /// Ein Timer je Chat (Review H1): hebt das Limit nach dem Ende auf und
    /// stellt Vorgemerktes zu — auch wenn Claude nicht von selbst weitermacht
    /// und deshalb kein Turn-Ende kommt. Macht Claude von selbst weiter, gilt
    /// das zuerst: ein Auftrag zum Ende brächte das Weitermachen ab. Belegt kam
    /// Claudes Fortsetzung 1–10 min nach dem Ende, deshalb dann 20 min Vorlauf.
    /// Beim Aufwachen wird der gespeicherte Stand neu gelesen; die Uhr läuft
    /// im Ruhezustand weiter (`.continuous`, Review M1).
    func scheduleUsageLimitEnd(sessionID: UUID) {
        usageLimitTimers[sessionID]?.cancel()
        usageLimitTimers[sessionID] = nil
        guard let resetsAt = store.loadWorkspace().sessions.first(where: { $0.id == sessionID })?.usageLimit?.resetsAt
        else { return }
        usageLimitTimers[sessionID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      let current = self.store.loadWorkspace().sessions.first(where: { $0.id == sessionID })?.usageLimit,
                      current.resetsAt == resetsAt else { return }
                let grace: TimeInterval = current.autoContinues == true ? 20 * 60 : 5
                let wait = resetsAt.addingTimeInterval(grace).timeIntervalSinceNow
                if wait <= 0 { break }
                try? await Task.sleep(for: .seconds(wait), clock: .continuous)
            }
            guard !Task.isCancelled, let self else { return }
            self.usageLimitTimers[sessionID] = nil
            self.endUsageLimit(sessionID: sessionID)
        }
    }

    /// Limit vorbei: Anzeige aufheben (der Verlauf ändert sich dabei nicht)
    /// und Vorgemerktes zustellen — auch bei den anderen Chats desselben
    /// Kontos, die das kontoweite Limit mit aufgehalten hat (Jarvis A).
    func endUsageLimit(sessionID: UUID) {
        let sessions = store.loadWorkspace().sessions
        let account = sessions.first(where: { $0.id == sessionID })?.usageLimit?.account
        try? store.setUsageLimit(nil, for: sessionID)
        deliverQueued(sessionID)
        guard let account else { return }
        deliverQueuedToSiblings(of: sessionID, account: account, in: sessions)
    }

    /// Beim App-Start: für jeden gespeicherten Limit-Zustand den Timer planen
    /// (Jarvis B). Ein abgelaufener endet sofort; sonst feuerte der Timer nach
    /// einem Neustart nur, wenn der Watcher zufällig eine Änderung meldet.
    func scheduleStoredUsageLimitEnds() {
        for session in store.loadWorkspace().sessions where session.usageLimit?.resetsAt != nil {
            scheduleUsageLimitEnd(sessionID: session.id)
        }
    }

    /// Erst einen frischen Poll des Verlaufs abwarten (höchstens 2 s): Am
    /// Limit meldet Claudes Registry ein gewöhnliches Turn-Ende, bevor der
    /// Watcher die Limit-Zeile gelesen hat (Review H2).
    func afterFreshTranscript(_ sessionID: UUID, _ action: @escaping () -> Void) {
        if let freshTranscriptBeforeTurnEnd {
            freshTranscriptBeforeTurnEnd(sessionID, action)
            return
        }
        var done = false
        let run = {
            guard !done else { return }
            done = true
            action()
        }
        watcher.refresh(sessionID: sessionID, completion: run)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            run()
        }
    }
}
