import Foundation

/// Umfang der History-Liste. `all` = jeder Run, `tasks` = nur Task-Mode-Runs
/// bzw. agentische Replies (ersetzt den früheren separaten Tasks-Reiter).
enum OutputHistoryScope: String, CaseIterable, Identifiable {
    case all = "All"
    case tasks = "Tasks"

    var id: String { rawValue }
}

/// Pure, testbare Filter-Logik für die Output-History. Hält keine UI und
/// keinen Store — nur die Regel „welche Reports bleiben sichtbar".
struct OutputHistoryFilter: Equatable {
    var scope: OutputHistoryScope = .all
    var status: TranscriptRunStatus?
    var searchText: String = ""

    func apply(to reports: [TranscriptRunReport]) -> [TranscriptRunReport] {
        reports.filter { matchesScope($0) && matchesStatus($0) && matchesSearch($0) }
    }

    private func matchesScope(_ report: TranscriptRunReport) -> Bool {
        switch scope {
        case .all:
            return true
        case .tasks:
            return report.mode.id == OutputMode.taskID || report.replyIntent == .agenticReply
        }
    }

    private func matchesStatus(_ report: TranscriptRunReport) -> Bool {
        guard let status else { return true }
        return report.status == status
    }

    private func matchesSearch(_ report: TranscriptRunReport) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }

        let haystack = [
            report.mode.name,
            report.sourceAppName,
            report.rawTranscript,
            report.finalTranscript,
            report.selectedText
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()

        return haystack.contains(needle)
    }
}
