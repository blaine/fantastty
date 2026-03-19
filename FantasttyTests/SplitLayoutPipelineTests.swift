import XCTest
import AppKit
@testable import Fantastty

/// Tests the full layout pipeline: tmux layout string → parse → ratio → pixel allocation.
///
/// The goal is to find container sizes where panes collapse to unusable heights/widths.
/// This simulates what SplitView does: apply ratio, subtract splitter, snap to cell grid.
final class SplitLayoutPipelineTests: XCTestCase {

    // MARK: - SplitView pixel math simulation

    /// Replicates SplitView.leftRect logic for the split-axis dimension.
    /// Returns (leftSize, rightSize) in points along the split axis.
    static func splitSizes(
        containerSize: CGFloat,
        ratio: CGFloat,
        splitterVisible: CGFloat = 1,
        cellSize: CGFloat = 1,
        minSize: CGFloat = 10
    ) -> (left: CGFloat, right: CGFloat) {
        // leftRect logic
        var leftSize = containerSize * ratio
        leftSize -= splitterVisible / 2
        if cellSize > 1 {
            leftSize -= leftSize.truncatingRemainder(dividingBy: cellSize)
        }
        // Min/max clamp (our fix)
        let maxLeft = containerSize - splitterVisible - minSize
        leftSize = min(max(leftSize, minSize), maxLeft)

        // rightRect logic: remaining space after left + splitter
        let rightSize = containerSize - leftSize - splitterVisible / 2
        // Note: rightRect doesn't subtract splitter/2 from left side, it adds it to origin
        // Actual: rightOrigin = leftSize + splitter/2, rightSize = containerSize - rightOrigin
        // So: rightSize = containerSize - leftSize - splitter/2

        return (leftSize, rightSize)
    }

    /// Given a SplitTree-style nested binary split (from TmuxLayoutMapper),
    /// compute the pixel sizes of all leaves along the split axis.
    static func leafPixelSizes(
        ratios: [Double],   // ratios at each level of the binary tree (outer → inner)
        containerSize: CGFloat,
        splitterVisible: CGFloat = 1,
        cellSize: CGFloat = 1,
        minSize: CGFloat = 10
    ) -> [CGFloat] {
        if ratios.isEmpty { return [containerSize] }

        var sizes: [CGFloat] = []
        var remaining = containerSize

        for (i, ratio) in ratios.enumerated() {
            let isLast = i == ratios.count - 1
            let (left, right) = splitSizes(
                containerSize: remaining,
                ratio: CGFloat(ratio),
                splitterVisible: splitterVisible,
                cellSize: cellSize,
                minSize: minSize
            )
            sizes.append(left)
            if isLast {
                sizes.append(right)
            } else {
                remaining = right
            }
        }
        return sizes
    }

    // MARK: - Ratio extraction from tmux layout

    /// Extract the chain of ratios that TmuxLayoutMapper.buildBinarySplit produces
    /// for a vertical or horizontal split with the given child sizes.
    static func extractRatios(childSizes: [Int], totalSize: Int) -> [Double] {
        guard childSizes.count >= 2 else { return [] }

        if childSizes.count == 2 {
            return [Double(childSizes[0]) / Double(totalSize)]
        }

        let firstSize = childSizes[0]
        let restSize = totalSize - firstSize
        let ratio = Double(firstSize) / Double(totalSize)
        let restRatios = extractRatios(
            childSizes: Array(childSizes.dropFirst()),
            totalSize: restSize
        )
        return [ratio] + restRatios
    }

    // MARK: - Tests

    /// Two equal vertical panes: sweep container heights and check no pane collapses.
    func testTwoEqualVerticalPanes_noCollapseAtAnyHeight() {
        let cellHeight: CGFloat = 17  // typical cell height
        let childHeights = [27, 27]   // tmux cell heights
        let totalHeight = 55
        let ratios = Self.extractRatios(childSizes: childHeights, totalSize: totalHeight)

        var failures: [(height: Int, sizes: [CGFloat])] = []

        // Sweep a range of container heights (400-1000 points)
        for containerHeight in 400...1000 {
            let sizes = Self.leafPixelSizes(
                ratios: ratios,
                containerSize: CGFloat(containerHeight),
                cellSize: cellHeight
            )
            let minPane = sizes.min() ?? 0
            if minPane < cellHeight {
                failures.append((containerHeight, sizes))
            }
        }

        if !failures.isEmpty {
            let sample = failures.prefix(5).map {
                "  height=\($0.height): panes=\($0.sizes.map { String(format: "%.1f", $0) })"
            }.joined(separator: "\n")
            XCTFail("Pane collapsed below cell height at \(failures.count) container heights:\n\(sample)")
        }
    }

    /// Two UNEQUAL vertical panes (like the user's screenshots: large top, small bottom).
    /// This is the most likely failure case.
    func testUnequalVerticalPanes_noCollapseAtAnyHeight() {
        let cellHeight: CGFloat = 17
        // Typical tmux split: top pane gets most of the space
        let childHeights = [40, 14]
        let totalHeight = 55
        let ratios = Self.extractRatios(childSizes: childHeights, totalSize: totalHeight)

        var failures: [(height: Int, sizes: [CGFloat])] = []

        for containerHeight in 200...1200 {
            let sizes = Self.leafPixelSizes(
                ratios: ratios,
                containerSize: CGFloat(containerHeight),
                cellSize: cellHeight
            )
            let minPane = sizes.min() ?? 0
            if minPane < cellHeight {
                failures.append((containerHeight, sizes))
            }
        }

        if !failures.isEmpty {
            let sample = failures.prefix(10).map {
                "  height=\($0.height): panes=\($0.sizes.map { String(format: "%.1f", $0) })"
            }.joined(separator: "\n")
            XCTFail("Pane collapsed below cell height at \(failures.count) container heights:\n\(sample)")
        }
    }

    /// Three vertical panes: the nested binary split makes this interesting.
    /// The bottom pane is most vulnerable due to cascading ratio application.
    func testThreeVerticalPanes_noCollapseAtAnyHeight() {
        let cellHeight: CGFloat = 17
        let childHeights = [18, 18, 18]
        let totalHeight = 55
        let ratios = Self.extractRatios(childSizes: childHeights, totalSize: totalHeight)

        var failures: [(height: Int, sizes: [CGFloat])] = []

        for containerHeight in 300...1200 {
            let sizes = Self.leafPixelSizes(
                ratios: ratios,
                containerSize: CGFloat(containerHeight),
                cellSize: cellHeight
            )
            let minPane = sizes.min() ?? 0
            if minPane < cellHeight {
                failures.append((containerHeight, sizes))
            }
        }

        if !failures.isEmpty {
            let sample = failures.prefix(10).map {
                "  height=\($0.height): panes=\($0.sizes.map { String(format: "%.1f", $0) })"
            }.joined(separator: "\n")
            XCTFail("Pane collapsed below cell height at \(failures.count) container heights:\n\(sample)")
        }
    }

    /// Test with actual tmux layout strings parsed end-to-end.
    func testParsedLayoutString_twoVerticalPanes() {
        // A typical two-pane vertical layout from tmux
        let layout = "bb62,213x55,0,0[213x40,0,0,0,213x14,0,41,1]"
        let parsed = TmuxLayoutParser.parse(layout)

        // Extract child sizes
        guard case .verticalSplit(let children, _, let totalHeight) = parsed else {
            return XCTFail("Expected vertical split, got \(parsed)")
        }
        let childHeights = children.map { $0.height }
        let ratios = Self.extractRatios(childSizes: childHeights, totalSize: totalHeight)

        let cellHeight: CGFloat = 17

        var failures: [(height: Int, sizes: [CGFloat])] = []

        for containerHeight in 200...1200 {
            let sizes = Self.leafPixelSizes(
                ratios: ratios,
                containerSize: CGFloat(containerHeight),
                cellSize: cellHeight
            )
            let minPane = sizes.min() ?? 0
            if minPane < cellHeight {
                failures.append((containerHeight, sizes))
            }
        }

        if !failures.isEmpty {
            let sample = failures.prefix(10).map {
                "  height=\($0.height): panes=\($0.sizes.map { String(format: "%.1f", $0) })"
            }.joined(separator: "\n")
            XCTFail("Pane collapsed below cell height at \(failures.count)/1001 container heights.\nRatios: \(ratios)\n\(sample)")
        }
    }

    /// Diagnostic test: print the exact pixel breakdown for a range of heights.
    /// This helps identify the pattern of problematic sizes.
    func testDiagnostic_printPixelBreakdownForVerticalSplit() {
        let cellHeight: CGFloat = 17
        let childHeights = [40, 14]
        let totalHeight = 55
        let ratios = Self.extractRatios(childSizes: childHeights, totalSize: totalHeight)

        var lines: [String] = []
        lines.append("Vertical split diagnostic (ratio: \(ratios))")
        lines.append("Cell height: \(cellHeight)pt, Splitter: 1pt visible")

        var problemCount = 0
        for containerHeight in 200...600 {
            let sizes = Self.leafPixelSizes(
                ratios: ratios,
                containerSize: CGFloat(containerHeight),
                cellSize: cellHeight
            )
            let topCells = Int(floor(sizes[0] / cellHeight))
            let bottomCells = Int(floor(sizes[1] / cellHeight))
            let marker = sizes[1] < cellHeight * 2 ? " *** PROBLEM" : ""
            if !marker.isEmpty || containerHeight % 50 == 0 {
                lines.append("  container=\(containerHeight)pt → top=\(String(format: "%.1f", sizes[0]))pt (\(topCells) cells), bottom=\(String(format: "%.1f", sizes[1]))pt (\(bottomCells) cells)\(marker)")
            }
            if !marker.isEmpty { problemCount += 1 }
        }
        lines.append("Problematic heights (<2 cells): \(problemCount)/401")
        // Uncomment to see diagnostic output:
        // XCTFail(lines.joined(separator: "\n"))
    }

    /// Test that the minSize clamp actually prevents collapse.
    func testMinSizeClampPreventsCollapse() {
        // With a very skewed ratio, verify the clamp works
        let (left, right) = Self.splitSizes(
            containerSize: 300,
            ratio: 0.99,
            splitterVisible: 1,
            cellSize: 17,
            minSize: 10
        )
        XCTAssertGreaterThanOrEqual(left, 10, "Left pane below minimum")
        XCTAssertGreaterThanOrEqual(right, 10, "Right pane below minimum")
    }

    // MARK: - Feedback loop simulation

    /// Simulates what tmux does when told a new window size:
    /// distributes rows proportionally, with 1-row separator between panes.
    static func tmuxDistribute(totalRows: Int, paneCount: Int) -> [Int] {
        guard paneCount > 0 else { return [] }
        let separators = paneCount - 1
        let usable = totalRows - separators
        guard usable > 0 else { return Array(repeating: 1, count: paneCount) }

        // Tmux distributes roughly equally, but we'll preserve original proportions
        let perPane = usable / paneCount
        let remainder = usable - perPane * paneCount
        var sizes = Array(repeating: perPane, count: paneCount)
        // Give remainder to first panes
        for i in 0..<remainder {
            sizes[i] += 1
        }
        return sizes
    }

    /// Simulates the full resize feedback loop:
    /// 1. Given container pixel height and cell height, apply layout ratios
    /// 2. Compute grid rows per pane from resulting pixel heights
    /// 3. Sum grid rows + separators = "reported" total rows
    /// 4. Simulate tmux redistributing those rows
    /// 5. Compute new ratios from tmux's distribution
    /// 6. Repeat
    ///
    /// Returns the sequence of (reportedRows, paneRowDistribution) at each iteration.
    static func simulateFeedbackLoop(
        containerHeight: CGFloat,
        initialPaneHeights: [Int],  // tmux cell heights
        initialTotalHeight: Int,
        cellHeight: CGFloat,
        splitterVisible: CGFloat = 1,
        maxIterations: Int = 20
    ) -> [(reportedRows: Int, paneRows: [Int], panePixels: [CGFloat])] {
        var history: [(reportedRows: Int, paneRows: [Int], panePixels: [CGFloat])] = []

        var currentPaneHeights = initialPaneHeights
        var currentTotalHeight = initialTotalHeight

        for _ in 0..<maxIterations {
            // Step 1: compute ratios from tmux pane sizes
            let ratios = extractRatios(childSizes: currentPaneHeights, totalSize: currentTotalHeight)

            // Step 2: compute pixel sizes using SplitView logic
            let pixelSizes = leafPixelSizes(
                ratios: ratios,
                containerSize: containerHeight,
                splitterVisible: splitterVisible,
                cellSize: cellHeight
            )

            // Step 3: compute grid rows per pane (what Ghostty surface reports)
            let gridRows = pixelSizes.map { max(Int(floor($0 / cellHeight)), 1) }

            // Step 4: sum for total reported size
            let separators = gridRows.count - 1
            let reportedRows = gridRows.reduce(0, +) + separators

            history.append((reportedRows, gridRows, pixelSizes))

            // Check for stability
            if history.count >= 2 {
                let prev = history[history.count - 2]
                if prev.paneRows == gridRows {
                    break  // Stable!
                }
            }

            // Step 5: tmux redistributes based on reportedRows
            // In reality, tmux preserves proportions from current layout
            // and adjusts. We'll approximate by keeping the same proportions.
            let totalPaneRows = gridRows.reduce(0, +)
            currentTotalHeight = reportedRows
            currentPaneHeights = gridRows.map { row in
                max(Int(Double(row) / Double(totalPaneRows) * Double(reportedRows - separators)), 1)
            }
            // Adjust last pane to absorb rounding
            let usedRows = currentPaneHeights.dropLast().reduce(0, +)
            currentPaneHeights[currentPaneHeights.count - 1] = reportedRows - separators - usedRows
        }

        return history
    }

    /// Test the feedback loop for stability across container heights.
    func testFeedbackLoop_twoVerticalPanes_stability() {
        let cellHeight: CGFloat = 17
        let initialPaneHeights = [27, 27]
        let initialTotalHeight = 55

        var unstable: [(containerH: Int, iterations: Int, lastRows: [Int])] = []

        for containerH in 200...800 {
            let history = Self.simulateFeedbackLoop(
                containerHeight: CGFloat(containerH),
                initialPaneHeights: initialPaneHeights,
                initialTotalHeight: initialTotalHeight,
                cellHeight: cellHeight
            )

            if history.count >= 20 {
                // Didn't converge
                let last = history.last!
                unstable.append((containerH, history.count, last.paneRows))
            }
        }

        if !unstable.isEmpty {
            let sample = unstable.prefix(10).map {
                "  container=\($0.containerH): \($0.iterations) iters, rows=\($0.lastRows)"
            }.joined(separator: "\n")
            XCTFail("Feedback loop didn't converge at \(unstable.count) container heights:\n\(sample)")
        }
    }

    /// Test that using container-derived grid size (contentSize) is stable.
    func testContentSizeDerived_isStable() {
        let cellHeight: CGFloat = 17
        let splitter: CGFloat = 1

        var unstable: [Int] = []

        for containerH in 200...800 {
            // contentSize approach: total rows from container, not from surface sums
            let totalRows = Int(floor(CGFloat(containerH) / cellHeight))
            // tmux distributes rows across 2 panes with 1-row separator
            let usable = totalRows - 1
            guard usable >= 2 else { continue }
            let topRows = usable / 2
            let bottomRows = usable - topRows

            // Apply these as ratio, compute pixel sizes
            let ratio = Double(topRows) / Double(totalRows)
            let sizes = Self.splitSizes(
                containerSize: CGFloat(containerH),
                ratio: CGFloat(ratio),
                splitterVisible: splitter,
                cellSize: cellHeight
            )

            // Recompute grid rows from pixel sizes
            let topGrid = Int(floor(sizes.left / cellHeight))
            let bottomGrid = Int(floor(sizes.right / cellHeight))
            let reportedTotal = topGrid + bottomGrid + 1

            // contentSize would report floor(containerH / cellHeight)
            let contentTotal = Int(floor(CGFloat(containerH) / cellHeight))

            // These should match (or be very close)
            if abs(reportedTotal - contentTotal) > 1 {
                unstable.append(containerH)
            }
        }

        if !unstable.isEmpty {
            XCTFail("contentSize diverged from surface sum at \(unstable.count) heights: \(unstable.prefix(10))")
        }
    }

    /// Diagnostic: show the feedback loop step-by-step for specific heights.
    func testFeedbackLoop_diagnostic() {
        let cellHeight: CGFloat = 17
        let initialPaneHeights = [27, 27]
        let initialTotalHeight = 55

        var lines: [String] = ["=== Feedback loop diagnostic ==="]

        // Test specific heights that might be problematic
        for containerH in [300, 350, 400, 450, 500, 550, 600] {
            let history = Self.simulateFeedbackLoop(
                containerHeight: CGFloat(containerH),
                initialPaneHeights: initialPaneHeights,
                initialTotalHeight: initialTotalHeight,
                cellHeight: cellHeight
            )

            lines.append("Container \(containerH)pt (\(history.count) iterations):")
            for (i, step) in history.enumerated() {
                let pxStr = step.panePixels.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                lines.append("  [\(i)] reported=\(step.reportedRows) rows, panes=\(step.paneRows) rows, px=[\(pxStr)]")
            }
        }

        XCTFail(lines.joined(separator: "\n"))
    }

    /// Sweep all cell sizes (common font heights) × container sizes.
    func testMultipleCellSizes_noCollapse() {
        let cellHeights: [CGFloat] = [13, 14, 15, 16, 17, 18, 19, 20, 22, 24]
        let childHeights = [27, 27]
        let totalHeight = 55
        let ratios = Self.extractRatios(childSizes: childHeights, totalSize: totalHeight)

        var allFailures: [(cellH: CGFloat, containerH: Int, sizes: [CGFloat])] = []

        for cellH in cellHeights {
            for containerH in 200...1000 {
                let sizes = Self.leafPixelSizes(
                    ratios: ratios,
                    containerSize: CGFloat(containerH),
                    cellSize: cellH
                )
                if let minPane = sizes.min(), minPane < cellH {
                    allFailures.append((cellH, containerH, sizes))
                }
            }
        }

        if !allFailures.isEmpty {
            let byCellSize = Dictionary(grouping: allFailures, by: { $0.cellH })
            var summary = "Failures by cell size:\n"
            for (cellH, failures) in byCellSize.sorted(by: { $0.key < $1.key }) {
                summary += "  cellH=\(cellH): \(failures.count) failures\n"
            }
            XCTFail(summary)
        }
    }
}
