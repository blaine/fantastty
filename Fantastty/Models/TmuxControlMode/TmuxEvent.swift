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
    /// Layout changed for a window: `%layout-change @<windowID> <layout>`
    case layoutChange(windowID: Int, layout: String)
    /// The attached session changed: `%session-changed $<sessionID> <name>`
    case sessionChanged(sessionID: Int, name: String)
    /// The sessions list changed: `%sessions-changed`
    case sessionsChanged
    /// A pane's mode changed: `%pane-mode-changed %<paneID>`
    case paneModeChanged(paneID: Int)
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
