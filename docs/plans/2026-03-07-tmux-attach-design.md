# Tmux Session Attach — Design Document

Date: 2026-03-07

## Overview

Attach to pre-existing tmux sessions (local or remote via SSH), rendering
windows as native Fantastty tabs and panes as native Ghostty splits, with full
bidirectional control. This is the iTerm2-style approach: Fantastty becomes a
first-class tmux control mode client.

## Goals

- Attach to any running tmux session, local or remote (via SSH)
- Display tmux windows as Fantastty tabs
- Display tmux panes as native Ghostty splits within tabs
- Full bidirectional control: create, close, rename, reorder windows and panes
- Persist attached sessions across app restarts with automatic re-attach
- Show disconnected state when connections drop; manual reconnect
- Unified session list in sidebar (local + remote) with host provenance

## Non-Goals (for initial implementation)

- Tmux status bar rendering (Fantastty replaces it with native UI)
- Tmux border rendering (Ghostty splits replace them)
- Mosh or other SSH alternatives (standard SSH only)
- Auto-reconnect on SSH drop (manual reconnect; resilient SSH config recommended)

## Architecture

### High-Level Component Diagram

```
SessionManager
 |-- Session (attached)
 |    |-- TerminalTab[] (driven by tmux windows)
 |    |    |-- SplitTree<SurfaceView> (driven by tmux panes)
 |    |
 |    |-- TmuxControlClient (Swift actor)
 |         |-- PTY to `tmux -CC attach -t <name>`
 |         |-- TmuxProtocolParser (pure struct)
 |         |-- CommandQueue (async FIFO)
 |         |-- TmuxLayoutParser (pure struct)
```

One `TmuxControlClient` actor per attached session. All I/O, state management,
and notification handling is actor-isolated — no threading issues.

### Data Flow

**Output** (tmux -> screen):
1. `tmux -CC` sends `%output %<paneID> <octal-escaped-data>`
2. `TmuxProtocolParser` decodes octal escapes into raw `Data`
3. `TmuxControlClient` looks up the surface for `paneID`
4. Calls `ghostty_surface_inject_output(surface, bytes, length)` on MainActor
5. Ghostty's terminal emulator renders the bytes

**Input** (user -> tmux):
1. User types in a split surface
2. Input intercepted at SurfaceView level before reaching the inert PTY
3. Forwarded to `TmuxControlClient.sendKeys(paneID:data:)`
4. Sent as `send-keys -t %<paneID> -H <hex-encoded-bytes>` over control connection

**Window lifecycle** (tmux -> tabs):
- `%window-add @<id>` -> create new TerminalTab, populate with pane surfaces
- `%window-close @<id>` -> remove TerminalTab
- `%window-renamed @<id> <name>` -> update tab title

**Pane layout** (tmux -> splits):
- `%layout-change @<windowID> <layout>` -> parse layout -> diff pane set ->
  create/destroy surfaces -> build new SplitTree -> assign to tab

## Core Components

### TmuxProtocolParser (Pure Struct)

Parses lines from the tmux control mode PTY into typed events. No I/O, no
side effects, fully unit-testable.

```swift
struct TmuxProtocolParser {
    mutating func parse(line: String) -> TmuxEvent?
}

enum TmuxEvent {
    case output(paneID: Int, data: Data)
    case windowAdd(windowID: Int)
    case windowClose(windowID: Int)
    case windowRenamed(windowID: Int, name: String)
    case layoutChange(windowID: Int, layout: String)
    case sessionChanged(sessionID: Int, name: String)
    case sessionsChanged
    case paneModeChanged(paneID: Int)
    case beginBlock(id: Int, flags: Int)
    case endBlock(id: Int)
    case errorBlock(id: Int)
    case exit(reason: String?)
    case unknown(String)
}
```

Responsibilities:
- Strip `\r` from PTY line endings
- Strip DCS prefix (`\x1bP1000p`) from first line of stream
- Decode octal escapes in `%output` data (`\NNN` -> byte value)
- Accumulate text between `%begin` and `%end`/`%error` into response buffers

### TmuxLayoutParser (Pure Struct)

Parses tmux layout descriptor strings into a tree structure.

```swift
struct TmuxLayoutParser {
    static func parse(_ layoutString: String) -> TmuxLayoutNode
}

enum TmuxLayoutNode {
    case leaf(paneID: Int, width: Int, height: Int)
    case horizontalSplit(children: [TmuxLayoutNode], width: Int, height: Int)
    case verticalSplit(children: [TmuxLayoutNode], width: Int, height: Int)
}
```

Tmux layout format:
- `WxH,X,Y,PaneID` — leaf pane
- `WxH,X,Y{...,...}` — horizontal split (left-to-right)
- `WxH,X,Y[...,...}` — vertical split (top-to-bottom)

Maps to Ghostty's SplitTree:
- `leaf(paneID)` -> `SplitTree.leaf(surfaceForPane[paneID])`
- `horizontalSplit` -> `SplitTree.split(.horizontal, ...)`
- `verticalSplit` -> `SplitTree.split(.vertical, ...)`
- Ratios derived from child dimensions relative to parent

### TmuxControlClient (Swift Actor)

Owns the control mode connection. Async API with FIFO response matching.

```swift
actor TmuxControlClient {
    let sessionName: String
    let host: TmuxHost

    private(set) var windows: [TmuxWindow]
    private(set) var state: ConnectionState  // .connecting, .connected, .disconnected

    // Lifecycle
    func connect() async throws
    func disconnect()

    // Commands
    func send(_ command: String) async throws -> String
    func sendFireAndForget(_ command: String)
    func sendKeys(paneID: Int, data: Data)
    func newWindow() async throws -> TmuxWindow
    func killWindow(windowID: Int) async throws
    func renameWindow(windowID: Int, name: String) async throws
    func splitPane(paneID: Int, direction: SplitDirection) async throws
    func killPane(paneID: Int) async throws
    func resizePane(paneID: Int, width: Int, height: Int) async throws
    func resizeClient(width: Int, height: Int) async throws
}
```

Connection lifecycle:
1. `connect()` spawns `tmux -CC attach-session -t <name>` (or via SSH)
2. Starts background Task reading from PTY line-by-line
3. Waits for initial `%begin/%end` greeting
4. Sends `list-windows` + `list-panes` to build initial state
5. Sends `capture-pane -p -e` for each pane to populate initial content
6. Publishes `.connected` state

Read loop runs as a detached Task within the actor. All event handling is
actor-isolated.

### CommandQueue

FIFO queue matching `send()` calls to `%begin/%end` response blocks.

```swift
struct CommandQueue {
    mutating func enqueue(continuation: CheckedContinuation<String, Error>?)
    mutating func dequeue() -> CheckedContinuation<String, Error>?
}
```

`send()` writes the command to the PTY and enqueues an async continuation.
When `%end` arrives, accumulated response text is delivered to the next
continuation. Fire-and-forget commands enqueue `nil` to maintain FIFO ordering.

## Surface Management

### Inert Subprocess Pattern

Each pane gets a Ghostty surface backed by a do-nothing PTY:

```
/bin/sh -c 'stty raw -echo; exec cat > /dev/null'
```

This satisfies Ghostty's PTY requirement while discarding all input. All real
I/O flows through the control connection.

### Input Interception

Surfaces belonging to an attached tmux session intercept input at the
SurfaceView level:

```swift
if let tmuxPaneID = self.tmuxPaneID {
    tmuxControlClient.sendKeys(paneID: tmuxPaneID, data: keyData)
    return  // don't pass to ghostty_surface_key()
} else {
    ghostty_surface_key(surface, key_ev)  // normal path
}
```

### Resize Handling

When a split surface resizes:
1. Ghostty calculates new rows/cols via `ghostty_surface_set_size()`
2. We send `resize-pane -t %<paneID> -x <cols> -y <rows>` to tmux
3. Tmux adjusts and sends authoritative `%layout-change`
4. We update our split tree to match tmux's decision (never fight tmux)

### Initial Content Population

On attach, surfaces start empty. After creating surfaces for all panes:
1. Send `capture-pane -t %<paneID> -p -e` for each pane
2. Inject captured content via `ghostty_surface_inject_output()`
3. `%output` streaming takes over for live updates

## Session Model

### New Types

```swift
enum SessionMode {
    case managed
    case attached(TmuxAttachmentInfo)
}

struct TmuxAttachmentInfo: Codable {
    let sessionName: String
    let host: TmuxHost
    var connectionState: ConnectionState
}

enum TmuxHost: Codable, Hashable {
    case local
    case ssh(SSHHostInfo)
}

struct SSHHostInfo: Codable, Hashable {
    let user: String?
    let hostname: String
    let port: Int?
}
```

`Session` gains:
- `mode: SessionMode` — `.managed` or `.attached(...)`
- `controlClient: TmuxControlClient?` — non-nil for attached sessions

### Tab Lifecycle for Attached Sessions

Tabs are driven by the control client, not user action:
- `%window-add` -> create tab with pane surfaces
- `%window-close` -> remove tab
- `%window-renamed` -> update tab title

User-initiated window creation/closure goes through the control client
(`new-window`, `kill-window`), which triggers the same notification flow.

### Sidebar Integration

Attached sessions appear as regular sidebar items with:
- Display name (tmux session name, editable)
- Host provenance label (localhost vs SSH hostname)
- Connection state indicator (normal when connected, dimmed when disconnected)
- "Reconnect" action when disconnected

### Persistence

`WorkspaceLayout` gains:

```swift
struct WorkspaceLayout: Codable {
    let workspaceID: String
    let selectedTabIndex: Int
    let sessionType: SessionType
    let attachment: TmuxAttachmentInfo?  // nil for managed sessions
}
```

On relaunch:
1. Load layout, find entries with `attachment != nil`
2. Attempt `tmux -CC attach -t <name>` (or via SSH)
3. If successful: populate tabs from live state
4. If failed: show session in disconnected state

### Saved SSH Hosts

Persisted in `~/.fantastty/ssh-hosts.json`. Added automatically on first
remote attach. Editable/removable from the attach dialog.

## Attach UI Flow

### Entry Point

Sidebar "+" button offers "Attach to tmux session..." alongside existing
session creation options.

### Discovery Dialog

A sheet with a unified, filterable list:
- On open: lists local tmux sessions immediately
- For each saved SSH host: connects in parallel, lists remote sessions
- Each entry shows session name + hostname
- "Add SSH host..." for new remote hosts
- Double-click or "Attach" button to connect

### Connection Flow

1. User selects session -> dialog shows connecting state
2. `TmuxControlClient.connect()` spawns control mode process
3. Initial greeting + window/pane enumeration completes
4. Session appears in sidebar with populated tabs
5. Dialog dismisses

## Error Handling

| Scenario | Detection | Response |
|----------|-----------|----------|
| Session killed externally | `%exit` notification | Disconnected state, frozen surfaces |
| SSH connection drops | PTY EOF / read error | Disconnected state, manual reconnect |
| Tmux server crashes | PTY EOF | Disconnected state |
| Control connection hangs | Watchdog timer (no data for N seconds) | Tear down, disconnected state |
| Command timeout | `%begin` without `%end` within timeout | Cancel continuation with error |

### Reconnection

On user-triggered reconnect:
1. Spawn new `tmux -CC attach -t <name>`
2. Enumerate windows/panes
3. Reconcile with existing tabs (reuse for surviving windows, create/remove as needed)
4. Populate surfaces with `capture-pane` content

### Race Conditions

- Actor serial execution guarantees in-order notification processing
- `send()` throws if disconnected
- Each `%layout-change` fully replaces the split tree (no incremental state)
- Buffer `%output` for a pane until its surface is created

### Tmux Version Requirements

- Control mode (`-CC`): tmux 1.8+
- Passthrough for shell integration: tmux 3.3+
- Check version on connect, warn if too old

## Migration Roadmap

1. **Phase 1**: Build control mode for attaching to external sessions (this design)
2. **Phase 2**: Migrate existing managed sessions to use control mode
3. **Phase 3**: Remove old PTY-per-tab approach

The `SessionMode` distinction is temporary. Once control mode is proven
reliable, all sessions will use it. The only remaining distinction will be
origin: did Fantastty create the tmux session, or find an existing one.
