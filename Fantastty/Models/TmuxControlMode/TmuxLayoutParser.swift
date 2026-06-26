import Foundation

/// A node in the parsed tmux layout tree.
///
/// Tmux represents window layouts as a compact descriptor string. This enum
/// models the three possible node kinds: a leaf pane, a horizontal split
/// (children arranged left-to-right), or a vertical split (children arranged
/// top-to-bottom).
enum TmuxLayoutNode: Equatable {
    case leaf(paneID: Int, width: Int, height: Int)
    case horizontalSplit(children: [TmuxLayoutNode], width: Int, height: Int)
    case verticalSplit(children: [TmuxLayoutNode], width: Int, height: Int)

    /// The width of this node.
    var width: Int {
        switch self {
        case .leaf(_, let w, _): return w
        case .horizontalSplit(_, let w, _): return w
        case .verticalSplit(_, let w, _): return w
        }
    }

    /// The height of this node.
    var height: Int {
        switch self {
        case .leaf(_, _, let h): return h
        case .horizontalSplit(_, _, let h): return h
        case .verticalSplit(_, _, let h): return h
        }
    }

    /// All pane IDs contained in this subtree, in depth-first order.
    func allPaneIDs() -> [Int] {
        switch self {
        case .leaf(let id, _, _):
            return [id]
        case .horizontalSplit(let children, _, _),
             .verticalSplit(let children, _, _):
            return children.flatMap { $0.allPaneIDs() }
        }
    }
}

/// Zero-copy recursive descent parser for tmux layout descriptor strings.
///
/// Layout format (from `tmux list-windows -F '#{window_layout}'`):
/// - Starts with a hex checksum followed by comma: `bb62,<rest>`
/// - Leaf: `WxH,X,Y,PaneID`
/// - Horizontal split (left-right): `WxH,X,Y{child,child,...}`
/// - Vertical split (top-bottom): `WxH,X,Y[child,child,...]`
///
/// Example: `bb62,213x55,0,0{106x55,0,0,0,106x55,107,0[106x27,107,0,1,106x27,107,28,2]}`
struct TmuxLayoutParser {

    private var source: String
    private var index: String.Index

    private init(_ layout: String) {
        self.source = layout
        self.index = layout.startIndex
    }

    // MARK: - Public API

    /// Parse a tmux layout descriptor string into a tree of ``TmuxLayoutNode``.
    ///
    /// - Parameter layout: The raw layout string from tmux (e.g. `"bb62,213x55,0,0,0"`).
    /// - Returns: The root ``TmuxLayoutNode`` representing the parsed layout.
    static func parse(_ layout: String) -> TmuxLayoutNode {
        var parser = TmuxLayoutParser(layout)
        parser.skipChecksum()
        return parser.parseNode()
    }

    // MARK: - Parsing primitives

    /// Skip the hex checksum and its trailing comma.
    private mutating func skipChecksum() {
        // Advance past the first comma
        while index < source.endIndex && source[index] != "," {
            advance()
        }
        // Skip the comma itself
        if index < source.endIndex {
            advance()
        }
    }

    /// Parse a single node: `WxH,X,Y` followed by either `{...}`, `[...]`, or `,PaneID`.
    private mutating func parseNode() -> TmuxLayoutNode {
        let width = parseInt()
        expect("x")
        let height = parseInt()

        // Skip `,X,Y`
        expect(",")
        _ = parseInt() // X
        expect(",")
        _ = parseInt() // Y

        // Determine node type by the next character
        if index < source.endIndex {
            let ch = source[index]
            if ch == "{" {
                advance() // skip '{'
                let children = parseChildren(closedBy: "}")
                return .horizontalSplit(children: children, width: width, height: height)
            } else if ch == "[" {
                advance() // skip '['
                let children = parseChildren(closedBy: "]")
                return .verticalSplit(children: children, width: width, height: height)
            }
        }

        // Leaf: `,PaneID`
        expect(",")
        if index < source.endIndex && source[index] == "%" {
            advance()
        }
        let paneID = parseInt()
        return .leaf(paneID: paneID, width: width, height: height)
    }

    /// Parse a comma-separated list of child nodes until the closing bracket.
    private mutating func parseChildren(closedBy closer: Character) -> [TmuxLayoutNode] {
        var children: [TmuxLayoutNode] = []
        children.append(parseNode())

        while index < source.endIndex && source[index] != closer {
            expect(",")
            children.append(parseNode())
        }

        // Skip closing bracket
        if index < source.endIndex {
            advance()
        }

        return children
    }

    // MARK: - Low-level helpers

    /// Consume consecutive digits and return the parsed integer.
    private mutating func parseInt() -> Int {
        var value = 0
        while index < source.endIndex && source[index].isASCII && source[index].isNumber {
            value = value * 10 + Int(source[index].asciiValue! - 0x30)
            advance()
        }
        return value
    }

    /// Advance the index by one character.
    private mutating func advance() {
        index = source.index(after: index)
    }

    /// Assert that the current character matches `expected` and advance past it.
    private mutating func expect(_ expected: Character) {
        if index < source.endIndex && source[index] == expected {
            advance()
        }
    }
}
