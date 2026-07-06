import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ReportCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            content
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

struct ReportKeyValue: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .foregroundStyle(AppTheme.textPrimary)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.caption)
    }
}

struct ReportInfoChip: View {
    let label: String
    let value: String
    let tone: SettingsStatusTone?

    init(_ label: String, _ value: String, tone: SettingsStatusTone? = nil) {
        self.label = label
        self.value = value
        self.tone = tone
    }

    var body: some View {
        ChipView(label: label, value: value, tone: tone)
    }
}

private struct ChipView: View {
    let label: String
    let value: String
    let tone: SettingsStatusTone?

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(AppTheme.textTertiary)
            Text(value)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(AppTheme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(tone?.color.opacity(0.35) ?? AppTheme.border, lineWidth: 1)
        }
    }

    private var valueColor: Color {
        tone?.color ?? AppTheme.textPrimary
    }
}

struct ReportTextBlock: View {
    let title: String
    let text: String?
    let isProminent: Bool
    let collapsesLongText: Bool

    @State private var isExpanded = false

    init(
        title: String,
        text: String?,
        isProminent: Bool = false,
        collapsesLongText: Bool = false
    ) {
        self.title = title
        self.text = text
        self.isProminent = isProminent
        self.collapsesLongText = collapsesLongText
    }

    private var copyableText: String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private var lines: [Substring] {
        copyableText?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
    }

    private var shouldCollapse: Bool {
        collapsesLongText && lines.count > 30
    }

    private var visibleText: String {
        guard let copyableText else { return "None" }
        guard shouldCollapse, !isExpanded else { return copyableText }
        return lines.prefix(15).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: isProminent ? 12.5 : 11.5, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                if let copyableText {
                    CopyToClipboardButton(text: copyableText)
                }
            }

            Text(visibleText)
                .font(.system(size: isProminent ? 13 : 12, design: .monospaced))
                .foregroundStyle(AppTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(isProminent ? 12 : 10)
                .background(AppTheme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                }

            if shouldCollapse {
                Button(isExpanded ? "Show less" : "Show all") {
                    isExpanded.toggle()
                }
                .font(.system(size: 11.5, weight: .semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.accent)
            }
        }
    }
}

/// Kleiner Copy-Button mit kurzer „Copied"-Bestätigung. Ergänzt die
/// Textauswahl, damit Raw/Final zuverlässig per Klick in die Zwischenablage
/// gehen (Textauswahl bleibt zusätzlich aktiv).
struct CopyToClipboardButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .buttonStyle(.borderless)
        .help("Copy to clipboard")
    }
}

struct TranscriptAttachmentCard: View {
    let attachment: TranscriptRunAttachmentReport

    @State private var previewImage: NSImage?
    @State private var isLoadingImage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview

            Text(attachment.kind.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(attachment.includedInCodexInput ? "Sent to Codex" : "Stored locally")
                .font(.caption2)
                .foregroundStyle(attachment.includedInCodexInput ? AppTheme.statusWorking : AppTheme.textTertiary)
            if let number = attachment.annotationNumber {
                Text("Annotation \(number)")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            if let comment = attachment.annotationComment, !comment.isEmpty {
                Text(comment)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(2)
            }
            if let duration = attachment.duration {
                Text(String(format: "%.1fs", duration))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(10)
        .background(AppTheme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
        .task(id: previewPath) {
            await loadPreview()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            Image(nsImage: previewImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.surface)
                if isLoadingImage {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: placeholderSystemImage)
                        .font(.title2)
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
            .frame(height: 86)
        }
    }

    private var previewPath: String? {
        attachment.thumbnailPath ?? attachment.storedPath
    }

    private var placeholderSystemImage: String {
        switch attachment.kind {
        case .screenClip:
            return "video"
        case .annotation:
            return "cursorarrow.rays"
        case .screenshot, .visualFrame:
            return "photo"
        }
    }

    private func loadPreview() async {
        guard let previewPath else {
            previewImage = nil
            isLoadingImage = false
            return
        }

        isLoadingImage = true
        let imageData = await Task.detached(priority: .utility) {
            Self.downsampledImageData(at: previewPath, maxPixelSize: 320)
        }.value

        guard !Task.isCancelled else { return }
        previewImage = imageData.flatMap(NSImage.init(data:))
        isLoadingImage = false
    }

    nonisolated private static func downsampledImageData(at path: String, maxPixelSize: Int) -> Data? {
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }
}
