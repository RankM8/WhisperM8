# AgentChatsView.swift — extraction plan

File: `/Users/giulianocosta/repos/whisperm8/WhisperM8/Views/AgentChatsView.swift` — 3208 LOC, single file containing one ~1466-line top-level `AgentChatsView` plus 17 private helpers (views, button styles, value types, theme, color extensions).

## Inline sub-views (extract into separate files)

| Sub-view | Lines | Suggested target file | Severity | Reason |
|---|---|---|---|---|
| `AgentResourceSummaryButton` (View) | 1482–1569 | `Views/AgentChats/Resources/AgentResourceSummaryButton.swift` | High | 88 LOC; owns its own polling task, popover, hover state. Already self-contained — no shared state with `AgentChatsView`. |
| `AgentResourcePopover` (View) | 1571–1684 | `Views/AgentChats/Resources/AgentResourcePopover.swift` | High | 114 LOC, two nested helpers (`metricColumn`, `projectSection`) and a `ForEach` of process rows. Purely a leaf renderer. |
| `AgentResourceFormat` (enum) | 1686–1703 | move next to popover or into `Services/AgentResourceMonitor.swift` | Medium | Formatting helpers tied to `AgentResourceSnapshot`. |
| `ProjectChatGroup` (View) | 1705–1959 | `Views/AgentChats/Sidebar/ProjectChatGroup.swift` | Critical | 255 LOC, 17 closure parameters, two nested drop destinations, two context menus, `groupedSessions` accessor + `relativeTime` helper. Biggest single offender. |
| `SessionListButton` (View) | 1961–2102 | `Views/AgentChats/Sidebar/SessionListButton.swift` | High | 142 LOC, owns connector-line logic, status indicator state machine, pulse animation. Pure leaf. |
| `SidebarCommandRow` (View) | 2104–2132 | `Views/AgentChats/Sidebar/SidebarCommandRow.swift` | Medium | Small + reused 3× in sidebar; lives logically with sidebar. |
| `SidebarRowButtonStyle` (ButtonStyle) | 2134–2155 | same file as `SidebarCommandRow` | Medium | Paired with `SidebarCommandRow`. |
| `ProviderTab` (View) | 2157–2190 | `Views/AgentChats/TabStrip/ProviderTab.swift` | Medium | Header-strip widget, decoupled. |
| `ChatTabButton` (View) | 2192–2273 | `Views/AgentChats/TabStrip/ChatTabButton.swift` | High | 82 LOC, has its own hover/trailing-indicator state machine. |
| `AgentChatColorName` (enum) | 2279–2294 | `Models/AgentChatColor.swift` (next to `AgentChatColor.palette`) | Low | Stateless lookup table — belongs with the palette it labels. |
| `colorSwatchImage(hex:size:)` (free fn) | 2299–2312 | `Support/ColorSwatchImage.swift` or extension on `NSImage` | Medium | Reused 3× (lines 772, 1403, 1799, 1909) — duplicated context-menu glue. |
| `ProviderIcon` (View) | 2314–2341 | `Views/AgentChats/Shared/ProviderIcon.swift` | High | Reused 6× (701, 1649, 2001, 2167, 2213, 2546). Already a shared component in spirit. |
| `ProjectAvatar` (View) | 2351–2379 | `Views/AgentChats/Sidebar/ProjectAvatar.swift` | Medium | Used only in `ProjectChatGroup` but conceptually shared (could end up in inspector). |
| `AgentChatsWindowAccessor` (NSViewRepresentable) | 2381–2413 | `Views/AgentChats/AgentChatsWindowAccessor.swift` | Medium | NSWindow-config glue, no SwiftUI state. Tiny and isolated. |
| `TitlebarIconButton` (View) | 2415–2452 | `Views/AgentChats/TabStrip/TitlebarIconButton.swift` | Low | Used 2× (lines 554, 616). Duplicates `HeaderIconButton`. |
| `BranchTag` (View) | 2454–2477 | **delete or move** | Low/Dead | Comment at 611–614 says removed from titlebar. Verify: no other call sites in file. Stale. |
| `HeaderIconButton` (View) | 2479–2508 | **delete or merge with `TitlebarIconButton`** | Low/Dead | Not invoked anywhere in this file — apparent dead code. Both buttons share 95 % of the structure. |
| `ProjectDetailPanel` (View) | 2510–2640 | `Views/AgentChats/Inspector/ProjectDetailPanel.swift` | Critical | 131 LOC, owns its own `GitProjectStatus` state, multiple `detailCard` blocks. Entire inspector lives here. |
| `DetailHeader`, `DetailRow`, `CompactActionButton` | 2642–2699 | same file as inspector or `Views/AgentChats/Inspector/InspectorAtoms.swift` | Low | Tightly coupled to `ProjectDetailPanel`. |
| `AgentSessionDetailView` (View) | 2701–2859 | `Views/AgentChats/Workspace/AgentSessionDetailView.swift` | Critical | 159 LOC; orchestrates terminal lifecycle (`prepareCommand`, `restartTerminal`, `markLaunched`, `markTerminated`, `bindExternalSessionIDWhenAvailable`). Owns its own `AgentSessionStore`. |
| `ClosedSessionSummaryView` (View) | 2866–3017 | `Views/AgentChats/Workspace/ClosedSessionSummaryView.swift` | High | 152 LOC, multiple `@ViewBuilder` sub-bodies. |
| `GitProjectStatus` (struct + `git` runner) | 3019–3067 | `Services/GitProjectStatus.swift` | Critical | Shells out to `/usr/bin/git` from a UI file. Service layer, not a view. |
| `AgentTheme` (enum) | 3074–3176 | `Support/AgentTheme.swift` | Critical | 103 LOC theme registry — shared resource, currently `private` so other views can never reuse it. |
| `Color.dynamic` extension | 3178–3189 | `Support/ColorDynamic.swift` (or merge with `AppearanceOverride.swift`) | Critical | Generic appearance helper buried as `private extension`. |
| `Color(hex:)` extension | 3191–3202 | `Support/Color+Hex.swift` | Critical | Same `private` issue. Used 6× in this file alone; likely re-implemented elsewhere. |
| `String.nilIfEmpty` | 3204–3208 | `Support/String+NilIfEmpty.swift` | Low | One-liner trivially shared. |

## State variable groupings

All belong to top-level `AgentChatsView` (lines 16–49). Grouped by concern:

| Group | State vars | Suggested store/coordinator |
|---|---|---|
| **Workspace data** | `store` (16), `workspace` (17) | `AgentWorkspaceCoordinator` (owns store + workspace, exposes mutating ops) |
| **Selection / navigation** | `selectedProjectID` (18), `selectedSessionID` (19), `expandedProjectIDs` (20), `openTabIDs` (41) | `AgentChatSelectionModel` (separates the four selection axes from data) |
| **Sidebar filter** | `searchText` (21) | local to extracted `SidebarView` |
| **Indexing** | `isIndexingSessions` (23), `indexRefreshTask` (24), `lastIndexStats` (25) | `AgentSessionIndexCoordinator` |
| **Runtime services** (lazy) | `runtimeWatcher` (33), `autoNamer` (34), `summarizer` (35), `runtimeStatusStore` (30), `terminalRegistry` (27) | `AgentRuntimeServices` (single `@StateObject` injecting all four). Kills the awkward `setupRuntimeServicesIfNeeded()` (lines 809–833). |
| **Summary UI** | `summariesInFlight` (38) | `AgentSummaryCoordinator` (with summarizer) |
| **Session action bus** | `sessionActionRequest` (26) | could move to `AgentChatSelectionModel` (or stay as Bridge) |
| **Inspector / sidebar visibility** | `isInspectorVisible` (39), `isSidebarVisible` (40) | local to a `WorkspaceChrome` view |
| **Renaming sheets** | `renameTargetID` (42), `renameDraft` (43), `renameProjectTargetID` (44), `renameProjectDraft` (45) | `RenameSheetModel` (single, can serve both project + session) |
| **Error surfacing** | `errorMessage` (22) | `ErrorBanner` view + `AppErrorChannel` |
| **Auto-icon scan dedupe** | `iconLookupAttempted` (49) | move into `AgentWorkspaceCoordinator`’s icon resolver helper |

Natural extraction shape: **3 coordinators** (`AgentWorkspaceCoordinator`, `AgentSelectionModel`, `AgentRuntimeServices`) reduce top-level state from ~24 vars to ~3 `@StateObject`s.

## Helper functions on AgentChatsView (>30 LOC or orchestration)

| Function | Line | LOC | Category | Severity | Notes |
|---|---|---|---|---|---|
| `syncActiveAgentChat` | 179 | 23 | Cross-cutting bridge (AppState) | Med | Pure mapping — move to `AgentSelectionModel`. |
| `commitRename` | 238 | 7 | Data-mutation | Low | Pair with RenameSheetModel. |
| `commitProjectRename` | 281 | 7 | Data-mutation | Low | Same. |
| `selectedSessionHeaderControls` | 712 | 86 | UI builder | **High** | 86 LOC view returning `some View`. Should be its own `SessionHeaderControls` view (with own context-menu submodule). |
| `setupRuntimeServicesIfNeeded` | 809 | 25 | Lifecycle | High | Workaround for `@StateObject` ordering. Removed by `AgentRuntimeServices` extraction. |
| `attachWatcher` | 839 | 15 | Orchestration | Med | Moves to `AgentRuntimeServices`. |
| `handleTurnFinished` (static) | 858 | 25 | Orchestration | Med | Already static for capture safety — fits cleanly in `AgentRuntimeServices`. |
| `loadWorkspaceFast` | 884 | 24 | Data-mutation | Med | Mutates 4 selection states + workspace. Owner of selection-fallback logic. Move to coordinator. |
| `refreshSessionsInBackground` | 909 | 47 | Orchestration | **High** | Nested `Task.detached`, manual cancel handling, logging, in-line side effects (`forceAutoNameUntitledSessions`, `generateMissingSummariesAfterScan`). Belongs in `AgentSessionIndexCoordinator`. |
| `dropSession` | 963 | 49 | Drag-drop coordinator | **High** | Two paths (same-project / cross-project), reorder math inline. Extract `SessionDropController`. |
| `dropProject` | 1015 | 20 | Drag-drop coordinator | Med | Same controller. |
| `forceAutoNameSession` | 1042 | 13 | Orchestration | Low | Trivial, but belongs in AutoNamer wrapper. |
| `forceAutoNameUntitledSessions` | 1061 | 23 | Orchestration | Med | Batch loop — belongs in AutoNamer. |
| `generateMissingSummariesAfterScan` | 1089 | 8 | Orchestration | Low | One-liner forwarding. |
| `requestSummary` | 1102 | 28 | Orchestration | Med | In-flight tracking + completion thread-hopping; belongs in `AgentSummaryCoordinator`. |
| `isDefaultUntitled` | 1134 | 7 | UI-decision | Low | Stringly-typed default detection — move to `AgentChatSession` extension. |
| `sessions(for:)` | 1142 | 17 | Selection-filter | Med | Duplicates filter logic with `headerTabs` (60–67). Single source of truth needed. |
| `selectProject` | 1160 | 16 | Navigation | Low | Move to `AgentSelectionModel`. |
| `toggleProject` | 1177 | 8 | Navigation | Low | Same. |
| `addProject` | 1185 | 20 | UI-decision + data | Med | NSOpenPanel + store call. Move panel-opening to `ProjectPicker` helper. |
| `createSession` | 1206 | 22 | Data-mutation | Med | Reads 4 `AppPreferences` keys + posts an action request. Belongs in coordinator. |
| `markSession` / `relaunch` / `renameSession` / `setSessionGroup` / `setSessionColor` | 1228–1272 | 5–13 each | Data-mutation | Low | All identical try/catch pattern — collapse into `AgentWorkspaceCoordinator.perform { ... }`. |
| `renameProject` / `setProjectColor` / `clearProjectIcon` / `reAutoDetectProjectIcon` | 1281–1340 | 7–11 | Data-mutation | Low | Same pattern. |
| `chooseProjectIcon` | 1302 | 16 | UI + data | Med | NSOpenPanel — extract picker helper. |
| `attemptAutoDetectProjectIcons` | 1346 | 29 | Orchestration | Med | `Task.detached` + MainActor reload — move to `ProjectIconResolverCoordinator`. |
| `moveSession` | 1376 | 8 | Data-mutation | Low | Same try/catch pattern. |
| `sessionManagementMenu` | 1386 | 32 | UI builder | Med | **Duplicates** the session sub-menu inside `selectedSessionHeaderControls` (lines 756–784) and inside `ProjectChatGroup.sessionRow` context-menu (1784–1812). |
| `beginRename`, `closeHeaderTab`, `switchSelectedProvider`, `openSelectedProjectInPHPStorm` | 1419–1479 | 4–30 | Mixed | Med | `closeHeaderTab` (29 LOC) inlines next-selection logic that belongs in `AgentSelectionModel`. `openSelectedProjectInPHPStorm` hardcodes `/Applications/PhpStorm.app` (1470). |

## Duplicated patterns

- **Session context-menu** appears **three times** with copy-paste content:
  - `selectedSessionHeaderControls` menu — 756–784
  - `sessionManagementMenu` — 1386–1417
  - `ProjectChatGroup.sessionRow` context-menu — 1783–1812
  All three contain the identical "Umbenennen / Titel automatisch generieren / Tab-Farbe / Schließen" block. Extract once as `SessionMenuItems(session:onRename:onAutoName:onSetColor:onClose:)`.
- **"Tab-Farbe" color palette menu** is the inner copy-paste — same block appears 765–780, 1395–1411, 1791–1807. Extract `TabColorMenu(session:onSetColor:)`.
- **`Color(hex:)` use sites** — 1652, 1981, 2202, 2300, 2365, 2549. Today there are *two* `Color(hex:)` paths (the `Color` extension at 3192 and `NSColor(Color(hex:))` at 2300). Centralise.
- **Try-store-load-workspace pattern** repeats in ~12 helpers (1233, 1249, 1257, 1267, 1283, 1291, 1312, 1324, 1334, 1378, 1434). Reduce with `withWorkspaceReload { try store.X }`.
- **`workspace.sessions.first(where: { $0.id == sessionID })` + `workspace.projects.first(where: { $0.id == session.projectID })`** lookup pair: lines 842–843, 865–866, 1044, 1068, 1104–1105. Extract `workspace.sessionAndProject(sessionID:) -> (AgentChatSession, AgentProject)?`.
- **`dropDestination(for: DraggableSession.self)`** wired at 579–583, 1757–1761, 1778–1782, 1892–1896 — four near-identical closures. Wrap in a `View.onSessionDrop(_:)` modifier.
- **`if isSelected ... else if isHovered ... else Color.clear`** background ladder: 1549–1553 (`AgentResourceSummaryButton.rowBackground`), 1931–1935 (`ProjectChatGroup.headerBackground`), 2097–2101 (`SessionListButton.rowBackground`), 2185–2189 (`ProviderTab.background`), 2264–2268 (`ChatTabButton.tabBackground`), 2446–2451 (`TitlebarIconButton.background`), 2503–2507 (`HeaderIconButton.background`). Extract `AgentTheme.rowBackground(isSelected:isHovered:)`.
- **Window-background dynamic color** at 2406–2411 duplicates the same darkAqua probe that lives in `Color.dynamic` (3184–3186). Unify.
- **`AgentTheme` is `private`** (3074) — every other view in `Views/` rebuilds its own palette or pulls from `ThemeManager` instead.

## Magic numbers worth theming

| Value | Where | Suggested token |
|---|---|---|
| Sidebar width `276` | line 120 | `AgentLayout.sidebarWidth` |
| Inspector width `292` | 138 | `AgentLayout.inspectorWidth` |
| Min-window `920 × 700` | 141 | `AgentLayout.minWindow` |
| Window-controls reserved width `70` | 294, 551 | `AgentLayout.windowButtonsInset` |
| Top bars `28`, `22`, `24` heights | 299, 621, 2177, 2226, 2429, 2492 | `AgentLayout.topBarHeight` / `controlHeight` |
| Rename sheet `360` | 234, 277 | `AgentLayout.sheetWidth` |
| Header row `36` | 1873 | `AgentLayout.projectRowHeight` |
| Session row `26` | 2025 | `AgentLayout.sessionRowHeight` |
| Connector X `18` | 1977 | `AgentLayout.connectorOffset` |
| Status-dot `5×5`, close-glyph `16×16`, swatch `12` | 720, 2040, 2299 | `AgentLayout.statusDotSize` / `closeGlyphSize` |
| Avatar `18` | 2353 | `AgentLayout.projectAvatarSize` |
| Branch-tag RGB `(0.78, 0.62, 1.0)` | 2466, 2469, 2470 | `AgentTheme.branchAccent` (and tag is likely dead — verify) |
| Provider-tint hexes `#32D74B`, `#FF9F0A` | 1652 | `AgentChatColor.providerDefault(.codex/.claude)` |
| Popover width `420`, max height `360` | 1528, 1615 | `AgentLayout.resourcePopover` |
| Bind-session sleep `1_500_000_000` ns | 2841 | named constant `bindLatestRetryDelay` |
| Cornerradii `3, 4, 5, 6, 7, 8, 10` scattered | many | `AgentLayout.radius.small/medium/large` |
| `RelativeDateTimeFormatter` rebuilt per call | 1955, 3013 | shared formatter |
| `prefix(20)` session cap | 1748 | `AgentLayout.maxSessionsPerProject` |
| Hardcoded `/Applications/PhpStorm.app` | 1470 | preference / `AppPreferences.editorAppPath` |
| `pulse` durations `0.9 / 0.7`, hover anim `0.12` | 2063, 2071, 2031, etc. | `AgentMotion.pulseFast/Slow`, `AgentMotion.hover` |
| Light/dark RGB tuples in `AgentTheme` | 3079–3175 | already tokenised but file-private — make module-public. |

## Inline closures >15 lines

| Range | Location | What it does |
|---|---|---|
| 117–175 | `body` | Top-level layout + 3 onChange + sheets. ~59 LOC. Decompose into `SidebarView`, `WorkspaceView`, `InspectorView`. |
| 319–363 | `ForEach(visibleProjects)` callback parameters | 45-line wall of closures wiring `ProjectChatGroup`. Hides selection logic in `onSelectSession`/`onNewChat`. Promote to `ProjectChatGroup.Actions` struct. |
| 514–533 | `AgentSessionDetailView` initializer | 20-line argument block — same fix as above (parameter object). |
| 566–587 | `ForEach(headerTabs)` inside ScrollView | 22 LOC closure with `.draggable`/`.dropDestination`/`.contextMenu` chain. |
| 749–784 | inline `Menu` content in header | 36 LOC; identical to `sessionManagementMenu`. |
| 819–829 | runtime-watcher init closure | 11 LOC of static-hop dance — fine but flagged for clarity. |
| 915–954 | `indexRefreshTask = Task { ... }` | 40-LOC nested task w/ defer + detached + error branches. |
| 968–1010 | `dropSession` body | 43 LOC inside one function. |
| 1359–1373 | `Task.detached` icon resolve | 15 LOC. |
| 1742–1764 | `ProjectChatGroup.body` | 23 LOC with nested `Color.clear` drop-target. |
| 1783–1812 | sessionRow `.contextMenu` | 30-LOC menu, third copy. |
| 1898–1928 | groupHeader `.contextMenu` | 31 LOC project menu — duplicate-pattern color/icon submenus. |
| 1985–2031 | `SessionListButton.body` | 47 LOC ZStack. Connector + label + indicator could each be a sub-view. |

## #if DEBUG / preview blocks

None present in this file. The only `#if`-shaped scaffolding is the `colorSwatchImage` `flipped` callback and `NSImage(named:).copy() as! NSImage` (2337). The `BranchTag` (2454–2477) and `HeaderIconButton` (2479–2508) are **stale code** rather than debug scaffolding — comments at 611–614 explicitly say BranchTag was removed from the titlebar but the type still exists, and `HeaderIconButton` has no callers in the file. Verify across the project and delete.

## Top 10 extraction targets, ranked by ROI

1. **Move `AgentTheme`, `Color.dynamic`, `Color(hex:)`, `String.nilIfEmpty` into `WhisperM8/Support/`.** ~150 LOC, near-zero risk, unlocks reuse across every other view file. Currently `private`, blocking everyone else.
2. **Split out `ProjectChatGroup` → `Views/AgentChats/Sidebar/ProjectChatGroup.swift`** (1705–1959, 255 LOC). Biggest readability win. Drag-drop logic moves with it.
3. **Extract `AgentSessionDetailView` + `ClosedSessionSummaryView` → `Views/AgentChats/Workspace/`** (2701–3017, 317 LOC). Two views, both with their own state; isolating them simplifies orchestration debugging.
4. **Extract `ProjectDetailPanel` + atoms → `Views/AgentChats/Inspector/`** (2510–2699, 190 LOC). Inspector becomes hot-swappable.
5. **Extract `GitProjectStatus` → `Services/GitProjectStatus.swift`** (3019–3067). Shelling out from a view file is a code-smell that bypasses any test harness.
6. **Introduce `SessionMenuItems` and `TabColorMenu` view-builders** to collapse the three duplicate session context-menus (756–784, 1386–1417, 1783–1812) and the three palette-loops.
7. **Extract `AgentRuntimeServices` (@StateObject)** bundling `terminalRegistry`, `runtimeStatusStore`, `runtimeWatcher`, `autoNamer`, `summarizer` plus `setupRuntimeServicesIfNeeded`, `attachWatcher`, `handleTurnFinished`, `requestSummary`, `forceAutoNameSession`, `forceAutoNameUntitledSessions`, `generateMissingSummariesAfterScan`. Kills the lazy-init dance and lets the view body drop ~8 `@State` properties.
8. **Extract `AgentResourceSummaryButton` + `AgentResourcePopover` + `AgentResourceFormat`** into a `Views/AgentChats/Resources/` folder (1482–1703). They have zero coupling to the rest.
9. **Extract `ProviderIcon`, `ProjectAvatar`, `SidebarCommandRow`, `SidebarRowButtonStyle`, `TitlebarIconButton`, `ChatTabButton`, `ProviderTab`** into a shared `Views/AgentChats/Components/` folder (~400 LOC, low-risk).
10. **Introduce `AgentSelectionModel` / `AgentWorkspaceCoordinator`** to absorb the 11 try/catch data-mutation helpers (`renameSession`, `setSessionColor`, `markSession`, `dropSession`, …) and the 4 selection fields. After steps 1–8 the remaining `AgentChatsView` body should fit in ~250 LOC.

After steps 1–4 alone the file shrinks from 3208 → ~2200 LOC; after 1–10 → roughly 300–400 LOC of orchestration + body.
