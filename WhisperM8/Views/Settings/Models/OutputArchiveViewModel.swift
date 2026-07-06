import Foundation
import Observation

struct OutputArchiveFallback: Equatable {
    var mode: OutputMode?
    var rawTranscript: String?
    var finalTranscript: String?
    var createdAt: Date?

    var title: String {
        let modeName = mode?.name ?? "Latest Output"
        return "\(modeName) · AppState"
    }

    var shortSummary: String {
        if let finalTranscript, !finalTranscript.isEmpty {
            return finalTranscript
        }
        if let rawTranscript, !rawTranscript.isEmpty {
            return rawTranscript
        }
        return "No transcript"
    }

    var hasVisibleOutput: Bool {
        rawTranscript?.isEmpty == false || finalTranscript?.isEmpty == false
    }
}

@MainActor
@Observable
final class OutputArchiveViewModel {
    private(set) var reports: [TranscriptRunReport] = []
    var selectedReportID: UUID?
    var searchText = ""
    var scope: OutputHistoryScope = .all
    var status: TranscriptRunStatus?
    var errorMessage: String?
    var latestFallback: OutputArchiveFallback?

    @ObservationIgnored private let store: TranscriptRunReportStore
    @ObservationIgnored private var preselectReportID: UUID?

    init(
        store: TranscriptRunReportStore = TranscriptRunReportStore(),
        preselectReportID: UUID? = nil,
        latestFallback: OutputArchiveFallback? = nil
    ) {
        self.store = store
        self.preselectReportID = preselectReportID
        self.latestFallback = latestFallback?.hasVisibleOutput == true ? latestFallback : nil
    }

    var filter: OutputHistoryFilter {
        OutputHistoryFilter(scope: scope, status: status, searchText: searchText)
    }

    var filteredReports: [TranscriptRunReport] {
        filter.apply(to: reports)
    }

    var latestReport: TranscriptRunReport? {
        reports.first
    }

    var selectedReport: TranscriptRunReport? {
        filteredReports.first { $0.id == selectedReportID } ?? filteredReports.first
    }

    var hasFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || scope != .all
            || status != nil
    }

    func setLatestFallback(_ fallback: OutputArchiveFallback?) {
        latestFallback = fallback?.hasVisibleOutput == true ? fallback : nil
    }

    func reload() {
        reports = store.recentReports(limit: 200)
        reconcileSelection()
        errorMessage = nil
    }

    func select(reportID: UUID?) {
        selectedReportID = reportID
    }

    func delete(report: TranscriptRunReport) {
        do {
            try store.delete(report)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func ensureSelectionIsVisible() {
        let visible = filteredReports
        if selectedReportID == nil || !visible.contains(where: { $0.id == selectedReportID }) {
            selectedReportID = visible.first?.id
        }
    }

    private func reconcileSelection() {
        let visible = filteredReports
        if let preselectReportID, visible.contains(where: { $0.id == preselectReportID }) {
            selectedReportID = preselectReportID
            self.preselectReportID = nil
        } else if selectedReportID == nil || !visible.contains(where: { $0.id == selectedReportID }) {
            selectedReportID = visible.first?.id
        }
    }
}
