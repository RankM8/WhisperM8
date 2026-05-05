import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct SelectedContextService {
    private let copyDelayNanoseconds: UInt64 = 160_000_000

    @MainActor
    func capture(from app: NSRunningApplication?) async -> SelectedContext {
        guard AppPreferences.shared.isSelectedContextCaptureEnabled else {
            return .empty
        }

        let sourceApp = app ?? NSWorkspace.shared.frontmostApplication

        if let accessibilityText = captureViaAccessibility(from: sourceApp),
           !accessibilityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SelectedContext(
                text: TextNormalizer.normalizeTranscriptionText(accessibilityText),
                sourceAppName: sourceApp?.localizedName,
                sourceBundleIdentifier: sourceApp?.bundleIdentifier
            )
        }

        guard PermissionService.hasAccessibilityPermission else {
            Logger.permission.warning("Selected context capture needs Accessibility permission")
            return .empty
        }

        if let clipboardText = await captureViaClipboard(from: sourceApp),
           !clipboardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SelectedContext(
                text: TextNormalizer.normalizeTranscriptionText(clipboardText),
                sourceAppName: sourceApp?.localizedName,
                sourceBundleIdentifier: sourceApp?.bundleIdentifier
            )
        }

        return .empty
    }

    private func captureViaAccessibility(from app: NSRunningApplication?) -> String? {
        guard let pid = app?.processIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedStatus == .success,
              let focusedElement = focusedValue,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }

        var selectedTextValue: CFTypeRef?
        let selectedTextStatus = AXUIElementCopyAttributeValue(
            focusedElement as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        guard selectedTextStatus == .success else { return nil }
        return selectedTextValue as? String
    }

    private func captureViaClipboard(from app: NSRunningApplication?) async -> String? {
        guard let app else { return nil }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let previousChangeCount = pasteboard.changeCount

        app.activate()
        try? await Task.sleep(for: .milliseconds(60))
        postCopyEvent()
        try? await Task.sleep(nanoseconds: copyDelayNanoseconds)

        let selectedText: String?
        if pasteboard.changeCount != previousChangeCount {
            selectedText = pasteboard.string(forType: .string)
        } else {
            selectedText = nil
        }

        snapshot.restore(to: pasteboard)
        return selectedText
    }

    private func postCopyEvent() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_C), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_C), keyDown: false) else {
            Logger.paste.error("Failed to create selected-context copy events")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)
    }
}

struct PasteboardSnapshot {
    private struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { pasteboardItem in
            Item(values: pasteboardItem.types.compactMap { type in
                guard let data = pasteboardItem.data(forType: type) else { return nil }
                return (type, data)
            })
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.values {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(restoredItems)
    }
}
