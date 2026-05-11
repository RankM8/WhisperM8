# Theme & AppKit interop

## Token placement & ownership

The theme system is split unevenly:

- **`AppearanceOverride`** (`WhisperM8/Support/AppearanceOverride.swift`): correct home. Tri-state enum (`system`/`light`/`dark`) with `preferredColorScheme` and `nsAppearance` accessors. Self-contained, clean.
- **`ThemeManager`** (`WhisperM8/Support/ThemeManager.swift`): correct home. Singleton, `@Published override` + `@Published resolvedColorScheme`, KVO on `NSApp.effectiveAppearance`.
- **`AgentTheme`** (22 tokens, `AgentChatsView.swift` L3074–3176): **misplaced**. It is the canonical design-token table for the whole Dock window (sidebar/header/panel/surface/control/hover/selection/border/text*/accent*) but it sits as `private enum` inside a 3,208-line view file. Visibility = `private` means it cannot be reused by sibling files even if they wanted to. It should move to `WhisperM8/Support/AgentTheme.swift` (or `WhisperM8/Theme/Tokens.swift`) with `internal` visibility.
- **Scattered ad-hoc colors elsewhere**: `RecordingOverlayView.swift` uses raw `Color.white.opacity(0.2)` / `Color.black.opacity(0.08)` (12 occurrences); `OnboardingView.swift` has 26 occurrences. The `BranchTag` view inside `AgentChatsView.swift` (L2466–2470) hard-codes `Color(red: 0.78, green: 0.62, blue: 1.0)` four times — a violet accent that should be an `AgentTheme.accentBranch` token.
- **`AgentChatsWindowAccessor`** (L2381) inlines a dynamic background `NSColor(name: nil)` with the exact same RGB triple as `AgentTheme.background` dark — direct duplication of a token. If `AgentTheme.background.nsColor` were exposed, this could read `window.backgroundColor = AgentTheme.background.nsColor` and never drift.

## Color.dynamic helper

`Color.dynamic(light:dark:)` is defined twice in `AgentChatsView.swift` as `private extension Color` (L3178 and L3191 — the second one for the unrelated `init(hex:)`, fine, but the duplicated `private extension Color` declaration block is a code smell). The helper itself is small and well-implemented: it wraps `NSColor(name: nil) { appearance in ... }` and uses `bestMatch(from: [.aqua, .darkAqua])` — same idiom as `ThemeManager.resolve(...)` and the duplicated `AgentChatsWindowAccessor.configure(...)`.

**Suggested home**: `WhisperM8/Support/Color+Dynamic.swift`, with `internal` visibility so `AgentTheme`, `RecordingOverlayView`, and `OnboardingView` can all use it. The `bestMatch` predicate is repeated in three places (Color.dynamic, AgentChatsWindowAccessor, ThemeManager.resolve) — worth extracting as `NSAppearance.isDark` extension.

## AgentChatsWindowAccessor pattern

`AgentChatsWindowAccessor` is functional but not idiomatic:

- It creates an empty `NSView()` purely to walk up to `view.window`. The classic SwiftUI gotcha (`view.window` is `nil` at `makeNSView` time) is worked around with `DispatchQueue.main.async`. This is a known-fragile pattern: the window may still be `nil` on the next runloop tick if the view is hosted in a deferred sheet.
- `updateNSView` re-runs `DispatchQueue.main.async { configure(...) }` on every SwiftUI invalidation. There's no idempotency guard; the window flags are set multiple times per second during interactive resize. The mutations are themselves idempotent (`titlebarAppearsTransparent = true` etc.), so this is wasteful but not buggy.
- **No NSKeyValueObservation, no leak**: the accessor only sets static properties, never observes anything. The leak risk is zero, but the `DispatchQueue.main.async` capture of `self` (a value-type `NSViewRepresentable`) is harmless.
- Compare with `ThemeManager.appearanceObserver`: that one holds an `NSKeyValueObservation?` and is released when `ThemeManager` is deallocated. Since `ThemeManager` is a `static let shared` singleton, it never deallocates and the observer leaks for the app lifetime — acceptable, but worth noting.

**Better pattern**: subscribe to `NSWindow.didBecomeKeyNotification` or use `NSHostingController`'s configuration callback. Best: configure the window once in `WhisperM8App.swift` via `WindowGroup` + `.windowStyle(.hiddenTitleBar)` modifier where possible, and only fall back to the accessor for things SwiftUI can't do (the `NSColor(name:)` dynamic background).

## RecordingPanel appearance sync

`RecordingPanel.swift` does **not** set its own appearance. It relies entirely on `NSApp.appearance`, which `ThemeManager.setOverride(...)` writes globally:

```swift
NSApp?.appearance = value.nsAppearance
```

For `.system` this is `nil`, and AppKit falls back to system appearance. For `.light`/`.dark` it sets `.aqua`/`.darkAqua`. NSPanels inherit the effective appearance from `NSApp.appearance` only when they don't override it themselves — `RecordingPanel.init(...)` correctly does not touch `appearance`, so inheritance works. The `.borderless + .nonactivatingPanel + level = .floating` combo also keeps it well-behaved.

**One gap**: when `override == .system` and the user toggles macOS between Light/Dark while the panel is visible, the panel re-renders because its `NSHostingView<RecordingOverlayView>` participates in the appearance chain. But `RecordingOverlayView` itself uses hard-coded `Color.white.opacity(0.2)` — those are absolute, not dynamic — so the overlay always looks the same regardless of theme. That's a UX choice (the overlay is a dark glassy chip on every background), but worth documenting.

## AgentTerminalPalette quality

Strong points:
- sRGB color space explicitly chosen (with a good comment about P3-display fringing).
- Light and dark are calibrated independently rather than auto-inverted.
- The `term(r,g,b)` helper correctly scales 8-bit → 16-bit (`r * 257` which equals `(r << 8) | r`, the standard widening).

Weak points:
- **No named constants**: 32 hex triples in two static arrays with comments like `// 1: red`. A `static let red = term(0xa6, 0x1b, 0x29)` aliased per palette would let `installColors` build the array from named tokens. Easier to audit and tweak.
- **No contrast-ratio assertion**: light foreground `(0.12, 0.12, 0.13)` on `NSColor.white` is ~17.5:1 — fine for AAA. But for example light ANSI yellow `0xb4 0x6a 0x00` (amber) on white is ~3.7:1 — passes AA for large text only. There is no compile-time or unit-test check; the only documentation is the comment "eher amber für Lesbarkeit". A `#if DEBUG` assertion using a `contrastRatio(_:_:)` helper would catch regressions.
- **Placement is fine**: the palette is genuinely terminal-specific and doesn't need to leak into `AgentTheme`. Keeping `SwiftTerm.Color` types out of the wider theme is correct.

## ClaudeThemeWriter correctness

Detailed review of `WhisperM8/Services/ClaudeThemeWriter.swift`:

- **Read-fail handling**: silently skipped with a `debug` log. Acceptable; the file is recreated by Claude on next launch.
- **Parse-fail handling**: correctly skips the write. The comment "Datei ist gerade mid-write von Claude" is the right read, but there is no retry — a `Task` that re-attempts after a short delay would catch the case where the write is finally complete. Currently a one-shot miss means the theme stays out of sync until the next `setOverride`.
- **Atomic write**: temp file in the same directory (correct, ensures `rename(2)` not cross-FS copy) + `replaceItemAt`. Permissions are read from the original and reapplied to the tmp file before rename. Good.
- **Debounce**: `pendingWorkItem` is canceled and replaced; final write happens 0.5s after the last call. The cancellation is synchronous on the main actor, so there's no race with the dispatched block. Solid.
- **One-time backup**: `hasCreatedInitialBackup` flag is an instance var — survives only the app lifetime. `fm.fileExists(atPath: backupURL.path)` is the persistent guard. Combined, this guarantees one backup ever, which is the documented intent.
- **Race against Claude**: documented in the file header. The only true race window is between the parse-success and the `replaceItemAt`. If Claude writes its own copy in that gap, our `replaceItemAt` clobbers it. This is acknowledged as unsolvable without OS-level locking and is the best you can do.
- **Idempotency**: the `current == target` guard prevents churn writes. Correct.
- **Logging**: uses `Logger.agentPerformance` with privacy tags. Good.

Overall: this file is the cleanest in the bunch.

## ThemeManager singleton + KVO

- **Lifecycle**: `static let shared = ThemeManager()` lives for the entire app process. `appearanceObserver` is `NSKeyValueObservation?` and only deinitializes when `ThemeManager` does — which is never. Net memory cost: one KVO observation. Not a real leak, just permanent.
- **Cycle risk**: the observer block uses `[weak self]` correctly even though `self` can't deallocate. Belt-and-suspenders style.
- **`Task { @MainActor [weak self] in ... }` inside the KVO block**: the outer KVO closure runs on whatever thread KVO fires from (typically main for AppKit, but not guaranteed). Hopping back via Task is correct. Slight overhead per appearance change — negligible.
- **`NSApp?` everywhere**: optional chain because `NSApp` is `nil` during tests. Sensible.
- **Initial sync**: `performInitialClaudeThemeSync()` is called from `WhisperM8App.swift` L95. Good wiring.

## Notification vs Combine

The `AgentTerminalController.themeDidChangeNotification` string-keyed notification is the weakest link:

- The notification is a `Notification.Name("AgentTerminalController.themeDidChange")` literal posted from `ThemeManager.recompute(...)` with the **type-defined name** living in a totally different file (`AgentTerminalView.swift` L267). Renaming one without the other silently breaks light/dark switching in terminals. Mitigation: post via `AgentTerminalController.themeDidChangeNotification` (the typed constant) rather than the raw string literal.
- The userInfo dict casts `["scheme"] as? ColorScheme` — also a string-keyed cast that fails silently.

A `Combine` subscription on `ThemeManager.shared.$resolvedColorScheme` would be type-safe end-to-end. `AgentTerminalController` already has `@Published` properties — it can hold an `AnyCancellable` and subscribe in `init`. The subscription auto-cancels on `deinit`, replacing the manual `NotificationCenter.removeObserver` dance.

Why notification might still be acceptable here: `AgentTerminalController` is NSObject-bridged and the SwiftUI-layer doesn't observe `resolvedColorScheme` directly — it reads `themeManager.override`. The notification is the bridge from "ThemeManager resolved a new scheme" to "non-SwiftUI sink reacts." Combine handles that just as well, with one fewer string identifier.

## Top refactors, ranked

1. **Move `AgentTheme` to `WhisperM8/Support/AgentTheme.swift`** with internal visibility. Unblocks reuse by `RecordingOverlayView` and `OnboardingView` and shrinks `AgentChatsView.swift` by ~100 LOC.
2. **Move `Color.dynamic(light:dark:)` to `WhisperM8/Support/Color+Dynamic.swift`** (internal) and extract `NSAppearance.isDark` to a shared extension; deduplicate three copies of the `bestMatch` predicate.
3. **Replace `themeDidChangeNotification` with a Combine subscription** on `ThemeManager.shared.$resolvedColorScheme` inside `AgentTerminalController`. Removes string-keyed userInfo and one `NotificationCenter.removeObserver` call.
4. **Fold `AgentChatsWindowAccessor`'s inline `NSColor(name:)` background** into `AgentTheme.background.nsColor` or a `WindowAppearance` helper, so the dark RGB triple lives in exactly one place.
5. **Promote ad-hoc colors** in `RecordingOverlayView` and `BranchTag` to `AgentTheme` tokens (`accentBranch`, `overlayGlass`, etc.).
6. **Add a `#if DEBUG` contrast-ratio assertion** for `AgentTerminalPalette` light variants — light amber yellow on white is borderline.
7. **Add a debounced retry in `ClaudeThemeWriter`** when JSON parsing fails (likely mid-write by Claude). One retry after 1s would close the only real correctness gap.
