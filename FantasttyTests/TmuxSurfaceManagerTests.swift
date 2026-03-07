import XCTest
@testable import Fantastty

final class MockSurface: Equatable {
    let paneID: Int
    var injectedData: [Data] = []
    var destroyed = false

    init(paneID: Int) { self.paneID = paneID }

    static func == (lhs: MockSurface, rhs: MockSurface) -> Bool {
        lhs === rhs
    }
}

final class MockSurfaceProvider: TmuxSurfaceProviding {
    var createdSurfaces: [Int: MockSurface] = [:]

    func createInertSurface(paneID: Int) -> MockSurface {
        let s = MockSurface(paneID: paneID)
        createdSurfaces[paneID] = s
        return s
    }
    func destroySurface(_ surface: MockSurface) {
        surface.destroyed = true
    }
    func injectOutput(_ surface: MockSurface, data: Data) {
        surface.injectedData.append(data)
    }
}

final class TmuxSurfaceManagerTests: XCTestCase {

    func testCreateSurface() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        let surface = manager.createSurface(paneID: 5)
        XCTAssertEqual(surface.paneID, 5)
        XCTAssertEqual(manager.surface(forPaneID: 5)?.paneID, 5)
    }

    func testRemoveSurface() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        let surface = manager.createSurface(paneID: 3)
        let removed = manager.removeSurface(paneID: 3)
        XCTAssertTrue(surface === removed)
        XCTAssertNil(manager.surface(forPaneID: 3))
    }

    func testRemoveNonexistentPaneReturnsNil() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        XCTAssertNil(manager.removeSurface(paneID: 99))
    }

    func testInjectOutput() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        _ = manager.createSurface(paneID: 0)
        let testData = Data("hello".utf8)
        manager.injectOutput(paneID: 0, data: testData)

        let surface = provider.createdSurfaces[0]!
        XCTAssertEqual(surface.injectedData.count, 1)
        XCTAssertEqual(surface.injectedData.first, testData)
    }

    func testInjectOutputToUnknownPaneIsNoOp() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        // Should not crash
        manager.injectOutput(paneID: 99, data: Data("hello".utf8))
    }

    func testRemoveAll() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        _ = manager.createSurface(paneID: 0)
        _ = manager.createSurface(paneID: 1)
        _ = manager.createSurface(paneID: 2)

        let removed = manager.removeAll()
        XCTAssertEqual(removed.count, 3)
        XCTAssertNil(manager.surface(forPaneID: 0))
        XCTAssertNil(manager.surface(forPaneID: 1))
        XCTAssertNil(manager.surface(forPaneID: 2))
    }

    func testPaneIDsTracked() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        _ = manager.createSurface(paneID: 5)
        _ = manager.createSurface(paneID: 10)

        XCTAssertEqual(Set(manager.paneIDs), Set([5, 10]))
    }
}
