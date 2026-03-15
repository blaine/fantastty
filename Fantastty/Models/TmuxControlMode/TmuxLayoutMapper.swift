import Foundation
import AppKit

struct TmuxLayoutMapper {

    static func mapToSplitTree<V: NSView & Codable & Identifiable>(
        _ node: TmuxLayoutNode,
        surfaceForPane: (Int) -> V
    ) -> SplitTree<V>.Node {
        switch node {
        case .leaf(let paneID, _, _):
            return .leaf(view: surfaceForPane(paneID))

        case .horizontalSplit(let children, let totalWidth, _):
            return buildBinarySplit(
                children: children,
                direction: .horizontal,
                totalSize: totalWidth,
                sizeOf: { $0.width },
                surfaceForPane: surfaceForPane
            )

        case .verticalSplit(let children, _, let totalHeight):
            return buildBinarySplit(
                children: children,
                direction: .vertical,
                totalSize: totalHeight,
                sizeOf: { $0.height },
                surfaceForPane: surfaceForPane
            )
        }
    }

    private static func buildBinarySplit<V: NSView & Codable & Identifiable>(
        children: [TmuxLayoutNode],
        direction: SplitTree<V>.Direction,
        totalSize: Int,
        sizeOf: (TmuxLayoutNode) -> Int,
        surfaceForPane: (Int) -> V
    ) -> SplitTree<V>.Node {
        assert(children.count >= 2)

        if children.count == 2 {
            let left = mapToSplitTree(children[0], surfaceForPane: surfaceForPane)
            let right = mapToSplitTree(children[1], surfaceForPane: surfaceForPane)
            let ratio = Double(sizeOf(children[0])) / Double(totalSize)
            return .split(SplitTree<V>.Node.Split(
                direction: direction, ratio: ratio, left: left, right: right
            ))
        }

        let first = children[0]
        let rest = Array(children.dropFirst())
        let firstSize = sizeOf(first)
        let restSize = totalSize - firstSize

        let left = mapToSplitTree(first, surfaceForPane: surfaceForPane)
        let right: SplitTree<V>.Node

        if rest.count == 1 {
            right = mapToSplitTree(rest[0], surfaceForPane: surfaceForPane)
        } else {
            right = buildBinarySplit(
                children: rest, direction: direction,
                totalSize: restSize, sizeOf: sizeOf,
                surfaceForPane: surfaceForPane
            )
        }

        let ratio = Double(firstSize) / Double(totalSize)
        return .split(SplitTree<V>.Node.Split(
            direction: direction, ratio: ratio, left: left, right: right
        ))
    }
}
