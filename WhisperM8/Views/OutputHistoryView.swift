import SwiftUI

/// Vollständige Output-History als Master-Detail: links die gefilterte,
/// durchsuchbare Liste aller persistierten Runs, rechts das bestehende
/// `TranscriptReportDetailView` (Raw/Final vollständig + kopierbar). Ersetzt
/// die bisher nur im toten „Output Reports"-Fenster erreichbaren Reports/Tasks.
struct OutputHistoryView: View {
    /// Report, der beim Öffnen vorselektiert werden soll (z. B. aus der
    /// Overview-Karte). Nil → neuester Run wird gewählt.
    var preselectReportID: UUID?

    @State private var store = TranscriptRunReportStore()
    @State private var reports: [TranscriptRunReport] = []
    @State private var selectedReportID: UUID?
    @State private var filter = OutputHistoryFilter()
    @State private var errorMessage: String?

    private var filteredReports: [TranscriptRunReport] {
        filter.apply(to: reports)
    }

    private var selectedReport: TranscriptRunReport? {
        filteredReports.first { $0.id == selectedReportID } ?? filteredReports.first
    }

    var body: some View {
        HStack(spacing: 0) {
            historyList
                .frame(width: 340)

            Divider()

            if let selectedReport {
                TranscriptReportDetailView(report: selectedReport) {
                    delete(selectedReport)
                }
            } else {
                ContentUnavailableView(
                    reports.isEmpty ? "No Output Yet" : "No Matches",
                    systemImage: reports.isEmpty ? "clock.arrow.circlepath" : "line.3.horizontal.decrease.circle",
                    description: Text(reports.isEmpty
                        ? "Recorded outputs will appear here."
                        : "No output matches the current filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("History")
        .onAppear(perform: reload)
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Text("\(filteredReports.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload history")
            }
            .padding([.top, .horizontal], 16)

            Picker("Scope", selection: $filter.scope) {
                ForEach(OutputHistoryScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search raw, final, app…", text: $filter.searchText)
                    .textFieldStyle(.plain)

                Menu {
                    Button("All statuses") { filter.status = nil }
                    Divider()
                    ForEach(statusFilterOptions, id: \.self) { status in
                        Button(status.displayText) { filter.status = status }
                    }
                } label: {
                    Image(systemName: filter.status == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(filter.status.map { "Status: \($0.displayText)" } ?? "Filter by status")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)

            List(selection: $selectedReportID) {
                ForEach(filteredReports) { report in
                    OutputHistoryRow(report: report)
                        .tag(report.id)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var statusFilterOptions: [TranscriptRunStatus] {
        [.succeeded, .rawFallback, .cautiousFallback, .failed]
    }

    private func reload() {
        reports = store.recentReports(limit: 200)
        // Vorselektion: explizit angeforderter Report, sonst aktuelle Auswahl
        // beibehalten, sonst neuester sichtbarer Run.
        let visible = filteredReports
        if let preselectReportID, visible.contains(where: { $0.id == preselectReportID }) {
            selectedReportID = preselectReportID
        } else if selectedReportID == nil || !visible.contains(where: { $0.id == selectedReportID }) {
            selectedReportID = visible.first?.id
        }
        errorMessage = nil
    }

    private func delete(_ report: TranscriptRunReport) {
        do {
            try store.delete(report)
            reports.removeAll { $0.id == report.id }
            if selectedReportID == report.id {
                selectedReportID = filteredReports.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct OutputHistoryRow: View {
    let report: TranscriptRunReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(report.mode.shortLabel)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(report.status.displayText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Text(report.sourceAppName ?? "Unknown app")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(report.shortSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(report.createdAt, format: .dateTime.month().day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var statusColor: Color {
        switch report.status {
        case .succeeded:
            return .green
        case .rawFallback, .cautiousFallback:
            return .orange
        case .failed:
            return .red
        }
    }
}
