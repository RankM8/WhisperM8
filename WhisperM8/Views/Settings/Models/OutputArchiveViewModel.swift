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
    static let pageSize = 50

    private(set) var reports: [TranscriptRunReportSummary] = []
    var selectedReportID: UUID?
    private(set) var selectedReport: TranscriptRunReport?
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            restartFullTextSearch()
            ensureSelectionIsVisible()
        }
    }
    var scope: OutputHistoryScope = .all {
        didSet {
            guard scope != oldValue else { return }
            ensureSelectionIsVisible()
        }
    }
    var status: TranscriptRunStatus? {
        didSet {
            guard status != oldValue else { return }
            ensureSelectionIsVisible()
        }
    }
    var errorMessage: String?
    var latestFallback: OutputArchiveFallback?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isLoadingDetail = false
    private(set) var hasMore = true
    private(set) var searchingDeeper = false

    @ObservationIgnored private let store: TranscriptRunReportStore
    @ObservationIgnored private var preselectReportID: UUID?
    @ObservationIgnored private var pageGeneration = 0
    @ObservationIgnored private var detailGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var fullTextSearchTask: Task<Void, Never>?
    @ObservationIgnored private var cachedReports: [UUID: TranscriptRunReport] = [:]
    @ObservationIgnored private var reportCacheOrder: [UUID] = []
    @ObservationIgnored private var fullTextMatches: [TranscriptRunReportSummary] = []

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

    var filteredReports: [TranscriptRunReportSummary] {
        let query = normalizedSearchText
        let baseMatches = reports.filter { summary in
            matchesScope(summary)
                && matchesStatus(summary)
                && matchesSummarySearch(summary, query: query)
        }
        let deeperMatches = fullTextMatches.filter { summary in
            matchesScope(summary) && matchesStatus(summary)
        }

        return sortedUnique(baseMatches + deeperMatches)
    }

    var latestReport: TranscriptRunReportSummary? {
        reports.first
    }

    var hasFilters: Bool {
        !normalizedSearchText.isEmpty
            || scope != .all
            || status != nil
    }

    func setLatestFallback(_ fallback: OutputArchiveFallback?) {
        latestFallback = fallback?.hasVisibleOutput == true ? fallback : nil
    }

    func initialLoad() async {
        guard reports.isEmpty, !isLoading else { return }
        await loadFirstPage()
    }

    func reload() async {
        preselectReportID = selectedReportID ?? preselectReportID
        reports = []
        fullTextMatches = []
        hasMore = true
        await loadFirstPage()
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore, let cursor = pageCursor else { return }

        isLoadingMore = true
        errorMessage = nil
        let generation = pageGeneration
        let store = self.store
        let pageSize = Self.pageSize
        let page = await Task.detached(priority: .utility) {
            store.reportSummaries(before: cursor, limit: pageSize)
        }.value

        guard generation == pageGeneration, !Task.isCancelled else { return }

        reports = sortedUnique(reports + page)
        hasMore = page.count == Self.pageSize
        isLoadingMore = false
        restartFullTextSearch()
        ensureSelectionIsVisible()
    }

    func select(id reportID: UUID?) {
        detailGeneration += 1
        detailTask?.cancel()

        guard let reportID else {
            selectedReportID = nil
            selectedReport = nil
            isLoadingDetail = false
            return
        }

        selectedReportID = reportID
        if let cached = cachedReport(id: reportID) {
            selectedReport = cached
            isLoadingDetail = false
            errorMessage = nil
            return
        }

        selectedReport = nil
        isLoadingDetail = true
        errorMessage = nil

        let generation = detailGeneration
        let store = self.store
        detailTask = Task { @MainActor in
            let report = await Task.detached(priority: .userInitiated) {
                store.loadReport(id: reportID)
            }.value

            guard generation == detailGeneration, !Task.isCancelled else { return }

            if let report {
                cache(report)
                selectedReport = report
            } else {
                selectedReportID = nil
                selectedReport = nil
                errorMessage = "Report could not be loaded."
            }
            isLoadingDetail = false
        }
    }

    func delete(id reportID: UUID) async {
        errorMessage = nil
        let store = self.store
        let cached = cachedReports[reportID] ?? (selectedReport?.id == reportID ? selectedReport : nil)
        let result = await Task.detached(priority: .utility) { () -> Result<Void, Error> in
            guard let report = cached ?? store.loadReport(id: reportID) else {
                return .success(())
            }

            do {
                try store.delete(report)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:
            removeLocalReport(id: reportID)
            ensureSelectionIsVisible()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func ensureSelectionIsVisible() {
        let visible = filteredReports
        if let selectedReportID, visible.contains(where: { $0.id == selectedReportID }) {
            return
        }

        select(id: visible.first?.id)
    }

    private func loadFirstPage() async {
        pageGeneration += 1
        let generation = pageGeneration
        isLoading = true
        isLoadingMore = false
        errorMessage = nil

        let store = self.store
        let pageSize = Self.pageSize
        let page = await Task.detached(priority: .utility) {
            store.reportSummaries(limit: pageSize)
        }.value

        guard generation == pageGeneration, !Task.isCancelled else { return }

        reports = page
        hasMore = page.count == Self.pageSize
        isLoading = false
        restartFullTextSearch()
        reconcileSelectionAfterPageLoad()
    }

    private func reconcileSelectionAfterPageLoad() {
        if let preselectReportID {
            self.preselectReportID = nil
            select(id: preselectReportID)
            return
        }

        ensureSelectionIsVisible()
    }

    private func restartFullTextSearch() {
        searchGeneration += 1
        fullTextSearchTask?.cancel()
        fullTextMatches = []

        let query = normalizedSearchText
        guard query.count >= 2 else {
            searchingDeeper = false
            return
        }

        searchingDeeper = true
        let generation = searchGeneration
        let store = self.store
        let chunkSize = 25
        var excludedIDs = Set(
            reports
                .filter { matchesSummarySearch($0, query: query) }
                .map(\.id)
        )

        fullTextSearchTask = Task { @MainActor in
            var cursor: (Date, UUID)?
            var accumulated: [TranscriptRunReportSummary] = []

            while !Task.isCancelled {
                let chunk = await Task.detached(priority: .utility) {
                    store.searchFullText(
                        matching: query,
                        before: cursor,
                        excluding: excludedIDs,
                        limit: chunkSize
                    )
                }.value

                guard generation == searchGeneration, !Task.isCancelled else { return }

                if chunk.isEmpty {
                    break
                }

                accumulated = sortedUnique(accumulated + chunk)
                excludedIDs.formUnion(chunk.map(\.id))
                fullTextMatches = accumulated
                ensureSelectionIsVisible()

                if let last = chunk.last {
                    cursor = (last.createdAt, last.id)
                }
                if chunk.count < chunkSize {
                    break
                }

                await Task.yield()
            }

            guard generation == searchGeneration, !Task.isCancelled else { return }
            searchingDeeper = false
            ensureSelectionIsVisible()
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var pageCursor: (Date, UUID)? {
        reports.last.map { ($0.createdAt, $0.id) }
    }

    private func matchesScope(_ summary: TranscriptRunReportSummary) -> Bool {
        switch scope {
        case .all:
            return true
        case .tasks:
            return summary.modeID == OutputMode.taskID || summary.replyIntent == .agenticReply
        }
    }

    private func matchesStatus(_ summary: TranscriptRunReportSummary) -> Bool {
        guard let status else { return true }
        return summary.status == status
    }

    private func matchesSummarySearch(_ summary: TranscriptRunReportSummary, query: String) -> Bool {
        guard !query.isEmpty else { return true }

        let haystack = [
            summary.modeName,
            summary.sourceAppName,
            summary.preview,
            summary.title
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()

        return haystack.contains(query)
    }

    private func sortedUnique(_ summaries: [TranscriptRunReportSummary]) -> [TranscriptRunReportSummary] {
        var seen = Set<UUID>()
        return summaries
            .sorted { left, right in
                if left.createdAt != right.createdAt {
                    return left.createdAt > right.createdAt
                }
                return left.id.uuidString < right.id.uuidString
            }
            .filter { summary in
                seen.insert(summary.id).inserted
            }
    }

    private func cache(_ report: TranscriptRunReport) {
        cachedReports[report.id] = report
        reportCacheOrder.removeAll { $0 == report.id }
        reportCacheOrder.append(report.id)

        // Kleiner LRU reicht hier: Detailwechsel sollen schnell sein, das Archiv
        // darf aber keine grossen Report-Objekte unbegrenzt halten.
        while reportCacheOrder.count > 5, let oldest = reportCacheOrder.first {
            reportCacheOrder.removeFirst()
            cachedReports.removeValue(forKey: oldest)
        }
    }

    private func cachedReport(id: UUID) -> TranscriptRunReport? {
        guard let report = cachedReports[id] else { return nil }
        reportCacheOrder.removeAll { $0 == id }
        reportCacheOrder.append(id)
        return report
    }

    private func removeLocalReport(id: UUID) {
        reports.removeAll { $0.id == id }
        fullTextMatches.removeAll { $0.id == id }
        cachedReports.removeValue(forKey: id)
        reportCacheOrder.removeAll { $0 == id }

        if selectedReportID == id {
            selectedReportID = nil
            selectedReport = nil
            isLoadingDetail = false
        }
    }
}
