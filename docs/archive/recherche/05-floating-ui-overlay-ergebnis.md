# Recherche-Ergebnis: Floating UI/Overlay unter macOS

# Building a floating recording overlay for WhisperM8 on macOS

A floating overlay for a voice recording app requires **NSPanel with the `.nonactivatingPanel` style mask** at the `.floating` window level—this combination ensures the overlay stays visible above other windows while letting users continue typing elsewhere without focus interruption. The optimal implementation uses NSPanel subclassed to host SwiftUI views via `NSHostingView`, with `canBecomeKey` and `canBecomeMain` returning `false` to prevent focus stealing. For macOS 15+, pure SwiftUI approaches using `.windowLevel(.floating)` and `.windowStyle(.plain)` modifiers now offer a cleaner alternative.

## NSPanel provides purpose-built floating window behavior

The choice between **NSPanel** and **NSWindow** is straightforward for recording overlays: NSPanel is specifically designed for auxiliary, floating interfaces and provides critical built-in behaviors that NSWindow requires manual configuration to achieve.

**NSPanel advantages over NSWindow:**
- Built-in `isFloatingPanel` property for automatic floating behavior
- Cannot become main window by default (only key window when needed)
- Doesn't appear in the Window menu
- Has `becomesKeyOnlyIfNeeded` property for intelligent focus handling
- Designed for tool palettes, inspectors, and overlays

The essential configuration for a non-activating recording overlay:

```swift
class RecordingOverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 56),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        
        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = true
        
        // Hide title bar and traffic lights
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

The **`.nonactivatingPanel`** style mask is the most critical setting—it ensures that clicking or opening the panel does not activate the owning application, allowing users to keep typing in other apps with their cursor still blinking.

## Window levels determine overlay stacking behavior

macOS uses a hierarchy of window levels to determine which windows appear above others. For a recording overlay, **`.floating` (level 3)** is the recommended choice:

| Level | Value | Behavior |
|-------|-------|----------|
| `.normal` | 0 | Standard windows |
| `.floating` | 3 | Above apps, below system UI |
| `.statusBar` | 25 | Above Dock and menu bar |
| `.screenSaver` | 101 | Very high, blocks system UI |

The `.floating` level keeps the overlay above application windows without interfering with pop-up menus, sheets, or system dialogs. If you need the overlay visible above the Dock, use `.statusBar` instead.

For **cross-Space visibility**, the `collectionBehavior` settings are essential: `.canJoinAllSpaces` makes the window appear on every desktop, `.fullScreenAuxiliary` allows it to appear over full-screen apps, and `.stationary` prevents it from moving during Exposé animations.

## SwiftUI integration through NSHostingView or native APIs

**For macOS 12–14**, host SwiftUI content inside NSPanel using `NSHostingView`:

```swift
contentView = NSHostingView(rootView: RecordingIndicatorView()
    .ignoresSafeArea())
```

**For macOS 15+**, SwiftUI now offers native window-level modifiers:

```swift
@main
struct WhisperM8App: App {
    var body: some Scene {
        WindowGroup(id: "recording-overlay") {
            RecordingOverlayView()
        }
        .windowLevel(.floating)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .windowManagerRole(.associated)
    }
}
```

The `.windowManagerRole(.associated)` modifier gives the window auxiliary behavior similar to NSPanel, though the NSPanel approach still offers finer control for complex use cases.

## Optimal overlay design balances visibility with non-intrusion

Based on analysis of macOS Dictation, CleanShot X, Loom, and other professional recording apps, the recommended design parameters are:

**Dimensions:** **180×56 points** for a minimal overlay showing recording indicator, timer, and compact audio visualization. This follows the "small" control size principle in Apple's HIG—large enough to be legible, small enough to stay unobtrusive.

**Positioning:** **Bottom-center of screen**, 40 points from the bottom edge, respecting Dock clearance. Professional apps universally avoid screen center (too intrusive) and cursor-proximate positioning (covers work). Make the overlay **draggable** with position persistence—users expect to move it where convenient.

**Visual style:** Use **`.regularMaterial` or `.hudWindow`** vibrancy for native macOS appearance that adapts to light/dark mode and blends with screen content. Corner radius of **10–12 points** matches system aesthetic.

## Recording indicator and animation implementation

A pulsing red recording dot provides essential "alive" feedback without being jarring. The animation should use a **1–1.5 second ease-in-out cycle**:

```swift
struct RecordingIndicator: View {
    @State private var isPulsing = false
    
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 12, height: 12)
            .overlay(
                Circle()
                    .stroke(Color.red.opacity(0.5), lineWidth: 2)
                    .scaleEffect(isPulsing ? 1.8 : 1)
                    .opacity(isPulsing ? 0 : 1)
            )
            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), 
                       value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
```

For **window appear/disappear transitions**, Apple recommends **spring animations** (WWDC 2023) over Bézier curves—they maintain velocity continuity during interrupts and feel more natural. Use duration of **0.25–0.35 seconds** with moderate bounce.

## Audio level visualization confirms microphone input

Audio level bars provide critical feedback that the microphone is receiving input—preventing "silent recording" failures. A simple **5-bar visualizer** updating at 10–15 FPS is sufficient:

```swift
class AudioLevelMonitor: ObservableObject {
    @Published var level: Float = 0.0
    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    
    func startMonitoring() {
        let url = URL(fileURLWithPath: "/dev/null")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1
        ]
        
        audioRecorder = try? AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.isMeteringEnabled = true
        audioRecorder?.record()
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            self.audioRecorder?.updateMeters()
            let power = self.audioRecorder?.averagePower(forChannel: 0) ?? -160
            self.level = max(0, 1 - (power / -160))
        }
    }
}
```

For more sophisticated waveform rendering, the **DSWaveformImage** library provides production-ready `WaveformLiveCanvas` views for real-time visualization.

## Complete overlay view combining all elements

```swift
struct VoiceRecordingOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    @State private var isPulsing = false
    @State private var elapsedTime: TimeInterval = 0
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    let startTime = Date()
    
    var body: some View {
        HStack(spacing: 12) {
            // Recording indicator
            RecordingIndicator()
            
            // Timer display
            Text(timeString)
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
            
            // Audio level bars
            AudioLevelBars(level: audioMonitor.level)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .onAppear { audioMonitor.startMonitoring() }
        .onDisappear { audioMonitor.stopMonitoring() }
        .onReceive(timer) { _ in
            elapsedTime = Date().timeIntervalSince(startTime)
        }
    }
    
    private var timeString: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
```

## Energy efficiency requires animation lifecycle management

Continuous animations drain battery unnecessarily when the overlay isn't visible. **Pause all animations and timers** when:

- The app resigns active status (`NSApplication.didResignActiveNotification`)
- The window is hidden or minimized
- The screen sleeps (`NSWorkspace.screensDidSleepNotification`)

For animations synchronized with display refresh, use **CADisplayLink** (macOS 14+) rather than Timer—it automatically adjusts to display refresh rate and suspends when the view isn't visible:

```swift
let displayLink = view.displayLink(target: self, selector: #selector(update))
displayLink.add(to: .current, forMode: .common)
```

For audio level updates, **10 FPS (100ms interval)** is sufficient for visual feedback—avoid unnecessary 60 FPS updates.

## Accessibility requirements for overlay interfaces

Recording overlays must support VoiceOver users with proper labeling:

```swift
.accessibilityLabel("Recording in progress")
.accessibilityValue("\(timeString) elapsed")
.accessibilityHint("Recording will continue until stopped")
.accessibilityAddTraits(.updatesFrequently)
```

**Respect Reduce Motion** by checking `@Environment(\.accessibilityReduceMotion)` and replacing spring/scale animations with simple fades or disabling the pulsing animation entirely.

**Maintain 4.5:1 minimum contrast ratio** for text elements. Use semantic colors (`.labelColor`, `.secondaryLabelColor`) that automatically adapt to appearance modes and Increase Contrast settings.

## Reference app patterns worth emulating

**macOS Dictation** uses minimal visual footprint—just a pulsing cursor indicator near the text insertion point. The key lesson: less is more when users need to focus on their work.

**CleanShot X** positions its overlay in a screen corner with configurable location, supports swipe gestures for quick interaction, and offers a "hide temporarily" option. Its timer appears in the menu bar as an alternative to the floating overlay.

**Loom** makes its recording controls freely draggable and remembers user-chosen positions. The dynamic waveform on the microphone indicator confirms active audio input—essential for preventing silent recordings.

**Krisp** demonstrates the menu bar approach—a small icon with an expandable widget that appears only when needed, staying completely out of the way during normal use.

## Implementation checklist

For WhisperM8's recording overlay:

1. **Subclass NSPanel** with `.nonactivatingPanel` style mask
2. **Set window level** to `.floating` (or `.statusBar` if needed above Dock)
3. **Configure collection behavior** for all Spaces and fullscreen support
4. **Override `canBecomeKey`/`canBecomeMain`** to return `false`
5. **Use NSHostingView** to embed SwiftUI content (or native APIs on macOS 15+)
6. **Enable `isMovableByWindowBackground`** for dragging
7. **Persist window position** using `frameAutosaveName` or UserDefaults
8. **Apply `.regularMaterial`** background for native vibrancy
9. **Implement pulsing animation** with 1.2s ease-out cycle
10. **Add audio level monitoring** at ~10 FPS update rate
11. **Pause animations** when window not visible
12. **Add VoiceOver labels** and respect Reduce Motion preference

The combination of NSPanel's floating behavior, proper collection behaviors for cross-Space visibility, and SwiftUI's declarative UI provides a solid foundation for a professional recording overlay that integrates seamlessly with the macOS experience.
---

## Technische Implementierung

<!-- Nach der Recherche ausfüllen -->

## Design-Empfehlung

<!-- Nach der Recherche ausfüllen -->

## Code-Beispiel

<!-- Nach der Recherche ausfüllen -->

## Referenz-Screenshots

<!-- Nach der Recherche ausfüllen -->
