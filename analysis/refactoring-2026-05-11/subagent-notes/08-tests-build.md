# Tests, build, deployment

Snapshot:
- 6 test files, ~2.5k LoC total, 148 `func test*` (`AgentChatsTests` 110, `OutputDashboardTests` 25, `PreferencesTests` 5, `AudioDuckingManagerTests` 2, `TranscriptionUtilityTests` 4, `WindowAndOverlayTests` 2).
- No `URLSession`, `Process`, real `claude`/`codex` calls, or `XCUI`/SnapshotTesting in the test target — pure unit tests.
- No CI workflow (`.github/` does not exist).

## Coverage matrix

| Service / area | File | Tested? | Brittle? |
|---|---|---|---|
| `AgentCommandBuilder` | Services/AgentCommandBuilder.swift | TESTED (7 tests) | no |
| `CodexSessionIndexer` | Services/AgentSessionIndexer.swift | TESTED (4 tests, cache + bounded reads) | no — uses temp dirs |
| `ClaudeSessionIndexer` | same | TESTED (2 tests, worktree-skip + cache) | no |
| `AgentSessionStore` | Services/AgentSessionStore.swift | TESTED (~25 tests: persistence, ordering, worktree migration, summary, icons, drag-drop, rename) | no |
| `AgentResourceMonitor` | Services/AgentResourceMonitor.swift | TESTED (3 tests, synthetic samples) | no |
| `AgentSessionAutoNamer` | Services/AgentSessionAutoNamer.swift | TESTED (title cleanup, can-auto-rename, force-generate, recordTurnEnded — 11 tests) | no |
| `AgentSessionSummarizer` | Services/AgentSessionSummarizer.swift | TESTED (parse + buildExtended, 5 tests) | no |
| `AgentSessionRuntimeWatcher` | Services/AgentSessionRuntimeWatcher.swift | NOT TESTED | n/a |
| `AgentTranscriptParser` + `StatusDecider` | Models/AgentSessionTranscript* | TESTED (transcript parser claude+codex, 6 + 6 tests) | no |
| `AgentTranscriptLocator` | Services/AgentSessionTranscript.swift | PARTIAL — only `encodeClaudeCwd` (1 test) | no |
| `AgentTranscriptExcerpt` | Services/AgentSessionSummarizer.swift | TESTED (truncation marker, short session) | no |
| `AgentProjectIconResolver` | Services/AgentProjectIconResolver.swift | TESTED (4 tests, real temp filesystem) | low |
| `AgentChatLaunchService` | Services/AgentChatLaunchService.swift | NOT TESTED | n/a |
| `AgentTerminalView` / SwiftTerm wiring | Views/AgentTerminalView.swift | PARTIAL — `TerminalShortcut.bytes`, `TerminalDropPayload` (10 tests). The 17k-LoC view itself is untested. | no |
| `LoginShellEnvironment` | Services/LoginShellEnvironment.swift | TESTED (7 tests, PATH merge, caching, env injection) | no |
| `ThemeManager` / `AppearanceOverride` / `ClaudeThemeWriter` | Support + Services | TESTED (5 tests) — only the pure `resolve`/name-mapping. The actual file-write side of `ClaudeThemeWriter` is **NOT** tested. | low |
| `OutputMode` / `OutputModeStore` / `PostProcessingTemplate(Store)` | Models / Services | TESTED (built-ins, migration, render, duplicate, default-enabled invariant) | no |
| `PostProcessingService` | Services | PARTIAL — Raw vs. configured-processor path + selected-context policy. Codex/Claude actual invocation NOT tested (uses `MockPostProcessor`). | no |
| `PromptPackageBuilder` / `ReplyIntentRouter` / `VisualAttachmentDeliveryBuilder` | Services / Models | TESTED (intent routing, image labels, disabled-mode skip) | no |
| `TranscriptRunReportStore` | Services | TESTED (1 round-trip incl. attachments) | medium — file I/O |
| `TranscriptContextBundle` | Models | TESTED (summary helpers, agent-chat refs, video selection) | no |
| `TranscriptionService` / OpenAI/Groq HTTP clients | Services/TranscriptionService.swift | NOT TESTED at the service layer; only `MultipartFormDataBuilder`, `TextNormalizer`, `calculateTimeout`, model→provider mapping covered. | no |
| `AudioDuckingManager` | Services | TESTED (route changes, unsupported device) via `FakeAudioVolumeController` | no |
| `AudioRecorder` | Services/AudioRecorder.swift (19k LoC) | **NOT TESTED** | n/a |
| `AudioDeviceManager` | Services | NOT TESTED | n/a |
| `RecordingCoordinator` (36k LoC, the orchestrator) | Services | **NOT TESTED** | n/a |
| `VisualContextCaptureService` / `SelectedContextService` / `PermissionService` | Services | NOT TESTED | n/a |
| `PasteService` | Services | NOT TESTED | n/a |
| `KeychainManager` | Services | NOT TESTED | n/a |
| `AppPreferences` | Support | TESTED (defaults, save/load, migration) | no |
| `WindowRequestCenter` / `OverlayPositionStore.clamp` | Windows | TESTED minimally (2 tests) | no — `WindowRequestCenter.shared` is a global singleton mutated across tests (parallel-test hazard, see below) |
| Agent drag-drop (sidebar + tab strip) | Views/AgentDragDropTypes.swift, AgentChatsView | PARTIAL — only store-side reorder/move tests. `.draggable`/`.onDrop` SwiftUI wiring is untested. | no |
| Finder file-drop into terminal | terminal drop payload | TESTED at payload-builder level only. | no |

Rough verdict: **services with small, deterministic surfaces are well-covered (≥80%)**. The big unfunneled holes are `RecordingCoordinator` (36 KB), `AudioRecorder` (19 KB), `VisualContextCaptureService` (20 KB), `PasteService`, `KeychainManager`, the actual transcription HTTP path, and **everything UI** (`AgentChatsView` 128 KB, `OutputDashboardView` 49 KB, `SettingsView` 27 KB, `OnboardingView` 21 KB, `RecordingOverlayView` 22 KB).

## AgentChatsTests organization

`Tests/WhisperM8Tests/AgentChatsTests.swift` is one 1750-line class with 110 tests. It uses 13 `// MARK:` sections, so it is loosely grouped but everything ends up in the same `final class AgentChatsTests: XCTestCase`. Logical clusters:

1. AgentCommandBuilder (L7–167, 7 tests)
2. CodexSessionIndexer + cache (L169–256, 4 tests)
3. ClaudeSessionIndexer (L257–321, 2 tests)
4. AgentSessionStore (L322–597, ~13 tests on workspace persistence/launch flags/ordering/worktree migration/unresumable cleanup)
5. AgentResourceMonitor (L598–672, 3 tests)
6. Auto-chat-context bundle (L693–779)
7. Terminal keyboard shortcuts (L781–962)
8. LoginShellEnvironment (L862–947)
9. Transcript parser + status decider (L964–1112)
10. Title generator / auto-naming (L1114–1304)
11. Transcript locator (L1306–1318)
12. Terminal drag-drop payload (L1320–1353)
13. Summary excerpt + parser (L1355–1417)
14. Session-summary persistence (L1419–1458)
15. Project icon resolver (L1460–1502)
16. Project metadata persistence (L1504–1599)
17. Drag-and-drop reordering (L1618–1692)
18. Theme resolve + ClaudeThemeWriter (L1694–1749)

**Proposed split** (one file per service, ~150–250 LoC each):

```
Tests/WhisperM8Tests/
  AgentCommandBuilderTests.swift           // §1
  AgentSessionIndexerTests.swift           // §2 + §3 (Claude + Codex share cache type)
  AgentSessionStoreTests.swift             // §4 + §14 + §16 + §17 + ordering helpers
  AgentResourceMonitorTests.swift          // §5
  AgentSessionAutoNamerTests.swift         // §10
  AgentSessionSummarizerTests.swift        // §13
  AgentTranscriptTests.swift               // §9 + §11
  TerminalShortcutTests.swift              // §7 + §12
  LoginShellEnvironmentTests.swift         // §8
  TranscriptContextBundleTests.swift       // §6
  AgentProjectIconResolverTests.swift      // §15
  ThemeManagerTests.swift                  // §18
  Helpers/AgentTestHelpers.swift           // shared makeTempStoreURL/makeTempProjectDirectory
```

This drops the largest file to ~250 LoC and gives every service a discoverable test home, matching the convention already used for `OutputDashboardTests`/`AudioDuckingManagerTests`/`PreferencesTests`. Cost: a single mechanical move — no behavioural changes.

## Test setup duplication

Helpers `makeTempStoreURL` (AgentChatsTests L1611) and `makeTempProjectDirectory` (L1604) exist **only as fileprivate methods on `AgentChatsTests`** and are used 17 times in that file (L1167/L1186/L1205/L1210/L1262/L1291/L1422/L1444/L1463/L1476/L1489/L1499/L1507/L1517/L1526/L1535/L1546/L1549/L1559/L1562/L1573/L1589/L1606/L1621/L1638/L1663). Adjacent inline temp-URL recipes still appear ~30 times in earlier sections (L322, 342, 361, 389, 410, 430, 469, 503, 536, 568, …) and are **not** routed through the helper — they pre-date it. Also duplicated in `OutputDashboardTests` (L82, L104, L185, L207, L344, L437) which builds its own copy of the same recipe.

Two more helpers are duplicated copy-paste verbatim across files:
- `withIsolatedPreferences(_:)` in `PreferencesTests.swift` (L103) and `withIsolatedDuckingPreferences(_:)` in `AudioDuckingManagerTests.swift` (L96) and `withIsolatedOutputPreferences(_:)` in `OutputDashboardTests.swift` (L495). All three swap `AppPreferences.shared` against a private `UserDefaults` suite and clean up. **Single shared helper would cut ~60 lines.**

Proposed shared `Tests/WhisperM8Tests/Helpers/`:
- `TempFiles.swift` — `tempDirectory(prefix:)`, `tempStoreURL(...)`, `tempProjectDirectory()`.
- `PreferenceIsolation.swift` — `withIsolatedPreferences(_:)` (one canonical implementation, generic over throwing/non-throwing).
- `MockPostProcessor.swift` — currently defined inline in `OutputDashboardTests` (L220, 227, 237) and would be useful elsewhere.

## Brittle / dangerous tests

None call the network or external binaries — good. The actual risks:

- **Date-of-epoch coupling** — `OutputDashboardTests.testTemplateRenderingReplacesPlaceholders` (L121–147) asserts the rendered string contains `"1970-01-01"`. That works only if `date` is formatted with the default time zone after `Date(timeIntervalSince1970: 0)`; in a non-UTC CI box this can shift to `1969-12-31`. **Fix:** pass an explicit time zone into the renderer or assert with a regex.
- **`WindowRequestCenter.shared` mutation** — `WindowAndOverlayTests.testWindowRequestCenterStoresLatestRequest` (L7–18) writes to the global singleton without restoring it. If XCTest runs anything else against the same process and reads `latestRequest`, order matters. Low risk today (only one such test), but a trap once the suite grows.
- **`AppPreferences.shared` swap is not thread-safe** — all three `withIsolatedPreferences*` helpers replace a global singleton in-place. Safe under `-parallel-testing-enabled NO` (the SwiftPM default), but the moment anyone runs `swift test --parallel` or uses XCTest's parallel destinations, these tests race. Worth a comment in the helper.
- **`AgentSessionIndexCache` bounded-read assertions are tightly coupled to magic numbers** — `testCodexSessionIndexerReadsOnlyBoundedMetadataPrefixAndUsesCache` (L188) asserts `bytesRead <= 256 KiB` and the Claude variant (L291) `<= 1 MiB`. If the implementation reasonably grows those limits, the test fails for the wrong reason. Replace with a relative bound (`< fileSize`).
- **`TranscriptRunReportStore` test writes to `/tmp` and never asserts the working directory survives a real `tearDown` if the test panics mid-write.** Minor — file is removed by `defer`, but a `setUp`/`tearDown` registered helper would be safer.
- **Worktree-migration tests construct real directory trees** at `/tmp/...claude/worktrees/...` (`AgentChatsTests` L468–533). They're correctly cleaned up via `defer`, but if a previous failed test left the tree behind, the next run can see it. A guarded `removeItem` at setUp is harmless and cheap.

No truly dangerous tests; the suite is refactor-friendly.

## UI test gap

The 128 KB `AgentChatsView` is fully untested at the view layer. Native macOS apps with `MenuBarExtra` and non-activating panels are awkward for `XCUITest`, but two cheap, high-value options exist:

1. **`ViewInspector`** (https://github.com/nalexn/ViewInspector) — lets you assert on a SwiftUI view's body without rendering. Lowest effort: pass a `AgentSessionStore` with a known workspace, render `AgentChatsView`, assert sidebar shows N rows, the right session is selected, tab strip enumerates open sessions in the right order. ~30 minutes per scenario, no UIKit/AppKit lift.
2. **Snapshot testing with `swift-snapshot-testing`** (https://github.com/pointfreeco/swift-snapshot-testing) — `assertSnapshot(matching: view, as: .image(size: …))`. Captures regressions on visual layout (e.g. sidebar collapse, tab-strip overflow, terminal placeholder for closed sessions). Needs Xcode toolchain (already required, see Makefile L8). Drawback: re-records on every theme tweak; mitigate by snapshotting *small* components (`SessionRow`, `TabStripItem`, `InactiveSessionSummary`) instead of the whole view.

Either pulled in as a `.testTarget` dependency in `Package.swift`. **Lowest-effort starter pack**: snapshot the three states of `RecordingOverlayView` (idle/recording/processing) and the four states of `AgentChatsView`'s right-pane (no-selection, active-terminal, summary-of-closed, summary-loading). Eight snapshots, ~80 lines of test code, catches 80% of the regressions a styling refactor would otherwise ship.

## Makefile review

| Target | Idempotent? | Findings |
|---|---|---|
| `dev` (alias `dev-reinstall`) | yes | `rsync -a --delete` preserves TCC. `lsregister -f` after sync is present (L68) and the right thing for picking up `UTExportedTypeDeclarations` changes. Good. |
| `build` | yes | Pure release build → local `.app`. Fine. |
| `install` | yes — **but missing `lsregister`**. `install` does the same rsync as `dev` (L102–107) but skips the LaunchServices re-registration. Consequence: changes to `Info.plist` (e.g. new UTIs) don't take effect when a user runs `make install` instead of `make dev`. **Fix:** factor the rsync + lsregister into an `_install_bundle` recipe and have both `dev` and `install` call it. |
| `run` | yes | Debug build, runs from project dir (separate TCC). Documented well. |
| `kill` | yes | `pkill -x WhisperM8` — exact match, safe. |
| `clean` | yes | Removes `.build` + local `.app`. |
| `clean-apps` | yes | Removes every known `.app` location. |
| `clean-install` | yes | Delegates to `scripts/clean-install.sh` (TCC reset + UserDefaults + Keychain + Caches) then `make install`. Heavy but correctly scoped. |
| `dmg` | mostly | Delegates to `scripts/build-dmg.sh`. The script runs `make build` first, then signs/notarizes if env vars are present. Side note: `make dmg` does **not** depend on `kill`, so if the app is running you still get a successful build, but the bundle in `WhisperM8.app/` may have a stale executable from a prior `make dev` that left a running process holding the file. Worth either chaining `kill` or removing local `.app` first. |
| `_bundle` | yes | Internal recipe; `PlistBuddy Delete` is guarded with `\|\| true`. Hard-codes the resource list — every new file under `Resources/` requires a Makefile edit *and* a `Package.swift` edit. Worth a `for f in WhisperM8/Resources/*.png` loop. |
| `mark-onboarded` | yes | One-shot defaults write, fine. |
| `dev-skip-onboarding` | yes | `kill` → `mark-onboarded` → `$(MAKE) dev`. |

Missing targets worth considering:
- `make test` — currently `swift test` works, but there's no documented Make target. Add: `test: ; @swift test`.
- `make ci` — wraps `test` + `build` for a single-command CI invocation.
- `make lint` — no SwiftLint config, no `swift-format` config. Optional.

## Dependencies

`Package.swift` declares four:

| Dependency | Pin | Used at | Status |
|---|---|---|---|
| `KeyboardShortcuts` | `exact: 1.16.1` | `WhisperM8App.swift`, `SettingsView.swift`, `MenuBarView.swift` | Used. Pinned exact — fine for a global-hotkey lib (API churn would silently break recording). |
| `Defaults` | `from: 8.0.0` | Imported? `grep` shows zero call sites. Either dead or only `@Default` macro is somewhere out of grep range. Worth a `swift package show-dependencies` confirm. **Likely unused.** |
| `LaunchAtLogin-Modern` (product `LaunchAtLogin`) | `from: 1.0.0` | `WhisperM8App.swift`, `SettingsView.swift` | Used. |
| `SwiftTerm` | `from: 1.13.0` | `AgentTerminalPalette.swift`, `AgentTerminalView.swift` | Used. |

**`CLAUDE.md` is out of date** — it still lists `ISSoundAdditions 2.0.0`, but `Package.swift` has dropped it. Audio ducking is implemented natively against CoreAudio (`AudioDuckingManager.swift`), so the doc is just stale. Worth fixing during refactor.

**`Defaults` is suspect** — no import in `WhisperM8/**/*.swift` matched the grep, and `AppPreferences.swift` rolls its own UserDefaults-backed properties (no `@Default` macros). If a build still succeeds without it, drop the dep.

## CI gap

There is no `.github/workflows/`, no `Bitrise`, no `fastlane`, nothing. For a 18k-LoC SwiftUI app with 148 tests, the **minimum** that would unblock refactors:

```yaml
# .github/workflows/test.yml
name: test
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with: { xcode-version: latest-stable }
      - name: Build
        run: swift build
      - name: Test
        run: swift test --parallel
```

That's it. ~5 minutes per run on `macos-14`. Adds the safety net needed to do the big splits suggested in §AgentChatsTests organization without breaking anything silently. Optional follow-ups:
- A second job running `make dmg` on tag pushes (publishes the DMG as a release asset).
- `actionlint` for the workflow itself.
- Cache `~/Library/Developer/Xcode/DerivedData` keyed on `Package.resolved` (cuts builds from ~3 min to ~30 s).

The fact that `make dmg` already supports `NOTARYTOOL_PROFILE` / `APPLE_ID` / `APPLE_TEAM_ID` env vars means notarization in CI is already plumbed end-to-end — only secrets configuration is missing.

## Info.plist completeness

Currently present (`WhisperM8/Info.plist`):
- `LSUIElement=false` (regular Dock app)
- `NSMicrophoneUsageDescription` (German)
- `NSScreenCaptureUsageDescription` (German)
- `CFBundleName`, `CFBundleIdentifier`, `CFBundleVersion`, `CFBundleShortVersionString` (both `1.2.0`)
- `LSMinimumSystemVersion` (14.0)
- `UTExportedTypeDeclarations` for `com.whisperm8.app.agent-chat-session` and `com.whisperm8.app.agent-project`

**Missing / recommended:**

- `NSAppleEventsUsageDescription` — **required at runtime** if `PasteService` ever sends an AppleEvent (it currently uses `CGEvent` for synthetic Cmd+V, which avoids the prompt, but if the auto-paste path is extended to target a specific app via AppleScript this becomes mandatory or paste silently fails).
- **`NSAccessibilityUsageDescription`** — TCC's Accessibility prompt for `CGEvent` posting (used by `PasteService`) reads from this string. Without it the system fallback is generic German "WhisperM8 möchte deinen Computer steuern", which is fine but unbranded. Recommended.
- `NSSystemAdministrationUsageDescription` — not needed; the app is unsandboxed (entitlements show `app-sandbox=false`).
- `LSApplicationCategoryType` — missing. Recommended for App Store / Spotlight categorization (`public.app-category.productivity`). Cosmetic.
- `CFBundleDevelopmentRegion` — missing. Currently defaults to "English" which can confuse the German micro-copy in Onboarding/Settings. Set to `de` or explicit `en`.
- `NSHumanReadableCopyright` — missing. Small, polish.
- `ITSAppUsesNonExemptEncryption` — missing. The app talks to OpenAI/Groq over HTTPS but uses only system TLS, so technically `false` suffices. Setting this explicitly avoids App Store/notarization warnings.
- `NSCameraUsageDescription` — not needed; no AVCaptureSession against camera.

Entitlements file is correct: `com.apple.security.network.client=true` (needed for OpenAI/Groq), `device.audio-input=true` (microphone), `app-sandbox=false` (consistent with the in-place `/Applications` install model).

## Refactor-readiness score per area

| Area | Score | Reasoning |
|---|---|---|
| `AgentCommandBuilder` | hoch | 7 deterministic tests cover new/resume/Codex/Claude/extras ordering. |
| `AgentSessionIndexer*` + cache | hoch | Bounded reads + cache-hit/miss/invalidation all covered. |
| `AgentSessionStore` | hoch | Persistence, sorting, drag-drop, worktree migration, unresumable cleanup, summary, icons — all green. The single biggest unit of agent-chats logic is well-fenced. |
| `AgentSessionAutoNamer` | hoch | Force-generate, manual-rename respect, legacy-default-name handling all asserted. |
| `AgentSessionSummarizer` | mittel | Parser + excerpt covered. The async LLM-call path is not. |
| `AgentTranscriptParser` / `StatusDecider` | hoch | 12 tests across both providers. |
| `AgentSessionRuntimeWatcher` | niedrig | Zero tests. Runtime-PID-tracking is gnarly to refactor blind. |
| `AgentChatLaunchService` | niedrig | Zero tests; orchestrates Process + terminal lifecycle. |
| `AgentTerminalView` + drag-drop | mittel | Key handling + drop payload tested at unit level; the SwiftUI binding plumbing is not. |
| `Theme` / `ClaudeThemeWriter` | mittel | Pure `resolve` covered; the actual `~/.claude/settings.json` write path is untested. |
| `OutputMode*` / `PostProcessingTemplate*` | hoch | Built-ins, migration, custom-template round-trip all tested. |
| `PostProcessingService` (LLM dispatch) | mittel | Only mock-processor paths; actual provider integrations untested. |
| `PromptPackageBuilder` / `ReplyIntentRouter` | hoch | Intent routing per mode + visual manifest covered. |
| `TranscriptionService` HTTP layer | niedrig | Only multipart builder + timeout calc covered; no fake URLProtocol-based integration. |
| `AudioRecorder` | niedrig | Zero tests, 19 KB of AVAudioEngine logic — risky to refactor. |
| `RecordingCoordinator` | niedrig | Zero tests, 36 KB orchestrator — refactor only after extracting protocols. |
| `AudioDuckingManager` | hoch | `FakeAudioVolumeController` makes this a clean refactor target. |
| `PasteService` / `KeychainManager` / `PermissionService` | niedrig | All untested; mostly small but security-sensitive. |
| `VisualContextCaptureService` | niedrig | 20 KB, zero tests. |
| `AppPreferences` / `Settings` migration | hoch | Defaults + save/load + legacy-provider migration green. |
| UI (`AgentChatsView`, `OutputDashboardView`, `SettingsView`, `OnboardingView`, `RecordingOverlayView`) | niedrig | ~250 KB combined, zero direct tests. Add snapshot tests before any visual refactor. |
| Makefile / build | mittel | Solid, but `install` missing `lsregister` and `dmg` doesn't kill running app first. Easy fixes. |
| CI | niedrig | Doesn't exist. First refactor PR should add a minimal `swift test` workflow. |
