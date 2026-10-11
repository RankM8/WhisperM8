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
            Text("Zielkonto: \(targetDisplayName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch phase {
        case .preview:
            return decision.actionableCount == 1
                ? "Chat in anderes Konto verschieben?"
                : "\(decision.actionableCount) Chats in anderes Konto verschieben?"
        case .running:
            return decision.switchNow.isEmpty ? "Verschiebe …" : "Verschiebe und setze fort …"
        case .finished:
            return "Umzug abgeschlossen"
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
                Text("\(done) von \(total) verschoben")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !decision.switchNow.isEmpty {
                    Text("Laufende Chats werden angehalten, umgezogen und im Tab fortgesetzt — das dauert wenige Sekunden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Der Abbruch wirkt nach dem aktuellen Chat — ein Transcript wird nie halb verschoben.")
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
                    Label("Kein Chat aus dieser Auswahl kann umziehen.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if decision.actionableCount > 0,
                   !pending.missingMCPServers.isEmpty || !pending.untrustedTitles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !pending.missingMCPServers.isEmpty {
                            Label("Im Zielkonto fehlen MCP-Server: \(pending.missingMCPServers.joined(separator: ", ")).",
                                  systemImage: "puzzlepiece.extension")
                        }
                        if !pending.untrustedTitles.isEmpty {
                            Label("\(targetDisplayName) hat den Ordner noch nicht freigegeben: Claude fragt beim Start nach — dort „Yes, I trust this folder“ wählen (vorausgewählt ist „No, exit“). Betrifft: \(pending.untrustedTitles.prefix(3).joined(separator: ", "))\(pending.untrustedTitles.count > 3 ? " …" : "")",
                                  systemImage: "lock.shield")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !decision.moveNow.isEmpty {
                    section(
                        title: "Wird verschoben (\(decision.moveNow.count))",
                        systemImage: "arrow.right.circle",
                        titles: decision.moveNow.map(\.title)
                    )
                }
                if !decision.switchNow.isEmpty {
                    section(
                        title: "Läuft — wird angehalten, verschoben und im Tab fortgesetzt (\(decision.switchNow.count))",
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
                        title: "Nicht gewechselt — \(group.reason.label) (\(group.titles.count))",
                        systemImage: "hand.raised",
                        titles: group.titles,
                        muted: true
                    )
                }
                ForEach(skippedGroups, id: \.reason) { group in
                    section(
                        title: "Übersprungen — \(group.reason.label) (\(group.candidates.count))",
                        systemImage: "minus.circle",
                        titles: group.candidates.map(\.title),
                        muted: true
                    )
                }

                if decision.actionableCount > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Ab dem nächsten Start zahlt das Kontingent von \(targetDisplayName).",
                              systemImage: "gauge.with.needle")
                        Label("Der Gesprächsverlauf zieht vollständig mit. Checkpoints und Datei-Historie (Rewind) bleiben im bisherigen Konto zurück.",
                              systemImage: "clock.arrow.circlepath")
                        if !decision.switchNow.isEmpty || !decision.waitForTurn.isEmpty {
                            Label("Im neuen Konto liest Claude den Verlauf einmal ohne Cache neu ein — bei großen Chats kostet das spürbar Kontingent. Früheres Thinking bleibt beim alten Konto.",
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
                        title: "Verschoben (\(outcome.moved.count))",
                        systemImage: "checkmark.circle",
                        titles: outcome.moved.map(\.sessionTitle)
                    )
                }
                if !decision.waitForTurn.isEmpty {
                    section(
                        title: "Vorgemerkt — wechselt nach dem Turn (\(decision.waitForTurn.count))",
                        systemImage: "clock",
                        titles: decision.waitForTurn.map(\.candidate.title)
                    )
                    Text("Aufheben: Rechtsklick auf den Chat → Zu Account verschieben → Kontowechsel aufheben.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !outcome.skippedRunning.isEmpty {
                    section(
                        title: "Nicht zurückgenommen — läuft gerade (\(outcome.skippedRunning.count))",
                        systemImage: "play.circle",
                        titles: outcome.skippedRunning,
                        muted: true
                    )
                }
                if outcome.wasCancelled {
                    Label("Abgebrochen — die bereits verschobenen Chats bleiben im Zielkonto.",
                          systemImage: "stop.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if !outcome.failed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Fehlgeschlagen (\(outcome.failed.count))", systemImage: "xmark.circle")
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
                Text("… und \(titles.count - 12) weitere")
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
                Button("Abbrechen", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(decision.actionableCount == 1 ? "Verschieben" : "\(decision.actionableCount) verschieben") {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(decision.actionableCount == 0)
            }
        case .running:
            HStack {
                Button("Abbrechen", role: .cancel, action: onCancelRun)
                Spacer()
            }
        case .finished(let outcome):
            HStack {
                // Rueckgaengig macht den Batch ueber das Journal rueckgaengig —
                // dieselbe Bewegung mit vertauschten Argumenten.
                Button("Rückgängig", action: onUndo)
                    .disabled(outcome.moved.isEmpty)
                Spacer()
                Button("Fertig", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
