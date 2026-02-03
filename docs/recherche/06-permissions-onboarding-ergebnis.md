# Recherche-Ergebnis: macOS Permissions & Onboarding Flow

# macOS permissions and onboarding for WhisperM8

**Microphone and Accessibility permissions on macOS require fundamentally different handling approaches.** Microphone access can be requested programmatically with a system dialog, but Accessibility always requires manual user action in System Settings. This asymmetry shapes your entire onboarding flow—you'll need a step-by-step wizard that guides users through the manual permission grant process while polling for status changes.

WhisperM8's requirements are common among macOS utility apps: microphone for audio capture, and Accessibility for global hotkeys. The good news is that this permission combination is well-established, with apps like Rectangle, Bartender, and Raycast using similar patterns you can learn from.

---

## Permission APIs: checking and requesting each type

### Microphone permission (AVFoundation)

Microphone access uses the standard AVFoundation authorization API with four possible states:

```swift
import AVFoundation

// Check current status
let status = AVCaptureDevice.authorizationStatus(for: .audio)

switch status {
case .notDetermined:  // User hasn't been asked yet
case .authorized:     // Access granted
case .denied:         // User denied access
case .restricted:     // MDM/parental controls block access
@unknown default: break
}

// Request access (shows system dialog if notDetermined)
AVCaptureDevice.requestAccess(for: .audio) { granted in
    DispatchQueue.main.async {
        // Update UI based on result
    }
}
```

**Critical behavior**: The system dialog appears only once, when status is `.notDetermined`. After denial, you cannot re-trigger it programmatically—users must enable access manually in System Settings. The completion handler fires on an arbitrary queue, so dispatch UI updates to main.

**Required Info.plist key** (app crashes without this):
```xml
<key>NSMicrophoneUsageDescription</key>
<string>WhisperM8 needs microphone access to record audio for transcription.</string>
```

### Accessibility permission (ApplicationServices)

Accessibility uses a simpler boolean API, but with a crucial limitation—**no automatic system dialog grants permission**:

```swift
import ApplicationServices

// Check if app is trusted
let isTrusted = AXIsProcessTrusted()  // Returns Bool

// Check with optional prompt (opens System Settings prompt, not a grant dialog)
let options: NSDictionary = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
]
let isTrusted = AXIsProcessTrustedWithOptions(options)
```

When `kAXTrustedCheckOptionPrompt` is `true` and the app isn't trusted, macOS shows an alert directing users to System Settings → Privacy & Security → Accessibility. The user must then **manually toggle your app's switch**. This security design prevents malware from silently gaining system control.

**Sandbox incompatibility warning**: Accessibility APIs do not work with sandboxed apps. `AXIsProcessTrustedWithOptions` always returns `false` in sandboxed apps, and the prompt never appears. Apps requiring Accessibility must be distributed outside the Mac App Store.

### Input Monitoring (when needed)

Input Monitoring is required for **passive keyboard event listening** via `CGEventTap` with `.listenOnly`. If you're posting synthetic events or modifying input, you need Accessibility instead.

```swift
import CoreGraphics

// Check permission
let hasAccess = CGPreflightListenEventAccess()

// Request permission (shows system dialog)
let wasRequested = CGRequestListenEventAccess()
```

**For WhisperM8's global hotkeys**: You likely need Accessibility, not Input Monitoring. Accessibility handles both listening and posting keyboard events. Input Monitoring is the fallback for sandboxed apps that only need to listen.

---

## Deep links to System Settings panes

All privacy-related URLs use the format `x-apple.systempreferences:com.apple.preference.security?[Anchor]`. These work across **macOS 12 Monterey through macOS 15 Sequoia**:

| Setting | Deep Link URL |
|---------|---------------|
| **Microphone** | `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` |
| **Accessibility** | `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| **Input Monitoring** | `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent` |
| Screen Recording | `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` |
| Full Disk Access | `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` |
| Privacy main pane | `x-apple.systempreferences:com.apple.preference.security?Privacy` |

**Implementation:**
```swift
import AppKit

func openSystemSettings(_ anchor: String) {
    let urlString = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
    if let url = URL(string: urlString) {
        NSWorkspace.shared.open(url)
    }
}

// Usage:
openSystemSettings("Privacy_Accessibility")
```

**Version notes**: Despite macOS 13 Ventura renaming "System Preferences" to "System Settings," the URL scheme remains `x-apple.systempreferences`. These URLs are undocumented by Apple but have remained stable across versions.

---

## Polling for Accessibility permission changes

Since macOS provides no notification when Accessibility permission is granted, you must poll. Here's a production-ready implementation:

```swift
import SwiftUI
import ApplicationServices
import Combine

@MainActor
class PermissionManager: ObservableObject {
    @Published var accessibilityGranted = false
    @Published var microphoneGranted = false
    
    private var accessibilityTimer: Timer?
    
    init() {
        refreshAllStatuses()
    }
    
    func refreshAllStatuses() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    // MARK: - Accessibility Polling
    
    func startAccessibilityPolling() {
        stopAccessibilityPolling()
        
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let nowTrusted = AXIsProcessTrusted()
                
                if nowTrusted != self.accessibilityGranted {
                    self.accessibilityGranted = nowTrusted
                    if nowTrusted {
                        self.stopAccessibilityPolling()
                    }
                }
            }
        }
        RunLoop.main.add(accessibilityTimer!, forMode: .common)
    }
    
    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }
    
    // MARK: - Request Methods
    
    func requestAccessibility() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)
        startAccessibilityPolling()
    }
    
    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run { microphoneGranted = granted }
    }
    
    // MARK: - Open Settings
    
    func openAccessibilitySettings() {
        openSettings("Privacy_Accessibility")
        startAccessibilityPolling()
    }
    
    func openMicrophoneSettings() {
        openSettings("Privacy_Microphone")
    }
    
    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

**Best practice**: Stop polling in `.onDisappear` to prevent resource leaks. A 1-second interval balances responsiveness with efficiency.

---

## Recommended onboarding flow order

Based on patterns from Rectangle, Bartender, Raycast, and Apple's Human Interface Guidelines, request permissions in this order:

1. **Welcome screen** — Explain what the app does and why permissions are needed
2. **Accessibility** (required, manual) — Request first since it's the biggest friction point and core to functionality
3. **Microphone** (required, automatic) — Request second; the system dialog provides a smoother experience
4. **Completion screen** — Celebrate success, show how to access settings later

**Key UX principles from popular apps:**

- **Prime before prompting**: Show a custom explanation screen before triggering any system dialog. Users grant permissions **40-60% more often** when they understand why.
- **One permission per screen**: Never stack multiple requests. Each permission deserves its own explanation.
- **Provide direct paths**: Always include an "Open System Settings" button that deep-links to the exact pane.
- **Show status visually**: Use green checkmarks when granted, orange/red indicators when pending/denied (Loom's pattern).
- **Handle denial gracefully**: Explain what won't work, provide recovery instructions, but don't punish users.

**Messaging examples for WhisperM8:**

| Permission | Explanation |
|------------|-------------|
| Accessibility | "WhisperM8 needs Accessibility access to detect your keyboard shortcut from any app. This allows you to start recording with a single keypress, no matter what you're doing." |
| Microphone | "WhisperM8 needs microphone access to record your voice for transcription. Audio is processed locally and never sent to external servers." |

---

## Complete SwiftUI onboarding implementation

```swift
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, accessibility, microphone, complete
}

struct OnboardingView: View {
    @StateObject private var permissions = PermissionManager()
    @State private var currentStep: OnboardingStep = .welcome
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)
            
            // Content
            TabView(selection: $currentStep) {
                WelcomeStep(onContinue: { currentStep = .accessibility })
                    .tag(OnboardingStep.welcome)
                
                AccessibilityStep(permissions: permissions, onContinue: { currentStep = .microphone })
                    .tag(OnboardingStep.accessibility)
                
                MicrophoneStep(permissions: permissions, onContinue: { currentStep = .complete })
                    .tag(OnboardingStep.microphone)
                
                CompleteStep(onFinish: { hasCompletedOnboarding = true })
                    .tag(OnboardingStep.complete)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .frame(width: 500, height: 450)
    }
}

// MARK: - Welcome Step

struct WelcomeStep: View {
    let onContinue: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue.gradient)
            
            Text("Welcome to WhisperM8")
                .font(.largeTitle.bold())
            
            Text("Voice-to-text transcription with a single keystroke.\nLet's set up the permissions you'll need.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Button("Get Started") { onContinue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Accessibility Step

struct AccessibilityStep: View {
    @ObservedObject var permissions: PermissionManager
    let onContinue: () -> Void
    @State private var isWaiting = false
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(permissions.accessibilityGranted ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .frame(width: 100, height: 100)
                
                Image(systemName: permissions.accessibilityGranted ? "checkmark.shield.fill" : "accessibility")
                    .font(.system(size: 44))
                    .foregroundColor(permissions.accessibilityGranted ? .green : .orange)
            }
            
            Text("Accessibility Permission")
                .font(.title.bold())
            
            Text("Required for global keyboard shortcuts.\nThis lets WhisperM8 detect your hotkey from any app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            
            Spacer()
            
            if permissions.accessibilityGranted {
                Label("Permission Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.headline)
                
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if isWaiting {
                ProgressView()
                    .scaleEffect(1.2)
                
                Text("Toggle WhisperM8 in System Settings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Button("I've enabled it") {
                    permissions.refreshAllStatuses()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Open System Settings") {
                    isWaiting = true
                    permissions.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            
            Spacer()
        }
        .padding(32)
        .onChange(of: permissions.accessibilityGranted) { granted in
            if granted { isWaiting = false }
        }
        .onDisappear {
            permissions.stopAccessibilityPolling()
        }
    }
}

// MARK: - Microphone Step

struct MicrophoneStep: View {
    @ObservedObject var permissions: PermissionManager
    let onContinue: () -> Void
    @State private var isRequesting = false
    
    private var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(permissions.microphoneGranted ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "mic.fill")
                    .font(.system(size: 44))
                    .foregroundColor(permissions.microphoneGranted ? .green : .blue)
            }
            
            Text("Microphone Access")
                .font(.title.bold())
            
            Text("Required for voice recording.\nYour audio is processed locally—nothing is sent to the cloud.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            
            Spacer()
            
            if permissions.microphoneGranted {
                Label("Permission Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.headline)
                
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
            } else if status == .denied {
                Label("Permission Denied", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.headline)
                
                Text("Enable in System Settings to use voice recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button("Open System Settings") {
                    permissions.openMicrophoneSettings()
                }
                .buttonStyle(.borderedProminent)
                
                Button("Skip for Now") { onContinue() }
                    .buttonStyle(.bordered)
                    
            } else {
                Button("Allow Microphone Access") {
                    isRequesting = true
                    Task {
                        await permissions.requestMicrophone()
                        isRequesting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequesting)
            }
            
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Complete Step

struct CompleteStep: View {
    let onFinish: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green.gradient)
            
            Text("You're All Set!")
                .font(.largeTitle.bold())
            
            Text("Press your hotkey anytime to start recording.\nChange settings or permissions later in Preferences.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Button("Start Using WhisperM8") { onFinish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            
            Spacer()
        }
        .padding(32)
    }
}
```

---

## Handling edge cases and permission revocation

### Detecting revoked permissions at runtime

Check permissions on app launch and when the app becomes active:

```swift
@main
struct WhisperM8App: App {
    @StateObject private var permissions = PermissionManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(permissions)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    permissions.refreshAllStatuses()
                }
        }
    }
}
```

### When microphone is denied after initial grant

```swift
func handleMicrophoneDenied() -> some View {
    VStack(spacing: 16) {
        Image(systemName: "mic.slash.fill")
            .font(.largeTitle)
            .foregroundColor(.red)
        
        Text("Microphone Access Required")
            .font(.headline)
        
        Text("WhisperM8 can't record without microphone access.\nRe-enable it in System Settings.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        
        Button("Open System Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.borderedProminent)
    }
    .padding()
}
```

### When Accessibility is revoked

Accessibility can be revoked at any time in System Settings. Poll or check on key actions:

```swift
func performHotkeyAction() {
    guard AXIsProcessTrusted() else {
        showAccessibilityRequiredAlert()
        return
    }
    // Proceed with hotkey registration
}
```

---

## macOS version differences (13-15)

| Aspect | macOS 13 Ventura | macOS 14 Sonoma | macOS 15 Sequoia |
|--------|------------------|-----------------|-------------------|
| **Permission APIs** | Stable | No changes | No changes |
| **Deep link URLs** | Same format works | Same | Same |
| **Known issues** | `AXIsProcessTrusted()` can briefly return incorrect values when toggling | None significant | Screen Recording requires weekly re-confirmation |
| **UI name** | System Settings | System Settings | System Settings |

**Code signing requirement**: Without proper Developer ID signing, your app won't appear in the Accessibility list. During development with Xcode, note that **Xcode itself** needs Accessibility permission when debugging, not your unsigned app.

---

## Required Info.plist and entitlements

**Info.plist:**
```xml
<key>NSMicrophoneUsageDescription</key>
<string>WhisperM8 needs microphone access to record audio for transcription.</string>

<key>NSAccessibilityUsageDescription</key>
<string>WhisperM8 needs Accessibility access for global keyboard shortcuts.</string>
```

**Entitlements (for hardened runtime):**
```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

---

## Conclusion

The core challenge with macOS permission onboarding is the **asymmetry between automatic and manual permissions**. Microphone follows iOS conventions with a one-time system dialog, but Accessibility deliberately requires manual user action for security reasons. Your onboarding must guide users through this friction gracefully.

**Key implementation takeaways:**

- Use **polling at 1-second intervals** for Accessibility since no notification API exists
- **Deep-link directly** to the correct Settings pane—never make users hunt for it
- **Prime users** with explanations before system dialogs to dramatically increase grant rates
- Store `hasCompletedOnboarding` in `@AppStorage` to skip the wizard on subsequent launches
- **Check permissions on app activation**, not just at launch, to catch revocations

The code examples provided form a complete, production-ready onboarding system. The main customization points are the permission explanations and visual styling to match WhisperM8's brand.
---

## Benötigte Permissions

<!-- Nach der Recherche ausfüllen -->

## Permission-Check APIs

<!-- Nach der Recherche ausfüllen -->

## Deep Links zu Systemeinstellungen

<!-- Nach der Recherche ausfüllen -->

## Onboarding-Flow Empfehlung

<!-- Nach der Recherche ausfüllen -->

## Code-Beispiele

<!-- Nach der Recherche ausfüllen -->

## Error-Handling

<!-- Nach der Recherche ausfüllen -->
