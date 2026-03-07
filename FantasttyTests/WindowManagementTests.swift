import XCTest
@testable import Fantastty

final class MockTmuxCommandSender: TmuxCommandSending {
    var newWindowCalls = 0
    var killedWindowIDs: [Int] = []
    var renamedWindows: [(windowID: Int, name: String)] = []
    var splitPaneCalls: [(paneID: Int, horizontal: Bool)] = []
    var killedPaneIDs: [Int] = []

    func newWindow() async throws -> String {
        newWindowCalls += 1
        return ""
    }
    func killWindow(windowID: Int) async throws {
        killedWindowIDs.append(windowID)
    }
    func renameWindow(windowID: Int, name: String) async throws {
        renamedWindows.append((windowID, name))
    }
    func splitPane(paneID: Int, horizontal: Bool) async throws {
        splitPaneCalls.append((paneID, horizontal))
    }
    func killPane(paneID: Int) async throws {
        killedPaneIDs.append(paneID)
    }
}

final class WindowManagementTests: XCTestCase {

    func testCreateTabOnAttachedSessionSendsNewWindow() async throws {
        let mock = MockTmuxCommandSender()
        _ = try await mock.newWindow()
        XCTAssertEqual(mock.newWindowCalls, 1)
    }

    func testCloseTabOnAttachedSessionSendsKillWindow() async throws {
        let mock = MockTmuxCommandSender()
        let windowID = 5
        try await mock.killWindow(windowID: windowID)
        XCTAssertEqual(mock.killedWindowIDs, [5])
    }

    func testSplitOnAttachedSessionSendsSplitPane() async throws {
        let mock = MockTmuxCommandSender()
        try await mock.splitPane(paneID: 3, horizontal: true)
        XCTAssertEqual(mock.splitPaneCalls.count, 1)
        XCTAssertEqual(mock.splitPaneCalls.first?.paneID, 3)
        XCTAssertTrue(mock.splitPaneCalls.first?.horizontal ?? false)
    }

    func testRenameWindowOnAttachedSession() async throws {
        let mock = MockTmuxCommandSender()
        try await mock.renameWindow(windowID: 2, name: "new-name")
        XCTAssertEqual(mock.renamedWindows.count, 1)
        XCTAssertEqual(mock.renamedWindows.first?.name, "new-name")
    }

    func testClosePaneOnAttachedSession() async throws {
        let mock = MockTmuxCommandSender()
        try await mock.killPane(paneID: 7)
        XCTAssertEqual(mock.killedPaneIDs, [7])
    }
}
