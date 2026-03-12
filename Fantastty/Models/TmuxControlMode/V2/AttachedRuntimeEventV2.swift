import Foundation

enum AttachedRuntimeEventV2 {
    case windowAdded(TmuxWindow)
    case windowClosed(windowID: Int)
    case windowRenamed(windowID: Int, title: String)
    case activeWindowChanged(windowID: Int)
    case layoutChanged(windowID: Int, layout: String)
    case activePaneChanged(windowID: Int, paneID: Int)
    case paneOutput(paneID: Int, data: Data)
    case clientExited
}
