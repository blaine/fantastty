import XCTest
@testable import Fantastty
import GhosttyKit

@MainActor
private enum TmuxWindowControllerTestSupport {
    static let ghosttyApp = Fantastty.Ghostty.App()
}

final class TmuxWindowControllerTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeController(
        windowID: Int = 1,
        title: String = "main",
        windowIndex: Int = 0
    ) -> TmuxWindowController {
        let app = TmuxWindowControllerTestSupport.ghosttyApp.app!
        return TmuxWindowController(
            windowID: windowID,
            title: title,
            windowIndex: windowIndex,
            surfaceFactory: { paneID in
                let surface = Ghostty.SurfaceView(app, baseConfig: nil)
                surface.tmuxPaneID = paneID
                return surface
            }
        )
    }

    // MARK: - Layout Contracts

    @MainActor
    func testLayoutProducesCorrectSplitTreeShape() {
        let controller = makeController()
        controller.applyLayout("bb62,213x55,0,0,7")

        XCTAssertEqual(controller.paneControllers.count, 1)
        XCTAssertNotNil(controller.paneControllers[7])
        XCTAssertEqual(controller.tab.surfaceTree?.root?.leaves().count, 1)
    }

    @MainActor
    func testLayoutWithSplitCreatesMultiplePaneControllers() {
        let controller = makeController()
        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")

        XCTAssertEqual(controller.paneControllers.count, 2)
        XCTAssertNotNil(controller.paneControllers[7])
        XCTAssertNotNil(controller.paneControllers[9])
        XCTAssertEqual(controller.tab.surfaceTree?.root?.leaves().count, 2)
    }

    @MainActor
    func testLayoutChangePreservesExistingPaneControllers() {
        let controller = makeController()
        controller.applyLayout("bb62,213x55,0,0,7")
        let originalController = controller.paneControllers[7]

        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")

        XCTAssertTrue(controller.paneControllers[7] === originalController)
        XCTAssertNotNil(controller.paneControllers[9])
    }

    @MainActor
    func testLayoutChangeDestroysRemovedPaneControllers() {
        let controller = makeController()
        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")
        XCTAssertEqual(controller.paneControllers.count, 2)

        controller.applyLayout("bb62,213x55,0,0,7")

        XCTAssertEqual(controller.paneControllers.count, 1)
        XCTAssertNil(controller.paneControllers[9])
    }

    // MARK: - Output Routing

    @MainActor
    func testOutputRoutedToCorrectPane() {
        var injected: [(paneID: Int, data: Data)] = []
        let app = TmuxWindowControllerTestSupport.ghosttyApp.app!
        let controller = TmuxWindowController(
            windowID: 1, title: "main", windowIndex: 0,
            surfaceFactory: { paneID in
                let surface = Ghostty.SurfaceView(app, baseConfig: nil)
                surface.tmuxPaneID = paneID
                return surface
            },
            paneInjectorFactory: { paneID in
                return { data in injected.append((paneID, data)); return true }
            }
        )
        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")

        controller.deliverOutput(paneID: 7, data: Data("hello".utf8))
        controller.deliverOutput(paneID: 9, data: Data("world".utf8))

        XCTAssertEqual(injected.count, 2)
        XCTAssertEqual(injected[0].paneID, 7)
        XCTAssertEqual(injected[1].paneID, 9)
    }

    @MainActor
    func testOutputForUnknownPaneIsBufferedThenFlushedOnLayout() {
        var injected: [Data] = []
        let app = TmuxWindowControllerTestSupport.ghosttyApp.app!
        let controller = TmuxWindowController(
            windowID: 1, title: "main", windowIndex: 0,
            surfaceFactory: { paneID in
                let surface = Ghostty.SurfaceView(app, baseConfig: nil)
                surface.tmuxPaneID = paneID
                return surface
            },
            paneInjectorFactory: { _ in
                return { data in injected.append(data); return true }
            }
        )

        // Output arrives before any layout
        controller.deliverOutput(paneID: 7, data: Data("early".utf8))
        XCTAssertTrue(injected.isEmpty)
        XCTAssertTrue(controller.paneControllers.isEmpty)

        // Layout arrives — buffered output should flush
        controller.applyLayout("bb62,213x55,0,0,7")

        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(String(data: injected[0], encoding: .utf8), "early")
    }

    @MainActor
    func testBootstrapTimeoutWaitsForLayoutBeforeContinuingPanes() async {
        let controller = makeController()
        var callbackPaneIDs: [[Int]] = []
        controller.onBootstrapReady = { [weak controller] in
            callbackPaneIDs.append(controller?.paneControllers.keys.sorted() ?? [])
        }

        controller.startBootstrapTimeout(seconds: 0)
        await Task.yield()

        XCTAssertTrue(callbackPaneIDs.isEmpty)

        controller.applyLayout("bb62,213x55,0,0,7")
        await Task.yield()

        XCTAssertEqual(callbackPaneIDs, [[7]])
    }

    // MARK: - Teardown

    @MainActor
    func testTeardownClearsAllPaneControllers() {
        let controller = makeController()
        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")
        XCTAssertEqual(controller.paneControllers.count, 2)

        controller.teardown()

        XCTAssertTrue(controller.paneControllers.isEmpty)
    }
}
