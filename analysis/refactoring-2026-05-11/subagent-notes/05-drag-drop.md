# Drag-and-drop — UX & implementation analysis

Scope: `AgentDragDropTypes.swift`, `Info.plist`, `AgentChatsView.swift` (drop coordinators + modifiers), `AgentSessionStore.swift` (reorder/move APIs), `Makefile` (`lsregister`).

## What works today

- **Custom UTIs registered correctly enough to function.** `com.whisperm8.app.agent-chat-session` / `.agent-project` are declared as `UTExportedTypeDeclarations` in `Info.plist:34-60` and matched in `AgentDragDropTypes.swift:37-39` with `UTType(exportedAs:conformingTo: .data)`. The `Makefile:65-68` runs `lsregister -f` after an in-place `rsync`, which is the trick that makes `.draggable(...)` actually fire after an upgrade.
- **Reorder + cross-project move both wired end-to-end.** `dropSession` (`AgentChatsView.swift:963-1011`) distinguishes same-project reorder from cross-project move and delegates to `store.reorderSessions` vs `store.moveSessionToProject` (`AgentSessionStore.swift:226-270`). Project reorder via `dropProject` (`AgentChatsView.swift:1015-1034`) calls `reorderProjects` (`AgentSessionStore.swift:213-221`). All three store APIs assign a clean 0…n-1 `sortIndex` sweep.
- **Tab strip participates as drag source and drop target.** `projectChatStrip` attaches `.draggable` + `.dropDestination(for: DraggableSession.self)` to each `ChatTabButton` (`AgentChatsView.swift:578-583`), so the tab order can be edited inline.
- **Sidebar “end of list” gap is hittable.** `ProjectChatGroup` adds an 8pt transparent trailer with `.contentShape(Rectangle())` + `.dropDestination` (`AgentChatsView.swift:1751-1761`) so dropping under the last row appends to the project.
- **Store APIs have unit coverage** (`Tests/WhisperM8Tests/AgentChatsTests.swift:1620-1683`): `reorderProjects`, `reorderSessions`, `moveSessionToProject`.

## UX gaps vs macOS HIG

- **No insertion line.** Finder/Mail draw a 2pt blue rule between rows during a drag. SwiftUI’s `.dropDestination` only gives an `isTargeted` Bool on the whole row. The only feedback today is the *group header* getting a faint `AgentTheme.selection.opacity(0.5)` overlay (`AgentChatsView.swift:1874-1878`). **Severity: high** — the user cannot tell where a row will land between two adjacent siblings.
- **Session-row drop target has no targeted feedback at all.** `sessionRow(_:)` calls `.dropDestination` (`AgentChatsView.swift:1778-1782`) without an `isTargeted:` closure. Dragging over an existing row in the same project shows no highlight. **Severity: high.**
- **Tab strip drop target has no targeted feedback.** `ChatTabButton` `.dropDestination` at `:579-583` likewise omits `isTargeted:`. **Severity: medium.**
- **Trailing-spacer drop has no feedback either** (`:1757-1761`), so the user cannot find the “append at end” gap. **Severity: medium.**
- **Cancellation = silent.** No `.onDrag/onEnded` instrumentation; SwiftUI handles cursor reset, but there is no spring-back animation or audible cue. Consistent with HIG, acceptable. **Severity: low.**
- **Project header overlay applies to header, but rows below don’t shift** to suggest insertion, so dropping a session on a header that already has visible rows is ambiguous (does it land at top or bottom?). The code chooses *end of list*, which is not signaled. **Severity: medium.**

## Hit-target / drop-zone gaps

| Zone | Drop target? | Behavior |
|---|---|---|
| Session row (`SessionListButton`) | yes (`sessionRow` `.dropDestination`) | inserts *before* this row |
| 8pt trailer below last row in expanded group | yes | appends |
| Spacing *between* two `sessionRow`s | **no** | LazyVStack uses `spacing: 0` here (`:1747`), so no literal gap exists — every Y pixel belongs to a row. Inserts before the row your cursor is over. |
| Project header (`groupHeader`) | yes, two zones stacked (DraggableProject + DraggableSession) | session→header always appends; project→header inserts *before* this project |
| Collapsed project (rows hidden) | session drop on header still appends to that project | works, but invisible |
| Sidebar empty area below all projects | **no** | a drop here is treated as cancel |
| Tab-strip `ChatTabButton` | yes (same-project only? — see below) | inserts before this tab |
| Tab-strip trailing area (after last tab, before "+") | **no** | nothing reacts |
| Anywhere on the chat content (terminal pane) | **no** | bare drop = cancel |

So the only real gap problem is **(a)** no drop zone in the sidebar empty-trailing-area for “last project” (you must drop *on* the last project header to reorder before it, can’t drop *after* it), and **(b)** no trailing zone in the tab strip.

## Concurrency / stale-snapshot risks

- `dropSession` (same-project branch) reads `workspace.sessions` from the view’s `@State`, computes `orderedIDs`, calls `store.reorderSessions`, then re-loads `workspace = store.loadWorkspace()` (`AgentChatsView.swift:970-987`). If `Sessions-Scan` adds/removes a session in the same tick (`SessionsScan` background indexer + auto-namer both mutate the store), the array passed to `reorderSessions` is stale. **The store guards against this**: `reorderSessions` only touches IDs that exist *and* still belong to `projectID` (`AgentSessionStore.swift:228-232`). Concretely:
  - Session removed concurrently → silently skipped, sortIndex sweep still consistent.
  - Session added concurrently → not in the dropped list, so it keeps its prior `sortIndex`. After our sweep writes 0…n-1 for the dragged subset, the new session can end up overlapping numerically. Sorting is then `sortIndex` then `lastActivityAt`, so visually the new one slides to its natural slot — but the *intended* drop position might shift.
- `dropProject` (`:1015-1034`) computes from `manualProjects` (filtered for visible). Same hazard as above; same mitigation in `reorderProjects`.
- `moveSessionToProject` (`AgentSessionStore.swift:242-270`) reloads `loadWorkspace()` internally, so it does not consume the stale view-side snapshot at all. **No risk** in cross-project moves.
- All three store writers do a full `loadWorkspace` → mutate → `saveWorkspace`. There is no file-level lock, so if two stores wrote concurrently (e.g. SessionsScan during a drop) the last writer wins. SessionsScan runs on background tasks; on `@MainActor` (the view), `dropSession` is synchronous, but the `saveWorkspace` call happens in the same tick before SessionsScan can interleave. **Low risk in practice**, but worth a stress test.

## Tab-strip vs sidebar contract

- The tab strip’s drop target (`AgentChatsView.swift:579-583`) calls `dropSession(dropped, in: session.projectID, beforeSessionID: session.id)`. The `session.projectID` is the **tab’s** project, not the dragged session’s. So **cross-project drops from tab-strip into another project’s tab work** — but the destination tab must already be open. There is no UI affordance to drag a tab into a project that has zero open tabs.
- `headerTabs` is the list of currently open sessions across all projects mixed together (it’s the strip, not a per-project ribbon). That means dragging session A from project P1 onto tab B (project P2) **silently moves A from P1 to P2** and reorders within P2. The user has no visual indication this is a cross-project operation. **Risk: medium UX surprise.**
- Sidebar mirrors store state immediately via `workspace = store.loadWorkspace()`, so the tab-strip reorder propagates to the sidebar on the next render cycle (same tick).
- `sortIndex` is shared between the two views: the strip uses `AgentSessionStore.sortedSessions(...)` indirectly through `headerTabs` which derives from `workspace.sessions`. A reorder in the strip changes the sidebar order. This *might* be intentional, but it’s undocumented and not obvious. **Risk: design inconsistency** — most editors keep tab order separate from sidebar order.

## Test coverage gaps

Existing (`AgentChatsTests.swift:1620-1683`):

- `testReorderProjectsAssignsSequentialSortIndices`
- `testReorderSessionsAffectsOnlyTargetProject`
- `testMoveSessionToProjectInsertsAtTargetIndex`
- Plus `testSortedProjectsPrefersExplicitSortIndex` (related)

Missing (would catch real regressions):

1. **`dropSession` coordinator logic itself.** `dropSession` does the same-project / cross-project branching *outside* the store. The store APIs are tested in isolation but the branch decision in the view is not. Refactor opportunity: extract `dropSession` into a pure function on a coordinator/VM so it can be unit-tested.
2. **`reorderSessions` with a stale ID list** (an ID that no longer belongs to the project, or a missing ID). Current behavior is silent skip — good — but no test pins it.
3. **`moveSessionToProject` with `targetIndex` out of bounds.** The code clamps (`AgentSessionStore.swift:261`); no test.
4. **`moveSessionToProject` when source == target project.** Should still produce a valid reorder; not tested.
5. **`moveSessionToProject` when `newProjectID` doesn’t exist** — the early `return` (`:249-251`) silently no-ops; not tested.
6. **`reorderProjects` with a partial ID list** (e.g. only the manually-visible subset, while archived projects exist in the store). Current implementation only touches matched IDs; behavior on unmentioned projects is implicit. No test.
7. **`reorderSessions` does not bump `updatedAt` on the project** — only `lastActivityAt` on the session. May or may not be intentional; not pinned.
8. **`DraggableSession` / `DraggableProject` round-trip through `CodableRepresentation`** (smoke test that the `Transferable` is serializable). Cheap, would catch a `Codable` regression.

## UTI correctness

- `Info.plist:34-60` declares both UTIs with `UTTypeIdentifier`, `UTTypeDescription`, `UTTypeConformsTo: [public.data]`, `UTTypeTagSpecification: <dict/>`.
- **Empty `UTTypeTagSpecification` is fine** for purely in-process UTIs — that key maps a UTI to filename extensions / MIME types, and we have neither. The empty dict is the conventional “no mapping” value and won’t produce LaunchServices warnings.
- **`conformingTo: .data` is correct** for an opaque in-memory blob. The alternative (`.content` or `.item`) would broaden conformance and could light up our drop targets for Finder file drags. With `.data`, a Finder URL drag (`public.file-url`, which does conform to `.data`) **could in principle satisfy the conformance check**, but SwiftUI’s `.dropDestination(for: DraggableSession.self)` matches by the *Transferable’s* `contentType`, not by conformance ancestry — so a `public.file-url` drop will not coerce into a `DraggableSession`. **Verified safe.** That said, conforming a private in-app payload to `public.data` is broader than needed; conforming to `.item` or no public type at all would be tighter, at the cost of (possibly) needing a non-empty MIME/extension to satisfy LaunchServices. Not a bug, mild over-conformance.
- **Missing**: no `UTImportedTypeDeclarations` entry, which is correct (we own the UTI, we export it). 
- **One latent risk**: both UTIs share the prefix `com.whisperm8.app.agent-*`. If a future app version renames the bundle ID, the old UTIs persist in LaunchServices’ cache. The `lsregister -f` in `Makefile:68` resolves it on `make dev`, but a user updating via DMG without that step could see stale registrations. **Severity: low**, but document this.

## Polish improvements (ranked by ROI)

1. **Add `isTargeted:` to every drop destination** (session row, tab button, trailing spacer). Even a simple background tint is huge for discoverability. Cheap.
2. **Insertion line indicator.** Track which `sessionID` is being targeted in a `@State var dropTargetID: UUID?` at the `ProjectChatGroup` level. Render a 2pt `AgentTheme.accent` `Rectangle` between rows where `session.id == dropTargetID`. The current `LazyVStack(spacing: 0)` would need spacing for the line or an overlay-based approach.
3. **Tab-strip trailing drop zone.** Mirror the sidebar’s 8pt trailer at the end of `ForEach(headerTabs)` so users can drop a tab “at the end” of the strip.
4. **Show project-tint badge on cross-project move.** When `dropped.sourceProjectID != target.projectID`, hint the move in the targeted state (e.g. a small arrow icon on the header overlay). Otherwise the move is silent.
5. **“Insert at smart position” option for header drops.** Currently always appends. Could use recently-accessed position (`lastActivityAt` median) or insert at top of expanded group. Open UX question — document, don’t silently change.
6. **Auto-expand collapsed project on hover-drag.** If a user hovers a `DraggableSession` over a collapsed group header for ~600ms, expand it so they can drop precisely. Hover-to-expand is standard Finder behavior.
7. **Auto-scroll near sidebar edges during drag.** Long project lists are unscrollable while dragging.
8. **Tighten UTI conformance** to `.item` (not `.data`) and verify drag/drop still works after `lsregister -f`. Defensive; not load-bearing.
9. **Extract `dropSession` / `dropProject` into a `DragDropCoordinator` value type** for unit testing the branch logic without instantiating the SwiftUI view.
10. **Add a stress test** that interleaves SessionsScan + `dropSession` to confirm the silent-skip behavior in `reorderSessions` holds under contention.
