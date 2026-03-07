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
}
