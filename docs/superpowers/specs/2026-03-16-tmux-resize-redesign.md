# Tmux Resize Redesign

## Problem

The current tmux resize tracking system uses a bidirectional feedback loop: Fantastty computes a total window size from container pixels, sends it to tmux via `refresh-client -C`, tmux responds with `%layout-change`, Fantastty applies the layout, which triggers geometry changes, which would send another `refresh-client`. This loop is managed by suppression flags, debounce timers, and dual size-computation paths (`treeSize` vs `contentSize`), all of which have produced bugs:

- Horizontal overfill (tmux told more columns than surfaces can render)
- Runaway feedback loop (panes shrinking to minimum)
- Infinite layout recursion (app hang)
- Terminal init failure (deferred bootstrap blocked by debounce)
- Incorrect padding/splitter accounting across split configurations

The fundamental issue: computing a window-level grid size from container pixels requires accounting for per-pane Ghostty padding, splitter widths, DPI scaling, and split topology — a calculation that is fragile and has no single source of truth.

## Design

### Core Principle: Surface-Owned Sizing

Each Ghostty surface is the single authority on its own grid dimensions. `ghostty_surface_size()` already accounts for window padding, DPI, font metrics, and cell size. When a surface's grid size changes, it tells tmux directly:

```
resize-pane -t %<paneID> -x <cols> -y <rows>
```

There is no centralized tree-walking or padding/splitter accounting for per-pane sizes.

### Two-Layer Sizing

Tmux constrains pane sizes to fit within the window. If we only send per-pane `resize-pane` without first setting the window size, tmux will clamp panes to the (possibly stale) window dimensions. We need two layers:

1. **Window bounds** (`refresh-client -C <cols>x<rows>`): Tells tmux the total window size. Computed simply as `floor(containerPixelWidth / cellWidth)` x `floor(containerPixelHeight / cellHeight)` from the GeometryReader. This intentionally may overcount by ~1 column/row due to per-pane padding, but that gives tmux *more* room than needed — panes never overflow because `resize-pane` sets exact values.

2. **Per-pane exact sizes** (`resize-pane -t %<paneID> -x <cols> -y <rows>`): Each surface reports its actual grid size, which accounts for padding, DPI, and cell metrics. This makes pane sizes exact.

The window bounds are a ceiling; the per-pane sizes are the floor of truth. The difference (typically 0-2 cells) is harmless empty space that tmux manages as balanced padding.

**Crucially:** neither `refresh-client` nor `resize-pane` responses trigger any action on our side. `%layout-change` is only processed for structural changes (pane set changed). This breaks the feedback loop entirely.

### Resize Path

When any event changes a surface's pixel allocation (window resize, split drag, font size change):

```
SwiftUI resizes container and/or surfaces
  → refresh-client -C (from container GeometryReader, if container size changed)
  → each surface re-renders, publishes surfaceSize
  → per-surface subscriber sends resize-pane -t %<paneID> -x <cols> -y <rows>
```

A short per-surface debounce (~100ms) prevents flooding tmux during continuous drag. Each surface manages its own timer independently. `refresh-client` uses its own debounce (~100ms), also independent.

Errors from `resize-pane` are silently ignored (fire-and-forget). If tmux rejects a resize (e.g., pane was closed between size change and command), the surface continues rendering at its own grid size — the user sees correct output regardless.

### Attach Flow (Layout Restore)

When Fantastty attaches to a tmux session with existing splits:

1. Parse tmux's layout string → extract tree structure and ratios
2. Build SplitTree using those ratios, create Ghostty surfaces for each pane
3. SwiftUI lays out the tree, allocating pixels to each surface based on ratios and actual window size
4. Container GeometryReader fires → `refresh-client -C` sets window bounds
5. Each surface renders, publishes `surfaceSize`, subscriber sends `resize-pane`
6. Deferred bootstrap: once all surfaces in a window have sent `resize-pane` (surfaceSize transitioned from nil to non-nil), capture pane contents at correct dimensions and inject into surfaces

There is no special attach-time sizing code. The same per-surface mechanism handles both attach and ongoing resize.

### Structural Changes from `%layout-change`

`%layout-change` is used only for structural changes — panes added or removed (e.g., user runs `tmux split-window` or `tmux kill-pane`).

**Detecting structural vs. non-structural:** Compare the set of pane IDs in the new layout against the current tree's pane IDs. If identical, ignore (it's tmux responding to our `resize-pane` or `refresh-client`). If panes were added or removed, rebuild the tree.

**Rebuild flow:**
1. Parse new layout → extract pane IDs and ratios
2. Diff against current tree's pane IDs
3. Create surfaces for new panes, destroy surfaces for removed panes
4. Rebuild split tree with new ratios (preserving existing surfaces for unchanged panes)
5. SwiftUI lays out new tree → surfaces resize → per-surface resize-pane fires automatically

We use tmux's ratios for visual layout but never tmux's absolute pixel/cell sizes. Each surface reports its own real size back to tmux.

Note: `TmuxWindowController.applyLayout` currently has a `lastAppliedLayout` string-equality guard. This should be replaced by the pane-ID-set comparison, which is the correct granularity (string equality would miss cases where ratios change but structure doesn't, and vice versa).

### Recapture After Resize

The current `scheduleAttachedTmuxWindowRecapture` mechanism re-captures pane content after a resize to ensure display correctness. Under the new design, `resize-pane` tells tmux the exact pane dimensions, and subsequent `%output` data is formatted for those dimensions. A one-time recapture after the initial attach sizes are sent ensures the display is correct. For ongoing resizes, tmux sends correctly-formatted output via `%output` once it knows the new pane size — no recapture needed.

## Code Changes

### Deleted from TmuxSessionBridge

- `updateAttachedTmuxWindowSize()` — the entire centralized size computation
- `preferredAttachedTmuxWindowSize()` — treeSize vs contentSize selection
- `attachedTmuxWindowSize()` — both overloads (surface-based and tree-walking)
- `countSplits()`, `maxLeafFanOut()` — padding/splitter accounting helpers
- `layoutAppliedSuppression` — feedback loop suppression flag
- `resizeDebounce` / `resizeDebounceInterval` — centralized debounce
- `attachedTmuxWindowSizes` / `AttachedTmuxWindowSizeKey` — cached sizes
- `tmuxWindowResizeSender` / `TmuxWindowResizeSender` — callback for sending refresh-client

### Deleted from SessionDetailView

- Size-tracking `onChange(of: geometry.size)` and `onReceive` handlers that call `updateAttachedTmuxWindowSize`
- `attachedTmuxCellSizePublisher`, `attachedTmuxSurfaceSizePublisher`
- `updateAttachedTmuxWindowSize()` forwarding method

### Kept in SessionDetailView (simplified)

- `GeometryReader` around the split tree — still needed to send `refresh-client -C` when container size changes. This becomes a simple `onChange(of: geometry.size)` that computes `floor(width/cellWidth)` x `floor(height/cellHeight)` and sends `refresh-client -C`. No tree-walking, no padding math.

### New: TmuxControlClient.resizePane

```swift
func resizePane(paneID: Int, columns: Int, rows: Int) async
// Sends: resize-pane -t %<paneID> -x <columns> -y <rows>
```

### New: Per-Surface Size Subscriber

A Combine subscription on each tmux-attached surface's `$surfaceSize`. When the grid size changes and the surface has a `tmuxPaneID` and `tmuxControlClient`, it calls `resizePane()` with ~100ms debounce.

This subscriber should be set up by `TmuxWindowController` when it creates surfaces for panes, keeping it out of the Ghostty vendor code (`SurfaceView_AppKit`). The subscription is stored in the controller and cancelled when the surface is removed.

### Modified: `%layout-change` Handling

Current: applies layout AND triggers resize feedback.
New: compares pane ID sets. If unchanged, ignores. If structural change, rebuilds tree (no resize feedback needed — per-surface subscribers handle it). Replaces the `lastAppliedLayout` string-equality guard in `TmuxWindowController`.

### Modified: Deferred Bootstrap Gating

Current: gated on first `refresh-client` being sent.
New: gated on all surfaces in a window having reported a non-nil `surfaceSize` (meaning `resize-pane` has been sent for each).
