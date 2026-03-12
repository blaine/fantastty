import XCTest
@testable import Fantastty

final class AttachedWindowRuntimeV2Tests: XCTestCase {
    func testApplyLayoutUpdatesPaneSetAndDropsStaleActivePane() {
        var runtime = AttachedWindowRuntimeV2(
            window: Fantastty.TmuxWindow(windowID: 1, name: "main", paneIDs: [7], windowIndex: 0, isActive: true)
        )
        _ = runtime.applyLayout("bb62,213x55,0,0,7")
        runtime.setActivePane(7)

        let paneIDs = runtime.applyLayout("bb62,213x55,0,0,9")

        XCTAssertEqual(paneIDs, [9])
        XCTAssertEqual(runtime.paneIDs, Set([9]))
        XCTAssertNil(runtime.activePaneID)
    }

    func testSetActivePaneOnlyAcceptsPaneInCurrentLayout() {
        var runtime = AttachedWindowRuntimeV2(
            window: Fantastty.TmuxWindow(windowID: 1, name: "main", paneIDs: [7], windowIndex: 0, isActive: true)
        )
        _ = runtime.applyLayout("bb62,213x55,0,0,7")

        runtime.setActivePane(9)

        XCTAssertNil(runtime.activePaneID)
    }
}
