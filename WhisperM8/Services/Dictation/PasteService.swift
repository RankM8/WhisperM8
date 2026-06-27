import AppKit
import Carbon.HIToolbox

struct PasteAttachment: Identifiable, Equatable {
    var id: UUID
    var label: String
    var fileURL: URL
    var kind: ContextAttachmentKind
}

struct PastePayload: Equatable {
    var text: String
    var attachments: [PasteAttachment]
    var restoreTextToClipboardAfterPaste: Bool

    static func textOnly(_ text: String) -> PastePayload {
        PastePayload(text: text, attachments: [], restoreTextToClipboardAfterPaste: true)
    }
}

struct PasteDeliveryResult: Equatable {
    var textPasted: Bool
    var pastedAttachments: [PasteAttachment]
    var errors: [String]

    static let notRequested = PasteDeliveryResult(textPasted: false, pastedAttachments: [], errors: [])
}

@MainActor
final class PasteService {
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func pasteToActiveApp(
        previousApp: NSRunningApplication?,
        onMissingPermission: @escaping () -> Void,
        onMissingTarget: @escaping () -> Void
    ) {
        Task {
            _ = await pastePayloadToActiveApp(
                PastePayload.textOnly(NSPasteboard.general.string(forType: .string) ?? ""),
                previousApp: previousApp,
                onMissingPermission: onMissingPermission,
                onMissingTarget: onMissingTarget
            )
        }
    }

    func pastePayloadToActiveApp(
        _ payload: PastePayload,
        previousApp: NSRunningApplication?,
        onMissingPermission: () -> Void,
        onMissingTarget: () -> Void
    ) async -> PasteDeliveryResult {
        guard PermissionService.hasAccessibilityPermission else {
            Logger.permission.error("Accessibility permission missing - cannot auto-paste")
            PermissionService.requestAccessibilityPermission()
            onMissingPermission()
            return PasteDeliveryResult(
                textPasted: false,
                pastedAttachments: [],
                errors: ["Accessibility permission missing for auto-paste."]
            )
        }

        guard let targetApp = previousApp else {
            Logger.paste.error("No previous app captured")
            onMissingTarget()
            return PasteDeliveryResult(
                textPasted: false,
                pastedAttachments: [],
                errors: ["No previous target app captured for auto-paste."]
            )
        }

        Logger.paste.info("Starting paste to: \(targetApp.localizedName ?? "unknown", privacy: .public)")

        await sleep(seconds: 0.05)
        Logger.focus.info("Activating target app...")
        targetApp.activate()
        await waitForActivation(of: targetApp)
        await sleep(seconds: 0.1)

        var errors: [String] = []
        var pastedAttachments: [PasteAttachment] = []

        copyToClipboard(payload.text)
        Logger.paste.info("Posting text Cmd+V CGEvent")
        let textPasted = postPasteEvent()
        if !textPasted {
            errors.append("Could not create paste event for text.")
        }

        for attachment in payload.attachments {
            await sleep(seconds: 0.35)
            do {
                try copyAttachmentToClipboard(attachment)
                Logger.paste.info("Posting attachment Cmd+V CGEvent for \(attachment.label, privacy: .public)")
                if postPasteEvent() {
                    pastedAttachments.append(attachment)
                } else {
                    errors.append("Could not create paste event for \(attachment.label).")
                }
            } catch {
                let message = "\(attachment.label): \(error.localizedDescription)"
                Logger.paste.error("Failed to prepare attachment paste: \(message, privacy: .public)")
                errors.append(message)
            }
        }

        if payload.restoreTextToClipboardAfterPaste {
            await sleep(seconds: 0.2)
            copyToClipboard(payload.text)
        }

        return PasteDeliveryResult(
            textPasted: textPasted,
            pastedAttachments: pastedAttachments,
            errors: errors
        )
    }

    private func waitForActivation(of app: NSRunningApplication, timeout: TimeInterval = 1.0) async {
        let start = Date()

        while true {
            if NSWorkspace.shared.frontmostApplication == app {
                Logger.focus.info("Target app is now active")
                return
            }

            if Date().timeIntervalSince(start) >= timeout {
                break
            }

            await sleep(seconds: 0.02)
        }

        Logger.focus.warning("Timeout waiting for app activation, pasting anyway")
    }

    private func copyAttachmentToClipboard(_ attachment: PasteAttachment) throws {
        guard FileManager.default.fileExists(atPath: attachment.fileURL.path) else {
            throw PasteServiceError.attachmentMissing(attachment.fileURL.path)
        }

        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setString(attachment.fileURL.absoluteString, forType: .fileURL)

        if let data = try? Data(contentsOf: attachment.fileURL) {
            item.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
        }

        if let image = NSImage(contentsOf: attachment.fileURL),
           let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw PasteServiceError.clipboardWriteFailed(attachment.label)
        }
    }

    private func postPasteEvent() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            Logger.paste.error("Failed to create CGEvents")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)

        Logger.paste.info("Paste event posted successfully")
        return true
    }

    private func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

private enum PasteServiceError: LocalizedError {
    case attachmentMissing(String)
    case clipboardWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .attachmentMissing(let path):
            return "Attachment file is missing at \(path)."
        case .clipboardWriteFailed(let label):
            return "Could not write \(label) to the clipboard."
        }
    }
}
