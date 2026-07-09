# Session services — refactoring analysis

Scope: the five service files under `WhisperM8/Services/AgentSession*.swift`
(AutoNamer, Summarizer, RuntimeWatcher, Transcript, Indexer). All five
coordinate around the on-disk JSONL transcripts of Claude / Codex CLI
subprocesses. The Transcript file already does most of the pure work
(`AgentTranscriptParser`, `AgentTranscriptStatusDecider`, `AgentTranscriptLocator`,
`AgentTranscriptExcerpt`) but a few duplicated chunks and architectural
smells remain.

## Duplication map

| Concept | File A | File B | Suggested shared service |
|---|---|---|---|
| Read transcript file → text → excerpt | `AgentSessionAutoNamer.swift:44-47` (`build(from:provider:)`) | `AgentSessionAutoNamer.swift:114-117` (`buildExtended(from:provider:)`) | Single `AgentTranscriptReader.readText(from:)` that returns the raw `String`; the excerpt builders just take text. |
| JSONL line → text body extraction (User / Assistant content) | `AgentSessionAutoNamer.swift:138-173` (`extractMessageText` + Claude/Codex variants) | none yet, but it duplicates the structural work `AgentTranscriptParser.parseClaudeLine` / `parseCodexLine` already does at `AgentSessionTranscript.swift:51-123` | Extend `AgentTranscriptParser` to return a richer `ParsedEntry { event, body: String? }` so excerpt builders never touch JSON again. |
| Locate transcript URL by `(provider, externalSessionID, cwd)` | called from `AgentSessionAutoNamer.swift:421-425` | called from `AgentSessionSummarizer.swift:77-82` and `AgentSessionRuntimeWatcher.swift:189-198` | Already shared via `AgentTranscriptLocator` — good. Keep as is. |
| Headless CLI argv assembly (`claude -p …` / `codex exec …`) | `AgentSessionAutoNamer.swift:216-222` (inside `generate`) | `AgentSessionSummarizer.swift:216-222` (inside the `runHeadless` extension) | Pull a single `AgentHeadlessInvocation.arguments(for: provider, prompt: …)` helper; right now the two call-sites are byte-identical. |
| In-flight set + Task lifecycle + `defer { remove }` | `AgentSessionAutoNamer.swift:320, 409-419` | `AgentSessionSummarizer.swift:31, 64-75` | A small generic `ThrottledOnceTask<Key: Hashable>` actor or `@MainActor` helper (`runUnique(key:) async throws`) — see below. |
| `inFlight: Set<UUID>` declaration | `AgentSessionAutoNamer.swift:320` | `AgentSessionSummarizer.swift:31` | same helper as above |
| JSONL first-line / N-line bounded reading | `AgentSessionIndexer.swift:114-147` (`BoundedJSONLReader`) | `AgentSessionRuntimeWatcher.swift:212-225` (`readTail`) | Pull a single `JSONLReader` namespace that exposes `firstLine`, `firstNLines`, `tail(bytes:)`. The Indexer's `BoundedJSONLReader` is currently `private` so the Watcher reinvents it. |
| ISO8601 date parser with fractional-seconds fallback | `AgentSessionTranscript.swift:127-141` (`parseDate`) | `AgentSessionIndexer.swift:276-281` & `:468-473` (`parseDate` in both indexers, duplicated) | `AgentDateParser.iso8601(_:)` static helper. |
| Per-provider file metadata struct + lookup | `AgentSessionIndexer.swift:263-274` and `:431-442` (`metadata(for:)` duplicated in `CodexSessionIndexer` and `ClaudeSessionIndexer`) | — | Hoist to free function `AgentSessionFileMetadata.read(for:)`. |

Net: ~150 LOC of true duplication and another ~80 LOC of "structural"
duplication where two services do the same JSONL-walking work with slightly
different filters.

## CLI invocation plumbing

Findings:

- The Process runner lives only on `AgentTitleGenerator`
  (`AgentSessionAutoNamer.swift:273-310`). That is the *only* `Process()` call
  in the session-services group, which is good.
- The `Summarizer` deliberately reuses it via an extension (`AgentSessionSummarizer.swift:208-226`,
  `runHeadless(provider:prompt:)`) — clever, but the type is misleadingly
  named: `AgentTitleGenerator` is no longer about titles, it's a generic
  "headless CLI invoker". Rename to `AgentHeadlessCLI` (or split
  `AgentHeadlessCLI` + `AgentTitleGenerator` wraps it for the cleanup pass).
- The argv assembly is byte-duplicated:
  `AgentSessionAutoNamer.swift:216-222` vs `AgentSessionSummarizer.swift:216-222`.
  Both lines read `case .claude: args = ["-p", prompt, "--output-format", "text"]`
  and `case .codex: args = ["exec", "--skip-git-repo-check", prompt]`. Easy
  to centralise.
- `LoginShellEnvironment.shared.processEnvironment()` is called from both
  sites (lines :223 each) — keep the call inside the new shared helper.
- No timeout: `defaultRunner` (`:273-310`) uses
  `withCheckedThrowingContinuation` + `process.terminationHandler` with **no
  timeout, no cancellation**. A hung `claude -p` will pin the in-flight set
  forever — the `defer` only fires when the continuation resumes.

## Status state-machine

`AgentTranscriptStatusDecider.decide(...)` (`AgentSessionTranscript.swift:148-213`):

- **Purity:** clean — no FS, no Process, only injected `now` and inputs.
- **Test coverage:** good, ~5 cases at `Tests/WhisperM8Tests/AgentChatsTests.swift:1037-1108`.
- **Heuristic concerns:**
  - `awaitingInputAfterSeconds = 8` (`:159`) is a magic number. Anything in
    `.assistantMessageOngoing` for >8 s gets flipped to `.awaitingInput`. In
    reality the CLI may stream a long answer and stop briefly between tokens
    — there is no signal in the JSONL that distinguishes "permission prompt"
    from "model thinking". This is a structural limitation of polling vs.
    a true PTY/IPC channel.
  - `.sessionMeta`/`.other` falls through `idleAfterSeconds = 30` (`:162`,
    `:208`). Reasonable, but combined with the awaiting-input branch it means
    a session that's actually crashed but whose mtime is recent gets
    classified `.working` indefinitely.
  - The `turnFinished` re-detection guard at `:188-195` compares against
    `priorTurnFinishedAt`. If the event has no timestamp it falls back to
    `mtime > prior`, which is wrong when the file is touched after the turn
    (e.g. by `Spotlight indexer`) — would refire `onTurnFinished`. Real-world
    risk low, but worth a test.
  - No `.errored` ever emitted from the decider — that path is only set in
    `AgentSessionRuntimeWatcher.markTerminated` (`:121-128`), which depends
    on the subprocess wrapper telling us about exit code. If the subprocess
    crashes silently (e.g. user kills the parent terminal), the watcher stays
    on `.working`/`.idle` forever.

Improvement ideas:
1. Make `awaitingInputAfterSeconds` / `idleAfterSeconds` injectable via the
   `Decision` call (or a `Config` struct) so tests can exercise both branches
   cheaply.
2. Add a `.staleSinceTooLong` → `.errored` rule for files that haven't been
   touched in N minutes while the session is still marked `.running` in the
   store.
3. Detect Claude permission-prompt lines explicitly: Claude emits a
   `type:"system"` JSONL row with `subtype:"permission_request"` (or
   similar). Treat that as a hard `.awaitingInput` signal instead of the
   8-second timeout heuristic.

## Polling vs FSEvents

`AgentSessionRuntimeWatcher` polls every 1.5 s (`:47, :132-141`) over all
watched sessions. Severity: **low–medium**.

Tradeoffs:

- Polling cost is small: each tick reads 64 KiB from the tail of every
  watched file (`:46, :164`). For 5 active sessions that's ~320 KiB/1.5 s =
  ~210 KiB/s. Not a concern on modern SSD, but it does keep the disk warm
  and prevents the laptop from idling cores.
- **FSEventStream**: would replace the 1.5 s tick with coalesced
  notifications on a single watch root (`~/.claude/projects/` and
  `~/.codex/sessions/`). Pros: lower idle wake-up rate, immediate latency
  on the actual `flush()`. Cons: FSEvents has ~1 s default coalescing
  latency anyway (configurable but not zero), is per-directory not per-file,
  and reports paths not contents — we'd still have to tail the file once
  per event. Net win is modest.
- **DispatchSource.makeFileSystemObjectSource(.write)**: per-file kqueue
  watch. Better fit. One FD per watched session, fires on write/extend.
  Still needs a tail-read on each fire. Drops events if the file is
  truncated/rotated, which Claude doesn't do mid-session so fine.
- **Status freshness during user typing**: the current polling does *not*
  notice the user's outgoing prompt at all — only Claude's writes to the
  JSONL change file mtime. So the 1.5 s "lag" only affects detecting the
  end of a model turn, where the user already knows the turn is done from
  the terminal output. UX impact: small.

Recommendation: keep polling. It's simpler, the file format is appended
not rewritten so a tail-read of 64 KiB is cheap, and the current 1.5 s
cadence is well below the perceptual threshold for "the spinner kept
spinning after Claude was done." If switching, prefer
`DispatchSource.makeFileSystemObjectSource` over FSEvents — single-FD,
no userspace coalescing, less code.

## Error handling matrix

| Path | Service:line | Current behavior |
|---|---|---|
| Executable missing (`claude`/`codex` not on PATH) | `AgentSessionAutoNamer.swift:211-213` | Throws `AgentTitleGeneratorError.executableNotFound` → swallowed by AutoNamer / Summarizer Task, logged via `Logger.agentPerformance.warning`, completion handler gets `.failure`. |
| Process spawn fails (`process.run()` throws) | `AgentSessionAutoNamer.swift:304-308` | Continuation resumes with the underlying error. Same swallow path. |
| Process non-zero exit | `AgentSessionAutoNamer.swift:293-300` | Logs first 200 chars of stderr at `.warning`, throws `nonZeroExit(code)`. **No retry, no stderr surfacing to UI.** |
| Empty stdout from CLI | `AgentSessionAutoNamer.swift:226-228` | Throws `emptyOutput`. Summarizer additionally checks parse result and re-throws `emptyTranscript` (`AgentSessionSummarizer.swift:95-97`). |
| Process hangs forever | `AgentSessionAutoNamer.swift:273-310` | **No timeout.** Continuation never resumes → `inFlight` set holds the UUID forever → second trigger is a no-op. Need `withTimeout` wrapper. |
| Network failure inside `claude -p` (CLI's own outbound HTTPS dies) | same as non-zero exit path | The CLI returns non-zero and writes the error to stderr. We log 200 chars and surface a generic "exit code N" string. UI never sees the actual provider error message. |
| Transcript file not yet on disk | `AgentSessionAutoNamer.swift:421-427`, `Summarizer:77-83`, `Watcher:154-171` | AutoNamer: returns `emptyOutput` failure. Summarizer: returns `transcriptNotFound`. Watcher: keeps status `.working` if previously unset, otherwise leaves prior status. |
| Empty transcript (file exists but no User/Assistant entries) | `AgentSessionAutoNamer.swift:429-433`, `Summarizer:86-90` | Throws `emptyOutput` / `emptyTranscript`. AutoNamer additionally records the session in `alreadyAttempted` (`:344, :409`) so it won't retry in this app session. |
| File read I/O error (`String(contentsOf:)`) | `AgentSessionAutoNamer.swift:45-46`, `:115-116` | Propagates the Foundation error up. Caught at `:440-445` in AutoNamer / `:112-117` in Summarizer, logged at `.warning`. |
| File tail read failure | `AgentSessionRuntimeWatcher.swift:212-225` (`readTail`) | Returns `nil`, caller falls back to "no event detected", status defaults to `.working` if unset. Silent. |
| JSONL parse error mid-line | `AgentSessionTranscript.swift:22-33` | Returns `nil` for that line. Caller skips it. Robust. |
| `applyAutoGeneratedTitle` / `setSessionSummary` store throws (e.g. session vanished) | `AgentSessionAutoNamer.swift:435`, `Summarizer:107` | Caught by the outer `do/catch`, logged `.warning`. UI completion gets `.failure`. |
| Subprocess terminates before the Watcher polls | `AgentSessionRuntimeWatcher.swift:121-128` (`markTerminated`) | Direct status write, no poll involved. Correct. |
| Stderr is read AFTER `terminationHandler` fires | `AgentSessionAutoNamer.swift:289-302` | The handler reads stdout AND stderr via `readDataToEndOfFile`. Potential dead-lock if stdout fills the pipe buffer (~64 KiB) before exit — but for a 3–6-word title or a few-sentence summary, well within bounds. Safe in practice. |

## Threading & concurrency

- **AgentSessionAutoNamer** (`:316-448`): `@MainActor final class`. `inFlight`
  and `alreadyAttempted` are MainActor-isolated → safe. Spawns a detached
  `Task { [weak self] in … }` (`:414`) and re-enters MainActor in `defer`
  (`:416-419`) to clean up. The Task captures `let store = store; let
  generator = titleGenerator` to avoid implicit self-capture across actor
  hop — clean.
- **AgentSessionSummarizer** (`:27-204`): same pattern, `@MainActor final
  class`, identical `Task { } / defer { Task { @MainActor } }` shape
  (`:70-75`). The two could share a helper trivially.
- **AgentSessionRuntimeWatcher** (`:42-226`): `@MainActor final class`. The
  `Timer.scheduledTimer` callback hops to MainActor explicitly (`:135-137`).
  `pollTimer?.invalidate()` is also called from `deinit` (`:63-65`) —
  technically the timer is MainActor-bound, and `deinit` may run off the
  MainActor; `Timer.invalidate()` is thread-safe in practice but the
  annotation is fishy. Worth verifying with a strict-concurrency build.
- **AgentTranscriptParser / Decider / Locator / Excerpt** (all in
  `AgentSessionTranscript.swift`): pure `enum` namespaces, no isolation
  attributes, freely callable from any context. Good.
- **AgentSessionIndexer**: `CodexSessionIndexer` / `ClaudeSessionIndexer` are
  plain structs, called by `AgentSessionStore` off-MainActor during scan.
  No actor isolation needed.
- **Silent error-drop Tasks**: the `defer { Task { @MainActor [weak self] in
  … } }` blocks at `AgentSessionAutoNamer.swift:416-419` and
  `AgentSessionSummarizer.swift:72-75` are fine (no `throws`), but the outer
  `Task { [weak self] in … }` swallows any error not caught by the inner
  `do/catch`. Both files do catch, so OK. **No** orphan `Task { try …}`.
- The `AgentTitleGenerator.runner` closure type is
  `(URL, [String], [String: String]) async throws -> String` (`:198`) — not
  `@Sendable`. Fine in non-strict mode; will require `@Sendable` once
  `-strict-concurrency=complete` is enabled.

## UI coupling check

| Service | Status |
|---|---|
| `AgentSessionAutoNamer` | **Clean.** Depends on `AgentSessionStore`, `AgentTitleGenerator`, `AgentTranscriptExcerpt`, `AgentTranscriptLocator`, `LoginShellEnvironment`, `AgentCommandBuilder`, `Logger`. Zero UI imports. |
| `AgentSessionSummarizer` | **Clean.** Same dependency set plus model types `AgentSessionSummary`, `AgentChatSession`, `AgentWorkspace`. No SwiftUI imports. |
| `AgentSessionRuntimeWatcher` | **Clean.** `import Combine, Foundation`. `AgentSessionRuntimeStatusStore` is `ObservableObject` — that's a Combine type, not SwiftUI. The sidebar binds it via `@ObservedObject`, but that coupling is in the View, not here. |
| `AgentSessionTranscript` | **Clean.** Pure `Foundation`. |
| `AgentSessionIndexer` | **Clean.** Pure `Foundation`. |

Single dirty smell: `AgentSessionRuntimeWatcher.swift:50-51` mentions
`AgentChatsView` in a docstring as the consumer of `onTurnFinished`. Just a
comment, not a real dependency, but it does hint the contract is shaped
around one specific caller. Verified at `Views/AgentChatsView.swift:811-861`
that view owns the watcher's lifecycle.

## Top refactors ranked by ROI

1. **`AgentHeadlessCLI` extraction (high ROI).** Pull the argv builder
   (`AgentSessionAutoNamer.swift:216-222` ≡ `AgentSessionSummarizer.swift:216-222`)
   and the `defaultRunner` into a dedicated `AgentHeadlessCLI` type with a
   single `run(provider: AgentProvider, prompt: String, timeout: Duration)
   async throws -> String` method. Rename `AgentTitleGenerator` to a thin
   wrapper that adds title cleanup. Eliminates ~40 LOC and gives us one
   place to add timeout / retry / structured-stderr surfacing.

2. **`ThrottledOnceTask<Key>` helper (medium-high ROI).** The
   `inFlight: Set<UUID>` + `Task { defer { remove } }` shape appears in two
   places (`AutoNamer:320, 409-419` and `Summarizer:31, 64-75`) and will
   appear in a third for the upcoming "regenerate summary" UI affordance.
   ~30 LOC saved + correctness (centralised cancellation handling).

3. **Timeout for headless CLI calls (high ROI, correctness).** Add a
   wallclock timeout to `defaultRunner` (`:273-310`). A hung `claude` /
   `codex` currently leaks UUIDs into `inFlight` forever. Combine with
   refactor #1.

4. **Unified `JSONLReader` namespace (medium ROI).** The Indexer's
   `BoundedJSONLReader` (`:114-147`) and the Watcher's `readTail`
   (`:212-225`) are the same concept. Pull into one place; expose `firstLine`,
   `firstNLines(maxLines:maxBytes:)`, `tail(bytes:)`. Reuse from the
   Summarizer's future "show last N transcript lines" view.

5. **Richer `AgentTranscriptParser` returning `(event, body)` (medium ROI).**
   The body-extraction logic in `AgentTranscriptExcerpt.extractMessageText`
   (`AgentSessionAutoNamer.swift:138-173`) duplicates the JSON-walking already
   done in `AgentTranscriptParser.parseClaudeLine` / `parseCodexLine`. One
   pass instead of two; one place to add support for new content blocks
   (images, tool_result text, etc.).

6. **State-machine config struct + `.errored` rule (low-medium ROI).** Inject
   thresholds, add a "stale beyond N minutes → `.errored`" rule. Makes the
   decider fully testable across all branches and surfaces dead processes
   the subprocess wrapper missed.

7. **DispatchSource per-file file-system watch (low ROI, optional).** Only
   worth doing if profiling shows polling cost. Today's 1.5 s tick over
   a handful of files is negligible.

8. **Rename `AgentTitleGenerator` (cosmetic, near-zero risk).** After
   refactor #1, the name is wrong. Rename to `AgentHeadlessCLI` and keep
   `cleanTitle` / `titlePrompt` as free functions or on a new
   `AgentTitleGenerator` struct that wraps the CLI.
