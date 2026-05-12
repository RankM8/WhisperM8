import SwiftUI

struct TranscriptReportsView: View {
    @State private var store = TranscriptRunReportStore()
    @State private var reports: [TranscriptRunReport] = []
    @State private var selectedReportID: UUID?
    @State private var errorMessage: String?

    private var selectedReport: TranscriptRunReport? {
        reports.first { $0.id == selectedReportID } ?? reports.first
    }

    var body: some View {
        HStack(spacing: 0) {
            reportList
                .frame(width: 320)

            Divider()

            if let selectedReport {
                TranscriptReportDetailView(report: selectedReport) {
                    delete(selectedReport)
                }
            } else {
                ContentUnavailableView("No Reports Yet", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Reports")
        .onAppear(perform: reload)
    }

    private var reportList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reports")
                    .font(.headline)
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload reports")
            }
            .padding([.top, .horizontal], 16)

            List(selection: $selectedReportID) {
                ForEach(reports) { report in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(report.mode.shortLabel)
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text(report.status.displayText)
                                .font(.caption)
                                .foregroundStyle(statusColor(report.status))
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

    private func reload() {
        reports = store.recentReports()
        if selectedReportID == nil || !reports.contains(where: { $0.id == selectedReportID }) {
            selectedReportID = reports.first?.id
        }
        errorMessage = nil
    }

    private func delete(_ report: TranscriptRunReport) {
        do {
            try store.delete(report)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func statusColor(_ status: TranscriptRunStatus) -> Color {
        switch status {
        case .succeeded:
            return .green
        case .rawFallback:
            return .orange
        case .cautiousFallback:
            return .orange
        case .failed:
            return .red
        }
    }
}

struct TaskReportsView: View {
    @State private var reports: [TranscriptRunReport] = []
    @State private var selectedReportID: UUID?
    private let store = TranscriptRunReportStore()

    private var taskReports: [TranscriptRunReport] {
        reports.filter { report in
            report.mode.id == OutputMode.taskID || report.replyIntent == .agenticReply
        }
    }

    private var selectedReport: TranscriptRunReport? {
        taskReports.first { $0.id == selectedReportID } ?? taskReports.first
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedReportID) {
                ForEach(taskReports) { report in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.title)
                            .lineLimit(1)
                        Text(report.replyIntent?.displayName ?? report.status.displayText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(report.id)
                }
            }
            .navigationTitle("Tasks")
        } detail: {
            if let selectedReport {
                TranscriptReportDetailView(report: selectedReport) {
                    try? store.delete(selectedReport)
                    refresh()
                }
            } else {
                ContentUnavailableView("No Tasks Yet", systemImage: "checklist")
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        reports = store.recentReports()
        if selectedReportID == nil || !taskReports.contains(where: { $0.id == selectedReportID }) {
            selectedReportID = taskReports.first?.id
        }
    }
}

struct TranscriptReportDetailView: View {
    let report: TranscriptRunReport
    var onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.title)
                            .font(.title2.weight(.semibold))
                        Text(report.createdAt, format: .dateTime.weekday().month().day().hour().minute().second())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if report.agentSessionID != nil {
                        Button("Open in Agent Chats") {
                            WindowRequestCenter.shared.request(.agentChats)
                        }
                    }

                    Button("Delete Report", role: .destructive, action: onDelete)
                }

                reportOverview
                reportContext
                reportDelivery
                reportPrompt
                reportOutput
            }
            .padding(24)
        }
    }

    private var reportOverview: some View {
        ReportCard("Run") {
            ReportKeyValue("Status", report.status.displayText)
            ReportKeyValue("Mode", "\(report.mode.name) (\(report.mode.shortLabel))")
            if let replyIntent = report.replyIntent {
                ReportKeyValue("Router", replyIntent.displayName)
            }
            ReportKeyValue("Template", report.mode.templateID ?? "None")
            ReportKeyValue("Source App", report.sourceAppName ?? "Unknown")
            ReportKeyValue("Provider", report.transcription.provider)
            ReportKeyValue("STT Model", report.transcription.model)
            ReportKeyValue("Language", report.transcription.language)
            ReportKeyValue("Audio Duration", String(format: "%.1fs", report.transcription.audioDuration))
            ReportKeyValue("Clipboard", report.copiedToClipboard ? "Copied" : "Not copied")
            ReportKeyValue("Auto-Paste", report.autoPasteRequested ? "Requested" : "Off")
            if report.autoPasteAttachmentsRequested == true {
                ReportKeyValue("Images Pasted", "\(report.pastedAttachmentCount ?? 0)")
            }
            if let codex = report.codex {
                ReportKeyValue("Codex Model", codex.model)
                ReportKeyValue("Thinking", codex.reasoningEffort)
                ReportKeyValue("Visual Input", CodexVisualInputMode.resolve(codex.visualInputMode).displayName)
                ReportKeyValue("Images Sent", "\(codex.imageInputPaths.count)")
                ReportKeyValue("Video Paths", "\(codex.videoInputPaths.count)")
                if codex.usesFrameFallbackForVideo {
                    ReportKeyValue("Video Fallback", "Frames sent via --image")
                }
            }
            if let errorMessage = report.errorMessage {
                ReportKeyValue("Error", errorMessage)
            }
            if let agentProvider = report.agentProvider {
                ReportKeyValue("Agent Provider", agentProvider.displayName)
            }
            if let agentSessionID = report.agentSessionID {
                ReportKeyValue("Agent Session", agentSessionID)
            }
            if let agentProjectPath = report.agentProjectPath {
                ReportKeyValue("Agent Project", agentProjectPath)
            }
        }
    }

    private var reportDelivery: some View {
        ReportCard("Delivery") {
            ReportKeyValue("Text Paste", report.autoPasteTextRequested == true ? "Requested" : "Off")
            ReportKeyValue("Image Paste", report.autoPasteAttachmentsRequested == true ? "Requested" : "Off")
            ReportKeyValue("Images Pasted", "\(report.pastedAttachmentCount ?? 0)")

            if let labels = report.deliveryAttachmentLabels, !labels.isEmpty {
                ReportTextBlock(title: "Delivery Labels", text: labels.joined(separator: "\n"))
            }

            if let errors = report.pasteErrors, !errors.isEmpty {
                ReportTextBlock(title: "Paste Errors", text: errors.joined(separator: "\n"))
            }
        }
    }

    private var reportContext: some View {
        ReportCard("Input Context") {
            ReportTextBlock(title: "Selected Text", text: report.selectedText)
            ReportTextBlock(title: "Visual Summary", text: report.visualContextSummary)

            if !report.attachments.isEmpty {
                Text("Attachments")
                    .font(.headline)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(report.attachments) { attachment in
                        TranscriptAttachmentCard(attachment: attachment)
                    }
                }
            }
        }
    }

    private var reportPrompt: some View {
        ReportCard("Prompt / Codex Input") {
            if let manifest = report.visualManifest, !manifest.isEmpty {
                ReportTextBlock(title: "Visual Manifest", text: manifest.markdown)
            }
            ReportTextBlock(title: "Rendered Prompt", text: report.renderedPrompt)
            if let command = report.codex?.commandPreview, !command.isEmpty {
                ReportTextBlock(title: "Command Preview", text: command.joined(separator: " "))
            }
            if let videoPaths = report.codex?.videoInputPaths, !videoPaths.isEmpty {
                ReportTextBlock(title: "Video Paths Given In Prompt", text: videoPaths.joined(separator: "\n"))
            }
        }
    }

    private var reportOutput: some View {
        ReportCard("Output") {
            ReportTextBlock(title: "Raw Transcript", text: report.rawTranscript)
            ReportTextBlock(title: "Final Output", text: report.finalTranscript)
        }
    }
}
