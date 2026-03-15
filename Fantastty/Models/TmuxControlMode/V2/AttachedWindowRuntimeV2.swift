import Foundation

struct AttachedWindowRuntimeV2 {
    private(set) var snapshot: AttachedWindowSnapshotV2
    private(set) var paneIDs: Set<Int> = []
    private(set) var activePaneID: Int?

    init(window: TmuxWindow) {
        snapshot = AttachedWindowSnapshotV2(
            windowID: window.windowID,
            title: window.name,
            windowIndex: window.windowIndex,
            isActive: window.isActive
        )
        paneIDs = window.paneIDs
    }

    mutating func applyLayout(_ layout: String) -> [Int] {
        let parsedPaneIDs = TmuxLayoutParser.parse(layout).allPaneIDs()
        paneIDs = Set(parsedPaneIDs)
        if let activePaneID, !paneIDs.contains(activePaneID) {
            self.activePaneID = nil
        }
        return parsedPaneIDs
    }

    mutating func rename(to title: String) {
        snapshot.title = title
    }

    mutating func setActivePane(_ paneID: Int) {
        guard paneIDs.contains(paneID) else { return }
        activePaneID = paneID
    }
}
