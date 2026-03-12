import Foundation

/// Typed events parsed from tmux control mode (`tmux -CC`) notifications.
enum TmuxEvent: Equatable {
    /// Output data for a pane: `%output %<paneID> <octal-encoded-data>`
    case output(paneID: Int, data: Data)
    /// A window was added: `%window-add @<windowID>`
    case windowAdd(windowID: Int)
    /// A window was closed: `%window-close @<windowID>`
    case windowClose(windowID: Int)
    /// A window was renamed: `%window-renamed @<windowID> <name>`
    case windowRenamed(windowID: Int, name: String)
    /// Layout changed for a window:
    /// `%layout-change @<windowID> <layout> <visibleLayout> <flags>`
    case layoutChange(windowID: Int, layout: String, visibleLayout: String, flags: String)
    /// The attached session changed: `%session-changed $<sessionID> <name>`
    case sessionChanged(sessionID: Int, name: String)
    /// The sessions list changed: `%sessions-changed`
    case sessionsChanged
    /// A client detached: `%client-detached <client>`
    case clientDetached(client: String)
    /// A client session changed:
    /// `%client-session-changed <client> $<sessionID> <name>`
    case clientSessionChanged(client: String, sessionID: Int, name: String)
    /// A config error occurred: `%config-error <error>`
    case configError(message: String)
    /// A paused pane was continued: `%continue %<paneID>`
    case continued(paneID: Int)
    /// A display message was emitted: `%message <message>`
    case message(message: String)
    /// A paste buffer changed: `%paste-buffer-changed <name>`
    case pasteBufferChanged(name: String)
    /// A paste buffer was deleted: `%paste-buffer-deleted <name>`
    case pasteBufferDeleted(name: String)
    /// A pane was paused: `%pause %<paneID>`
    case pause(paneID: Int)
    /// A pane's mode changed: `%pane-mode-changed %<paneID>`
    case paneModeChanged(paneID: Int)
    /// Current session renamed: `%session-renamed <name>`
    case sessionRenamed(name: String)
    /// Session active window changed:
    /// `%session-window-changed $<sessionID> @<windowID>`
    case sessionWindowChanged(sessionID: Int, windowID: Int)
    /// A subscription value changed:
    /// `%subscription-changed <name> $<sessionID> @<windowID> <windowIndex> %<paneID> ... : <value>`
    case subscriptionChanged(
        name: String,
        sessionID: Int,
        windowID: Int,
        windowIndex: Int,
        paneID: Int,
        value: String
    )
    /// Unlinked window added: `%unlinked-window-add @<windowID>`
    case unlinkedWindowAdd(windowID: Int)
    /// Unlinked window closed: `%unlinked-window-close @<windowID>`
    case unlinkedWindowClose(windowID: Int)
    /// Unlinked window renamed: `%unlinked-window-renamed @<windowID>`
    case unlinkedWindowRenamed(windowID: Int)
    /// Window active pane changed:
    /// `%window-pane-changed @<windowID> %<paneID>`
    case windowPaneChanged(windowID: Int, paneID: Int)
    /// Start of a command-response block: `%begin <timestamp> <id> <flags>`
    case beginBlock(id: Int, flags: Int)
    /// Successful end of a command-response block: `%end <timestamp> <id> <flags>`
    case endBlock(id: Int, flags: Int)
    /// Error end of a command-response block: `%error <timestamp> <id> <flags>`
    case errorBlock(id: Int, flags: Int)
    /// The control mode client is exiting: `%exit [reason]`
    case exit(reason: String?)
    /// An unrecognized `%`-prefixed notification.
    case unknown(String)
}
