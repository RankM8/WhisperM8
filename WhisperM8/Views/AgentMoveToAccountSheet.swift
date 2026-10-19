import SwiftUI

/// Vorschau, Bestaetigung, Fortschritt und Ergebnis eines Konto-Umzugs.
///
/// Bewusst ein Sheet statt eines `confirmationDialog`: der Nutzer muss VOR der
/// Entscheidung sehen, was uebersprungen wird und warum — ein Bulk, der still
/// die Haelfte auslaesst, ist schlimmer als gar keiner. Ausserdem gehen zwei
/// Nebenwirkungen hier nicht unter: das Kontingent des Zielkontos zahlt ab
/// dem naechsten Turn, und die Checkpoint-/Datei-Historie der Session bleibt
/// im Herkunftskonto zurueck.
struct AgentMoveToAccountSheet: View {
    enum Phase: Equatable {
        case preview
        case running(done: Int, total: Int)
        case finished(AccountMoveService.Outcome)
    }

    let pending: PendingAccountMove
    @Binding var phase: Phase
    let onConfirm: () -> Void
    let onCancelRun: () -> Void
    let onUndo: () -> Void
    let onClose: () -> Void

    private var decision: AccountSwitchPlanner.Decision { pending.decision }
    private var targetDisplayName: String { pending.targetDisplayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text("Target account: \(targetDisplayName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch phase {
        case .preview:
            return decision.actionableCount == 1
                ? String(localized: "Move chat to another account?")
                : String(localized: "Move \(decision.actionableCount) chats to another account?")
        case .running:
            return decision.switchNow.isEmpty ? String(localized: "Moving …") : String(localized: "Moving and resuming …")
        case .finished:
            return String(localized: "Move finished")
        }
    }

    // MARK: - Inhalt

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preview:
            previewContent
        case .running(let done, let total):
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(done) of \(total) moved")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !decision.switchNow.isEmpty {
                    Text("Running chats are paused, moved and resumed in their tab — this takes a few seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Cancelling takes effect after the current chat — a transcript is never moved halfway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished(let outcome):
            finishedContent(outcome)
        }
    }

    private var previewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if decision.actionableCount == 0 {
                    Label("No chat in this selection can be moved.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if decision.actionableCount > 0,
                   !pending.missingMCPServers.isEmpty || !pending.untrustedTitles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !pending.missingMCPServers.isEmpty {
                            Label("The target account is missing MCP servers: \(pending.missingMCPServers.joined(separator: ", ")).",
                                  systemImage: "puzzlepiece.extension")
                        }
                        if !pending.untrustedTitles.isEmpty {
                            Label("\(targetDisplayName) has not approved the folder yet: Claude asks on start — choose “Yes, I trust this folder” there (“No, exit” is preselected). Affects: \(pending.untrustedTitles.prefix(3).joined(separator: ", "))\(pending.untrustedTitles.count > 3 ? " …" : "")",
                                  systemImage: "lock.shield")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !decision.moveNow.isEmpty {
                    section(
                        title: String(localized: "Being moved (\(decision.moveNow.count))"),
                        systemImage: "arrow.right.circle",
                        titles: decision.moveNow.map(\.title)
                    )
                }
                if !decision.switchNow.isEmpty {
                    section(
                        title: String(localized: "Running — will be paused, moved and resumed in its tab (\(decision.switchNow.count))"),
                        systemImage: "arrow.triangle.2.circlepath",
                        titles: decision.switchNow.map(\.title)
                    )
                }
                ForEach(waitGroups, id: \.reason) { group in
                    section(
                        title: "\(group.reason.label) (\(group.titles.count))",
                        systemImage: "clock",
                        titles: group.titles
                    )
                }
                ForEach(blockedGroups, id: \.reason) { group in
                    section(
                        title: String(localized: "Not switched — \(group.reason.label) (\(group.titles.count))"),
                        systemImage: "hand.raised",
                        titles: group.titles,
                        muted: true
                    )
                }
                ForEach(skippedGroups, id: \.reason) { group in
                    section(
                        title: String(localized: "Skipped — \(group.reason.label) (\(group.candidates.count))"),
                        systemImage: "minus.circle",
                        titles: group.candidates.map(\.title),
                        muted: true
                    )
                }

                if decision.actionableCount > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("From the next start, the quota of \(targetDisplayName) is used.",
                              systemImage: "gauge.with.needle")
                        Label("The conversation history moves along completely. Checkpoints and file history (rewind) stay in the previous account.",
                              systemImage: "clock.arrow.circlepath")
                        if !decision.switchNow.isEmpty || !decision.waitForTurn.isEmpty {
                            Label("In the new account Claude re-reads the history once without cache — for large chats this noticeably costs quota. Earlier thinking stays with the old account.",
                                  systemImage: "arrow.clockwise")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 400)
    }

    private var waitGroups: [(reason: AccountSwitchPlanner.WaitReason, titles: [String])] {
        let order: [AccountSwitchPlanner.WaitReason] = [.turnRunning, .backgroundTasks, .awaitingInput, .unsentInput]
        return order.compactMap { reason in
            let titles = decision.waitForTurn.filter { $0.reason == reason }.map(\.candidate.title)
            return titles.isEmpty ? nil : (reason, titles)
        }
    }

    private var blockedGroups: [(reason: AccountSwitchPlanner.BlockReason, titles: [String])] {
        let order: [AccountSwitchPlanner.BlockReason] = [.trustMissing, .ownSession]
        return order.compactMap { reason in
            let titles = decision.blocked.filter { $0.reason == reason }.map(\.candidate.title)
            return titles.isEmpty ? nil : (reason, titles)
        }
    }

    /// Skip-Gründe des Planers, ohne „läuft gerade" — das entscheidet jetzt
    /// `decision` (bei abgeschaltetem Feature steht es dort wieder drin).
    private var skippedGroups: [(reason: AccountMovePlanner.SkipReason, candidates: [AccountMovePlanner.Candidate])] {
        AccountMovePlanner.Plan(targetProfile: decision.targetProfile, movable: [], skipped: decision.skipped)
            .skippedByReason()
    }

    private func finishedContent(_ outcome: AccountMoveService.Outcome) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !outcome.moved.isEmpty {
                    section(
                        title: String(localized: "Moved (\(outcome.moved.count))"),
                        systemImage: "checkmark.circle",
                        titles: outcome.moved.map(\.sessionTitle)
                    )
                }
                if !decision.waitForTurn.isEmpty {
                    section(
                        title: String(localized: "Scheduled — switches after the turn (\(decision.waitForTurn.count))"),
                        systemImage: "clock",
                        titles: decision.waitForTurn.map(\.candidate.title)
                    )
                    Text("To cancel: right-click the chat → Move to account → Cancel account switch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !outcome.skippedRunning.isEmpty {
                    section(
                        title: String(localized: "Not reverted — running right now (\(outcome.skippedRunning.count))"),
                        systemImage: "play.circle",
                        titles: outcome.skippedRunning,
                        muted: true
                    )
                }
                if outcome.wasCancelled {
                    Label("Cancelled — chats already moved stay in the target account.",
                          systemImage: "stop.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if !outcome.failed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Failed (\(outcome.failed.count))", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                        ForEach(Array(outcome.failed.enumerated()), id: \.offset) { _, failure in
                            Text("• \(failure.title): \(failure.message)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
    }

    private func section(
        title: String,
        systemImage: String,
        titles: [String],
        muted: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            ForEach(Array(titles.prefix(12).enumerated()), id: \.offset) { _, name in
                Text("• \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if titles.count > 12 {
                Text("… and \(titles.count - 12) more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Fuss

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .preview:
            HStack {
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(decision.actionableCount == 1 ? String(localized: "Move") : String(localized: "Move \(decision.actionableCount)")) {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(decision.actionableCount == 0)
            }
        case .running:
            HStack {
                Button("Cancel", role: .cancel, action: onCancelRun)
                Spacer()
            }
        case .finished(let outcome):
            HStack {
                // Rueckgaengig macht den Batch ueber das Journal rueckgaengig —
                // dieselbe Bewegung mit vertauschten Argumenten.
                Button("Undo", action: onUndo)
                    .disabled(outcome.moved.isEmpty)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
