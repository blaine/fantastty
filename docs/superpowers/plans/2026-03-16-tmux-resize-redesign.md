# Tmux Resize Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bidirectional tmux resize feedback loop with unidirectional per-surface sizing.

**Architecture:** Each Ghostty surface tells tmux its own grid size via `resize-pane`. A simple `refresh-client -C` sets window bounds from the container. `%layout-change` is only processed for structural changes (pane add/remove). All centralized size computation, suppression flags, and debounce machinery in TmuxSessionBridge is deleted.

**Tech Stack:** Swift, SwiftUI, Combine, tmux control mode protocol

**Spec:** `docs/superpowers/specs/2026-03-16-tmux-resize-redesign.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Fantastty/Models/TmuxControlMode/TmuxControlClient.swift` | Modify | Add `resizePane()` method |
| `Fantastty/Models/TmuxControlMode/TmuxWindowController.swift` | Modify | Own per-surface size subscriptions, change `applyLayout` to pane-ID-set comparison |
| `Fantastty/Models/TmuxSessionBridge.swift` | Modify | Delete centralized size machinery, simplify `%layout-change` action handling |
| `Fantastty/Views/Terminal/SessionDetailView.swift` | Modify | Replace size publishers with simple `refresh-client` on container resize |
| `FantasttyTests/TmuxControlClientTests.swift` | Modify | Add test for `resizePane` command formatting |
| `FantasttyTests/TmuxResizeTests.swift` | Modify | Replace centralized resize tests with per-surface resize tests |

---

## Chunk 1: Per-Surface Resize Infrastructure

### Task 1: Add `resizePane()` to TmuxControlClient

**Files:**
- Modify: `Fantastty/Models/TmuxControlMode/TmuxControlClient.swift:654-666`
- Test: `FantasttyTests/TmuxControlClientTests.swift`

- [ ] **Step 1: Write failing test for resizePane command formatting**

In `TmuxControlClientTests.swift`, add a test that verifies the command string format. Follow the existing test pattern in that file for command formatting tests.

```swift
func testResizePaneCommandFormat() async throws {
    // Verify the static command formatter produces the correct tmux command
    let command = TmuxControlClient.resizePaneCommand(paneID: 5, columns: 80, rows: 24)
    XCTAssertEqual(command, "resize-pane -t %5 -x 80 -y 24")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Fantastty -only-testing FantasttyTests/TmuxControlClientTests/testResizePaneCommandFormat 2>&1 | tail -20`
Expected: FAIL — `resizePaneCommand` does not exist

- [ ] **Step 3: Implement resizePane**

In `TmuxControlClient.swift`, add after `refreshClientSize()` (around line 666):

```swift
/// Tells tmux the exact grid size of a single pane.
/// Fire-and-forget: errors are silently ignored.
func resizePane(paneID: Int, columns: Int, rows: Int) {
    guard columns > 0, rows > 0 else { return }
    sendFireAndForget(Self.resizePaneCommand(paneID: paneID, columns: columns, rows: rows))
}

static func resizePaneCommand(paneID: Int, columns: Int, rows: Int) -> String {
    "resize-pane -t %\(paneID) -x \(columns) -y \(rows)"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Fantastty -only-testing FantasttyTests/TmuxControlClientTests/testResizePaneCommandFormat 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxControlClient.swift FantasttyTests/TmuxControlClientTests.swift
git commit -m "feat(tmux): add resizePane command for per-surface sizing"
```

---

### Task 2: Add per-surface size subscriptions to TmuxWindowController

**Files:**
- Modify: `Fantastty/Models/TmuxControlMode/TmuxWindowController.swift`

This task adds Combine subscriptions that watch each surface's `$surfaceSize` and call `resizePane()` when the grid dimensions change. The subscriptions are owned by TmuxWindowController and cancelled when surfaces are removed.

- [ ] **Step 1: Add import and subscription storage**

In `TmuxWindowController.swift`, add `import Combine` at the top (after `import GhosttyKit`). Then add properties after `lastAppliedLayout` (line 15):

```swift
private var surfaceSizeSubscriptions: [Int: AnyCancellable] = [:]  // keyed by paneID
private var resizeDebounce: [Int: Task<Void, Never>] = [:]  // keyed by paneID
private let resizeDebounceInterval: TimeInterval = 0.1
```

- [ ] **Step 2: Add method to subscribe to a surface's size changes**

Add after the existing methods:

```swift
/// Subscribes to a surface's grid size changes and sends resize-pane to tmux.
private func subscribeSurfaceSize(paneID: Int, surface: Ghostty.SurfaceView) {
    surfaceSizeSubscriptions[paneID] = surface.$surfaceSize
        .compactMap { $0 }  // skip nil (surface hasn't rendered yet)
        .removeDuplicates { $0.columns == $1.columns && $0.rows == $1.rows }
        .sink { [weak self] size in
            guard let self, let client = surface.tmuxControlClient else { return }
            let cols = Int(size.columns)
            let rows = Int(size.rows)
            guard cols > 0, rows > 0 else { return }

            // Debounce to avoid flooding tmux during continuous drag
            self.resizeDebounce[paneID]?.cancel()
            self.resizeDebounce[paneID] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(self.resizeDebounceInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.resizeDebounce.removeValue(forKey: paneID)
                client.resizePane(paneID: paneID, columns: cols, rows: rows)
            }
        }
}
```

- [ ] **Step 3: Wire subscriptions into pane lifecycle**

In `applyLayout()`, after a new `TmuxPaneController` is created and added to `paneControllers` (line 60), add the subscription. Note: the surface is created by `surfaceFactory` (called inside `buildLayoutTree`) with `tmuxControlClient` already set (see `upsertWindow` in TmuxSessionBridge.swift line 586), so the client is available when the subscriber fires.

To get the surface for the new pane, use `tab.surfaceTree`'s leaves after the tree is set (line 70). Add after line 70:

```swift
// Subscribe to size changes for newly added panes
for paneID in newPaneIDs where surfaceSizeSubscriptions[paneID] == nil {
    if let surface = tab.surfaceTree?.root?.leaves().first(where: { $0.tmuxPaneID == paneID }) {
        subscribeSurfaceSize(paneID: paneID, surface: surface)
    }
}
```

And in the block that removes old pane controllers (panes no longer in layout), add cleanup:

```swift
surfaceSizeSubscriptions.removeValue(forKey: paneID)
resizeDebounce[paneID]?.cancel()
resizeDebounce.removeValue(forKey: paneID)
```

- [ ] **Step 4: Clean up subscriptions in teardown()**

In `teardown()`, add before clearing paneControllers:

```swift
surfaceSizeSubscriptions.removeAll()
resizeDebounce.values.forEach { $0.cancel() }
resizeDebounce.removeAll()
```

- [ ] **Step 5: Build to verify compilation**

Run: `xcodebuild -scheme Fantastty -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxWindowController.swift
git commit -m "feat(tmux): add per-surface size subscriptions to TmuxWindowController"
```

---

## Chunk 2: Simplify Container Sizing and Delete Centralized Machinery

### Task 3: Replace SessionDetailView size tracking with simple refresh-client

**Files:**
- Modify: `Fantastty/Views/Terminal/SessionDetailView.swift:219-323`

The current code has a GeometryReader with three event handlers that feed into the centralized `updateAttachedTmuxWindowSize`. Replace with a single `onChange(of: geometry.size)` that sends `refresh-client -C` directly. This sets the window bounds; per-surface `resize-pane` (from Task 2) handles exact pane sizes.

- [ ] **Step 1: Replace the GeometryReader body in TabContentView**

Replace the entire `case .terminal:` block in `TabContentView.body` (approximately lines 222-248) with:

```swift
case .terminal:
    if let tree = tab.surfaceTree {
        GeometryReader { geometry in
            TerminalSplitTreeView(
                tree: tree,
                action: handleSplitOperation
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear {
                if let focused = tab.focusedSurface {
                    Ghostty.moveFocus(to: focused)
                }
                sendRefreshClient(containerSize: geometry.size)
                tab.requestThumbnailRefresh()
            }
            .onChange(of: geometry.size) { _, newSize in
                sendRefreshClient(containerSize: newSize)
                tab.requestThumbnailRefresh()
            }
        }
    }
```

- [ ] **Step 2: Replace updateAttachedTmuxWindowSize with sendRefreshClient**

Delete the `updateAttachedTmuxWindowSize()` method, the `attachedTmuxCellSizePublisher`, the `attachedTmuxSurfaceSizePublisher`, and the `attachedTmuxSizingSurface()` helper. Replace with:

```swift
/// Sends refresh-client to set tmux window bounds from container pixel size.
/// This is intentionally a rough ceiling — per-surface resize-pane sets exact sizes.
private func sendRefreshClient(containerSize: CGSize) {
    guard case .attached = session.mode,
          let client = session.controlClient,
          let windowID = tab.tmuxWindowID,
          let surface = tab.surfaceTree?.root?.leftmostLeaf() else {
        return
    }

    let cellSize = surface.cellSize
    guard cellSize.width > 0, cellSize.height > 0 else { return }

    let cols = Int(floor(containerSize.width / cellSize.width))
    let rows = Int(floor(containerSize.height / cellSize.height))
    guard cols > 0, rows > 0 else { return }

    client.refreshClientSize(windowID: windowID, width: cols, height: rows)
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -scheme Fantastty -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (may have warnings about unused SessionManager methods — those are cleaned up in Task 4)

- [ ] **Step 4: Commit**

```bash
git add Fantastty/Views/Terminal/SessionDetailView.swift
git commit -m "refactor(tmux): replace size publishers with simple refresh-client"
```

---

### Task 4: Delete centralized size machinery from TmuxSessionBridge

**Files:**
- Modify: `Fantastty/Models/TmuxSessionBridge.swift`

Delete all the centralized resize tracking code. This is a large deletion — the key is to remove precisely the right things without breaking the event routing and deferred bootstrap.

- [ ] **Step 1: Delete properties**

Remove these properties from the class:
- `attachedTmuxWindowSizes` dictionary
- `attachedTmuxWindowRecaptureTasks` dictionary
- `layoutAppliedSuppression` set
- `resizeDebounce` dictionary and `resizeDebounceInterval` constant
- `tmuxWindowResizeSender` property and `TmuxWindowResizeSender` typealias
- `attachedTmuxWindowRecaptureDelay` property

Remove from `deinit`:
- `attachedTmuxWindowRecaptureTasks.values.forEach { $0.cancel() }`
- `resizeDebounce.values.forEach { $0.cancel() }`

Remove from `init`:
- Any setup related to `tmuxWindowResizeSender` (check if it's set in init or if the default is fine)

- [ ] **Step 2: Delete methods**

Remove these methods entirely:
- `updateAttachedTmuxWindowSize(session:tab:contentSize:)` (the large centralized method)
- `preferredAttachedTmuxWindowSize(root:treeSize:contentSize:isInitial:)`
- `attachedTmuxWindowSize(surfaceSize:contentSize:cellSize:)` (static, two-arg overload)
- `attachedTmuxWindowSize(tree:contentSize:cellSize:)` (static, tree overload)
- `attachedTmuxWindowSize(in:)` (private static, tree-walking)
- `countSplits(in:)`
- `maxLeafFanOut(in:)`
- `firstLeafView(in:)` (check if used elsewhere — if only by the deleted methods, remove it)
- `scheduleAttachedTmuxWindowRecapture` (if it exists — check if still needed)
- `AttachedTmuxWindowSizeKey` struct
- `AttachedTmuxWindowSize` struct (check if used by other code first)

Also delete:
- `defaultTmuxWindowResizeSender` static method (around line 115)
- `cleanupAttachedTmuxWindowState` — all 3 overloads (lines ~397-415). These reference `attachedTmuxWindowSizes` and `attachedTmuxWindowRecaptureTasks` which are being deleted. Simplify or inline their remaining logic (cleanup of `windowControllersByWorkspace` etc.) into the callers (`unregisterSession`, `controlClientDidExit`, `.removeWindow` action handler).
- `SessionManager.updateAttachedTmuxWindowSize` forwarding method (if it exists)

- [ ] **Step 3: Remove layoutAppliedSuppression from action handling**

In the `apply(actions:session:client:)` method, find the `.applyLayout` case. Remove the line that inserts into `layoutAppliedSuppression`:

```swift
// DELETE this line:
layoutAppliedSuppression.insert(layoutKey)
```

And remove the `AttachedTmuxWindowSizeKey` construction around it.

- [ ] **Step 4: Build and fix any remaining references**

Run: `xcodebuild -scheme Fantastty -configuration Debug build 2>&1 | grep error:`

Fix any compilation errors from dangling references to deleted code. Common ones:
- `SessionManager` may have a forwarding method to delete
- `defaultTmuxWindowResizeSender` static method to delete
- Test files may reference deleted types

- [ ] **Step 5: Run tests**

Run: `xcodebuild test -scheme Fantastty 2>&1 | tail -20`
Expected: Tests pass (some existing resize tests may need deletion — see Task 6)

- [ ] **Step 6: Commit**

```bash
git add Fantastty/Models/TmuxSessionBridge.swift Fantastty/Models/SessionManager.swift
git commit -m "refactor(tmux): delete centralized resize tracking machinery"
```

---

## Chunk 3: Structural-Only Layout Changes and Bootstrap Gating

### Task 5: Change `%layout-change` handling to structural-only

**Files:**
- Modify: `Fantastty/Models/TmuxControlMode/TmuxWindowController.swift`
- Modify: `Fantastty/Models/TmuxControlMode/V2/AttachedWorkspaceRuntimeV2.swift` (if needed)

Currently `applyLayout()` uses a `lastAppliedLayout` string-equality guard to prevent re-applying identical layouts. Replace this with a pane-ID-set comparison: if the set of pane IDs hasn't changed, ignore the layout change entirely (it's tmux responding to our `resize-pane` or `refresh-client`).

- [ ] **Step 1: Add pane ID extraction helper**

In `TmuxWindowController.swift`, add a helper that extracts pane IDs from a layout string. The layout is already parsed by `TmuxLayoutMapper` — we need to extract pane IDs from the parsed `TmuxLayoutNode`. Add:

```swift
/// Extracts all pane IDs from a layout string using the existing parser.
private static func paneIDs(fromLayout layout: String) -> Set<Int> {
    let node = TmuxLayoutParser.parse(layout)  // returns non-optional TmuxLayoutNode
    return Set(node.allPaneIDs())  // allPaneIDs() is a method on TmuxLayoutNode
}
```

Note: `TmuxLayoutParser.parse()` returns a non-optional `TmuxLayoutNode`. `TmuxLayoutNode.allPaneIDs()` is an existing method (line 33 of TmuxLayoutParser.swift) that recursively collects leaf pane IDs.

- [ ] **Step 2: Replace lastAppliedLayout guard with pane-ID-set comparison**

In `applyLayout()`, replace:
```swift
guard layout != lastAppliedLayout else { return }
lastAppliedLayout = layout
```

With:
```swift
let newPaneIDs = Self.paneIDs(fromLayout: layout)
let currentPaneIDs = Set(paneControllers.keys)

// If pane set is unchanged, this is a non-structural change
// (tmux responding to our resize-pane/refresh-client). Ignore it.
if newPaneIDs == currentPaneIDs, !currentPaneIDs.isEmpty {
    return
}
```

Note: we still allow the first layout application (when `currentPaneIDs` is empty) to proceed, even if the pane sets would technically match.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Fantastty -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxWindowController.swift
git commit -m "refactor(tmux): use pane-ID-set comparison for layout-change filtering"
```

---

### Task 6: Update deferred bootstrap gating

**Files:**
- Modify: `Fantastty/Models/TmuxControlMode/TmuxWindowController.swift`
- Modify: `Fantastty/Models/TmuxSessionBridge.swift` (if bootstrap logic lives there)

Currently deferred bootstrap is gated on the first `refresh-client` being sent. Change it to gate on all surfaces in a window having reported a non-nil `surfaceSize` (meaning `resize-pane` has been sent for each pane).

- [ ] **Step 1: Track which panes have reported sizes**

In `TmuxWindowController.swift`, add:

```swift
private var panesWithReportedSize: Set<Int> = []
private var bootstrapCompleted: Bool = false
```

- [ ] **Step 2: Track size reports in the subscriber**

In the `subscribeSurfaceSize` method's `.sink` closure, after the debounced `resizePane` call, add tracking:

```swift
// Inside the sink, before the debounce:
if self.panesWithReportedSize.insert(paneID).inserted {
    self.checkBootstrapReadiness()
}
```

Move the `panesWithReportedSize.insert` OUTSIDE the debounce (it should fire on the first non-nil surfaceSize, not after the debounce delay).

- [ ] **Step 3: Add bootstrap readiness check**

```swift
private func checkBootstrapReadiness() {
    guard !bootstrapCompleted else { return }
    let allPaneIDs = Set(paneControllers.keys)
    guard !allPaneIDs.isEmpty, panesWithReportedSize.isSuperset(of: allPaneIDs) else { return }
    bootstrapCompleted = true
    onBootstrapReady?()
}
```

Add an `onBootstrapReady` callback property:

```swift
var onBootstrapReady: (() -> Void)?
```

- [ ] **Step 4: Wire bootstrap callback in TmuxSessionBridge**

In TmuxSessionBridge's `upsertWindow()` method (line 576), set the callback on the controller right after it is created (before it is stored in `windowControllersByWorkspace`):

```swift
controller.onBootstrapReady = { [weak self, weak client] in
    guard let self, let client else { return }
    let paneIDs = Array(controller.paneControllers.keys).sorted()
    guard !paneIDs.isEmpty else { return }
    Task {
        await client.continueDeferredBootstrap(paneIDs: paneIDs)
    }
}
```

Note: `continueDeferredBootstrap` internally calls `capturePaneContents` — this handles the one-time initial content capture described in the spec's "Recapture After Resize" section.

Remove any existing deferred bootstrap triggers from the old `updateAttachedTmuxWindowSize` code path (should already be deleted in Task 4).

**Important:** Do not manually test the app between Task 4 (which deletes the old bootstrap trigger) and this task. The bootstrap path is broken until this task is complete.

- [ ] **Step 5: Build and verify**

Run: `xcodebuild -scheme Fantastty -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxWindowController.swift Fantastty/Models/TmuxSessionBridge.swift
git commit -m "feat(tmux): gate deferred bootstrap on all surfaces reporting size"
```

---

## Chunk 4: Test Updates and Cleanup

### Task 7: Update and clean up tests

**Files:**
- Modify: `FantasttyTests/TmuxResizeTests.swift`
- Modify: `FantasttyTests/SplitLayoutPipelineTests.swift`

- [ ] **Step 1: Remove tests for deleted code**

In `TmuxResizeTests.swift`, remove tests that reference:
- `attachedTmuxWindowSize` (both overloads)
- `preferredAttachedTmuxWindowSize`
- `countSplits`
- `maxLeafFanOut`
- `AttachedTmuxWindowSizeKey`

In `SplitLayoutPipelineTests.swift`, remove or update tests that test the centralized resize pipeline (these tested the feedback loop behavior which no longer exists).

- [ ] **Step 2: Add test for pane-ID-set comparison logic**

Add a test that verifies the structural change detection:

```swift
func testPaneIDSetComparison_sameSet_ignoresLayout() {
    // When the pane set is unchanged, applyLayout should be a no-op
    // (would need to verify through behavior — e.g., tree doesn't get rebuilt)
}

func testPaneIDSetComparison_newPane_rebuildsTree() {
    // When a new pane appears, the tree should be rebuilt
}
```

Adapt these to the actual test infrastructure available in the project.

- [ ] **Step 3: Build and run all tests**

Run: `xcodebuild test -scheme Fantastty 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add FantasttyTests/
git commit -m "test(tmux): update tests for per-surface resize architecture"
```

---

### Task 8: Manual integration test

- [ ] **Step 1: Launch Fantastty and verify basic operation**

Build and launch:
```bash
xcodebuild -scheme Fantastty -configuration Debug build 2>&1 | tail -5
open ~/Library/Developer/Xcode/DerivedData/Fantastty-*/Build/Products/Debug/Fantastty.app
```

Verify:
1. App launches and attaches to existing tmux sessions
2. Terminal displays correctly (no "failed to initialize" error)
3. Text can be entered in panes
4. Programs display at correct width (no horizontal overfill)

- [ ] **Step 2: Test window resize**

1. Resize the window by dragging edges
2. Verify panes resize smoothly (no jank, no hang)
3. Run `tput cols; tput lines` in a pane — verify dimensions match the visible area
4. Open a full-width program (e.g., `htop` or run `printf '%*s\n' "$(tput cols)" '' | tr ' ' '-'`) — verify lines don't wrap past the right edge

- [ ] **Step 3: Test split panes**

1. If the session has splits, verify both panes display correctly
2. Run `tput cols` in each pane — verify dimensions are correct for each
3. Resize the window — verify both panes update correctly
4. If possible, run `tmux split-window` from within a pane — verify the new split appears

- [ ] **Step 4: Test attach with existing layout**

1. Quit Fantastty
2. Relaunch — verify it reconnects to existing sessions
3. Verify split layout is restored with correct proportions
4. Verify text is displayed at correct width immediately
