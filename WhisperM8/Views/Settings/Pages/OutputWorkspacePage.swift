import SwiftUI

struct OutputWorkspacePage: View {
    @Environment(AppState.self) private var appState
    @State private var model: OutputArchiveViewModel
    @State private var reportPendingDeletion: TranscriptRunReport?
    @State private var isConfirmingDelete = false

    init(
        preselectReportID: UUID? = nil,
        store: TranscriptRunReportStore = TranscriptRunReportStore()
    ) {
        _model = State(initialValue: OutputArchiveViewModel(
            store: store,
            preselectReportID: preselectReportID
        ))
    }

    var body: some View {
        SettingsPageContainer(
            title: "Output",
            subtitle: "Your dictation results: latest run plus the full archive."
        ) {
            latestRun
            archiveWorkspace
        }
        .onAppear {
            updateFallbackFromAppState()
            model.reload()
        }
        .onChange(of: model.searchText) { _, _ in model.ensureSelectionIsVisible() }
        .onChange(of: model.scope) { _, _ in model.ensureSelectionIsVisible() }
        .onChange(of: model.status) { _, _ in model.ensureSelectionIsVisible() }
        .confirmationDialog("Delete report?", isPresented: $isConfirmingDelete) {
            Button("Delete Report", role: .destructive) {
                if let reportPendingDeletion {
                    model.delete(report: reportPendingDeletion)
                    self.reportPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                reportPendingDeletion = nil
            }
        } message: {
            Text("This removes the report and its attachments from the local archive.")
        }
    }

    @ViewBuilder
    private var latestRun: some View {
        SettingsSection("Latest Run") {
            if let report = model.latestReport {
                Button {
                    model.select(reportID: report.id)
                } label: {
                    LatestReportRow(report: report)
                }
                .buttonStyle(.plain)
            } else if let fallback = model.latestFallback {
                LatestFallbackRow(fallback: fallback)
            } else {
                EmptyOutputPanel(
                    title: "No output yet",
                    systemImage: "clock.arrow.circlepath",
                    description: "Recorded outputs will appear here."
                )
            }
        }
    }

    private var archiveWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            archiveToolbar

            HStack(alignment: .top, spacing: 18) {
                archiveList
                    .frame(width: 360, alignment: .topLeading)

                detailPane
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var archiveToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.textTertiary)

                TextField("Search raw, final, app...", text: $model.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppTheme.control)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }

            Picker("Scope", selection: $model.scope) {
                Text("All modes").tag(OutputHistoryScope.all)
                Text("Tasks").tag(OutputHistoryScope.tasks)
            }
            .labelsHidden()
            .frame(width: 150)

            Picker("Status", selection: $model.status) {
                Text("Any status").tag(Optional<TranscriptRunStatus>.none)
                ForEach(statusOptions, id: \.self) { status in
                    Text(status.displayText).tag(Optional(status))
                }
            }
            .labelsHidden()
            .frame(width: 190)

            Button {
                updateFallbackFromAppState()
                model.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Reload output archive")
            .buttonStyle(SettingsButtonStyle.standard)
        }
    }

    @ViewBuilder
    private var archiveList: some View {
        if model.filteredReports.isEmpty {
            EmptyOutputPanel(
                title: model.reports.isEmpty ? "No Output Yet" : "No Matches",
                systemImage: model.reports.isEmpty ? "clock.arrow.circlepath" : "line.3.horizontal.decrease.circle",
                description: model.reports.isEmpty
                    ? "Recorded outputs will appear here."
                    : "No output matches the current filter."
            )
        } else {
            VStack(spacing: 2) {
                ForEach(model.filteredReports) { report in
                    Button {
                        model.select(reportID: report.id)
                    } label: {
                        OutputArchiveReportRow(
                            report: report,
                            isSelected: model.selectedReport?.id == report.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedReport = model.selectedReport {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Detail")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    Spacer()

                    Button(role: .destructive) {
                        confirmDelete(selectedReport)
                    } label: {
                        Label("Delete Report...", systemImage: "trash")
                    }
                    .buttonStyle(SettingsButtonStyle.destructive)
                }

                TranscriptReportDetailView(report: selectedReport) {
                    confirmDelete(selectedReport)
                }
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.statusError)
                }
            }
        } else {
            EmptyOutputPanel(
                title: model.reports.isEmpty ? "No Output Yet" : "No Matches",
                systemImage: model.reports.isEmpty ? "clock.arrow.circlepath" : "line.3.horizontal.decrease.circle",
                description: model.reports.isEmpty
                    ? "Recorded outputs will appear here."
                    : "No output matches the current filter."
            )
        }
    }

    private var statusOptions: [TranscriptRunStatus] {
        [.succeeded, .rawFallback, .cautiousFallback, .failed]
    }

    private func updateFallbackFromAppState() {
        model.setLatestFallback(OutputArchiveFallback(
            mode: appState.lastOutputMode,
            rawTranscript: appState.lastRawTranscription,
            finalTranscript: appState.lastFinalTranscription ?? appState.lastTranscription,
            createdAt: nil
        ))
    }

    private func confirmDelete(_ report: TranscriptRunReport) {
        reportPendingDeletion = report
        isConfirmingDelete = true
    }
}

private struct LatestReportRow: View {
    let report: TranscriptRunReport

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(report.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                LatestTranscriptPreviews(
                    rawTranscript: report.rawTranscript,
                    finalTranscript: report.finalTranscript,
                    emptyText: report.errorMessage ?? "No transcript"
                )
            }

            VStack(alignment: .trailing, spacing: 7) {
                OutputStatusChip(status: report.status)
                Text(report.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }
}

private struct LatestFallbackRow: View {
    let fallback: OutputArchiveFallback

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(fallback.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                if let createdAt = fallback.createdAt {
                    Text(createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }

            LatestTranscriptPreviews(
                rawTranscript: fallback.rawTranscript,
                finalTranscript: fallback.finalTranscript,
                emptyText: "No transcript"
            )
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }
}

private struct LatestTranscriptPreviews: View {
    let rawTranscript: String?
    let finalTranscript: String?
    let emptyText: String

    private var rawPreview: String? {
        Self.visibleText(rawTranscript)
    }

    private var finalPreview: String? {
        Self.visibleText(finalTranscript)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let rawPreview {
                LatestTranscriptPreviewBlock(title: "Raw Transcript", text: rawPreview)
            }

            if let finalPreview {
                LatestTranscriptPreviewBlock(title: "Final / Fallback", text: finalPreview)
            }

            if rawPreview == nil && finalPreview == nil {
                Text(emptyText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func visibleText(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}

private struct LatestTranscriptPreviewBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.textTertiary)

            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OutputArchiveReportRow: View {
    let report: TranscriptRunReport
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(report.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textPrimary)
                    .lineLimit(1)

                Text(report.shortSummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                OutputStatusChip(status: report.status)
                Text(relativeDate(report.createdAt))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? AppTheme.accentTint : AppTheme.surface.opacity(0))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct OutputStatusChip: View {
    let status: TranscriptRunStatus

    var body: some View {
        Text(status.displayText)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tone.color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var tone: SettingsStatusTone {
        switch status {
        case .succeeded:
            return .ok
        case .rawFallback, .cautiousFallback:
            return .warn
        case .failed:
            return .error
        }
    }
}

private struct EmptyOutputPanel: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(AppTheme.textTertiary)

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(18)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}
