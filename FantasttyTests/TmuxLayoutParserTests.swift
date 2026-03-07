import XCTest
@testable import Fantastty

final class TmuxLayoutParserTests: XCTestCase {

    // MARK: - Single pane

    func testSinglePane() {
        let layout = "bb62,213x55,0,0,0"
        let node = TmuxLayoutParser.parse(layout)

        XCTAssertEqual(node, .leaf(paneID: 0, width: 213, height: 55))
        XCTAssertEqual(node.width, 213)
        XCTAssertEqual(node.height, 55)
        XCTAssertEqual(node.allPaneIDs(), [0])
    }

    // MARK: - Horizontal split (left-right, curly braces)

    func testHorizontalSplitTwoPanes() {
        // Two panes side by side: 100+100 = 200 wide (plus 1 separator not in dimensions)
        let layout = "1234,200x50,0,0{100x50,0,0,0,100x50,101,0,1}"
        let node = TmuxLayoutParser.parse(layout)

        guard case .horizontalSplit(let children, let w, let h) = node else {
            XCTFail("Expected horizontal split, got \(node)")
            return
        }

        XCTAssertEqual(w, 200)
        XCTAssertEqual(h, 50)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0], .leaf(paneID: 0, width: 100, height: 50))
        XCTAssertEqual(children[1], .leaf(paneID: 1, width: 100, height: 50))
    }

    // MARK: - Vertical split (top-bottom, square brackets)

    func testVerticalSplitTwoPanes() {
        // Two panes stacked: 25+24 = 49 high (plus 1 separator)
        let layout = "abcd,200x50,0,0[200x25,0,0,0,200x24,0,26,1]"
        let node = TmuxLayoutParser.parse(layout)

        guard case .verticalSplit(let children, let w, let h) = node else {
            XCTFail("Expected vertical split, got \(node)")
            return
        }

        XCTAssertEqual(w, 200)
        XCTAssertEqual(h, 50)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0], .leaf(paneID: 0, width: 200, height: 25))
        XCTAssertEqual(children[1], .leaf(paneID: 1, width: 200, height: 24))
    }

    // MARK: - Three-way horizontal split

    func testThreeWayHorizontalSplit() {
        // Three panes side by side: 66+66+66 = 198 (plus separators)
        let layout = "cafe,200x50,0,0{66x50,0,0,5,66x50,67,0,6,66x50,134,0,7}"
        let node = TmuxLayoutParser.parse(layout)

        guard case .horizontalSplit(let children, let w, let h) = node else {
            XCTFail("Expected horizontal split, got \(node)")
            return
        }

        XCTAssertEqual(w, 200)
        XCTAssertEqual(h, 50)
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(children[0], .leaf(paneID: 5, width: 66, height: 50))
        XCTAssertEqual(children[1], .leaf(paneID: 6, width: 66, height: 50))
        XCTAssertEqual(children[2], .leaf(paneID: 7, width: 66, height: 50))
    }

    // MARK: - Nested splits

    func testNestedSplits() {
        // Horizontal split: left pane 0, right side is a vertical split of panes 1 and 2
        let layout = "d00d,200x50,0,0{100x50,0,0,0,100x50,101,0[100x25,101,0,1,100x24,101,26,2]}"
        let node = TmuxLayoutParser.parse(layout)

        guard case .horizontalSplit(let children, let w, let h) = node else {
            XCTFail("Expected horizontal split, got \(node)")
            return
        }

        XCTAssertEqual(w, 200)
        XCTAssertEqual(h, 50)
        XCTAssertEqual(children.count, 2)

        // First child is a leaf
        XCTAssertEqual(children[0], .leaf(paneID: 0, width: 100, height: 50))

        // Second child is a vertical split
        guard case .verticalSplit(let innerChildren, let iw, let ih) = children[1] else {
            XCTFail("Expected vertical split for second child, got \(children[1])")
            return
        }

        XCTAssertEqual(iw, 100)
        XCTAssertEqual(ih, 50)
        XCTAssertEqual(innerChildren.count, 2)
        XCTAssertEqual(innerChildren[0], .leaf(paneID: 1, width: 100, height: 25))
        XCTAssertEqual(innerChildren[1], .leaf(paneID: 2, width: 100, height: 24))
    }

    // MARK: - allPaneIDs on complex layout

    func testAllPaneIDs() {
        // Three-level nesting: horizontal { leaf, vertical [ leaf, horizontal { leaf, leaf } ] }
        let layout = "beef,300x60,0,0{150x60,0,0,10,150x60,151,0[150x30,151,0,20,150x29,151,31{75x29,151,31,30,74x29,227,31,31}]}"
        let node = TmuxLayoutParser.parse(layout)

        let paneIDs = node.allPaneIDs()
        XCTAssertEqual(paneIDs, [10, 20, 30, 31])

        // Also verify the top-level dimensions
        XCTAssertEqual(node.width, 300)
        XCTAssertEqual(node.height, 60)

        // Verify the structure: horizontal split at top level
        guard case .horizontalSplit(let topChildren, _, _) = node else {
            XCTFail("Expected horizontal split at top level")
            return
        }
        XCTAssertEqual(topChildren.count, 2)

        // First child is leaf pane 10
        XCTAssertEqual(topChildren[0], .leaf(paneID: 10, width: 150, height: 60))

        // Second child is vertical split with pane 20 and nested horizontal
        guard case .verticalSplit(let midChildren, _, _) = topChildren[1] else {
            XCTFail("Expected vertical split as second child")
            return
        }
        XCTAssertEqual(midChildren.count, 2)
        XCTAssertEqual(midChildren[0], .leaf(paneID: 20, width: 150, height: 30))

        // The bottom of the vertical split is a horizontal split with panes 30 and 31
        guard case .horizontalSplit(let bottomChildren, _, _) = midChildren[1] else {
            XCTFail("Expected horizontal split at bottom level")
            return
        }
        XCTAssertEqual(bottomChildren.count, 2)
        XCTAssertEqual(bottomChildren[0], .leaf(paneID: 30, width: 75, height: 29))
        XCTAssertEqual(bottomChildren[1], .leaf(paneID: 31, width: 74, height: 29))
    }

    // MARK: - Width and height computed properties

    func testWidthHeightComputedProperties() {
        let leaf = TmuxLayoutNode.leaf(paneID: 0, width: 80, height: 24)
        XCTAssertEqual(leaf.width, 80)
        XCTAssertEqual(leaf.height, 24)

        let hsplit = TmuxLayoutNode.horizontalSplit(
            children: [leaf],
            width: 160,
            height: 48
        )
        XCTAssertEqual(hsplit.width, 160)
        XCTAssertEqual(hsplit.height, 48)

        let vsplit = TmuxLayoutNode.verticalSplit(
            children: [leaf],
            width: 120,
            height: 36
        )
        XCTAssertEqual(vsplit.width, 120)
        XCTAssertEqual(vsplit.height, 36)
    }
}
