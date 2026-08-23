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

    let plan: AccountMovePlanner.Plan
    let targetDisplayName: String
    @Binding var phase: Phase
    let onConfirm: () -> Void
    let onCancelRun: () -> Void
    let onUndo: () -> Void
    let onClose: () -> Void

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
            return plan.movable.count == 1
                ? "Chat in anderes Konto verschieben?"
                : "\(plan.movable.count) Chats in anderes Konto verschieben?"
        case .running:
            return "Verschiebe …"
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
                if plan.movable.isEmpty {
                    Label("Kein Chat aus dieser Auswahl kann umziehen.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    section(
                        title: "Wird verschoben (\(plan.movable.count))",
                        systemImage: "arrow.right.circle",
                        titles: plan.movable.map(\.title)
                    )
                }

                ForEach(plan.skippedByReason(), id: \.reason) { group in
                    section(
                        title: "Übersprungen — \(group.reason.label) (\(group.candidates.count))",
                        systemImage: "minus.circle",
                        titles: group.candidates.map(\.title),
                        muted: true
                    )
                }

                if !plan.movable.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Ab dem nächsten Start zahlt das Kontingent von \(targetDisplayName).",
                              systemImage: "gauge.with.needle")
                        Label("Der Gesprächsverlauf zieht vollständig mit. Checkpoints und Datei-Historie (Rewind) bleiben im bisherigen Konto zurück.",
                              systemImage: "clock.arrow.circlepath")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
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
                Button(plan.movable.count == 1 ? "Verschieben" : "\(plan.movable.count) verschieben") {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.movable.isEmpty)
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
