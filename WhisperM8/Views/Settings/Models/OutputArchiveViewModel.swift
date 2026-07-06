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
        report(matching: selectedReportID) ?? filteredReports.first
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
        guard let reportID else {
            selectedReportID = nil
            return
        }
        selectedReportID = report(matching: reportID)?.id
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
        if report(matching: selectedReportID) == nil {
            selectedReportID = filteredReports.first?.id
        }
    }

    private func reconcileSelection() {
        let visible = filteredReports
        if let preselectReportID, report(matching: preselectReportID) != nil {
            selectedReportID = preselectReportID
            self.preselectReportID = nil
        } else if report(matching: selectedReportID) == nil {
            selectedReportID = visible.first?.id
        }
    }

    private func report(matching reportID: UUID?) -> TranscriptRunReport? {
        guard let reportID else { return nil }
        return reports.first { $0.id == reportID }
    }
}
