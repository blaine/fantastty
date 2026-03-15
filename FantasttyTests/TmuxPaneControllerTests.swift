import XCTest
@testable import Fantastty

final class TmuxPaneControllerTests: XCTestCase {

    // MARK: - Output Injection

    func testOutputDataIsInjectedIntoSurface() {
        var injectedData: [Data] = []
        let controller = TmuxPaneController(
            paneID: 7,
            injector: { data in injectedData.append(data); return true }
        )

        controller.deliver(Data("hello".utf8))

        XCTAssertEqual(injectedData.count, 1)
        XCTAssertEqual(String(data: injectedData[0], encoding: .utf8), "hello")
    }

    func testOutputBeforeSurfaceReadyIsBuffered() {
        let controller = TmuxPaneController(paneID: 7, injector: nil)

        controller.deliver(Data("early".utf8))
        controller.deliver(Data("data".utf8))

        XCTAssertEqual(controller.bufferedOutputCount, 2)
    }

    func testBufferedOutputFlushesWhenInjectorIsSet() {
        var injectedData: [Data] = []
        let controller = TmuxPaneController(paneID: 7, injector: nil)

        controller.deliver(Data("early".utf8))
        controller.deliver(Data("data".utf8))

        controller.setInjector { data in injectedData.append(data); return true }

        XCTAssertEqual(injectedData.count, 2)
        XCTAssertEqual(String(data: injectedData[0], encoding: .utf8), "early")
        XCTAssertEqual(String(data: injectedData[1], encoding: .utf8), "data")
        XCTAssertEqual(controller.bufferedOutputCount, 0)
    }

    func testNoOutputDeliveredAfterTeardown() {
        var injectedData: [Data] = []
        let controller = TmuxPaneController(
            paneID: 7,
            injector: { data in injectedData.append(data); return true }
        )

        controller.teardown()
        controller.deliver(Data("late".utf8))

        XCTAssertTrue(injectedData.isEmpty)
    }

    func testFailedInjectionBuffersData() {
        var attempts = 0
        let controller = TmuxPaneController(
            paneID: 7,
            injector: { _ in attempts += 1; return false }
        )

        controller.deliver(Data("fail".utf8))

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(controller.bufferedOutputCount, 1)
    }
}
