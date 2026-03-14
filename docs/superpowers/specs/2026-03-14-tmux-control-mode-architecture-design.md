# Tmux Control Mode Architecture Design

## Goal

Decompose the monolithic `SessionManager` (1600+ lines) into focused modules with clear responsibility boundaries, and rename `SessionManagerV2` to reflect its actual role. This enables reliable tmux control mode by making each layer independently testable and debuggable.

## Current Problems

- `SessionManager` mixes workspace CRUD, tmux event handling, notification routing, persistence, activity tracking, and thumbnail management
- `closeTab` does not send `kill-window` to tmux
- `closeSurface` does not send `kill-pane` to tmux
- Closing the last terminal tab kills the entire tmux session instead of entering placeholder state
- `SessionManagerV2` is a misleading name for what is actually the tmux-to-UI bridge
- Bugs in protocol parsing, window resizing, and paint refresh are difficult to isolate because responsibilities are tangled

## Architecture

### Tmux Event Chain

```
TmuxControlClient (protocol layer)
        |
        v delegate callbacks
TmuxSessionBridge (session-level: window set, active window, connect/disconnect)
        |
        v routes per-window events
TmuxWindowController (window-level: layout, split tree, pane set, resize)
        |
        v routes per-pane events
TmuxPaneController (pane-level: output injection, buffering, focus)
        |
        v ghostty_surface_inject_output()
Ghostty.SurfaceView
```

### SessionManager Composition

```
SessionManager (slim: workspace CRUD, selection, composes everything)
    +-- TmuxSessionBridge (tmux events -> UI model)
    +-- TerminalLifecycleRouter (UI actions -> tmux commands)
    +-- LayoutPersistence (save/restore layout snapshots)
    +-- NotificationRouter (ghostty NSNotifications -> handlers)
    +-- ActivityTracker (idle detection, time accumulation, thumbnails)
```

## Module Details

### TmuxPaneController

- Owns one `Ghostty.SurfaceView` and its `tmuxPaneID`
- Single responsibility: receive `Data`, inject into surface
- Buffers output if surface is not ready (replaces `AttachedPaneRuntimeV2` buffering)
- Testable with a mock surface or injector closure

### TmuxWindowController

- Owns one `TerminalTab`, its `SplitTree`, and a `[Int: TmuxPaneController]` map
- Receives layout strings, parses via `TmuxLayoutParser`/`TmuxLayoutMapper`, builds tree
- Creates/destroys `TmuxPaneController` instances as panes appear/disappear in layout
- Routes output to correct pane controller
- Handles window resize
- Replaces `AttachedWindowRuntimeV2` + layout-application code currently in `SessionManagerV2.applyLayout()`

### TmuxSessionBridge (renamed from SessionManagerV2)

- Is the `TmuxControlClientDelegate`
- Maintains `[Int: TmuxWindowController]` keyed by tmux window ID
- On `%window-add`: creates `TmuxWindowController`, inserts tab into session
- On `%window-close`: destroys controller, removes tab
- On `%layout-change`: forwards to window controller
- On `%output`: forwards to window controller (which forwards to pane controller)
- On active window change: updates tab selection
- On client exit: tears down all window controllers
- Tab selection observation: UI selection sends `select-window` to tmux

### TerminalLifecycleRouter

- Close terminal tab sends `kill-window`
- Close pane sends `kill-pane`
- New tab sends `new-window`
- Split sends `split-pane`
- Close last terminal tab enters placeholder state (does NOT kill session)
- All actions gated on connected state

### LayoutPersistence

- `save(sessions:)` / `load(from:)` / `restore(snapshot:into:)`
- Only persists browser tabs
- Only restores browser tabs; terminal tabs derived from tmux

### NotificationRouter

- Registers ghostty `NSNotification` observers
- Resolves surface to session/tab via index
- Dispatches to typed handler closures
- No business logic, just routing

### ActivityTracker

- `ThumbnailRefreshController` (already exists, stays)
- Idle detection timer, time accumulation, periodic flush
- Mouse/key input tracking
- Completely independent of tmux

### SessionManager (slimmed)

- `@Published var sessions: [Session]`
- `@Published var selectedSessionID: UUID?`
- Workspace create/close/archive/unarchive
- Composes all modules above
- Remains the SwiftUI-observable entry point

## Contract Tests

### Pane Contracts (TmuxPaneControllerTests)

- Output data is injected into surface
- Output before surface ready is buffered
- Buffered output flushes when surface becomes ready
- No output delivered after controller is torn down

### Window Contracts (TmuxWindowControllerTests)

- Layout string produces correct `SplitTree` shape
- Layout change creates new pane controllers for new panes
- Layout change preserves existing pane controllers for retained panes
- Layout change destroys pane controllers for removed panes
- Output routed to correct pane by ID
- Output for unknown pane is buffered until layout includes it
- Resize sends correct dimensions to tmux

### Session Bridge Contracts (TmuxSessionBridgeTests)

- `%window-add` creates window controller and tab at correct index
- `%window-close` destroys controller, removes tab, selects adjacent
- `%window-renamed` updates tab title
- Active window change selects tab without echoing `select-window`
- Tab selection sends `select-window` to tmux
- Client exit tears down all controllers, sets disconnected state
- Output before window-add is buffered
- Bootstrap populates all existing windows

### Lifecycle Router Contracts (TerminalLifecycleRouterTests)

- Close terminal tab sends `kill-window` with correct window ID
- Close pane sends `kill-pane` with correct pane ID
- Close last terminal tab enters placeholder state, tmux session NOT killed
- New tab sends `new-window`
- Split sends `split-pane` with correct pane ID and direction
- All actions no-op when disconnected
- Close browser tab sends no tmux command

### Persistence Contracts (LayoutPersistenceTests)

- Save includes browser tabs, excludes terminal tabs
- Restore creates browser tabs only
- Restore skips archived/trashed workspaces
- Missing layout file returns graceful nil
- Corrupt layout file returns graceful nil

## Migration Strategy

The V2 runtime value types (`AttachedWorkspaceRuntimeV2`, `AttachedWindowRuntimeV2`, `AttachedPaneRuntimeV2`) become the state-machine cores of their respective controllers. Their existing tests continue to pass. The controllers add UI binding on top.

Existing `SessionManagerV2` tests get renamed to `TmuxSessionBridgeTests` and augmented with the contract tests. Existing `WindowManagementTests` that test through `SessionManager` remain as integration tests.
