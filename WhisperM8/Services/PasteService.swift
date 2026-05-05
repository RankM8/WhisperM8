import AppKit
import Carbon.HIToolbox

@MainActor
final class PasteService {
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func pasteToActiveApp(previousApp: NSRunningApplication?, onMissingPermission: () -> Void, onMissingTarget: () -> Void) {
        guard PermissionService.hasAccessibilityPermission else {
            Logger.permission.error("Accessibility permission missing - cannot auto-paste")
            PermissionService.requestAccessibilityPermission()
            onMissingPermission()
            return
        }

        guard let targetApp = previousApp else {
            Logger.paste.error("No previous app captured")
            onMissingTarget()
            return
        }

        Logger.paste.info("Starting paste to: \(targetApp.localizedName ?? "unknown", privacy: .public)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Logger.focus.info("Activating target app...")
            targetApp.activate()

            self.waitForActivation(of: targetApp) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    Logger.paste.info("Posting Cmd+V CGEvent")
                    self.postPasteEvent()
                }
            }
        }
    }

    private func waitForActivation(of app: NSRunningApplication, timeout: TimeInterval = 1.0, completion: @escaping () -> Void) {
        let start = Date()

        func check() {
            if NSWorkspace.shared.frontmostApplication == app {
                Logger.focus.info("Target app is now active")
                completion()
            } else if Date().timeIntervalSince(start) < timeout {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    check()
                }
            } else {
                Logger.focus.warning("Timeout waiting for app activation, pasting anyway")
                completion()
            }
        }

        check()
    }

    private func postPasteEvent() {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            Logger.paste.error("Failed to create CGEvents")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)

        Logger.paste.info("Paste event posted successfully")
    }
}
