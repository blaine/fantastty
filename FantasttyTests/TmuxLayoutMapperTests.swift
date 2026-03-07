import XCTest
import AppKit
@testable import Fantastty

/// Minimal NSView subclass satisfying SplitTree's generic constraints.
final class MockSplitView: NSView, Codable, Identifiable {
    let paneID: Int
    var id: Int { paneID }

    init(paneID: Int) {
        self.paneID = paneID
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Codable
    enum CodingKeys: CodingKey { case paneID }
    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(paneID: try c.decode(Int.self, forKey: .paneID))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paneID, forKey: .paneID)
    }

    // Equatable (for test assertions)
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MockSplitView else { return false }
        return paneID == other.paneID
    }
}

final class TmuxLayoutMapperTests: XCTestCase {

    func makeSurface(paneID: Int) -> MockSplitView {
        MockSplitView(paneID: paneID)
    }

    // MARK: - Single pane

    func testSinglePane() {
        let layout = TmuxLayoutNode.leaf(paneID: 0, width: 200, height: 50)
        let node = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)
        guard case .leaf(let view) = node else {
            return XCTFail("Expected leaf")
        }
        XCTAssertEqual(view.paneID, 0)
    }

    // MARK: - Two-way split

    func testTwoWayHorizontalSplit() {
        let layout = TmuxLayoutNode.horizontalSplit(children: [
            .leaf(paneID: 0, width: 100, height: 50),
            .leaf(paneID: 1, width: 100, height: 50),
        ], width: 200, height: 50)
        let node = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)
        guard case .split(let split) = node else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(split.direction, .horizontal)
        XCTAssertEqual(split.ratio, 0.5, accuracy: 0.01)
        guard case .leaf(let left) = split.left else { return XCTFail("Expected leaf") }
        guard case .leaf(let right) = split.right else { return XCTFail("Expected leaf") }
        XCTAssertEqual(left.paneID, 0)
        XCTAssertEqual(right.paneID, 1)
    }

    func testTwoWayVerticalSplit() {
        let layout = TmuxLayoutNode.verticalSplit(children: [
            .leaf(paneID: 0, width: 200, height: 25),
            .leaf(paneID: 1, width: 200, height: 25),
        ], width: 200, height: 50)
        let node = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)
        guard case .split(let split) = node else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(split.direction, .vertical)
        XCTAssertEqual(split.ratio, 0.5, accuracy: 0.01)
    }

    // MARK: - Three-way split becomes nested binary

    func testThreeWayHorizontalSplit() {
        let layout = TmuxLayoutNode.horizontalSplit(children: [
            .leaf(paneID: 0, width: 100, height: 50),
            .leaf(paneID: 1, width: 100, height: 50),
            .leaf(paneID: 2, width: 100, height: 50),
        ], width: 300, height: 50)
        let node = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)

        // Should be: split(pane-0, split(pane-1, pane-2))
        guard case .split(let outer) = node else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(outer.direction, .horizontal)
        XCTAssertEqual(outer.ratio, 1.0 / 3.0, accuracy: 0.01)

        guard case .leaf(let left) = outer.left else { return XCTFail("Expected leaf") }
        XCTAssertEqual(left.paneID, 0)

        guard case .split(let inner) = outer.right else {
            return XCTFail("Expected inner split")
        }
        XCTAssertEqual(inner.ratio, 0.5, accuracy: 0.01)

        guard case .leaf(let innerLeft) = inner.left else { return XCTFail("Expected leaf") }
        guard case .leaf(let innerRight) = inner.right else { return XCTFail("Expected leaf") }
        XCTAssertEqual(innerLeft.paneID, 1)
        XCTAssertEqual(innerRight.paneID, 2)
    }

    // MARK: - Unequal ratios

    func testUnequalRatio() {
        let layout = TmuxLayoutNode.horizontalSplit(children: [
            .leaf(paneID: 0, width: 150, height: 50),
            .leaf(paneID: 1, width: 50, height: 50),
        ], width: 200, height: 50)
        let node = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)
        guard case .split(let split) = node else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(split.ratio, 0.75, accuracy: 0.01)
    }

    // MARK: - Nested splits

    func testNestedHorizontalThenVertical() {
        let layout = TmuxLayoutNode.horizontalSplit(children: [
            .leaf(paneID: 0, width: 100, height: 50),
            .verticalSplit(children: [
                .leaf(paneID: 1, width: 100, height: 25),
                .leaf(paneID: 2, width: 100, height: 25),
            ], width: 100, height: 50),
        ], width: 200, height: 50)
        let node = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)

        guard case .split(let outer) = node else { return XCTFail("Expected split") }
        XCTAssertEqual(outer.direction, .horizontal)

        guard case .leaf(let left) = outer.left else { return XCTFail("Expected leaf") }
        XCTAssertEqual(left.paneID, 0)

        guard case .split(let inner) = outer.right else { return XCTFail("Expected split") }
        XCTAssertEqual(inner.direction, .vertical)
    }

    // MARK: - Four-way split

    func testFourWayNestedBinary() {
        let layout = TmuxLayoutNode.horizontalSplit(children: [
            .leaf(paneID: 0, width: 50, height: 50),
            .leaf(paneID: 1, width: 50, height: 50),
            .leaf(paneID: 2, width: 50, height: 50),
            .leaf(paneID: 3, width: 50, height: 50),
        ], width: 200, height: 50)
        let node = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)

        // Should be: split(0, split(1, split(2, 3)))
        guard case .split(let s1) = node else { return XCTFail("Expected split") }
        XCTAssertEqual(s1.ratio, 0.25, accuracy: 0.01)
        guard case .split(let s2) = s1.right else { return XCTFail("Expected split") }
        XCTAssertEqual(s2.ratio, 1.0 / 3.0, accuracy: 0.01)
        guard case .split(let s3) = s2.right else { return XCTFail("Expected split") }
        XCTAssertEqual(s3.ratio, 0.5, accuracy: 0.01)
    }
}
