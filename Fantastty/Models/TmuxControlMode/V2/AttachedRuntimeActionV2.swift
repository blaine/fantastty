import Foundation

struct AttachedWindowSnapshotV2: Equatable {
    let windowID: Int
    var title: String
    var windowIndex: Int?
    var isActive: Bool
}

enum AttachedRuntimeActionV2: Equatable {
    case upsertWindow(AttachedWindowSnapshotV2)
    case removeWindow(windowID: Int)
    case renameWindow(windowID: Int, title: String)
    case selectWindow(windowID: Int)
    case applyLayout(windowID: Int, layout: String, paneIDs: [Int])
    case setActivePane(windowID: Int, paneID: Int)
    case deliverPaneOutput(windowID: Int, paneID: Int, data: Data)
}
