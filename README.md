# Fantastty

A macOS terminal app built on [Ghostty](https://ghostty.org) (libghostty) with workspace-based session management and persistent tmux-backed sessions.

## Download

Grab the latest signed and notarized DMG from [Releases](https://github.com/blaine/fantastty/releases).

Requires **macOS 15.0** (Sequoia) or later, Apple Silicon.

## Features

- **Workspaces** — Each sidebar item is an independent workspace with its own tabs, notes, and metadata. Auto-generated names (e.g., "bold-falcon") keep things identifiable.
- **Persistent sessions** — Workspaces are backed by tmux sessions that survive app restarts. Quit and relaunch — everything is exactly where you left it.
- **Tabs and splits** — Multiple tabs per workspace, each with its own tmux session. Split panes within tabs.
- **Notes panel** — Attach timestamped notes to any workspace, manually or via terminal escape sequences. Editable with revision history.
- **Workspace URLs** — Track ticket and PR URLs per workspace, settable from the UI or via shell escape sequences.
- **Workspace archiving** — Archive workspaces you're not actively using. Unarchive them later to pick up where you left off.
- **SSH sessions** — Connect to remote hosts with tmux persistence on both ends.
- **Attention indicators** — Background workspaces light up when a bell rings or a command finishes.
- **Shell integration** — Automatic zsh integration for pwd tracking through tmux, plus the `fantastty-note` command for adding notes from the terminal.

## Shell Integration

Fantastty includes a shell integration script that adds terminal commands:

```sh
source ~/.fantastty/shell-integration/fantastty.sh

# Add a note to the current workspace
fantastty-note "deploy finished"
fn "shorter alias works too"
```

Zsh integration (pwd tracking, escape sequence passthrough) is set up automatically when persistent sessions are enabled.

## Building from Source

### Prerequisites

- Xcode 16+
- [Zig](https://ziglang.org) (see `vendor/ghostty/build.zig.zon` for the required version)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (if regenerating the Xcode project)

### Build

```sh
# Clone with submodules
git clone --recursive https://github.com/blaine/fantastty.git
cd fantastty

# Build the GhosttyKit xcframework (takes a few minutes)
make xcframework

# Open in Xcode and build, or:
xcodebuild -scheme Fantastty -configuration Debug build
```

### Release Build

The `scripts/build-release.sh` script builds a signed, notarized DMG:

```sh
# Full build with notarization (requires Developer ID certificate + notarytool credentials)
./scripts/build-release.sh

# Local testing without notarization
./scripts/build-release.sh --skip-notarize
```

Output lands in `build/release/Fantastty.dmg`.

## Architecture

Fantastty is a SwiftUI app that uses Ghostty's libghostty as a static library for terminal rendering. Session persistence is handled through tmux:

- **SessionManager** orchestrates all workspaces, tabs, and tmux lifecycle
- **Session** represents a single workspace (sidebar item), keyed by a stable workspace ID
- **TerminalTab** represents a tab within a workspace, each backed by an independent tmux session
- **TmuxManager** handles tmux process creation, discovery, and cleanup

Workspace metadata (names, notes, URLs, tags) is persisted in `~/.fantastty/workspaces.json`. Layout state (sidebar order, tab order, selections) is saved to `~/.fantastty/layout.json` on quit and restored on launch.

## License

[MIT](LICENSE)
