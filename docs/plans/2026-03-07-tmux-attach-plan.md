# Tmux Session Attach — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Attach to pre-existing tmux sessions (local/remote) via control mode, rendering windows as tabs and panes as native Ghostty splits.

**Architecture:** Pure `tmux -CC` control mode. One `TmuxControlClient` Swift actor per attached session handles all I/O. Surfaces use inert subprocesses + `ghostty_surface_inject_output()`. Input intercepted at SurfaceView level and routed via `send-keys -H`.

**Tech Stack:** Swift, SwiftUI, Ghostty (libghostty C API), tmux control mode protocol

**Design Doc:** `docs/plans/2026-03-07-tmux-attach-design.md`

---

## Prerequisites

Before starting, create an XCTest target in Xcode:
1. Open `Fantastty.xcodeproj` in Xcode
2. File → New → Target → Unit Testing Bundle → name it `FantasttyTests`
3. Ensure it links against the Fantastty app target
4. Commit the project file changes

---

## Task 1: TmuxEvent Enum & Protocol Parser — Basic Notifications

Pure struct, no I/O. Parses single lines from the tmux control mode stream.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxEvent.swift`
- Create: `Fantastty/Models/TmuxControlMode/TmuxProtocolParser.swift`
- Create: `FantasttyTests/TmuxProtocolParserTests.swift`

**Step 1: Write failing tests for basic notification parsing**

```swift
// FantasttyTests/TmuxProtocolParserTests.swift
import XCTest
@testable import Fantastty

final class TmuxProtocolParserTests: XCTestCase {

    var parser = TmuxProtocolParser()

    // MARK: - Window notifications

    func testWindowAdd() {
        let event = parser.parse(line: "%window-add @1")
        guard case .windowAdd(let windowID) = event else {
            return XCTFail("Expected windowAdd, got \(String(describing: event))")
        }
        XCTAssertEqual(windowID, 1)
    }

    func testWindowClose() {
        let event = parser.parse(line: "%window-close @3")
        guard case .windowClose(let windowID) = event else {
            return XCTFail("Expected windowClose, got \(String(describing: event))")
        }
        XCTAssertEqual(windowID, 3)
    }

    func testWindowRenamed() {
        let event = parser.parse(line: "%window-renamed @2 my-window")
        guard case .windowRenamed(let windowID, let name) = event else {
            return XCTFail("Expected windowRenamed, got \(String(describing: event))")
        }
        XCTAssertEqual(windowID, 2)
        XCTAssertEqual(name, "my-window")
    }

    func testWindowRenamedWithSpaces() {
        let event = parser.parse(line: "%window-renamed @0 my cool window")
        guard case .windowRenamed(let windowID, let name) = event else {
            return XCTFail("Expected windowRenamed")
        }
        XCTAssertEqual(windowID, 0)
        XCTAssertEqual(name, "my cool window")
    }

    // MARK: - Session notifications

    func testSessionChanged() {
        let event = parser.parse(line: "%session-changed $1 main")
        guard case .sessionChanged(let sessionID, let name) = event else {
            return XCTFail("Expected sessionChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(sessionID, 1)
        XCTAssertEqual(name, "main")
    }

    func testSessionsChanged() {
        let event = parser.parse(line: "%sessions-changed")
        guard case .sessionsChanged = event else {
            return XCTFail("Expected sessionsChanged")
        }
    }

    // MARK: - Layout change

    func testLayoutChange() {
        let layout = "bb62,213x55,0,0,0"
        let event = parser.parse(line: "%layout-change @0 \(layout)")
        guard case .layoutChange(let windowID, let layoutStr) = event else {
            return XCTFail("Expected layoutChange, got \(String(describing: event))")
        }
        XCTAssertEqual(windowID, 0)
        XCTAssertEqual(layoutStr, layout)
    }

    // MARK: - Exit

    func testExitWithReason() {
        let event = parser.parse(line: "%exit server exited")
        guard case .exit(let reason) = event else {
            return XCTFail("Expected exit")
        }
        XCTAssertEqual(reason, "server exited")
    }

    func testExitWithoutReason() {
        let event = parser.parse(line: "%exit")
        guard case .exit(let reason) = event else {
            return XCTFail("Expected exit")
        }
        XCTAssertNil(reason)
    }

    // MARK: - Pane mode

    func testPaneModeChanged() {
        let event = parser.parse(line: "%pane-mode-changed %5")
        guard case .paneModeChanged(let paneID) = event else {
            return XCTFail("Expected paneModeChanged")
        }
        XCTAssertEqual(paneID, 5)
    }

    // MARK: - Unknown

    func testUnknownNotification() {
        let event = parser.parse(line: "%some-future-notification foo")
        guard case .unknown(let line) = event else {
            return XCTFail("Expected unknown")
        }
        XCTAssertEqual(line, "%some-future-notification foo")
    }

    func testNonNotificationLine() {
        let event = parser.parse(line: "some random output")
        XCTAssertNil(event)
    }

    func testEmptyLine() {
        let event = parser.parse(line: "")
        XCTAssertNil(event)
    }

    // MARK: - Carriage return stripping

    func testStripsCarriageReturn() {
        let event = parser.parse(line: "%window-add @1\r")
        guard case .windowAdd(let windowID) = event else {
            return XCTFail("Expected windowAdd after CR strip")
        }
        XCTAssertEqual(windowID, 1)
    }
}
```

**Step 2: Run tests — verify they fail**

Run: `xcodebuild test -scheme Fantastty -only-testing:FantasttyTests/TmuxProtocolParserTests -destination 'platform=macOS' 2>&1 | tail -20`
Expected: Build failure — files don't exist yet.

**Step 3: Implement TmuxEvent and TmuxProtocolParser**

```swift
// Fantastty/Models/TmuxControlMode/TmuxEvent.swift
import Foundation

enum TmuxEvent: Equatable {
    case output(paneID: Int, data: Data)
    case windowAdd(windowID: Int)
    case windowClose(windowID: Int)
    case windowRenamed(windowID: Int, name: String)
    case layoutChange(windowID: Int, layout: String)
    case sessionChanged(sessionID: Int, name: String)
    case sessionsChanged
    case paneModeChanged(paneID: Int)
    case beginBlock(id: Int, flags: Int)
    case endBlock(id: Int, flags: Int)
    case errorBlock(id: Int, flags: Int)
    case exit(reason: String?)
    case unknown(String)
}
```

```swift
// Fantastty/Models/TmuxControlMode/TmuxProtocolParser.swift
import Foundation

struct TmuxProtocolParser {
    private var dcsStripped = false
    private static let dcsPrefix = "\u{1b}P1000p"

    /// Parse a single line from the tmux control mode stream.
    /// Returns nil for non-notification lines (e.g. command response body lines
    /// are handled separately via begin/end block accumulation).
    mutating func parse(line rawLine: String) -> TmuxEvent? {
        var line = rawLine
        // Strip trailing CR from PTY line endings
        if line.hasSuffix("\r") { line.removeLast() }
        // Strip DCS prefix from first line
        if !dcsStripped {
            if line.hasPrefix(Self.dcsPrefix) {
                line = String(line.dropFirst(Self.dcsPrefix.count))
            }
            dcsStripped = true
        }
        guard line.hasPrefix("%") else { return nil }

        let parts = line.split(separator: " ", maxSplits: 1)
        guard let keyword = parts.first else { return nil }

        switch keyword {
        case "%window-add":
            guard let windowID = parseWindowID(parts) else { return .unknown(line) }
            return .windowAdd(windowID: windowID)

        case "%window-close":
            guard let windowID = parseWindowID(parts) else { return .unknown(line) }
            return .windowClose(windowID: windowID)

        case "%window-renamed":
            let subparts = line.split(separator: " ", maxSplits: 2)
            guard subparts.count >= 3,
                  let windowID = parseAtID(String(subparts[1])) else {
                return .unknown(line)
            }
            let name = String(subparts[2])
            return .windowRenamed(windowID: windowID, name: name)

        case "%layout-change":
            let subparts = line.split(separator: " ", maxSplits: 2)
            guard subparts.count >= 3,
                  let windowID = parseAtID(String(subparts[1])) else {
                return .unknown(line)
            }
            let layout = String(subparts[2])
            return .layoutChange(windowID: windowID, layout: layout)

        case "%output":
            let subparts = line.split(separator: " ", maxSplits: 2)
            guard subparts.count >= 3,
                  let paneID = parsePercentID(String(subparts[1])) else {
                return .unknown(line)
            }
            let data = Self.decodeOctalEscapes(String(subparts[2]))
            return .output(paneID: paneID, data: data)

        case "%session-changed":
            let subparts = line.split(separator: " ", maxSplits: 2)
            guard subparts.count >= 3,
                  let sessionID = parseDollarID(String(subparts[1])) else {
                return .unknown(line)
            }
            let name = String(subparts[2])
            return .sessionChanged(sessionID: sessionID, name: name)

        case "%sessions-changed":
            return .sessionsChanged

        case "%pane-mode-changed":
            guard let paneID = parsePaneID(parts) else { return .unknown(line) }
            return .paneModeChanged(paneID: paneID)

        case "%begin":
            return parseBeginEndError(line, kind: "begin")

        case "%end":
            return parseBeginEndError(line, kind: "end")

        case "%error":
            return parseBeginEndError(line, kind: "error")

        case "%exit":
            if parts.count > 1 {
                let reason = String(parts[1])
                return .exit(reason: reason)
            }
            return .exit(reason: nil)

        default:
            return .unknown(line)
        }
    }

    // MARK: - ID Parsers

    /// Parse `@<number>` from the second element of split parts.
    private func parseWindowID(_ parts: [Substring]) -> Int? {
        guard parts.count > 1 else { return nil }
        return parseAtID(String(parts[1]))
    }

    /// Parse `%<number>` from the second element of split parts.
    private func parsePaneID(_ parts: [Substring]) -> Int? {
        guard parts.count > 1 else { return nil }
        return parsePercentID(String(parts[1]))
    }

    /// Parse `@<number>` -> number
    private func parseAtID(_ s: String) -> Int? {
        guard s.hasPrefix("@") else { return nil }
        return Int(s.dropFirst())
    }

    /// Parse `%<number>` -> number
    private func parsePercentID(_ s: String) -> Int? {
        guard s.hasPrefix("%") else { return nil }
        return Int(s.dropFirst())
    }

    /// Parse `$<number>` -> number
    private func parseDollarID(_ s: String) -> Int? {
        guard s.hasPrefix("$") else { return nil }
        return Int(s.dropFirst())
    }

    // MARK: - Begin/End/Error

    private func parseBeginEndError(_ line: String, kind: String) -> TmuxEvent? {
        // Format: %begin <timestamp> <command_number> <flags>
        let parts = line.split(separator: " ")
        guard parts.count >= 4,
              let id = Int(parts[2]),
              let flags = Int(parts[3]) else {
            return .unknown(line)
        }
        switch kind {
        case "begin": return .beginBlock(id: id, flags: flags)
        case "end":   return .endBlock(id: id, flags: flags)
        case "error": return .errorBlock(id: id, flags: flags)
        default:      return .unknown(line)
        }
    }

    // MARK: - Octal Escape Decoding

    /// Decode tmux octal escapes: `\NNN` for chars < 32 and backslash.
    static func decodeOctalEscapes(_ string: String) -> Data {
        var data = Data()
        var chars = string.unicodeScalars.makeIterator()
        while let c = chars.next() {
            if c == "\\" {
                // Read up to 3 octal digits
                var octal = ""
                for _ in 0..<3 {
                    // Peek not possible on iterator, so we consume greedily
                    // and rely on tmux always emitting exactly 3 digits
                }
                // Re-approach: tmux always emits exactly 3 octal digits after backslash
                var octalValue: UInt8 = 0
                var validOctal = true
                for _ in 0..<3 {
                    guard let digit = chars.next(),
                          digit >= "0" && digit <= "7" else {
                        validOctal = false
                        break
                    }
                    octalValue = octalValue * 8 + UInt8(digit.value - UnicodeScalar("0").value)
                }
                if validOctal {
                    data.append(octalValue)
                } else {
                    // Malformed escape — emit backslash and whatever we consumed
                    data.append(UInt8(ascii: "\\"))
                }
            } else {
                // Regular character — encode as UTF-8
                var buf = [UInt8](repeating: 0, count: 4)
                let s = String(c)
                let utf8 = Array(s.utf8)
                data.append(contentsOf: utf8)
            }
        }
        return data
    }
}
```

**Step 4: Run tests — verify they pass**

Run: `xcodebuild test -scheme Fantastty -only-testing:FantasttyTests/TmuxProtocolParserTests -destination 'platform=macOS' 2>&1 | tail -20`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxEvent.swift \
       Fantastty/Models/TmuxControlMode/TmuxProtocolParser.swift \
       FantasttyTests/TmuxProtocolParserTests.swift
git commit -m "feat: add TmuxProtocolParser with basic notification parsing"
```

---

## Task 2: Protocol Parser — Output Decoding & Begin/End Blocks

Extend the parser with tests for `%output` octal decoding and `%begin/%end` block parsing.

**Files:**
- Modify: `Fantastty/Models/TmuxControlMode/TmuxProtocolParser.swift`
- Modify: `FantasttyTests/TmuxProtocolParserTests.swift`

**Step 1: Write failing tests**

```swift
// Add to TmuxProtocolParserTests.swift

// MARK: - Output decoding

func testOutputSimpleText() {
    let event = parser.parse(line: "%output %0 hello world")
    guard case .output(let paneID, let data) = event else {
        return XCTFail("Expected output, got \(String(describing: event))")
    }
    XCTAssertEqual(paneID, 0)
    XCTAssertEqual(String(data: data, encoding: .utf8), "hello world")
}

func testOutputOctalEscapes() {
    // \015 = CR (13), \012 = LF (10)
    let event = parser.parse(line: "%output %2 hello\\015\\012")
    guard case .output(_, let data) = event else {
        return XCTFail("Expected output")
    }
    XCTAssertEqual(data, Data([0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0d, 0x0a]))
}

func testOutputBackslashEscape() {
    // \134 = backslash (92)
    let event = parser.parse(line: "%output %0 path\\134file")
    guard case .output(_, let data) = event else {
        return XCTFail("Expected output")
    }
    XCTAssertEqual(String(data: data, encoding: .utf8), "path\\file")
}

func testOutputEscapeSequence() {
    // ESC = \033
    let event = parser.parse(line: "%output %0 \\033[1mBold\\033[0m")
    guard case .output(_, let data) = event else {
        return XCTFail("Expected output")
    }
    XCTAssertEqual(data[0], 0x1b)  // ESC
    XCTAssertEqual(data[1], 0x5b)  // [
}

// MARK: - Begin/End blocks

func testBeginBlock() {
    let event = parser.parse(line: "%begin 1234567890 1 0")
    guard case .beginBlock(let id, let flags) = event else {
        return XCTFail("Expected beginBlock, got \(String(describing: event))")
    }
    XCTAssertEqual(id, 1)
    XCTAssertEqual(flags, 0)
}

func testEndBlock() {
    let event = parser.parse(line: "%end 1234567890 1 0")
    guard case .endBlock(let id, let flags) = event else {
        return XCTFail("Expected endBlock")
    }
    XCTAssertEqual(id, 1)
    XCTAssertEqual(flags, 0)
}

func testErrorBlock() {
    let event = parser.parse(line: "%error 1234567890 2 1")
    guard case .errorBlock(let id, let flags) = event else {
        return XCTFail("Expected errorBlock")
    }
    XCTAssertEqual(id, 2)
    XCTAssertEqual(flags, 1)
}

// MARK: - DCS prefix stripping

func testStripsDCSPrefix() {
    var freshParser = TmuxProtocolParser()
    let event = freshParser.parse(line: "\u{1b}P1000p%window-add @0")
    guard case .windowAdd(let windowID) = event else {
        return XCTFail("Expected windowAdd after DCS strip")
    }
    XCTAssertEqual(windowID, 0)
}

func testDCSOnlyStrippedOnce() {
    var freshParser = TmuxProtocolParser()
    _ = freshParser.parse(line: "\u{1b}P1000p%window-add @0")
    // Second line should NOT have DCS stripped
    let event = freshParser.parse(line: "%window-add @1")
    guard case .windowAdd(let windowID) = event else {
        return XCTFail("Expected windowAdd")
    }
    XCTAssertEqual(windowID, 1)
}
```

**Step 2: Run tests — verify new tests fail (output decoding may already pass from Task 1)**

Run: `xcodebuild test -scheme Fantastty -only-testing:FantasttyTests/TmuxProtocolParserTests -destination 'platform=macOS' 2>&1 | tail -30`

**Step 3: Fix any failing tests**

The implementation from Task 1 should already handle these cases. If any octal decoding edge cases fail, fix `decodeOctalEscapes()`. Ensure DCS stripping uses the `dcsStripped` flag correctly.

**Step 4: Run tests — verify all pass**

**Step 5: Commit**

```bash
git add -u
git commit -m "test: add output decoding and begin/end block parser tests"
```

---

## Task 3: TmuxLayoutParser

Parses tmux layout descriptor strings into a tree. Pure function, fully testable.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxLayoutParser.swift`
- Create: `FantasttyTests/TmuxLayoutParserTests.swift`

**Step 1: Write failing tests**

```swift
// FantasttyTests/TmuxLayoutParserTests.swift
import XCTest
@testable import Fantastty

final class TmuxLayoutParserTests: XCTestCase {

    // MARK: - Single pane (leaf)

    func testSinglePane() {
        // Format: checksum,WxH,X,Y,PaneID
        let node = TmuxLayoutParser.parse("bb62,213x55,0,0,0")
        guard case .leaf(let paneID, let width, let height) = node else {
            return XCTFail("Expected leaf, got \(node)")
        }
        XCTAssertEqual(paneID, 0)
        XCTAssertEqual(width, 213)
        XCTAssertEqual(height, 55)
    }

    // MARK: - Horizontal split (left-right, curly braces)

    func testHorizontalSplitTwoPanes() {
        // Two panes side by side: {left,right}
        let node = TmuxLayoutParser.parse("1234,200x50,0,0{100x50,0,0,0,100x50,101,0,1}")
        guard case .horizontalSplit(let children, let width, let height) = node else {
            return XCTFail("Expected horizontalSplit, got \(node)")
        }
        XCTAssertEqual(width, 200)
        XCTAssertEqual(height, 50)
        XCTAssertEqual(children.count, 2)
        guard case .leaf(let id0, _, _) = children[0] else { return XCTFail("Expected leaf") }
        guard case .leaf(let id1, _, _) = children[1] else { return XCTFail("Expected leaf") }
        XCTAssertEqual(id0, 0)
        XCTAssertEqual(id1, 1)
    }

    // MARK: - Vertical split (top-bottom, square brackets)

    func testVerticalSplitTwoPanes() {
        // Two panes stacked: [top,bottom]
        let node = TmuxLayoutParser.parse("abcd,200x50,0,0[200x25,0,0,0,200x24,0,26,1]")
        guard case .verticalSplit(let children, let width, let height) = node else {
            return XCTFail("Expected verticalSplit, got \(node)")
        }
        XCTAssertEqual(width, 200)
        XCTAssertEqual(height, 50)
        XCTAssertEqual(children.count, 2)
    }

    // MARK: - Three-way split

    func testThreeWayHorizontalSplit() {
        // Three panes side by side
        let node = TmuxLayoutParser.parse("5678,300x50,0,0{100x50,0,0,0,100x50,101,0,1,100x50,202,0,2}")
        guard case .horizontalSplit(let children, _, _) = node else {
            return XCTFail("Expected horizontalSplit")
        }
        XCTAssertEqual(children.count, 3)
    }

    // MARK: - Nested splits

    func testNestedSplits() {
        // Horizontal split: left pane, right side vertically split
        let node = TmuxLayoutParser.parse("9abc,200x50,0,0{100x50,0,0,0,100x50,101,0[100x25,101,0,1,100x24,101,26,2]}")
        guard case .horizontalSplit(let children, _, _) = node else {
            return XCTFail("Expected horizontalSplit")
        }
        XCTAssertEqual(children.count, 2)
        guard case .leaf(let id0, _, _) = children[0] else { return XCTFail("Expected leaf") }
        XCTAssertEqual(id0, 0)
        guard case .verticalSplit(let nested, _, _) = children[1] else {
            return XCTFail("Expected verticalSplit")
        }
        XCTAssertEqual(nested.count, 2)
    }

    // MARK: - Pane ID extraction

    func testAllPaneIDs() {
        let node = TmuxLayoutParser.parse("9abc,200x50,0,0{100x50,0,0,5,100x50,101,0[100x25,101,0,7,100x24,101,26,12]}")
        let ids = node.allPaneIDs()
        XCTAssertEqual(Set(ids), Set([5, 7, 12]))
    }
}
```

**Step 2: Run tests — verify they fail**

**Step 3: Implement TmuxLayoutParser**

```swift
// Fantastty/Models/TmuxControlMode/TmuxLayoutParser.swift
import Foundation

enum TmuxLayoutNode: Equatable {
    case leaf(paneID: Int, width: Int, height: Int)
    case horizontalSplit(children: [TmuxLayoutNode], width: Int, height: Int)
    case verticalSplit(children: [TmuxLayoutNode], width: Int, height: Int)

    /// Collect all pane IDs in this subtree.
    func allPaneIDs() -> [Int] {
        switch self {
        case .leaf(let paneID, _, _):
            return [paneID]
        case .horizontalSplit(let children, _, _),
             .verticalSplit(let children, _, _):
            return children.flatMap { $0.allPaneIDs() }
        }
    }

    var width: Int {
        switch self {
        case .leaf(_, let w, _): return w
        case .horizontalSplit(_, let w, _): return w
        case .verticalSplit(_, let w, _): return w
        }
    }

    var height: Int {
        switch self {
        case .leaf(_, _, let h): return h
        case .horizontalSplit(_, _, let h): return h
        case .verticalSplit(_, _, let h): return h
        }
    }
}

struct TmuxLayoutParser {
    /// Parse a tmux layout string into a tree.
    /// Format: `checksum,<node>` where checksum is a hex string.
    static func parse(_ layout: String) -> TmuxLayoutNode {
        // Skip the checksum prefix (hex digits followed by comma)
        let commaIndex = layout.firstIndex(of: ",")!
        let body = String(layout[layout.index(after: commaIndex)...])
        var index = body.startIndex
        return parseNode(body, &index)
    }

    /// Parse a single node starting at `index`.
    /// A node is either:
    /// - `WxH,X,Y,PaneID` (leaf)
    /// - `WxH,X,Y{child,child,...}` (horizontal split)
    /// - `WxH,X,Y[child,child,...]` (vertical split)
    private static func parseNode(_ s: String, _ i: inout String.Index) -> TmuxLayoutNode {
        // Parse WxH
        let width = parseInt(s, &i)
        advance(s, &i) // skip 'x'
        let height = parseInt(s, &i)
        advance(s, &i) // skip ','
        // Parse X
        _ = parseInt(s, &i)
        advance(s, &i) // skip ','
        // Parse Y
        _ = parseInt(s, &i)

        // What follows determines the node type
        guard i < s.endIndex else {
            // End of string — this shouldn't happen in valid input, treat as leaf 0
            return .leaf(paneID: 0, width: width, height: height)
        }

        let next = s[i]
        if next == "{" {
            advance(s, &i) // skip '{'
            let children = parseChildren(s, &i, closing: "}")
            return .horizontalSplit(children: children, width: width, height: height)
        } else if next == "[" {
            advance(s, &i) // skip '['
            let children = parseChildren(s, &i, closing: "]")
            return .verticalSplit(children: children, width: width, height: height)
        } else {
            // Leaf: next char should be ',' before PaneID
            advance(s, &i) // skip ','
            let paneID = parseInt(s, &i)
            return .leaf(paneID: paneID, width: width, height: height)
        }
    }

    /// Parse comma-separated children until the closing bracket.
    private static func parseChildren(_ s: String, _ i: inout String.Index, closing: Character) -> [TmuxLayoutNode] {
        var children: [TmuxLayoutNode] = []
        while i < s.endIndex && s[i] != closing {
            if s[i] == "," && !children.isEmpty {
                advance(s, &i) // skip ',' separator between children
            }
            children.append(parseNode(s, &i))
        }
        if i < s.endIndex && s[i] == closing {
            advance(s, &i) // skip closing bracket
        }
        return children
    }

    /// Parse a non-negative integer from the string.
    private static func parseInt(_ s: String, _ i: inout String.Index) -> Int {
        var value = 0
        while i < s.endIndex && s[i].isNumber {
            value = value * 10 + s[i].wholeNumberValue!
            s.formIndex(after: &i)
        }
        return value
    }

    /// Advance index by one character.
    private static func advance(_ s: String, _ i: inout String.Index) {
        if i < s.endIndex { s.formIndex(after: &i) }
    }
}
```

**Step 4: Run tests — verify they pass**

**Step 5: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxLayoutParser.swift \
       FantasttyTests/TmuxLayoutParserTests.swift
git commit -m "feat: add TmuxLayoutParser for tmux layout descriptor strings"
```

---

## Task 4: CommandQueue

FIFO queue matching async `send()` calls to `%begin/%end` response blocks.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/CommandQueue.swift`
- Create: `FantasttyTests/CommandQueueTests.swift`

**Step 1: Write failing tests**

```swift
// FantasttyTests/CommandQueueTests.swift
import XCTest
@testable import Fantastty

final class CommandQueueTests: XCTestCase {

    func testEnqueueDequeue() {
        var queue = CommandQueue()
        XCTAssertTrue(queue.isEmpty)

        queue.enqueue(nil)  // fire-and-forget
        XCTAssertFalse(queue.isEmpty)

        let result = queue.dequeue()
        XCTAssertNil(result)  // was fire-and-forget
        XCTAssertTrue(queue.isEmpty)
    }

    func testFIFOOrdering() {
        var queue = CommandQueue()
        queue.enqueue(nil)  // command 1 (fire-and-forget)
        queue.enqueue(nil)  // command 2 (fire-and-forget)

        _ = queue.dequeue()  // pops command 1
        _ = queue.dequeue()  // pops command 2
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
        queue.appendToCurrentResponse("line 1\n")
        queue.appendToCurrentResponse("line 2\n")
        let (_, text) = queue.dequeueRaw()!
        XCTAssertEqual(text, "line 1\nline 2\n")
    }
}
```

**Step 2: Run tests — verify they fail**

**Step 3: Implement CommandQueue**

```swift
// Fantastty/Models/TmuxControlMode/CommandQueue.swift
import Foundation

/// FIFO queue matching tmux commands to their %begin/%end responses.
struct CommandQueue {
    struct Entry {
        let continuation: CheckedContinuation<String, any Error>?
        var responseText: String = ""
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Enqueue a continuation (or nil for fire-and-forget).
    mutating func enqueue(_ continuation: CheckedContinuation<String, any Error>?) {
        entries.append(Entry(continuation: continuation))
    }

    /// Append text to the current (first) entry's response buffer.
    /// Called for lines between %begin and %end.
    mutating func appendToCurrentResponse(_ text: String) {
        guard !entries.isEmpty else { return }
        entries[0].responseText += text
    }

    /// Dequeue the first entry, delivering the response text to its continuation.
    /// Returns the continuation (so the caller can resume it) or nil for fire-and-forget.
    @discardableResult
    mutating func dequeue() -> CheckedContinuation<String, any Error>? {
        guard let entry = dequeueRaw() else { return nil }
        entry.continuation?.resume(returning: entry.responseText)
        return entry.continuation
    }

    /// Dequeue the first entry and deliver an error to its continuation.
    mutating func dequeueWithError(_ error: any Error) {
        guard let entry = dequeueRaw() else { return }
        entry.continuation?.resume(throwing: error)
    }

    /// Raw dequeue without resuming the continuation. For testing.
    mutating func dequeueRaw() -> (continuation: CheckedContinuation<String, any Error>?, text: String)? {
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        return (entry.continuation, entry.responseText)
    }
}
```

**Step 4: Run tests — verify they pass**

**Step 5: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/CommandQueue.swift \
       FantasttyTests/CommandQueueTests.swift
git commit -m "feat: add CommandQueue for tmux control mode request/response FIFO"
```

---

## Task 5: Model Types

New types for the session model: `TmuxHost`, `SSHHostInfo`, `TmuxAttachmentInfo`, `ConnectionState`, `SessionMode`.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift`
- Modify: `Fantastty/Models/Session.swift` (add `mode` and `controlClient` properties)

**Step 1: Create model types**

```swift
// Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift
import Foundation

enum ConnectionState: Codable, Equatable {
    case connecting
    case connected
    case disconnected(reason: String?)
}

enum TmuxHost: Codable, Hashable {
    case local
    case ssh(SSHHostInfo)

    var displayName: String {
        switch self {
        case .local: return "localhost"
        case .ssh(let info): return info.displayName
        }
    }
}

struct SSHHostInfo: Codable, Hashable {
    let user: String?
    let hostname: String
    let port: Int?

    var displayName: String {
        var s = ""
        if let user { s += "\(user)@" }
        s += hostname
        if let port, port != 22 { s += ":\(port)" }
        return s
    }

    /// Build the ssh command prefix (without the remote command).
    var sshCommandPrefix: String {
        var parts = ["ssh", "-t"]
        if let port { parts += ["-p", "\(port)"] }
        if let user {
            parts.append("\(user)@\(hostname)")
        } else {
            parts.append(hostname)
        }
        return parts.joined(separator: " ")
    }
}

struct TmuxAttachmentInfo: Codable, Equatable {
    let sessionName: String
    let host: TmuxHost
    var connectionState: ConnectionState

    /// Build the command to spawn the tmux -CC control connection.
    func controlCommand(tmuxPath: String = "tmux") -> String {
        let tmuxCmd = "\(tmuxPath) -CC attach-session -t '\(sessionName)'"
        switch host {
        case .local:
            return tmuxCmd
        case .ssh(let info):
            return "\(info.sshCommandPrefix) \(tmuxCmd)"
        }
    }
}

enum SessionMode: Codable, Equatable {
    case managed
    case attached(TmuxAttachmentInfo)
}
```

**Step 2: Add properties to Session**

Modify `Fantastty/Models/Session.swift`. After the existing `tmuxTabCounter` property (around line 39), add:

```swift
var mode: SessionMode = .managed
// controlClient is not Codable — it's runtime-only, set by SessionManager
```

**Step 3: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift \
       Fantastty/Models/Session.swift
git commit -m "feat: add SessionMode, TmuxAttachmentInfo, and connection model types"
```

---

## Task 6: TmuxControlClient Actor — Connection Lifecycle

The core actor that manages the `tmux -CC` process and read loop.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxControlClient.swift`

**Step 1: Implement the actor**

```swift
// Fantastty/Models/TmuxControlMode/TmuxControlClient.swift
import Foundation

/// Errors specific to the tmux control client.
enum TmuxControlError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case commandError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to tmux session"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .commandError(let msg): return "Tmux command error: \(msg)"
        case .timeout: return "Command timed out"
        }
    }
}

/// Represents a tmux window as seen by the control client.
struct TmuxWindow: Equatable, Identifiable {
    let windowID: Int
    var name: String
    var paneIDs: [Int]

    var id: Int { windowID }
}

/// Delegate protocol for TmuxControlClient notifications.
/// All methods are called on MainActor.
@MainActor
protocol TmuxControlClientDelegate: AnyObject {
    func controlClient(_ client: TmuxControlClient, didAddWindow window: TmuxWindow)
    func controlClient(_ client: TmuxControlClient, didCloseWindowID windowID: Int)
    func controlClient(_ client: TmuxControlClient, didRenameWindowID windowID: Int, to name: String)
    func controlClient(_ client: TmuxControlClient, didChangeLayoutForWindowID windowID: Int, layout: String)
    func controlClient(_ client: TmuxControlClient, didReceiveOutput data: Data, forPaneID paneID: Int)
    func controlClient(_ client: TmuxControlClient, didChangeState state: ConnectionState)
    func controlClientDidExit(_ client: TmuxControlClient, reason: String?)
}

actor TmuxControlClient {
    let attachmentInfo: TmuxAttachmentInfo

    private(set) var state: ConnectionState = .disconnected(reason: nil)
    private(set) var windows: [Int: TmuxWindow] = [:]  // windowID -> TmuxWindow

    private var process: Process?
    private var inputPipe: Pipe?   // our writes -> tmux stdin
    private var outputPipe: Pipe?  // tmux stdout -> our reads
    private var parser = TmuxProtocolParser()
    private var commandQueue = CommandQueue()
    private var readTask: Task<Void, Never>?
    private var inResponseBlock = false  // between %begin and %end

    // Delegate for UI updates — must be set before connect()
    nonisolated weak var delegate: (any TmuxControlClientDelegate)?

    init(attachmentInfo: TmuxAttachmentInfo) {
        self.attachmentInfo = attachmentInfo
    }

    deinit {
        process?.terminate()
        readTask?.cancel()
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        guard case .disconnected = state else { return }

        setState(.connecting)

        let proc = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", attachmentInfo.controlCommand()]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            setState(.disconnected(reason: error.localizedDescription))
            throw TmuxControlError.connectionFailed(error.localizedDescription)
        }

        self.process = proc
        self.inputPipe = inPipe
        self.outputPipe = outPipe

        // Start the read loop
        readTask = Task { [weak self] in
            await self?.readLoop()
        }

        // Wait for the initial %begin/%end greeting
        do {
            let _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
                commandQueue.enqueue(cont)
            }
        } catch {
            disconnect()
            throw TmuxControlError.connectionFailed("No greeting received")
        }

        // Enumerate windows and panes
        try await enumerateInitialState()

        setState(.connected)
    }

    func disconnect() {
        readTask?.cancel()
        readTask = nil
        process?.terminate()
        process = nil
        inputPipe = nil
        outputPipe = nil
        setState(.disconnected(reason: nil))
    }

    // MARK: - Commands

    /// Send a command and wait for its response.
    func send(_ command: String) async throws -> String {
        guard case .connected = state, let inPipe = inputPipe else {
            throw TmuxControlError.notConnected
        }

        let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
            commandQueue.enqueue(cont)
            let data = (command + "\n").data(using: .utf8)!
            inPipe.fileHandleForWriting.write(data)
        }
        return response
    }

    /// Send a command without waiting for a response.
    func sendFireAndForget(_ command: String) {
        guard let inPipe = inputPipe else { return }
        commandQueue.enqueue(nil)
        let data = (command + "\n").data(using: .utf8)!
        inPipe.fileHandleForWriting.write(data)
    }

    /// Send keystrokes to a specific pane as hex-encoded bytes.
    func sendKeys(paneID: Int, data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendFireAndForget("send-keys -t %\(paneID) -H \(hex)")
    }

    // MARK: - Window/Pane Commands

    func newWindow() async throws -> String {
        try await send("new-window")
    }

    func killWindow(windowID: Int) async throws {
        _ = try await send("kill-window -t @\(windowID)")
    }

    func renameWindow(windowID: Int, name: String) async throws {
        _ = try await send("rename-window -t @\(windowID) '\(name)'")
    }

    func splitPane(paneID: Int, horizontal: Bool) async throws {
        let flag = horizontal ? "-h" : "-v"
        _ = try await send("split-window \(flag) -t %\(paneID)")
    }

    func killPane(paneID: Int) async throws {
        _ = try await send("kill-pane -t %\(paneID)")
    }

    func resizePane(paneID: Int, width: Int, height: Int) async throws {
        _ = try await send("resize-pane -t %\(paneID) -x \(width) -y \(height)")
    }

    func capturePane(paneID: Int) async throws -> String {
        try await send("capture-pane -t %\(paneID) -p -e")
    }

    // MARK: - Read Loop

    private func readLoop() async {
        guard let outPipe = outputPipe else { return }
        let handle = outPipe.fileHandleForReading

        // Read line-by-line using a buffer
        var buffer = Data()

        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = handle.availableData
            }
            if chunk.isEmpty {
                // EOF — process exited
                await handleExit(reason: "connection closed")
                return
            }

            buffer.append(chunk)

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])

                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                await handleLine(line)
            }
        }
    }

    private func handleLine(_ line: String) async {
        // If we're inside a %begin/%end block, accumulate response text
        // (unless the line is itself a %end or %error)
        if inResponseBlock {
            if let event = parser.parse(line: line) {
                switch event {
                case .endBlock:
                    inResponseBlock = false
                    commandQueue.dequeue()
                    return
                case .errorBlock:
                    inResponseBlock = false
                    commandQueue.dequeueWithError(
                        TmuxControlError.commandError(
                            commandQueue.dequeueRaw()?.text ?? "unknown error"
                        )
                    )
                    return
                default:
                    // Other notifications can arrive between %begin and %end
                    await dispatchEvent(event)
                    return
                }
            } else {
                // Non-notification line inside a block = response body text
                commandQueue.appendToCurrentResponse(line + "\n")
                return
            }
        }

        guard let event = parser.parse(line: line) else { return }
        await dispatchEvent(event)
    }

    private func dispatchEvent(_ event: TmuxEvent) async {
        switch event {
        case .beginBlock:
            inResponseBlock = true

        case .endBlock:
            inResponseBlock = false
            commandQueue.dequeue()

        case .errorBlock:
            inResponseBlock = false
            let errorText = commandQueue.dequeueRaw()?.text ?? ""
            commandQueue.dequeueWithError(TmuxControlError.commandError(errorText))

        case .output(let paneID, let data):
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.delegate?.controlClient(self, didReceiveOutput: data, forPaneID: paneID)
            }

        case .windowAdd(let windowID):
            // Query the window's details
            let window = TmuxWindow(windowID: windowID, name: "", paneIDs: [])
            windows[windowID] = window
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.delegate?.controlClient(self, didAddWindow: window)
            }

        case .windowClose(let windowID):
            windows.removeValue(forKey: windowID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.delegate?.controlClient(self, didCloseWindowID: windowID)
            }

        case .windowRenamed(let windowID, let name):
            windows[windowID]?.name = name
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.delegate?.controlClient(self, didRenameWindowID: windowID, to: name)
            }

        case .layoutChange(let windowID, let layout):
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.delegate?.controlClient(self, didChangeLayoutForWindowID: windowID, layout: layout)
            }

        case .exit(let reason):
            await handleExit(reason: reason)

        case .sessionChanged, .sessionsChanged, .paneModeChanged, .unknown:
            break  // Logged but not acted on for now
        }
    }

    // MARK: - Private Helpers

    private func enumerateInitialState() async throws {
        // Get window list
        let windowOutput = try await send(
            "list-windows -F '#{window_id} #{window_name} #{window_panes}'"
        )
        for line in windowOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2,
                  let windowID = Int(parts[0].dropFirst()) else { continue }  // drop '@'
            let name = parts.count > 2 ? String(parts[1]) : ""
            let window = TmuxWindow(windowID: windowID, name: name, paneIDs: [])
            windows[windowID] = window
        }

        // Get pane list with window association
        let paneOutput = try await send(
            "list-panes -s -F '#{window_id} #{pane_id}'"
        )
        for line in paneOutput.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2,
                  let windowID = Int(parts[0].dropFirst()),  // drop '@'
                  let paneID = Int(parts[1].dropFirst()) else { continue }  // drop '%'
            windows[windowID]?.paneIDs.append(paneID)
        }
    }

    private func handleExit(reason: String?) async {
        process = nil
        inputPipe = nil
        outputPipe = nil
        readTask?.cancel()
        readTask = nil
        setState(.disconnected(reason: reason))
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.delegate?.controlClientDidExit(self, reason: reason)
        }
    }

    private func setState(_ newState: ConnectionState) {
        state = newState
        let delegate = self.delegate
        Task { @MainActor in
            delegate?.controlClient(self, didChangeState: newState)
        }
    }
}
```

**Step 2: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxControlClient.swift
git commit -m "feat: add TmuxControlClient actor with connection lifecycle and read loop"
```

---

## Task 7: Layout-to-SplitTree Mapping

Convert `TmuxLayoutNode` (N-ary) to Ghostty's binary `SplitTree`. Ghostty's `SplitTree.Split` uses binary left/right with a ratio, so N-ary tmux layouts must be converted to nested binary splits.

**Reference:** `Fantastty/Splits/SplitTree.swift` — `Split` has `direction: Direction`, `ratio: Double`, `left: Node`, `right: Node`.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxLayoutMapper.swift`
- Create: `FantasttyTests/TmuxLayoutMapperTests.swift`

**Step 1: Write failing tests**

```swift
// FantasttyTests/TmuxLayoutMapperTests.swift
import XCTest
@testable import Fantastty

final class TmuxLayoutMapperTests: XCTestCase {

    /// Mock surface factory that returns a unique ID for each pane.
    var surfaces: [Int: String] = [:]  // paneID -> label

    func makeSurface(paneID: Int) -> String {
        let label = "pane-\(paneID)"
        surfaces[paneID] = label
        return label
    }

    // MARK: - Single pane

    func testSinglePane() {
        let layout = TmuxLayoutNode.leaf(paneID: 0, width: 200, height: 50)
        let tree = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)
        guard case .leaf(let label) = tree else {
            return XCTFail("Expected leaf")
        }
        XCTAssertEqual(label, "pane-0")
    }

    // MARK: - Two-way split

    func testTwoWayHorizontalSplit() {
        let layout = TmuxLayoutNode.horizontalSplit(children: [
            .leaf(paneID: 0, width: 100, height: 50),
            .leaf(paneID: 1, width: 100, height: 50),
        ], width: 200, height: 50)
        let tree = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)
        guard case .split(let split) = tree else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(split.direction, .horizontal)
        XCTAssertEqual(split.ratio, 0.5, accuracy: 0.01)
    }

    // MARK: - Three-way split becomes nested binary

    func testThreeWayHorizontalSplit() {
        let layout = TmuxLayoutNode.horizontalSplit(children: [
            .leaf(paneID: 0, width: 100, height: 50),
            .leaf(paneID: 1, width: 100, height: 50),
            .leaf(paneID: 2, width: 100, height: 50),
        ], width: 300, height: 50)
        let tree = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)
        // Should be: split(pane-0, split(pane-1, pane-2))
        // First split ratio: 100/300 = 0.333
        guard case .split(let outer) = tree else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(outer.ratio, 1.0 / 3.0, accuracy: 0.01)
        guard case .leaf(let l) = outer.left else { return XCTFail("Expected leaf") }
        XCTAssertEqual(l, "pane-0")
        guard case .split(let inner) = outer.right else { return XCTFail("Expected inner split") }
        XCTAssertEqual(inner.ratio, 0.5, accuracy: 0.01)
    }

    // MARK: - Ratio calculation

    func testUnequalRatio() {
        let layout = TmuxLayoutNode.horizontalSplit(children: [
            .leaf(paneID: 0, width: 150, height: 50),
            .leaf(paneID: 1, width: 50, height: 50),
        ], width: 200, height: 50)
        let tree = TmuxLayoutMapper.mapToSplitTree(layout, surfaceForPane: makeSurface)
        guard case .split(let split) = tree else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(split.ratio, 0.75, accuracy: 0.01)
    }
}
```

**Step 2: Run tests — verify they fail**

**Step 3: Implement TmuxLayoutMapper**

```swift
// Fantastty/Models/TmuxControlMode/TmuxLayoutMapper.swift
import Foundation

/// Maps N-ary TmuxLayoutNode trees to binary SplitTree nodes.
struct TmuxLayoutMapper {

    /// Convert a TmuxLayoutNode into a SplitTree.Node.
    /// `surfaceForPane` is called for each leaf pane to get/create its surface.
    static func mapToSplitTree<V>(
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

    /// Convert an N-ary split into nested binary splits.
    /// Strategy: peel off the first child as `left`, and recursively build
    /// the remaining children as `right`. The ratio is the first child's
    /// size relative to the remaining total.
    private static func buildBinarySplit<V>(
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
            return .split(SplitTree<V>.Split(
                direction: direction,
                ratio: ratio,
                left: left,
                right: right
            ))
        }

        // N > 2: first child is left, rest form right subtree
        let first = children[0]
        let rest = Array(children.dropFirst())
        let firstSize = sizeOf(first)
        let restSize = totalSize - firstSize

        let left = mapToSplitTree(first, surfaceForPane: surfaceForPane)
        let right: SplitTree<V>.Node

        if rest.count == 1 {
            right = mapToSplitTree(rest[0], surfaceForPane: surfaceForPane)
        } else {
            // Build the rest as a sub-split with the same direction
            right = buildBinarySplit(
                children: rest,
                direction: direction,
                totalSize: restSize,
                sizeOf: sizeOf,
                surfaceForPane: surfaceForPane
            )
        }

        let ratio = Double(firstSize) / Double(totalSize)
        return .split(SplitTree<V>.Split(
            direction: direction,
            ratio: ratio,
            left: left,
            right: right
        ))
    }
}
```

Note: The tests use `String` as the generic type. The actual `SplitTree<V>` requires `V: NSView & Codable & Identifiable` — for testing, you may need to either make `SplitTree` generic without those constraints, or create a mock view type. Adjust the test approach based on what `SplitTree`'s actual generic constraints allow.

**Step 4: Run tests — verify they pass**

**Step 5: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxLayoutMapper.swift \
       FantasttyTests/TmuxLayoutMapperTests.swift
git commit -m "feat: add TmuxLayoutMapper converting N-ary tmux layouts to binary SplitTree"
```

---

## Task 8: Surface Management — Inert Subprocess + Output Injection

Wire up surface creation for tmux panes and output injection.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxSurfaceManager.swift`
- Modify: `Fantastty/GhosttyBridge/SurfaceView_AppKit.swift` (add tmux pane ID property + input interception)

**Step 1: Create TmuxSurfaceManager**

This helper creates inert-subprocess surfaces and manages the paneID→surface mapping.

```swift
// Fantastty/Models/TmuxControlMode/TmuxSurfaceManager.swift
import Foundation
import Cocoa

/// Manages Ghostty surfaces for tmux control mode panes.
/// Each pane gets an inert-subprocess surface; output is injected via
/// ghostty_surface_inject_output(), input is intercepted and routed
/// to the control client.
@MainActor
class TmuxSurfaceManager {
    private let app: ghostty_app_t
    private weak var controlClient: TmuxControlClient?

    /// Maps tmux pane ID -> Ghostty surface view.
    private(set) var surfaces: [Int: Ghostty.SurfaceView] = [:]

    init(app: ghostty_app_t, controlClient: TmuxControlClient) {
        self.app = app
        self.controlClient = controlClient
    }

    /// Create a surface for a tmux pane.
    func createSurface(paneID: Int) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'stty raw -echo; exec cat > /dev/null'"
        let surface = Ghostty.SurfaceView(app, baseConfig: config)
        surface.tmuxPaneID = paneID
        surface.tmuxControlClient = controlClient
        surfaces[paneID] = surface
        return surface
    }

    /// Remove and return the surface for a pane.
    @discardableResult
    func removeSurface(paneID: Int) -> Ghostty.SurfaceView? {
        let surface = surfaces.removeValue(forKey: paneID)
        surface?.tmuxPaneID = nil
        surface?.tmuxControlClient = nil
        return surface
    }

    /// Inject output data into the surface for a pane.
    func injectOutput(paneID: Int, data: Data) {
        guard let surface = surfaces[paneID],
              let rawSurface = surface.surface else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_inject_output(rawSurface, ptr, UInt(buffer.count))
        }
    }

    /// Get the surface for a pane, if it exists.
    func surface(forPaneID paneID: Int) -> Ghostty.SurfaceView? {
        surfaces[paneID]
    }

    /// Remove all surfaces.
    func removeAll() -> [Int: Ghostty.SurfaceView] {
        let old = surfaces
        surfaces.removeAll()
        for (_, surface) in old {
            surface.tmuxPaneID = nil
            surface.tmuxControlClient = nil
        }
        return old
    }
}
```

**Step 2: Add tmux properties to SurfaceView**

Modify `Fantastty/GhosttyBridge/SurfaceView_AppKit.swift`. Add stored properties near the top of the class (after existing properties around line 215):

```swift
/// Tmux control mode: if set, this surface is driven by a tmux pane.
/// Input is intercepted and routed to the control client instead of the PTY.
var tmuxPaneID: Int?
weak var tmuxControlClient: TmuxControlClient?
```

**Step 3: Add input interception**

In `SurfaceView_AppKit.swift`, modify the `keyAction()` method (around line 1354). At the very beginning of the method, before existing logic, add:

```swift
// Tmux control mode: intercept input and route to control client
if let paneID = tmuxPaneID, let client = tmuxControlClient {
    if let text = text, !text.isEmpty {
        let data = Data(text.utf8)
        Task { await client.sendKeys(paneID: paneID, data: data) }
        return true
    } else {
        // For non-text keys (arrows, function keys, etc.), let ghostty
        // translate the key event to the appropriate escape sequence,
        // then we'll intercept the PTY write. For now, build the
        // escape sequence from the key event.
        if let data = event.ghosttyKeyData {
            Task { await client.sendKeys(paneID: paneID, data: data) }
            return true
        }
    }
}
```

Note: The exact input interception implementation may need refinement based on how Ghostty translates key events to escape sequences. The critical path is ensuring keystrokes reach the tmux control client's `send-keys` command rather than the inert subprocess's PTY. This may require a helper on `NSEvent` to produce the terminal escape sequence bytes. Explore `ghostty_surface_key` internals or consider intercepting at the PTY write level instead.

**Step 4: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxSurfaceManager.swift \
       Fantastty/GhosttyBridge/SurfaceView_AppKit.swift
git commit -m "feat: add TmuxSurfaceManager and input interception for control mode surfaces"
```

---

## Task 9: SessionManager Integration — Attach Flow

Wire the control client into SessionManager so that attaching to a tmux session creates a Session with tabs driven by control mode notifications.

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`

**Step 1: Add TmuxControlClientDelegate conformance**

Add a new method to SessionManager and make it conform to `TmuxControlClientDelegate`. This is the bridge between the control client's notifications and the Session/Tab model.

At the end of `SessionManager.swift`, add an extension:

```swift
// MARK: - TmuxControlClientDelegate

extension SessionManager: TmuxControlClientDelegate {

    func controlClient(_ client: TmuxControlClient, didAddWindow window: TmuxWindow) {
        guard let session = sessionForControlClient(client) else { return }

        // Create surface for each pane in the window
        guard let surfaceManager = session.tmuxSurfaceManager else { return }
        let firstPaneID = window.paneIDs.first ?? 0
        let surfaceView = surfaceManager.createSurface(paneID: firstPaneID)

        // Create tab
        let tab = TerminalTab(type: session.type, surfaceView: surfaceView)
        tab.title = window.name.isEmpty ? "Window @\(window.windowID)" : window.name
        tab.tmuxWindowID = window.windowID

        session.tabs.append(tab)
        if session.selectedTabID == nil {
            session.selectedTabID = tab.id
        }

        setupTitleObserver(tab: tab, session: session)
    }

    func controlClient(_ client: TmuxControlClient, didCloseWindowID windowID: Int) {
        guard let session = sessionForControlClient(client) else { return }
        guard let tabIndex = session.tabs.firstIndex(where: { $0.tmuxWindowID == windowID }) else { return }

        let tab = session.tabs[tabIndex]
        deregisterSurfaces(for: tab)
        session.tabs.remove(at: tabIndex)

        if session.selectedTabID == tab.id {
            session.selectedTabID = session.tabs.first?.id
        }
    }

    func controlClient(_ client: TmuxControlClient, didRenameWindowID windowID: Int, to name: String) {
        guard let session = sessionForControlClient(client) else { return }
        guard let tab = session.tabs.first(where: { $0.tmuxWindowID == windowID }) else { return }
        tab.title = name
    }

    func controlClient(_ client: TmuxControlClient, didChangeLayoutForWindowID windowID: Int, layout: String) {
        guard let session = sessionForControlClient(client),
              let surfaceManager = session.tmuxSurfaceManager,
              let tab = session.tabs.first(where: { $0.tmuxWindowID == windowID }) else { return }

        let layoutNode = TmuxLayoutParser.parse(layout)
        let newPaneIDs = Set(layoutNode.allPaneIDs())
        let existingPaneIDs = Set(surfaceManager.surfaces.keys)

        // Remove surfaces for panes that no longer exist
        for paneID in existingPaneIDs.subtracting(newPaneIDs) {
            if let surface = surfaceManager.removeSurface(paneID: paneID) {
                deregisterSurface(surface)
            }
        }

        // Build new split tree, creating surfaces for new panes
        let newTree = TmuxLayoutMapper.mapToSplitTree(layoutNode) { paneID in
            if let existing = surfaceManager.surface(forPaneID: paneID) {
                return existing
            }
            let surface = surfaceManager.createSurface(paneID: paneID)
            registerSurface(surface, session: session, tab: tab)
            return surface
        }

        tab.surfaceTree = SplitTree(root: newTree)
    }

    func controlClient(_ client: TmuxControlClient, didReceiveOutput data: Data, forPaneID paneID: Int) {
        guard let session = sessionForControlClient(client) else { return }
        session.tmuxSurfaceManager?.injectOutput(paneID: paneID, data: data)
    }

    func controlClient(_ client: TmuxControlClient, didChangeState state: ConnectionState) {
        guard let session = sessionForControlClient(client) else { return }
        if case .attached(var info) = session.mode {
            info.connectionState = state
            session.mode = .attached(info)
        }
    }

    func controlClientDidExit(_ client: TmuxControlClient, reason: String?) {
        guard let session = sessionForControlClient(client) else { return }
        if case .attached(var info) = session.mode {
            info.connectionState = .disconnected(reason: reason)
            session.mode = .attached(info)
        }
        // Surfaces remain frozen — last rendered state is visible
    }

    // MARK: - Helpers

    private func sessionForControlClient(_ client: TmuxControlClient) -> Session? {
        sessions.first { $0.controlClient === client }
    }
}
```

**Step 2: Add the attach method to SessionManager**

Add this method to the main SessionManager class body:

```swift
/// Attach to an existing tmux session via control mode.
@discardableResult
func attachToTmuxSession(info: TmuxAttachmentInfo) async throws -> Session? {
    guard let app = ghosttyApp else { return nil }

    let workspaceID = String(UUID().uuidString.prefix(8)).lowercased()
    let session = Session(title: info.sessionName, initialTab: TerminalTab.placeholder(),
                          type: info.host == .local ? .local : .ssh(/* derive from host */),
                          workspaceID: workspaceID)
    session.mode = .attached(info)
    session.tabs = []  // tabs will be populated by control client

    let surfaceManager = TmuxSurfaceManager(app: app, controlClient: nil)
    session.tmuxSurfaceManager = surfaceManager

    let client = TmuxControlClient(attachmentInfo: info)
    client.delegate = self
    session.controlClient = client

    surfaceManager.controlClient = client

    sessions.append(session)
    selectedSessionID = session.id

    // Connect — this populates windows, which trigger delegate callbacks to create tabs
    try await client.connect()

    // Capture initial pane content for each surface
    let windows = await client.windows
    for (_, window) in windows {
        for paneID in window.paneIDs {
            if let content = try? await client.capturePane(paneID: paneID) {
                surfaceManager.injectOutput(paneID: paneID, data: Data(content.utf8))
            }
        }
    }

    // Request initial layout for each window
    for (windowID, _) in windows {
        if let layout = try? await client.send(
            "list-windows -t @\(windowID) -F '#{window_layout}'"
        ) {
            controlClient(client, didChangeLayoutForWindowID: windowID,
                          layout: layout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    return session
}
```

**Step 3: Add supporting properties to Session and TerminalTab**

Add to `Session.swift`:
```swift
var tmuxSurfaceManager: TmuxSurfaceManager?
var controlClient: TmuxControlClient?
```

Add to `TerminalTab.swift`:
```swift
var tmuxWindowID: Int?
```

**Step 4: Commit**

```bash
git add Fantastty/Models/SessionManager.swift \
       Fantastty/Models/Session.swift \
       Fantastty/Models/TerminalTab.swift
git commit -m "feat: integrate TmuxControlClient with SessionManager for attach flow"
```

---

## Task 10: Resize Handling

When a surface resizes, notify tmux to resize the corresponding pane.

**Files:**
- Modify: `Fantastty/GhosttyBridge/SurfaceView_AppKit.swift`

**Step 1: Add resize notification for tmux panes**

In `SurfaceView_AppKit.swift`, find the `sizeDidChange(_ size: CGSize)` method (around line 455). After the existing `ghostty_surface_set_size()` call, add:

```swift
// Notify tmux control client of size change
if let paneID = tmuxPaneID, let client = tmuxControlClient {
    let surfaceSize = ghostty_surface_size(surface)
    let cols = Int(surfaceSize.columns)
    let rows = Int(surfaceSize.rows)
    Task {
        try? await client.resizePane(paneID: paneID, width: cols, height: rows)
    }
}
```

**Step 2: Commit**

```bash
git add Fantastty/GhosttyBridge/SurfaceView_AppKit.swift
git commit -m "feat: notify tmux of pane resize from surface size changes"
```

---

## Task 11: Persistence — Layout & Re-Attach

Persist attached session info in layout.json and re-attach on launch.

**Files:**
- Modify: `Fantastty/Models/LayoutSnapshot.swift`
- Modify: `Fantastty/Models/SessionManager.swift` (saveLayout + restore)
- Create: `Fantastty/Models/TmuxControlMode/SSHHostStore.swift`

**Step 1: Extend WorkspaceLayout**

Add to `WorkspaceLayout` in `LayoutSnapshot.swift`:

```swift
var attachment: TmuxAttachmentInfo?  // nil for managed sessions
```

**Step 2: Save attached session info in saveLayout()**

In SessionManager's `saveLayout()` method, when building `WorkspaceLayout` entries, populate the `attachment` field:

```swift
if case .attached(let info) = session.mode {
    layout.attachment = info
}
```

**Step 3: Restore attached sessions on launch**

In SessionManager's `restoreTmuxSessions()` method, after restoring managed sessions, handle attached sessions:

```swift
// Restore attached sessions
for workspace in layoutSnapshot.workspaces where workspace.attachment != nil {
    guard var info = workspace.attachment else { continue }
    info.connectionState = .disconnected(reason: nil)

    let session = Session(title: info.sessionName, ...)
    session.mode = .attached(info)
    sessions.append(session)

    // Attempt re-attach in background
    Task {
        do {
            try await attachToTmuxSession(info: info)
        } catch {
            // Session stays in disconnected state — user can manually reconnect
        }
    }
}
```

**Step 4: Create SSHHostStore**

```swift
// Fantastty/Models/TmuxControlMode/SSHHostStore.swift
import Foundation

/// Persists saved SSH hosts for the attach dialog.
class SSHHostStore {
    static let shared = SSHHostStore()

    private let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fantastty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ssh-hosts.json")
    }()

    private(set) var hosts: [SSHHostInfo] = []

    init() { load() }

    func add(_ host: SSHHostInfo) {
        guard !hosts.contains(host) else { return }
        hosts.append(host)
        save()
    }

    func remove(_ host: SSHHostInfo) {
        hosts.removeAll { $0 == host }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SSHHostInfo].self, from: data) else { return }
        hosts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

**Step 5: Commit**

```bash
git add Fantastty/Models/LayoutSnapshot.swift \
       Fantastty/Models/SessionManager.swift \
       Fantastty/Models/TmuxControlMode/SSHHostStore.swift
git commit -m "feat: persist attached sessions and SSH hosts for re-attach on launch"
```

---

## Task 12: Attach UI — Session Discovery Dialog

SwiftUI sheet for discovering and attaching to tmux sessions.

**Files:**
- Create: `Fantastty/Views/TmuxAttachSheet.swift`
- Modify: Sidebar view (wherever the "+" button is) to present the sheet

**Step 1: Create TmuxAttachSheet**

```swift
// Fantastty/Views/TmuxAttachSheet.swift
import SwiftUI

struct TmuxAttachSheet: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) var dismiss

    @State private var sessions: [DiscoveredSession] = []
    @State private var selectedSession: DiscoveredSession?
    @State private var filterText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @State private var showAddHost = false
    @State private var newHostText = ""

    struct DiscoveredSession: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let host: TmuxHost
        let windowCount: Int

        var hostLabel: String { host.displayName }
    }

    var filteredSessions: [DiscoveredSession] {
        if filterText.isEmpty { return sessions }
        return sessions.filter {
            $0.name.localizedCaseInsensitiveContains(filterText) ||
            $0.hostLabel.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Attach to tmux session")
                .font(.headline)
                .padding()

            // Filter
            TextField("Filter...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            // Session list
            List(filteredSessions, selection: $selectedSession) { session in
                HStack {
                    VStack(alignment: .leading) {
                        Text(session.name).fontWeight(.medium)
                        Text(session.hostLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(session.windowCount) windows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(session)
            }
            .frame(minHeight: 200)

            if isLoading {
                ProgressView("Discovering sessions...")
                    .padding()
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            Divider()

            // Add host
            if showAddHost {
                HStack {
                    TextField("[user@]hostname[:port]", text: $newHostText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addHost() }
                    Button("Add") { addHost() }
                        .disabled(newHostText.isEmpty)
                }
                .padding()
            } else {
                Button("Add SSH host...") { showAddHost = true }
                    .padding(.vertical, 8)
            }

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Attach") { attach() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedSession == nil || isConnecting)
            }
            .padding()
        }
        .frame(width: 400, height: 450)
        .task { await discoverSessions() }
    }

    private func discoverSessions() async {
        isLoading = true
        defer { isLoading = false }

        // Discover local sessions
        let localSessions = TmuxManager.shared.listAllSessions()
        for info in localSessions {
            sessions.append(DiscoveredSession(
                name: info.name,
                host: .local,
                windowCount: info.windowCount
            ))
        }

        // Discover remote sessions from saved hosts (in parallel)
        let hosts = SSHHostStore.shared.hosts
        await withTaskGroup(of: [DiscoveredSession].self) { group in
            for host in hosts {
                group.addTask {
                    await discoverRemoteSessions(host: host)
                }
            }
            for await remoteSessions in group {
                sessions.append(contentsOf: remoteSessions)
            }
        }
    }

    private func discoverRemoteSessions(host: SSHHostInfo) async -> [DiscoveredSession] {
        // Run `ssh host tmux list-sessions -F '#{session_name}:#{session_windows}'`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = {
            var args: [String] = []
            if let port = host.port { args += ["-p", "\(port)"] }
            args += ["-o", "ConnectTimeout=5"]
            if let user = host.user {
                args.append("\(user)@\(host.hostname)")
            } else {
                args.append(host.hostname)
            }
            args += ["tmux", "list-sessions", "-F", "#{session_name}:#{session_windows}"]
            return args
        }()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard let name = parts.first else { return nil }
                let windowCount = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                return DiscoveredSession(
                    name: String(name),
                    host: .ssh(host),
                    windowCount: windowCount
                )
            }
        } catch {
            return []
        }
    }

    private func addHost() {
        guard let host = parseHostString(newHostText) else { return }
        SSHHostStore.shared.add(host)
        newHostText = ""
        showAddHost = false
        // Re-discover with new host
        Task { await discoverRemoteSessions(host: host).forEach { sessions.append($0) } }
    }

    private func parseHostString(_ s: String) -> SSHHostInfo? {
        // Parse [user@]hostname[:port]
        var user: String?
        var hostname = s
        var port: Int?

        if let atIndex = hostname.firstIndex(of: "@") {
            user = String(hostname[..<atIndex])
            hostname = String(hostname[hostname.index(after: atIndex)...])
        }
        if let colonIndex = hostname.lastIndex(of: ":") {
            if let p = Int(hostname[hostname.index(after: colonIndex)...]) {
                port = p
                hostname = String(hostname[..<colonIndex])
            }
        }
        guard !hostname.isEmpty else { return nil }
        return SSHHostInfo(user: user, hostname: hostname, port: port)
    }

    private func attach() {
        guard let selected = selectedSession else { return }
        isConnecting = true
        let info = TmuxAttachmentInfo(
            sessionName: selected.name,
            host: selected.host,
            connectionState: .connecting
        )
        Task {
            do {
                try await sessionManager.attachToTmuxSession(info: info)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }
}
```

**Step 2: Add "Attach to tmux session..." to sidebar**

Find the sidebar view that contains the session creation "+" button. Add a menu item or button that presents `TmuxAttachSheet` as a sheet. The exact location depends on the sidebar implementation — search for the "+" button or `createSession` call in the sidebar view.

**Step 3: Add `listAllSessions()` to TmuxManager**

In `TmuxManager.swift`, add a method that lists ALL tmux sessions (not just fantastty-prefixed ones):

```swift
/// List all tmux sessions (not just Fantastty-managed ones).
func listAllSessions() -> [TmuxSessionInfo] {
    // Same as listFantasttySessions() but without the prefix filter
    guard isTmuxAvailable else { return [] }
    // ... run `tmux list-sessions -F '#{session_name}:#{session_created}:#{session_windows}'`
    // Parse output into TmuxSessionInfo array
    // Return ALL sessions, not just those matching sessionPrefix
}
```

**Step 4: Commit**

```bash
git add Fantastty/Views/TmuxAttachSheet.swift \
       Fantastty/Models/TmuxManager.swift
git commit -m "feat: add tmux session discovery dialog and sidebar attach entry point"
```

---

## Task 13: Sidebar — Host Provenance & Connection State

Show host labels and connection state indicators on attached sessions in the sidebar.

**Files:**
- Modify: Sidebar session row view (find with `Grep` for session row rendering)

**Step 1: Update sidebar session row**

Find the sidebar view that renders each session row. For sessions with `mode == .attached(let info)`:
- Show `info.host.displayName` as a subtitle/badge
- When `info.connectionState == .disconnected`: dim the row, show a "Reconnect" button
- When `.connecting`: show a small spinner

The exact implementation depends on the existing sidebar view structure. Search for the view that renders session names in the sidebar and add conditional UI based on `session.mode`.

**Step 2: Add reconnect action**

Add a context menu item or inline button for disconnected sessions:

```swift
Button("Reconnect") {
    Task {
        guard case .attached(let info) = session.mode else { return }
        try? await sessionManager.attachToTmuxSession(info: info)
    }
}
```

**Step 3: Commit**

```bash
git add -u
git commit -m "feat: show host provenance and connection state for attached sessions in sidebar"
```

---

## Task 14: Window Management Commands from Fantastty UI

Wire Fantastty's tab creation/closure/rename actions to tmux commands for attached sessions.

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`

**Step 1: Modify createTab for attached sessions**

In `createTab()`, check if the current session is attached. If so, send `new-window` via the control client instead of creating a new tmux session:

```swift
func createTab(...) -> TerminalTab? {
    guard let session = currentSession else { return nil }

    if let client = session.controlClient {
        // Attached session: create window via control client
        // The delegate callback will create the tab when %window-add arrives
        Task { try? await client.newWindow() }
        return nil  // tab will be created asynchronously
    }

    // ... existing managed session logic ...
}
```

**Step 2: Modify closeTab for attached sessions**

In `closeTab()`, for attached sessions, send `kill-window` instead of killing a tmux session:

```swift
func closeTab(id: UUID) {
    guard let session = currentSession,
          let tab = session.tabs.first(where: { $0.id == id }) else { return }

    if let client = session.controlClient, let windowID = tab.tmuxWindowID {
        Task { try? await client.killWindow(windowID: windowID) }
        return  // tab removal happens via %window-close delegate callback
    }

    // ... existing managed session logic ...
}
```

**Step 3: Add split-pane support**

In the notification handler for `ghosttyNewSplit`, for attached sessions:

```swift
if let client = session.controlClient,
   let surface = notification.object as? Ghostty.SurfaceView,
   let paneID = surface.tmuxPaneID {
    let horizontal = /* determine direction from notification */
    Task { try? await client.splitPane(paneID: paneID, horizontal: horizontal) }
    return  // pane creation happens via %layout-change delegate callback
}
```

**Step 4: Commit**

```bash
git add Fantastty/Models/SessionManager.swift
git commit -m "feat: route tab/split creation and closure through tmux control client"
```

---

## Task 15: End-to-End Testing & Polish

Manual testing protocol and fixes.

**Step 1: Local attach test**

1. Start a tmux session externally: `tmux new-session -s test-session`
2. Create a second window: `Ctrl-b c`
3. In Fantastty, click "+" → "Attach to tmux session..."
4. Select "test-session" → Attach
5. Verify: two tabs appear, matching the tmux windows
6. Type in each tab — verify input reaches the correct tmux window
7. In tmux, create a third window — verify a new tab appears in Fantastty
8. In tmux, close a window — verify the tab disappears
9. In tmux, rename a window — verify the tab title updates
10. In Fantastty, create a new tab — verify a new tmux window appears
11. Create a split in tmux (`Ctrl-b %`) — verify the tab shows two Ghostty splits

**Step 2: Disconnect/reconnect test**

1. Attach to a local session
2. Kill the tmux session: `tmux kill-session -s test-session`
3. Verify: session shows disconnected state in sidebar
4. Recreate the tmux session with the same name
5. Click "Reconnect" — verify re-attachment works

**Step 3: SSH attach test** (requires a remote host with tmux)

1. Add SSH host via the dialog
2. Verify remote sessions are listed
3. Attach to a remote session
4. Verify windows appear as tabs, input works

**Step 4: Persistence test**

1. Attach to a session
2. Quit Fantastty
3. Relaunch — verify the session re-attaches automatically
4. Kill the tmux session before relaunch — verify disconnected state appears

**Step 5: Fix any issues found, commit**

```bash
git add -u
git commit -m "fix: address issues from end-to-end testing"
```

---

## File Summary

### New Files (in `Fantastty/Models/TmuxControlMode/`)
| File | Purpose |
|------|---------|
| `TmuxEvent.swift` | Event enum for parsed control mode notifications |
| `TmuxProtocolParser.swift` | Pure line→event parser for tmux -CC protocol |
| `TmuxLayoutParser.swift` | Pure parser for tmux layout descriptor strings |
| `TmuxLayoutMapper.swift` | Maps N-ary layout trees to binary SplitTree |
| `CommandQueue.swift` | FIFO for matching commands to %begin/%end responses |
| `TmuxAttachmentInfo.swift` | Model types: TmuxHost, SSHHostInfo, ConnectionState, SessionMode |
| `TmuxControlClient.swift` | Swift actor managing the tmux -CC connection |
| `TmuxSurfaceManager.swift` | Creates/manages inert-subprocess surfaces for panes |
| `SSHHostStore.swift` | Persists saved SSH hosts |

### New Files (in `Fantastty/Views/`)
| File | Purpose |
|------|---------|
| `TmuxAttachSheet.swift` | Session discovery and attach dialog |

### New Test Files (in `FantasttyTests/`)
| File | Purpose |
|------|---------|
| `TmuxProtocolParserTests.swift` | Protocol parser unit tests |
| `TmuxLayoutParserTests.swift` | Layout parser unit tests |
| `CommandQueueTests.swift` | Command queue unit tests |
| `TmuxLayoutMapperTests.swift` | Layout-to-SplitTree mapping tests |

### Modified Files
| File | Changes |
|------|---------|
| `Session.swift` | Add `mode`, `controlClient`, `tmuxSurfaceManager` properties |
| `TerminalTab.swift` | Add `tmuxWindowID` property |
| `SessionManager.swift` | Add `attachToTmuxSession()`, `TmuxControlClientDelegate` conformance, modify `createTab`/`closeTab` for attached sessions |
| `SurfaceView_AppKit.swift` | Add `tmuxPaneID`, `tmuxControlClient` properties; input interception in `keyAction()`; resize notification |
| `LayoutSnapshot.swift` | Add `attachment` field to `WorkspaceLayout` |
| `TmuxManager.swift` | Add `listAllSessions()` method |
| Sidebar view | Add "Attach to tmux session..." entry point, host/connection state UI |

### Xcode Project
All new `.swift` files must be added to `project.pbxproj` (4 sections: PBXBuildFile, PBXFileReference, PBXGroup, Sources build phase). Easiest to add via Xcode's UI.
