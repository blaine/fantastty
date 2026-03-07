import XCTest
@testable import Fantastty

final class CommandQueueTests: XCTestCase {

    func testEnqueueDequeue() {
        var queue = CommandQueue()
        XCTAssertTrue(queue.isEmpty)

        queue.enqueue(nil)
        XCTAssertFalse(queue.isEmpty)

        let result = queue.dequeueRaw()
        XCTAssertNotNil(result)
        XCTAssertNil(result?.continuation)
        XCTAssertEqual(result?.text, "")
        XCTAssertTrue(queue.isEmpty)
    }

    func testFIFOOrdering() {
        var queue = CommandQueue()

        queue.enqueue(nil)
        queue.enqueue(nil)
        XCTAssertFalse(queue.isEmpty)

        queue.appendToCurrentResponse("first")
        _ = queue.dequeueRaw()
        XCTAssertFalse(queue.isEmpty)

        queue.appendToCurrentResponse("second")
        let result = queue.dequeueRaw()
        XCTAssertEqual(result?.text, "second")
        XCTAssertTrue(queue.isEmpty)
    }

    func testDequeueFromEmptyReturnsNil() {
        var queue = CommandQueue()
        let result = queue.dequeueRaw()
        XCTAssertNil(result)
    }

    func testAccumulateResponseText() {
        var queue = CommandQueue()
        queue.enqueue(nil)

        queue.appendToCurrentResponse("line1\n")
        queue.appendToCurrentResponse("line2\n")

        let result = queue.dequeueRaw()
        XCTAssertEqual(result?.text, "line1\nline2\n")
    }

    func testAppendToEmptyQueueIsNoOp() {
        var queue = CommandQueue()
        // Should not crash
        queue.appendToCurrentResponse("orphan text")
        XCTAssertTrue(queue.isEmpty)
    }

    func testMultipleEntriesAccumulateIndependently() {
        var queue = CommandQueue()

        queue.enqueue(nil)
        queue.enqueue(nil)

        queue.appendToCurrentResponse("for-first")
        let first = queue.dequeueRaw()
        XCTAssertEqual(first?.text, "for-first")

        queue.appendToCurrentResponse("for-second")
        let second = queue.dequeueRaw()
        XCTAssertEqual(second?.text, "for-second")

        XCTAssertTrue(queue.isEmpty)
    }
}
