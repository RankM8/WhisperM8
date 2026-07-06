import SwiftUI

/// Detail-Ansicht eines einzelnen Transcript-Run-Reports (Output, Kontext,
/// Prompt, Metadaten). Wird von `OutputWorkspacePage` als Detailansicht genutzt.
struct TranscriptReportDetailView: View {
    let report: TranscriptRunReport
    var onDelete: () -> Void

    @State private var isDeliveryExpanded = false
    @State private var isPromptExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                reportOutput
                reportOverview
                reportContext
                reportAttachments
                reportDelivery
                reportPrompt
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(report.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(report.createdAt, format: .dateTime.weekday().month().day().hour().minute().second())
                    .font(.system(size: 12.5))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            if report.agentSessionID != nil {
                Button {
                    WindowRequestCenter.shared.request(.agentChats)
                } label: {
                    Label("Open in Agent Chats", systemImage: "rectangle.connected.to.line.below")
                }
                .buttonStyle(SettingsButtonStyle.standard)
            }

            Button(role: .destructive, action: onDelete) {
                Label("Delete Report", systemImage: "trash")
            }
            .buttonStyle(SettingsButtonStyle.destructive)
        }
    }

    private var reportOutput: some View {
        ReportCard("Output") {
            ReportTextBlock(
                title: "Raw Transcript",
                text: report.rawTranscript,
                isProminent: true,
                collapsesLongText: true
            )
            ReportTextBlock(
                title: "Final Output",
                text: report.finalTranscript,
                isProminent: true,
                collapsesLongText: true
            )
        }
    }

    private var reportOverview: some View {
        ReportCard("Run Summary") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(runSummaryChips) { chip in
                    ReportInfoChip(chip.label, chip.value, tone: chip.tone)
                }
            }
        }
    }

    private var reportContext: some View {
        ReportCard("Input Context") {
            ReportTextBlock(title: "Selected Text", text: report.selectedText)
            ReportTextBlock(title: "Visual Summary", text: report.visualContextSummary)
        }
    }

    @ViewBuilder
    private var reportAttachments: some View {
        if !report.attachments.isEmpty {
            ReportCard("Attachments") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(report.attachments) { attachment in
                        TranscriptAttachmentCard(attachment: attachment)
                    }
                }
            }
        }
    }

    private var reportDelivery: some View {
        ReportDisclosureGroup("Delivery", isExpanded: $isDeliveryExpanded) {
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

    private var reportPrompt: some View {
        ReportDisclosureGroup("Prompt / Codex Input", isExpanded: $isPromptExpanded) {
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

    private var runSummaryChips: [RunSummaryChip] {
        var chips: [RunSummaryChip] = []
        chips.append(RunSummaryChip("Status", report.status.displayText, tone: statusTone))
        chips.append(RunSummaryChip("Mode", "\(report.mode.name) (\(report.mode.shortLabel))"))
        appendChip("Source App", report.sourceAppName, to: &chips)
        chips.append(RunSummaryChip("Provider", report.transcription.provider))
        chips.append(RunSummaryChip("STT Model", report.transcription.model))
        chips.append(RunSummaryChip("Language", report.transcription.language))
        chips.append(RunSummaryChip("Audio Duration", String(format: "%.1fs", report.transcription.audioDuration)))
        chips.append(RunSummaryChip("Clipboard", report.copiedToClipboard ? "Copied" : "Not copied"))
        chips.append(RunSummaryChip("Auto-Paste", report.autoPasteRequested ? "Requested" : "Off"))
        if let pastedAttachmentCount = report.pastedAttachmentCount {
            chips.append(RunSummaryChip("Images Pasted", "\(pastedAttachmentCount)"))
        }
        if let codex = report.codex {
            chips.append(RunSummaryChip("Images Sent", "\(codex.imageInputPaths.count)"))
            appendChip("Codex Model", codex.model, to: &chips)
            appendChip("Thinking", codex.reasoningEffort, to: &chips)
            chips.append(RunSummaryChip("Visual Input", CodexVisualInputMode.resolve(codex.visualInputMode).displayName))
            if !codex.videoInputPaths.isEmpty {
                chips.append(RunSummaryChip("Video Paths", "\(codex.videoInputPaths.count)"))
            }
            if codex.usesFrameFallbackForVideo {
                chips.append(RunSummaryChip("Video Fallback", "Frames sent via --image"))
            }
        }
        if let replyIntent = report.replyIntent {
            chips.append(RunSummaryChip("Router", replyIntent.displayName))
        }
        appendChip("Template", report.mode.templateID, to: &chips)
        appendChip("Error", report.errorMessage, tone: .error, to: &chips)
        if let agentProvider = report.agentProvider {
            chips.append(RunSummaryChip("Agent Provider", agentProvider.displayName))
        }
        appendChip("Agent Session", report.agentSessionID, to: &chips)
        appendChip("Agent Project", report.agentProjectPath, to: &chips)

        return chips
    }

    private var statusTone: SettingsStatusTone {
        switch report.status {
        case .succeeded:
            return .ok
        case .rawFallback, .cautiousFallback:
            return .warn
        case .failed:
            return .error
        }
    }

    private func appendChip(
        _ label: String,
        _ value: String?,
        tone: SettingsStatusTone? = nil,
        to chips: inout [RunSummaryChip]
    ) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        chips.append(RunSummaryChip(label, value, tone: tone))
    }
}

private struct RunSummaryChip: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let tone: SettingsStatusTone?

    init(_ label: String, _ value: String, tone: SettingsStatusTone? = nil) {
        self.label = label
        self.value = value
        self.tone = tone
    }
}

private struct ReportDisclosureGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.top, 12)
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}
