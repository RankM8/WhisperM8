# macOS Accessibility and CGEvent auto-paste: a comprehensive developer guide

**Simulating keyboard input on macOS 14+ requires navigating a complex interplay of code signing, TCC permissions, and app activation states.** This report provides battle-tested solutions for the most frustrating development challenges: permission invalidation on recompile, proper CGEvent timing, and reliable focus restoration for menu bar apps. The core insight is that **code signature stability** is the root cause of most accessibility permission issues during development, while **proper sequencing** (dismiss panel → activate target → wait → post event) determines paste reliability.

## Why AXIsProcessTrusted() fails despite enabled permissions

The TCC (Transparency, Consent, Control) database doesn't just store a bundle identifier—it stores a **code signing requirement blob** (`csreq`) that must match your running binary exactly. When you grant accessibility permission, macOS records both your bundle ID and the designated requirement derived from your code signature.

**macOS identifies apps using three factors:**
- **Bundle Identifier** (`client` field) — e.g., `com.yourcompany.app`
- **Code Signing Requirement** (`csreq` blob) — validates certificate chain and Team ID
- **Client Type** — 0 for bundle ID, 1 for absolute path

Each recompile with ad-hoc signing (`codesign -s -`) generates a **unique signature**. The TCC daemon validates against the stored `csreq`, and when signatures don't match, `AXIsProcessTrusted()` returns `false` even though System Settings shows your app as enabled. This is why "Sign to Run Locally" causes persistent issues—there's no stable identity.

```swift
import ApplicationServices

/// Check if accessibility permission is actually working (not just reported)
func validateAccessibilityActuallyWorks() -> Bool {
    guard AXIsProcessTrusted() else { return false }
    
    // Try to access Finder's windows as a validation test
    guard let finder = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.finder"
    ).first else { return true }
    
    let finderElement = AXUIElementCreateApplication(finder.processIdentifier)
    var windows: AnyObject?
    let result = AXUIElementCopyAttributeValue(
        finderElement, kAXWindowsAttribute as CFString, &windows
    )
    
    // .cannotComplete indicates TCC database corruption
    return result != .cannotComplete
}
```

The fix requires a **stable signing identity**. Using a Development certificate from Apple Developer Program (even the free tier) provides consistent Team ID and certificate chain across builds. Self-signed certificates work but require manual trust configuration in Keychain Access.

## Managing the TCC database during development

The TCC database lives at `/Library/Application Support/com.apple.TCC/TCC.db` (system-wide, SIP-protected) and `~/Library/Application Support/com.apple.TCC/TCC.db` (user-level). **Accessibility permissions are stored in the system database**, which cannot be modified with SIP enabled.

```bash
# Read accessibility clients (requires Full Disk Access for Terminal)
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, auth_value FROM access WHERE service='kTCCServiceAccessibility';"

# Reset accessibility for your app (the only write operation allowed with SIP)
sudo tccutil reset Accessibility com.yourcompany.app

# Reset all accessibility permissions
tccutil reset Accessibility
```

The `auth_value` column uses these values: **0** = denied, **1** = unknown, **2** = allowed. The `tccutil` command can only **reset** permissions, not grant them. Direct SQLite modification requires disabling SIP—never appropriate for production workflows.

For development, create a self-signed certificate in **Keychain Access → Certificate Assistant → Create a Certificate**, selecting "Self Signed Root" and "Code Signing" as the certificate type. Set validity to **3650 days** and trust it for code signing. Then configure Xcode's Build Settings to use this certificate with "Manual" code signing style.

## CGEvent keyboard simulation on macOS 14+

The CGEvent API remains stable in macOS 14 (Sonoma) and macOS 15 with **no breaking changes**. The critical requirement is Accessibility permission, enforced since Mojave. Sandboxed apps **cannot use CGEventPost**—this is documented as intentional, meaning Mac App Store distribution is incompatible with keyboard simulation.

```swift
import CoreGraphics
import Carbon.HIToolbox

final class KeyboardSimulator {
    
    /// Virtual key codes (ANSI US layout - refers to physical key positions)
    static let kVK_V: CGKeyCode = 0x09
    static let kVK_C: CGKeyCode = 0x08
    static let kVK_A: CGKeyCode = 0x00
    
    /// Simulate Cmd+V with proper timing
    static func simulatePaste() {
        guard AXIsProcessTrusted() else {
            print("Accessibility permission required")
            return
        }
        
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        
        guard let keyDown = CGEvent(keyboardEventSource: source, 
                                    virtualKey: kVK_V, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, 
                                  virtualKey: kVK_V, keyDown: false) else { return }
        
        // Set Command modifier on BOTH events
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        
        // Post to HID tap (events go to frontmost app)
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)  // 20ms delay between down and up
        keyUp.post(tap: .cghidEventTap)
    }
    
    /// Post to specific process (doesn't require app to be frontmost)
    static func simulatePaste(toPID pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: false) 
        else { return }
        
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        
        keyDown.postToPid(pid)
        usleep(20_000)
        keyUp.postToPid(pid)
    }
}
```

**Timing recommendations:** Use **10-50ms** between keyDown and keyUp, **100-300ms** after app activation before posting events. The `.hidSystemState` event source is recommended for most cases. Neither `LSUIElement=true` nor `NSPanel` with `.nonactivatingPanel` affects CGEvent posting capability—these only control your app's activation behavior.

## Alternative approaches that avoid CGEvent

### Direct text insertion via Accessibility API

This approach finds the focused text field and sets its value directly, bypassing the clipboard entirely:

```swift
import ApplicationServices

func insertTextDirectly(_ text: String) -> Bool {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedElement: CFTypeRef?
    
    guard AXUIElementCopyAttributeValue(systemWide, 
          kAXFocusedUIElementAttribute as CFString, 
          &focusedElement) == .success else { return false }
    
    let element = focusedElement as! AXUIElement
    
    // Check if value attribute is settable
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
          settable.boolValue else { return false }
    
    return AXUIElementSetAttributeValue(element, 
           kAXValueAttribute as CFString, text as CFTypeRef) == .success
}
```

This works well for native macOS apps but **fails silently** on Electron apps (VS Code, Slack), web browsers, and even Apple's Pages. Use it as a fast path with CGEvent fallback.

### AppleScript execution from Swift

AppleScript provides the most universal compatibility across applications:

```swift
import Foundation

func pasteViaAppleScript() -> Bool {
    let script = NSAppleScript(source: """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """)
    
    var error: NSDictionary?
    script?.executeAndReturnError(&error)
    return error == nil
}

/// Paste matching style (Cmd+Opt+Shift+V)
func pasteMatchingStyle() -> Bool {
    let script = NSAppleScript(source: """
        tell application "System Events"
            keystroke "v" using {option down, shift down, command down}
        end tell
        """)
    var error: NSDictionary?
    script?.executeAndReturnError(&error)
    return error == nil
}
```

Add `NSAppleEventsUsageDescription` to Info.plist and the `com.apple.security.automation.apple-events` entitlement. AppleScript requires **Automation permission** (separate from Accessibility) which users must grant per-target-app.

## How popular clipboard apps implement auto-paste

Production apps use a **hybrid approach**: try the Accessibility API first for speed, fall back to CGEvent paste simulation when it fails.

| App | Primary Technique | Distribution |
|-----|------------------|--------------|
| **Alfred** | Accessibility API + CGEvent | Developer ID (not App Store) |
| **Raycast** | Clipboard API with paste action | Developer ID |
| **TextExpander** | Accessibility + keyboard simulation | Direct download |
| **Maccy** | CGEvent paste simulation | App Store (limited) + Direct (full) |
| **PopClip** | AppleScript + Accessibility | Developer ID |

The open-source **Maccy** clipboard manager (17.8k GitHub stars) demonstrates the standard pattern. All these apps require Accessibility permission and distribute outside the Mac App Store to access CGEvent APIs.

**Key insight from production apps:** `AXUIElementSetAttributeValue` returns success for Google Docs, VS Code, and similar apps but **doesn't actually insert text**. Always verify insertion worked or use the paste fallback unconditionally for maximum compatibility.

## Correct focus handling for menu bar apps with floating panels

The critical mistake is capturing focus *after* showing your panel. **Capture `frontmostApplication` before your panel appears**, then restore focus before posting events.

```swift
import AppKit

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .nonactivatingPanel,  // CRITICAL: prevents app activation
                .titled,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        
        isFloatingPanel = true
        level = .floating
        collectionBehavior.insert(.fullScreenAuxiliary)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    
    // Required for keyboard input while non-activating
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PasteCoordinator {
    private var previousApp: NSRunningApplication?
    
    func showPanel(_ panel: NSPanel) {
        // CAPTURE BEFORE SHOWING
        previousApp = NSWorkspace.shared.frontmostApplication
        panel.orderFront(nil)
        panel.makeKey()
    }
    
    func performPaste(dismissing panel: NSPanel) {
        // 1. Dismiss panel
        panel.orderOut(nil)
        
        // 2. Activate target after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let app = self?.previousApp else { return }
            app.activate(options: [.activateIgnoringOtherApps])
            
            // 3. Wait for activation, then paste
            self?.waitForActivation(of: app) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    KeyboardSimulator.simulatePaste()
                }
            }
        }
    }
    
    private func waitForActivation(of app: NSRunningApplication, 
                                   timeout: TimeInterval = 1.0,
                                   completion: @escaping () -> Void) {
        let start = Date()
        func check() {
            if NSWorkspace.shared.frontmostApplication == app {
                completion()
            } else if Date().timeIntervalSince(start) < timeout {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { check() }
            }
        }
        check()
    }
}
```

**Timing sequence:** Panel dismiss (0ms) → Wait (50ms) → Activate target → Poll until active (up to 1s) → Wait (100ms) → Post CGEvent. macOS Sonoma changed `activate(options:)` behavior—AppleScript activation is more reliable as a fallback if `NSRunningApplication.activate()` fails.

## Development workflow for persistent permissions

The most effective development workflow avoids permission issues entirely:

1. **Enroll in Apple Developer Program** (free tier works) to get a Development certificate with stable Team ID
2. **Configure Xcode** with automatic signing using your team
3. **Grant permission once** after the first signed build
4. **Use "Run Without Building"** (⌃⌘R) when testing permission-sensitive features to avoid resigning

If permissions become corrupted:
```bash
tccutil reset Accessibility com.yourcompany.app
# Relaunch app, re-grant in System Settings
```

For continuous monitoring of TCC issues during development:
```bash
log stream --predicate 'process == "tccd"' --level debug
```

## Conclusion

Reliable auto-paste on macOS requires understanding that **permission stability comes from code signing**, not bundle identifiers. Use a Development certificate from day one, capture focus state *before* showing UI, and always implement the hybrid approach: try direct Accessibility API insertion first, fall back to CGEvent paste simulation. The 50-100ms delays between activation and event posting aren't optional—they're required for the window server to synchronize state. For Mac App Store distribution, you'll need to find alternative approaches since CGEventPost is incompatible with App Sandbox by design.

**Key documentation:**
- [AXIsProcessTrusted()](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted)
- [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent)
- [NSPanel](https://developer.apple.com/documentation/appkit/nspanel)
- [NSRunningApplication](https://developer.apple.com/documentation/appkit/nsrunningapplication)
- [Code Signing Technical Note TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)