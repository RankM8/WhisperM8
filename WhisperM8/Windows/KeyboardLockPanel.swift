import AppKit
import SwiftUI

/// Zeigt bzw. verbirgt das schwebende Entsperr-Panel der Tastatursperre.
@MainActor
protocol KeyboardLockPanelPresenting: AnyObject {
    func show(controller: KeyboardLockController)
    func hide()
}

/// Schwebendes Panel über allen Fenstern und Spaces, solange die Tastatur
/// gesperrt ist. Es aktiviert die App nicht und nimmt den ersten Mausklick an.
final class KeyboardLockPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Über Vollbild-Apps und normalen schwebenden Fenstern.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    /// Nie Key-Fenster: sonst zöge das Panel den Tastaturfokus aus der App ab,
    /// in der man gerade arbeitet. Klicks kommen über `acceptsFirstMouse` an.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting-View, die schon den ersten Klick an den Knopf weitergibt — sonst
/// bräuchte „Entsperren“ in einem inaktiven Panel zwei Klicks.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class KeyboardLockPanelController: KeyboardLockPanelPresenting {
    private var panel: KeyboardLockPanel?

    func show(controller: KeyboardLockController) {
        let panel = self.panel ?? KeyboardLockPanel()
        let hosting = FirstMouseHostingView(rootView: KeyboardLockPanelView(controller: controller))
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        // Bildschirm unter dem Mauszeiger — dort, wo man gerade hinschaut.
        let mouse = NSEvent.mouseLocation
        let underMouse = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        if let screen = underMouse ?? NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

struct KeyboardLockPanelView: View {
    @ObservedObject var controller: KeyboardLockController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.accentStrong)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard locked")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Clean away. Mouse and trackpad keep working.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            if let deadline = controller.deadline {
                HStack(spacing: 4) {
                    Text("Unlocks automatically in")
                    Text(timerInterval: min(Date(), deadline)...deadline, countsDown: true)
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(AppTheme.textPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                if controller.secureInputActive {
                    notice(
                        "A password field or secure keyboard entry is active. macOS lets keys through to it.",
                        color: AppTheme.statusError
                    )
                }
                if controller.capsLockOn {
                    notice("Caps Lock is on.", color: AppTheme.statusAwaiting)
                }
                notice(
                    "The power button and Touch ID can't be locked. Pressing them puts the Mac to sleep and unlocks the keyboard.",
                    color: AppTheme.textTertiary
                )
            }

            HStack(spacing: 8) {
                Button("Unlock Keyboard") {
                    controller.unlock(reason: .user)
                }
                .buttonStyle(SettingsButtonStyle.primary)

                Button("+1 Minute") {
                    controller.extend()
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(!controller.canExtend)
            }
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }

    private func notice(_ key: LocalizedStringKey, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(key)
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
