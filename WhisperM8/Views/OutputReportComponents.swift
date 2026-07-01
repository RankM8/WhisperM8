import AppKit
import SwiftUI

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
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.caption)
    }
}

struct ReportTextBlock: View {
    let title: String
    let text: String?

    private var copyableText: String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let copyableText {
                    CopyToClipboardButton(text: copyableText)
                }
            }
            Text(text?.isEmpty == false ? text! : "None")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
        }
        .buttonStyle(.borderless)
        .help("Copy to clipboard")
    }
}

struct TranscriptAttachmentCard: View {
    let attachment: TranscriptRunAttachmentReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = imagePreview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 86)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.6))
                    Image(systemName: attachment.kind == .screenClip ? "video" : (attachment.kind == .annotation ? "cursorarrow.rays" : "photo"))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 86)
            }

            Text(attachment.kind.rawValue)
                .font(.caption.weight(.semibold))
            Text(attachment.includedInCodexInput ? "Sent to Codex" : "Stored locally")
                .font(.caption2)
                .foregroundStyle(attachment.includedInCodexInput ? .green : .secondary)
            if let number = attachment.annotationNumber {
                Text("Annotation \(number)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let comment = attachment.annotationComment, !comment.isEmpty {
                Text(comment)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let duration = attachment.duration {
                Text(String(format: "%.1fs", duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var imagePreview: NSImage? {
        let path = attachment.thumbnailPath ?? attachment.storedPath
        guard let path else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
