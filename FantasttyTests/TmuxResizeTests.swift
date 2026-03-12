import XCTest
@testable import Fantastty

final class TmuxResizeTests: XCTestCase {

    func testResizeCommandFormat() {
        let paneID = 3
        let cols = 120
        let rows = 40
        let command = "resize-pane -t %\(paneID) -x \(cols) -y \(rows)"
        XCTAssertEqual(command, "resize-pane -t %3 -x 120 -y 40")
    }

    func testResizeCommandWithLargePane() {
        let paneID = 255
        let cols = 300
        let rows = 80
        let command = "resize-pane -t %\(paneID) -x \(cols) -y \(rows)"
        XCTAssertEqual(command, "resize-pane -t %255 -x 300 -y 80")
    }

    func testResizeCommandWithZeroIsValid() {
        let paneID = 0
        let cols = 1
        let rows = 1
        let command = "resize-pane -t %\(paneID) -x \(cols) -y \(rows)"
        XCTAssertEqual(command, "resize-pane -t %0 -x 1 -y 1")
    }

    func testRefreshClientSizeCommandForAttachedWindow() {
        let command = TmuxControlClient.clientSizeCommand(windowID: 9, width: 132, height: 38)
        XCTAssertEqual(command, "refresh-client -C @9:132x38")
    }

    func testRefreshClientSizeCommandForWholeClient() {
        let command = TmuxControlClient.clientSizeCommand(windowID: nil, width: 120, height: 40)
        XCTAssertEqual(command, "refresh-client -C 120x40")
    }
}
