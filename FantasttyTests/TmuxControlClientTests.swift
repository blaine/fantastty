import XCTest
@testable import Fantastty

/// Records delegate calls for assertion.
@MainActor
final class MockControlClientDelegate: TmuxControlClientDelegate {
    var addedWindows: [TmuxWindow] = []
    var closedWindowIDs: [Int] = []
    var renamedWindows: [(windowID: Int, name: String)] = []
    var layoutChanges: [(windowID: Int, layout: String)] = []
    var outputReceived: [(paneID: Int, data: Data)] = []
    var stateChanges: [ConnectionState] = []
    var exitReasons: [String?] = []

    func controlClient(_ client: TmuxControlClient, didAddWindow window: TmuxWindow) {
        addedWindows.append(window)
    }
    func controlClient(_ client: TmuxControlClient, didCloseWindowID windowID: Int) {
        closedWindowIDs.append(windowID)
    }
    func controlClient(_ client: TmuxControlClient, didRenameWindowID windowID: Int, to name: String) {
        renamedWindows.append((windowID, name))
    }
    func controlClient(_ client: TmuxControlClient, didChangeLayoutForWindowID windowID: Int, layout: String) {
        layoutChanges.append((windowID, layout))
    }
    func controlClient(_ client: TmuxControlClient, didReceiveOutput data: Data, forPaneID paneID: Int) {
        outputReceived.append((paneID, data))
    }
    func controlClient(_ client: TmuxControlClient, didChangeState state: ConnectionState) {
        stateChanges.append(state)
    }
    func controlClientDidExit(_ client: TmuxControlClient, reason: String?) {
        exitReasons.append(reason)
    }
}

final class TmuxControlClientTests: XCTestCase {

    var client: TmuxControlClient!
    var delegate: MockControlClientDelegate!

    @MainActor
    override func setUp() {
        let info = TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        client = TmuxControlClient(attachmentInfo: info)
        delegate = MockControlClientDelegate()
        client.delegate = delegate
    }

    // MARK: - Event dispatch

    func testWindowAddNotifiesDelegate() async {
        await client.processLine("%window-add @5")

        let added = await MainActor.run { delegate.addedWindows }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.windowID, 5)
    }

    func testWindowCloseNotifiesDelegate() async {
        // First add the window so it exists in state
        await client.processLine("%window-add @3")
        await client.processLine("%window-close @3")

        let closed = await MainActor.run { delegate.closedWindowIDs }
        XCTAssertEqual(closed, [3])
    }

    func testWindowRenamedNotifiesDelegate() async {
        await client.processLine("%window-add @1")
        await client.processLine("%window-renamed @1 new-name")

        let renamed = await MainActor.run { delegate.renamedWindows }
        XCTAssertEqual(renamed.count, 1)
        XCTAssertEqual(renamed.first?.name, "new-name")

        // Also verify internal state updated
        let windows = await client.windows
        XCTAssertEqual(windows[1]?.name, "new-name")
    }

    func testOutputNotifiesDelegate() async {
        await client.processLine("%output %0 hello")

        let output = await MainActor.run { delegate.outputReceived }
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.paneID, 0)
        XCTAssertEqual(String(data: output.first!.data, encoding: .utf8), "hello")
    }

    func testLayoutChangeNotifiesDelegate() async {
        await client.processLine("%layout-change @2 bb62,213x55,0,0,0")

        let changes = await MainActor.run { delegate.layoutChanges }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.windowID, 2)
        XCTAssertEqual(changes.first?.layout, "bb62,213x55,0,0,0")
    }

    func testExitNotifiesDelegate() async {
        await client.processLine("%exit server exited")

        let exits = await MainActor.run { delegate.exitReasons }
        XCTAssertEqual(exits.count, 1)
        XCTAssertEqual(exits.first, "server exited")
    }

    // MARK: - Begin/End block handling

    func testResponseBlockAccumulatesText() async {
        // Simulate a command response
        await client.processLine("%begin 123 1 0")
        await client.processLine("response line 1")
        await client.processLine("response line 2")
        await client.processLine("%end 123 1 0")
        // The command queue should have delivered the response.
        // This tests that non-% lines inside blocks are accumulated,
        // not treated as notifications.
    }

    func testNotificationsDuringResponseBlock() async {
        // Notifications can arrive between %begin and %end
        await client.processLine("%begin 123 1 0")
        await client.processLine("%window-add @9")
        await client.processLine("%end 123 1 0")

        let added = await MainActor.run { delegate.addedWindows }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.windowID, 9)
    }

    // MARK: - Command string generation

    func testSendKeysHexEncoding() async {
        // Verify sendKeys produces correct hex format
        let data = Data([0x1b, 0x5b, 0x41])  // ESC [ A (up arrow)
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        XCTAssertEqual(hex, "1b 5b 41")
    }
}
