# Recording pipeline analysis

## Components & responsibilities

| File | LOC | Role |
|---|---|---|
| `Services/RecordingCoordinator.swift` | 884 | Orchestrates entire voice → text → improved → paste flow; owns ~6 sub-services; mutates 17 distinct `AppState` slots |
| `Services/AudioRecorder.swift` | 490 | AVAudioEngine wrapper; 16 kHz mono M4A writer; auto-handles Bluetooth/device reconfiguration |
| `Services/TranscriptionService.swift` | 309 | Two HTTP clients (OpenAI / Groq) over one `MultipartTranscriptionClient`; adaptive timeout |
| `Services/PostProcessingService.swift` | 539 | Codex CLI invocation (subprocess + idle-timeout watchdog); cancel registry; visual input selection |
| `Services/PromptPackageBuilder.swift` | 330 | Renders LLM prompt from template + bundle; resolves `ReplyIntentKind` |
| `Services/VisualContextCaptureService.swift` | 530 | ScreenCaptureKit screenshots, screen clips, frame extraction |
| `Services/VisualAttachmentDeliveryBuilder.swift` | 51 | Copies attachments into per-run delivery dir for `PasteService` |
| `Services/AudioDuckingManager.swift` | 245 | CoreAudio system-volume ducking during recording |
| `Services/AudioDeviceManager.swift` | 334 | Device enumeration + default-device-change observer |
| `Windows/RecordingPanel.swift` | 357 | Non-activating NSPanel + `OverlayController` (`ObservableObject`) |
| `Views/RecordingOverlayView.swift` | 630 | 11 sub-views in one file, full + mini overlay layouts |
| `Models/TranscriptContextBundle.swift` | 211 | Aggregates selectedText, agentChat, screenshots, annotations, screenClips, visualFrames |

## RecordingCoordinator — split opportunities

`RecordingCoordinator` is doing five jobs. References below are file:line in `RecordingCoordinator.swift`.

1. **Recording lifecycle controller** (`startRecording` 55, `stopRecording` 141, `cancelRecording` 228, ESC monitor 823–845, duration timer 847–860, audio level pump). This is the natural "happy path" — small, testable.
2. **Context-bundle editor** (`clearContextBundle` 288, `removeAgentChatFromContext` 307, `removeSelectedTextFromContext` 315, `removeAttachmentFromContext` 325, `addContextScreenshot` 268, `toggleScreenClip` 276, `startScreenClip` 695, `stopScreenClipAndAttach` 713, `scheduleScreenClipLimit` 733, `startClipboardScreenshotMonitor` 743, `importClipboardScreenshotIfNeeded` 762). ~270 LOC of pure context mutation. The attachment-removal block at 325–359 even rebuilds a fake bundle just so `visualContextCaptureService.cleanup` can be reused — that's a strong signal the cleanup API is wrong, not just that the method is in the wrong file.
3. **Transcription + post-processing pipeline** (`transcribeAndDeliver` 361, `processTranscriptIfNeeded` 487, `cautiousFallbackText` 606, `chatTitle` 584, `latestTaskAgentSession` 592, `cancelPostProcessing` 222). Owns provider/key/language resolution, calls `service.transcribe`, branches per `OutputMode.chatID`, dispatches Codex, falls back. ~250 LOC.
4. **Run-report writer** (`saveRunReport` 627–685). 50-arg builder. Pure shaping, no recording state — should be a free function on `TranscriptRunReportDraft.init(from:)`.
5. **Error / alerts / network-message mapping** (`handleTranscriptionFailure` 687, `networkErrorMessage` 799, `showErrorAlert` 814, `logAudioFileAttributes` 872, `scheduleDuckingReinforcement` 862).

Concrete split:

- `RecordingLifecycleController` — owns `audioRecorder`, `recordingTimer`, `recordingStartTime`, ESC monitor, ducking, overlay show/hide. Exposes `start() / stop() / cancel()` and an audio-finished event.
- `ContextBundleEditor` (already `@MainActor`) — wraps a binding to `appState.contextBundle` + `lastContextBundle`; owns the clipboard-screenshot polling task and screen-clip lifecycle. Removes 270 LOC.
- `TranscriptionPipeline` — takes the recorded URL, returns a `TranscriptResult { rawText, finalText, intent, prompt, ... }`. No `AppState` knowledge; the lifecycle controller adapts it to UI status. Encapsulates the chat-mode branch (`OutputMode.chatID` at 516–535).
- `TranscriptRunReportBuilder` — drops 60 lines of param-passing.

After this split, `RecordingCoordinator` becomes a ~150-LOC façade that wires the three pieces together for `AppState`.

## Context bundle assembly

Assembly is reasonably centralized — `TranscriptContextBundle.from(selectedContext:sourceApp:agentChat:)` at `TranscriptContextBundle.swift:199-210` is the only constructor used at recording start (`RecordingCoordinator.swift:74-78`). Mid-recording mutations bypass it and append directly to bundle fields (`screenshots.append` at 786, `screenClips.append` at 721, `visualFrames.append` at 722, `selectedText` writes at 318).

Issues:

- `RecordingCoordinator.removeAttachmentFromContext` (325–359) constructs a synthetic `TranscriptContextBundle` purely as a vehicle to pass one attachment to `visualContextCaptureService.cleanup`. The cleanup API should take `[ContextAttachment]`, not a bundle. That alone removes ~12 LOC and a real correctness risk: the "is the screenshot still in the bundle? then don't pass it" check at line 349 is fragile.
- Agent-chat gating logic at 68–73 (only inject `appState.activeAgentChat` if WhisperM8 was frontmost) belongs on `AgentChatContextRef` or `TranscriptContextBundle.from`, not in the coordinator. Right now nothing else can re-derive it.
- `lastContextBundle` / `lastSelectedContext` are maintained in three places (94–95, 287, 298–299, 723, 787). A `ContextBundleEditor` with single setters would close that.
- `bundle.allAttachments` (`TranscriptContextBundle.swift:105`) duplicates concatenation that `visualContextCaptureService.cleanup` likely re-walks; `visualAttachments` (97) and `allAttachments` differ subtly (allAttachments includes screenClips, visualAttachments does not). Both names obscure that — rename to `imageAttachments` / `everything`.

## Output modes / post-processing

Modes are defined in `Models/OutputMode.swift`. The constants are clear (`rawID`, `cleanID`, `promptID`, `chatID`, `taskID`, `emailID`, `slackID`, `whatsappID`, `notesID` at lines 76–84). Each mode carries `templateID`, `contextPolicy` (`.off | .auto | .required`), `pasteVisualAttachments`, and computed `usesPostProcessing`. That's a good data model.

The mode-selection plumbing is less clean. `OutputMode.chatID` is special-cased in three different files:

- `RecordingCoordinator.swift:406` — disables auto-paste for chat
- `RecordingCoordinator.swift:516` — branches into `AgentChatLaunchService` instead of `postProcessingService.process`
- `RecordingCoordinator.swift:543` — `OutputMode.taskID` triggers `latestTaskAgentSession` lookup
- `PostProcessingService.swift:151,158` — `taskID` switches Codex CWD and disables `--ephemeral`

A mode-strategy protocol (`ModeRunner` with `execute(rawText:, bundle:) -> ModeResult`) would centralize this; today the OutputMode is essentially a tagged enum being matched by ID strings in 4+ call sites.

`cautiousFallbackText` (606–625) hard-codes German fallback strings per mode — these should live on `OutputMode` (or its template) so localization / non-DACH users get sensible output.

## RecordingOverlayView extraction list

`Views/RecordingOverlayView.swift` already contains 11 named structs in one file. Even ignoring `RecordingOverlayView` itself, the per-struct line ranges are:

- `FullRecordingOverlayView` — 18–87
- `VisualContextActionButtons` — 89–142
- `MiniRecordingOverlayView` — 144–185
- `OutputModeMenu` — 187–227
- `ContextControl` — 229–281
- `ContextMenuContent` — 283–453 *(170 LOC, the heaviest)*
- `MiniOutputModeChip` — 455–472
- `CancelRecordingButton` — 474–490
- `RecordingStatusIndicator` — 494–538
- `AudioLevelBars` — 542–587
- `MiniAudioLevelBars` — 589–630

Recommended extraction:

1. `Views/Overlay/ContextMenuContent.swift` — pull out 283–453 *with* its thumbnail/icon/label helpers; this is the single biggest file-shrink win.
2. `Views/Overlay/AudioLevelBars.swift` — 542–630 (full + mini variants together).
3. `Views/Overlay/VisualContextActionButtons.swift` — 89–142; it reaches into `PermissionService` and `AppPreferences.shared` and deserves its own file for review.
4. `Views/Overlay/OutputModePicker.swift` — `OutputModeMenu` + `MiniOutputModeChip` (187–227, 455–472).
5. `Views/Overlay/RecordingStatusIndicator.swift` — 494–538.

That leaves `RecordingOverlayView.swift` at ~180 LOC: just `RecordingOverlayView`, `Full*`, `Mini*`, and `CancelRecordingButton`.

Two specific smells inside `ContextMenuContent`: `thumbnailImage(for:)` (`RecordingOverlayView.swift:396-402`) loads `NSImage(contentsOf:)` synchronously on the main thread per menu render — that should be a cached thumbnail (`ContextAttachment.thumbnailURL` is already populated). `attachmentLabel` (413–431) builds the strings inline; they belong on `ContextAttachment` itself.

## Error handling matrix

| Failure mode | Where | Behavior |
|---|---|---|
| Mic permission denied | `AudioRecorder.swift:54-57` throws `RecordingError.microphonePermissionDenied` | Caught at `RecordingCoordinator.swift:135-138` → `appState.lastError`; **no alert** shown for start failures (different from stop failures at 184/692) — UX inconsistency |
| Engine `start()` fail | `AudioRecorder.swift:167-170` re-throws | Same path as above |
| Config-change format unrecoverable | `AudioRecorder.swift:290-296` sets `isRecording=false` silently | **Silent failure** — the coordinator's `appState.isRecording` stays true, the timer keeps running, level pump returns 0. No user signal until they hit stop. Race risk noted below. |
| Recording too short (<0.3s) | `RecordingCoordinator.swift:151-154` returns silently | `isProcessing` is **not** reset; subsequent stop calls hit the guard at 142 and bail. This is a real bug. |
| `audioURL == nil` after stop | 180-186 | Alert + cleanup |
| Transcription network error | 201-202 → `handleTranscriptionFailure` → alert + delete audio |
| Transcription API error | `TranscriptionService.swift:187-191` throws `apiError` → coordinator 203-204 |
| File too large | `TranscriptionService.swift:158-161` throws `fileTooLarge` |
| Post-processing template missing | `PostProcessingService.swift:104-106` throws `missingTemplate` |
| Codex not signed in | `PostProcessingService.swift:109-113` throws `codexUnavailable` |
| Codex idle timeout 30 s | `PostProcessingService.swift:197-235`; throws → coordinator branches on `fallbackToRawOnProcessingError` at `RecordingCoordinator.swift:561` |
| Codex user-cancel | `cancelPostProcessing` at 222–226 calls `CodexProcessRegistry.shared.cancel()` → SIGTERM. `appState.postProcessingStatusText = "Abgebrochen…"` but the awaiting `process(...)` throws `codexUnavailable("Codex wurde abgebrochen.")` which becomes `appState.lastError` at 564. That's confusing — user-initiated cancel shouldn't surface as an error. |
| Visual attachment delivery error | 416-420 collected into `deliveryErrors` |
| Auto-paste permission missing | 439-441 → `appState.lastError = "Accessibility permission required..."` — but the text was already copied to clipboard (423), so the user can still paste manually. Status text doesn't say that. |
| Screen-clip permission | 706-708 prompts permission |
| Clipboard screenshot max reached | 771-775 reports error and continues |

## Audio state machine

The machine is **implicit and split across two owners**. `AudioRecorder` exposes `isRecording`. `AppState` separately holds `isRecording`, `isTranscribing`, `isPostProcessing`, `isScreenClipRecording`. The coordinator holds `isProcessing` (a local re-entrancy lock). Total: **5 booleans**, no single source of truth.

Race risks:

- **The "<0.3 s" early return leaves `isProcessing = true`.** `RecordingCoordinator.swift:151-154` returns before `isProcessing = false`, so the next stop call hits the guard at 142 and silently bails. The user has to cancel.
- **Config-change "silent fail" path.** `AudioRecorder.swift:290-296` sets `isRecording = false` on the recorder but `appState.isRecording` stays `true`. The duration timer at 847-860 keeps incrementing; the overlay shows "Recording…" forever. Stop will go through, but `stopRecording()` returns the partial URL and the file may be unreadable.
- **`isRestarting` window during Bluetooth handoff.** If the user hits stop during the 300 ms HFP sleep (271), the engine is already stopped (265), the tap is removed, but `audioFile` may be mid-write. `stopRecording()` doesn't check `isRestarting`; it just nils the engine. Plausible but unverified data-loss on the last buffers.
- **Two ducking calls.** `scheduleDuckingReinforcement` (862) loops re-ducking up to 1.5 s after start. If the user stops at 0.5 s, `restore()` runs at 178, but the scheduled `duck()` at the 0.6 / 1.0 / 1.5 marks fires *after* restore (guard at 866 catches it, good). However, if the user cancels (`cancelRecording`) and immediately starts again within 1.5 s, the new recording's `isRecording=true` may be observed by the old loop and re-duck — `appState` reference is shared.
- **ESC monitor leak risk.** `setupEscKeyMonitor` (823) is called in `startRecording`; `removeEscKeyMonitor` runs in both `stopRecording` (170) and `cancelRecording` (232). If start fails after 79 (audio recorder threw), monitor was never installed — fine. But the monitor closure captures `self` weakly *and* `appState` indirectly via `self.appState?.isRecording`; if a hotkey-driven start runs while a previous overlay's ESC monitor still exists due to an exception path, two monitors compete.

Recommendation: extract a `RecordingPhase` enum (`.idle, .recording, .transcribing, .postProcessing(intent:), .cancelling`) on the lifecycle controller; AppState mirrors it as a single derived state. The 5 booleans become computed properties.

## NSPanel focus / activation quirks

`RecordingPanel.swift:121-141` is well-formed for a non-activating overlay:

- `[.borderless, .nonactivatingPanel]` style mask
- `canBecomeKey = false`, `canBecomeMain = false` (140-141)
- `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
- `isMovableByWindowBackground = true`

Implications and findings:

- Because the panel can't become key, **text input inside the menus works** (NSMenu hosts its own event loop), but a hypothetical text field would not receive keystrokes. The current overlay has none, so no issue today.
- ESC handling is implemented via a **process-global `NSEvent.addLocalMonitorForEvents`** at `RecordingCoordinator.swift:826-837`, not via the panel. This is the correct choice given `canBecomeKey = false` — but it means ESC also triggers when *other* apps are frontmost. The guard `self.appState?.isRecording == true` (829) compensates; the side effect is that ESC sent to e.g. Cursor will *also* cancel the recording. Probably intended, worth noting.
- `previousApp` capture in `OverlayController.show` at `RecordingPanel.swift:231` happens *before* `panel.orderFront(nil)` — correct ordering. But during a re-show (the `hide()` call at 234 closes the previous panel; that close briefly removes the topmost window from the windowserver), the freshly captured `previousApp` could already be wrong if another app activated during the brief gap. Unlikely in practice.
- `hide()` at 279 doesn't post any notification — if any client cached `previousApp` they'd hold stale state. None do today.
- `windowDidMove` re-clamps to the screen frame and re-fires `onMove` (`RecordingPanel.swift:160-180`). Saving position on every move is fine for a `defer`-style save, but it writes to `AppPreferences` synchronously on the main thread for every cursor delta — a debounce would be cheap insurance.
- The hosting view is recreated on every `show()` (266); SwiftUI state inside subviews is therefore reset on every recording. That's fine because the controller holds the state, but anyone adding `@State` inside `ContextMenuContent` etc. will be surprised.

## Top refactors ranked

1. **Split `RecordingCoordinator` into 3** — `RecordingLifecycleController`, `TranscriptionPipeline`, `ContextBundleEditor`. 884 LOC → 3 × ~250 LOC. Highest reward, biggest reviewability win.
2. **Fix the `<0.3 s` `isProcessing` leak** (`RecordingCoordinator.swift:151-154`). One-line bug, real user impact.
3. **Replace 5 booleans with a `RecordingPhase` enum.** Eliminates whole classes of state-machine bugs (config-change silent fail, cancel-during-restart).
4. **Extract `ContextMenuContent` (170 LOC) and `AudioLevelBars` from `RecordingOverlayView.swift`.** Mechanical, immediately makes the view file readable.
5. **Mode-strategy protocol** to replace string-ID switches on `chatID`/`taskID` scattered across `RecordingCoordinator` and `PostProcessingService`.
6. **Move `cautiousFallbackText` strings onto `OutputMode`** (DACH-only fallback hardcoded in code today, `RecordingCoordinator.swift:615-624`).
7. **Reshape `VisualContextCaptureService.cleanup` to accept `[ContextAttachment]`** so `removeAttachmentFromContext` (325-359) stops faking bundles.
8. **Differentiate user-cancelled post-processing from errors** — currently `cancelPostProcessing` surfaces `"Codex wurde abgebrochen."` as `appState.lastError`.
9. **Cache attachment thumbnails** instead of `NSImage(contentsOf:)` per menu render (`RecordingOverlayView.swift:396-402`).
10. **Debounce overlay position saves** in `RecordingPanel.windowDidMove` (160-180).
