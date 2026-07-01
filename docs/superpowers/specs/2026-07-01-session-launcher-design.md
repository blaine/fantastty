# Session Launcher Design

## Scope

Unify the workspace creation and session adoption panels into one launcher. This replaces the separate SSH, Sprite, and tmux attach sheets with a single location-first flow.

Sparkle updater UX is out of scope for this spec. Notes, tab thumbnails, sidebar rows, recovery views, and other session inspector surfaces are also out of scope.

## Current State

The app currently exposes several separate creation paths:

- `NewSessionMenu` and the sidebar footer provide menu actions.
- `SSHConnectionSheet` creates SSH or remote-engine workspaces.
- `SpriteConnectionSheet` creates or connects to Sprite workspaces.
- `TmuxAttachSheet` discovers and attaches local or remote tmux sessions.

These flows ask related questions in different orders. The unified launcher should make the domain model explicit: first choose where the session lives, then choose which session at that location Fantastty should open.

## Design Goals

- Make the primary question "Where is the session?" rather than "Which implementation path?"
- Treat new and existing sessions as choices in one list.
- Keep remote engine as an optional connection setting, not a peer mode.
- Do not store passwords, private keys, or other credentials.
- Keep the implementation small and aligned with current SwiftUI patterns.

## Launcher Model

The launcher is a single sheet titled "New Workspace".

The left rail is location-based:

- This Mac
- SSH host
- Sprite

Selecting a location changes the right pane. The right pane has two conceptual sections:

1. Connection details for the selected location.
2. A session list for that location.

The session list always starts with a `New session` row. Discovered existing sessions appear below it. Selecting `New session` creates a fresh session at the selected location. Selecting an existing row adopts that session.

The primary button reflects the selected row:

- `Create Workspace` for `New session`
- `Adopt Session` for an existing session

## Location Details

### This Mac

The local location has no connection fields.

Its session list contains:

- `New session`: create a normal local shell workspace.
- Existing local tmux sessions discovered from `TmuxManager`.

### SSH Host

The SSH location has connection fields:

- Host
- User
- Port
- `Use remote engine` checkbox

Remote engine stays in the connection section because it changes how Fantastty talks to the selected SSH target. It is not a separate session type.

Credentials stay outside the launcher. Fantastty should rely on SSH config, keys, agent, and system SSH prompts. Future UI can surface SSH config or agent hints, but the launcher must not become a credential store.

The SSH session list contains:

- `New session`: create a fresh remote workspace at the host.
- Existing remote sessions discovered at the host, including tmux sessions.

When `Use remote engine` is checked, `New session` creates a remote-engine workspace for the SSH host, and existing-session rows adopt through the remote-engine transport. When unchecked, `New session` creates a plain SSH workspace, and existing-session rows attach through tmux control over SSH.

### Sprite

The Sprite location has Sprite identity and discovery controls. The launcher should model Sprite as supporting both fresh session creation and adoption of discovered sessions.

The Sprite session list contains:

- `New session`: create or connect to a fresh Sprite session.
- Existing Sprite sessions discovered by `SpriteManager`.

Sprite discovery returns whichever existing Sprite sessions or environments `SpriteManager` can open. If there are no adoptable Sprite rows, the list still shows `New session` and an empty-state row for existing sessions.

## Entry Points

Visible "New Workspace" affordances should open the unified launcher.

Existing specialized commands should open the same launcher preselected to the relevant location:

- New SSH Workspace opens the launcher with `SSH host` selected.
- New Sprite Workspace opens the launcher with `Sprite` selected.
- Attach to tmux Session opens the launcher with `This Mac` selected and the existing-session list focused. The user can switch the location to `SSH host` or `Sprite` before attaching.

The direct local fast path remains available as a command-menu action for users who want an immediate local shell. It must not introduce a second panel.

## States

The launcher needs explicit states for each location:

- Empty discovered sessions: show `New session` and an empty-state row for existing sessions.
- Loading discovery: keep `New session` selectable and show progress in the existing-session area.
- Discovery failed: keep `New session` selectable and show the failure with a retry action.
- Invalid connection details: disable discovery and the primary action until the required fields are valid.
- Already attached session: show it disabled or omitted consistently with current tmux attach behavior.

## Components

The implementation should introduce a shared launcher view rather than expanding the existing sheets independently.

Recommended structure:

- `SessionLauncherSheet`: owns selection state and lays out the rail and detail pane.
- `SessionLauncherLocation`: enum for This Mac, SSH host, and Sprite.
- `SessionLauncherSelection`: model for `New session` or an existing discovered session.
- `SessionLauncherConnectionForm`: connection section for the selected location.
- `SessionLauncherSessionList`: shared list rendering `New session`, loading/error/empty state, and discovered sessions.

Existing pure parsing and discovery helpers from `SSHConnectionSheet`, `SpriteConnectionSheet`, and `TmuxAttachSheet` should be reused or moved into small testable helpers. Avoid broad rewrites of session creation internals.

## Testing

Unit tests should cover the decision logic, not rendered SwiftUI strings:

- SSH host parsing still normalizes user and port.
- Remote-engine checkbox chooses the remote-engine path for supported SSH actions.
- Selecting `New session` routes to the create action for each location.
- Selecting an existing tmux session routes to attach/adopt.
- Already-attached sessions are filtered or disabled consistently.
- Invalid connection details prevent discovery and primary action.

UI-level coverage stays light: a smoke test for the launcher model and focused tests for extracted helpers are enough for this pass.
