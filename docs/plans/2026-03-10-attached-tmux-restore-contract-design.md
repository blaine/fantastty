# Attached Tmux Restore Contract Design

## Goal

Make workspace restore fully spec-driven for attached tmux control mode by enforcing one runtime contract:

- `1 workspace -> 1 tmux session`
- `1 terminal tab -> 1 tmux window`
- browser tabs are Fantastty-owned and always restorable

This removes legacy managed behavior and ad-hoc restore reconstruction.

## Approved Product Rules

1. Terminal tab order always mirrors live tmux window order.
2. Active terminal tab always mirrors live tmux active window.
3. Browser tabs restore even when tmux is unavailable.
4. `Create Shell` always creates canonical workspace tmux session and starts with exactly one window.
5. Closing attached terminal tabs always sends `tmux kill-window`; no local hide/detach path.

## Runtime Model

### Workspace State

Each local terminal workspace is always `.attached(TmuxAttachmentInfo)` and has:

- attachment identity (canonical session name + host)
- connection state (`connecting | connected | disconnected(reason)`)
- browser tab state (order + selected browser tab)
- zero or more live terminal tabs derived only from tmux windows

Terminal tabs are not authoritative persisted state.

### Restore State Machine

For each workspace:

1. Rehydrate metadata and browser tabs from persistence.
2. Attempt control-mode attach to workspace attachment.
3. If attach succeeds:
   - list windows from tmux
   - build terminal tabs strictly from tmux windows
   - order tabs by tmux window index/order
   - select tmux active window tab
4. If attach fails:
   - preserve workspace + browser tabs
   - set placeholder/backing missing state for terminal area
   - expose `Reattach` and `Create Shell`

No restore step should recreate prior terminal placeholders from saved layout.

## Creation and Recovery Flows

### New Workspace

1. Create attached workspace with canonical session name.
2. Connect in `.create` mode.
3. Ensure tmux session exists.
4. If no window exists, create one.
5. Render exactly one terminal tab bound to that window.

### Create Shell (from placeholder)

1. Reconfigure workspace to canonical attached info with `.create`.
2. Connect tmux control mode.
3. Ensure exactly one initial tmux window exists.
4. Render terminal tabs from live tmux state only.

### Reattach

1. Reconfigure workspace to persisted/canonical attached info with `.attach`.
2. Connect tmux control mode.
3. Render tabs from tmux windows.

## Persistence Contract

Persist:

- workspace metadata
- attachment info
- browser tabs + selected browser tab

Do not persist attached terminal tabs as replayable restore input.

On boot:

- migrate legacy managed records to attached metadata before restore
- ignore legacy terminal tab records as runtime authority

## Data and Control Ownership

- `TmuxControlClient`: protocol/transport correctness, event stream, command responses.
- `SessionManager`: workspace lifecycle and mapping tmux windows <-> terminal tabs.
- `TerminalTab`: terminal surface binding for a tmux window, or browser tab.

`SessionManager` must not invent terminal tabs when tmux state is unknown.

## Error Handling

- Attach/create failures must preserve root cause (`%error`, `%exit`, termination).
- Disconnected tmux never removes workspace object.
- Placeholder mode is terminal-only degradation; browser tabs remain usable.
- Any terminal action requiring live tmux must gate on attached connected state.

## Testing Requirements

1. Restore uses tmux window order for terminal tabs.
2. Restore uses tmux active window for selected terminal tab.
3. Browser tabs restore with tmux unavailable.
4. `Create Shell` yields exactly one tmux-backed terminal tab for new session.
5. Attached new tab maps to `new-window` and materializes from tmux event.
6. Attached close tab maps to `kill-window`.
7. No legacy managed runtime path remains reachable for local terminal workspaces.

## Non-Goals

- Supporting pre-3.6a tmux control semantics.
- Preserving legacy managed runtime behavior.
- Reconstructing stale terminal tab layouts disconnected from tmux.
