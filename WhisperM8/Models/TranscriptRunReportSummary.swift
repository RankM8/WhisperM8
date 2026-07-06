import Foundation

struct TranscriptRunReportSummary: Identifiable, Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var status: TranscriptRunStatus
    var modeID: String
    var modeName: String
    var sourceAppName: String?
    var title: String
    var preview: String
    var attachmentCount: Int
    var replyIntent: ReplyIntentKind?

    init(
        id: UUID,
        createdAt: Date,
        status: TranscriptRunStatus,
        modeID: String,
        modeName: String,
        sourceAppName: String?,
        title: String,
        preview: String,
        attachmentCount: Int,
        replyIntent: ReplyIntentKind?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.modeID = modeID
        self.modeName = modeName
        self.sourceAppName = sourceAppName
        self.title = title
        self.preview = preview
        self.attachmentCount = attachmentCount
        self.replyIntent = replyIntent
    }

    init(from report: TranscriptRunReport) {
        self.init(
            id: report.id,
            createdAt: report.createdAt,
            status: report.status,
            modeID: report.mode.id,
            modeName: report.mode.name,
            sourceAppName: report.sourceAppName,
            title: report.title,
            preview: String(report.shortSummary.prefix(240)),
            attachmentCount: report.attachments.count,
            replyIntent: report.replyIntent
        )
    }
}
