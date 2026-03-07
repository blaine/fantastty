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

    private func parseWindowID(_ parts: [Substring]) -> Int? {
        guard parts.count > 1 else { return nil }
        return parseAtID(String(parts[1]))
    }

    private func parsePaneID(_ parts: [Substring]) -> Int? {
        guard parts.count > 1 else { return nil }
        return parsePercentID(String(parts[1]))
    }

    private func parseAtID(_ s: String) -> Int? {
        guard s.hasPrefix("@") else { return nil }
        return Int(s.dropFirst())
    }

    private func parsePercentID(_ s: String) -> Int? {
        guard s.hasPrefix("%") else { return nil }
        return Int(s.dropFirst())
    }

    private func parseDollarID(_ s: String) -> Int? {
        guard s.hasPrefix("$") else { return nil }
        return Int(s.dropFirst())
    }

    // MARK: - Begin/End/Error

    private func parseBeginEndError(_ line: String, kind: String) -> TmuxEvent? {
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
                    data.append(UInt8(ascii: "\\"))
                }
            } else {
                let s = String(c)
                data.append(contentsOf: Array(s.utf8))
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

    func testSinglePane() {
        let node = TmuxLayoutParser.parse("bb62,213x55,0,0,0")
        guard case .leaf(let paneID, let width, let height) = node else {
            return XCTFail("Expected leaf, got \(node)")
        }
        XCTAssertEqual(paneID, 0)
        XCTAssertEqual(width, 213)
        XCTAssertEqual(height, 55)
    }

    func testHorizontalSplitTwoPanes() {
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

    func testVerticalSplitTwoPanes() {
        let node = TmuxLayoutParser.parse("abcd,200x50,0,0[200x25,0,0,0,200x24,0,26,1]")
        guard case .verticalSplit(let children, let width, let height) = node else {
            return XCTFail("Expected verticalSplit, got \(node)")
        }
        XCTAssertEqual(width, 200)
        XCTAssertEqual(height, 50)
        XCTAssertEqual(children.count, 2)
    }

    func testThreeWayHorizontalSplit() {
        let node = TmuxLayoutParser.parse("5678,300x50,0,0{100x50,0,0,0,100x50,101,0,1,100x50,202,0,2}")
        guard case .horizontalSplit(let children, _, _) = node else {
            return XCTFail("Expected horizontalSplit")
        }
        XCTAssertEqual(children.count, 3)
    }

    func testNestedSplits() {
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
    static func parse(_ layout: String) -> TmuxLayoutNode {
        let commaIndex = layout.firstIndex(of: ",")!
        let body = String(layout[layout.index(after: commaIndex)...])
        var index = body.startIndex
        return parseNode(body, &index)
    }

    private static func parseNode(_ s: String, _ i: inout String.Index) -> TmuxLayoutNode {
        let width = parseInt(s, &i)
        advance(s, &i) // skip 'x'
        let height = parseInt(s, &i)
        advance(s, &i) // skip ','
        _ = parseInt(s, &i) // X
        advance(s, &i) // skip ','
        _ = parseInt(s, &i) // Y

        guard i < s.endIndex else {
            return .leaf(paneID: 0, width: width, height: height)
        }

        let next = s[i]
        if next == "{" {
            advance(s, &i)
            let children = parseChildren(s, &i, closing: "}")
            return .horizontalSplit(children: children, width: width, height: height)
        } else if next == "[" {
            advance(s, &i)
            let children = parseChildren(s, &i, closing: "]")
            return .verticalSplit(children: children, width: width, height: height)
        } else {
            advance(s, &i) // skip ','
            let paneID = parseInt(s, &i)
            return .leaf(paneID: paneID, width: width, height: height)
        }
    }

    private static func parseChildren(_ s: String, _ i: inout String.Index, closing: Character) -> [TmuxLayoutNode] {
        var children: [TmuxLayoutNode] = []
        while i < s.endIndex && s[i] != closing {
            if s[i] == "," && !children.isEmpty {
                advance(s, &i)
            }
            children.append(parseNode(s, &i))
        }
        if i < s.endIndex && s[i] == closing {
            advance(s, &i)
        }
        return children
    }

    private static func parseInt(_ s: String, _ i: inout String.Index) -> Int {
        var value = 0
        while i < s.endIndex && s[i].isNumber {
            value = value * 10 + s[i].wholeNumberValue!
            s.formIndex(after: &i)
        }
        return value
    }

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

        queue.enqueue(nil)
        XCTAssertFalse(queue.isEmpty)

        let result = queue.dequeue()
        XCTAssertNil(result)
        XCTAssertTrue(queue.isEmpty)
    }

    func testFIFOOrdering() {
        var queue = CommandQueue()
        queue.enqueue(nil)
        queue.enqueue(nil)

        _ = queue.dequeue()
        _ = queue.dequeue()
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

    func testAppendToEmptyQueueIsNoOp() {
        var queue = CommandQueue()
        queue.appendToCurrentResponse("orphaned text")
        XCTAssertTrue(queue.isEmpty)
    }

    func testMultipleEntriesAccumulateIndependently() {
        var queue = CommandQueue()
        queue.enqueue(nil)
        queue.appendToCurrentResponse("first response\n")
        queue.enqueue(nil)
        // Second entry's response isn't written yet — only first gets appended
        let (_, text1) = queue.dequeueRaw()!
        XCTAssertEqual(text1, "first response\n")
        queue.appendToCurrentResponse("second response\n")
        let (_, text2) = queue.dequeueRaw()!
        XCTAssertEqual(text2, "second response\n")
    }
}
```

**Step 2: Run tests — verify they fail**

**Step 3: Implement CommandQueue**

```swift
// Fantastty/Models/TmuxControlMode/CommandQueue.swift
import Foundation

struct CommandQueue {
    struct Entry {
        let continuation: CheckedContinuation<String, any Error>?
        var responseText: String = ""
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func enqueue(_ continuation: CheckedContinuation<String, any Error>?) {
        entries.append(Entry(continuation: continuation))
    }

    mutating func appendToCurrentResponse(_ text: String) {
        guard !entries.isEmpty else { return }
        entries[0].responseText += text
    }

    @discardableResult
    mutating func dequeue() -> CheckedContinuation<String, any Error>? {
        guard let entry = dequeueRaw() else { return nil }
        entry.continuation?.resume(returning: entry.responseText)
        return entry.continuation
    }

    mutating func dequeueWithError(_ error: any Error) {
        guard let entry = dequeueRaw() else { return }
        entry.continuation?.resume(throwing: error)
    }

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

New types for the session model with full test coverage for serialization and command generation.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift`
- Create: `FantasttyTests/TmuxAttachmentInfoTests.swift`
- Modify: `Fantastty/Models/Session.swift` (add `mode` and `controlClient` properties)

**Step 1: Write failing tests**

```swift
// FantasttyTests/TmuxAttachmentInfoTests.swift
import XCTest
@testable import Fantastty

final class TmuxAttachmentInfoTests: XCTestCase {

    // MARK: - SSHHostInfo

    func testSSHHostDisplayNameSimple() {
        let host = SSHHostInfo(user: nil, hostname: "dev.example.com", port: nil)
        XCTAssertEqual(host.displayName, "dev.example.com")
    }

    func testSSHHostDisplayNameWithUser() {
        let host = SSHHostInfo(user: "deploy", hostname: "prod.example.com", port: nil)
        XCTAssertEqual(host.displayName, "deploy@prod.example.com")
    }

    func testSSHHostDisplayNameWithPort() {
        let host = SSHHostInfo(user: nil, hostname: "dev.example.com", port: 2222)
        XCTAssertEqual(host.displayName, "dev.example.com:2222")
    }

    func testSSHHostDisplayNameDefaultPort() {
        let host = SSHHostInfo(user: "me", hostname: "dev.example.com", port: 22)
        XCTAssertEqual(host.displayName, "me@dev.example.com")
    }

    func testSSHHostDisplayNameFull() {
        let host = SSHHostInfo(user: "deploy", hostname: "prod.example.com", port: 2222)
        XCTAssertEqual(host.displayName, "deploy@prod.example.com:2222")
    }

    func testSSHCommandPrefixSimple() {
        let host = SSHHostInfo(user: nil, hostname: "dev.example.com", port: nil)
        XCTAssertEqual(host.sshCommandPrefix, "ssh -t dev.example.com")
    }

    func testSSHCommandPrefixFull() {
        let host = SSHHostInfo(user: "deploy", hostname: "prod.example.com", port: 2222)
        XCTAssertEqual(host.sshCommandPrefix, "ssh -t -p 2222 deploy@prod.example.com")
    }

    // MARK: - TmuxHost

    func testTmuxHostLocalDisplayName() {
        let host = TmuxHost.local
        XCTAssertEqual(host.displayName, "localhost")
    }

    func testTmuxHostSSHDisplayName() {
        let host = TmuxHost.ssh(SSHHostInfo(user: "me", hostname: "mybox", port: nil))
        XCTAssertEqual(host.displayName, "me@mybox")
    }

    // MARK: - TmuxAttachmentInfo command generation

    func testControlCommandLocal() {
        let info = TmuxAttachmentInfo(
            sessionName: "my-session",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        XCTAssertEqual(info.controlCommand(), "tmux -CC attach-session -t 'my-session'")
    }

    func testControlCommandRemote() {
        let info = TmuxAttachmentInfo(
            sessionName: "dev",
            host: .ssh(SSHHostInfo(user: "deploy", hostname: "prod.example.com", port: 2222)),
            connectionState: .disconnected(reason: nil)
        )
        let cmd = info.controlCommand()
        XCTAssertEqual(cmd, "ssh -t -p 2222 deploy@prod.example.com tmux -CC attach-session -t 'dev'")
    }

    func testControlCommandCustomTmuxPath() {
        let info = TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        XCTAssertEqual(
            info.controlCommand(tmuxPath: "/opt/homebrew/bin/tmux"),
            "/opt/homebrew/bin/tmux -CC attach-session -t 'test'"
        )
    }

    // MARK: - Codable round-trips

    func testSSHHostInfoCodable() throws {
        let original = SSHHostInfo(user: "deploy", hostname: "prod.example.com", port: 2222)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSHHostInfo.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTmuxHostLocalCodable() throws {
        let original = TmuxHost.local
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TmuxHost.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTmuxHostSSHCodable() throws {
        let original = TmuxHost.ssh(SSHHostInfo(user: nil, hostname: "box", port: nil))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TmuxHost.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testConnectionStateCodable() throws {
        let states: [ConnectionState] = [
            .connecting,
            .connected,
            .disconnected(reason: nil),
            .disconnected(reason: "server exited"),
        ]
        for original in states {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ConnectionState.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    func testTmuxAttachmentInfoCodable() throws {
        let original = TmuxAttachmentInfo(
            sessionName: "test-session",
            host: .ssh(SSHHostInfo(user: "me", hostname: "box", port: 22)),
            connectionState: .connected
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TmuxAttachmentInfo.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSessionModeCodable() throws {
        let managed = SessionMode.managed
        let data1 = try JSONEncoder().encode(managed)
        let decoded1 = try JSONDecoder().decode(SessionMode.self, from: data1)
        XCTAssertEqual(decoded1, managed)

        let attached = SessionMode.attached(TmuxAttachmentInfo(
            sessionName: "s",
            host: .local,
            connectionState: .disconnected(reason: nil)
        ))
        let data2 = try JSONEncoder().encode(attached)
        let decoded2 = try JSONDecoder().decode(SessionMode.self, from: data2)
        XCTAssertEqual(decoded2, attached)
    }
}
```

**Step 2: Run tests — verify they fail**

**Step 3: Implement model types**

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

**Step 4: Run tests — verify they pass**

**Step 5: Add properties to Session.swift**

Modify `Fantastty/Models/Session.swift`. After the existing `tmuxTabCounter` property (around line 39), add:

```swift
var mode: SessionMode = .managed
```

Note: `controlClient` and `tmuxSurfaceManager` are runtime-only (not Codable), added in Task 9.

**Step 6: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift \
       FantasttyTests/TmuxAttachmentInfoTests.swift \
       Fantastty/Models/Session.swift
git commit -m "feat: add SessionMode, TmuxAttachmentInfo, and connection model types"
```

---

## Task 6: TmuxControlClient Actor — Connection Lifecycle

The core actor. Testable via pipe-based integration: feed known protocol lines into a Pipe, verify delegate callbacks and state transitions.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxControlClient.swift`
- Create: `FantasttyTests/TmuxControlClientTests.swift`

**Step 1: Write the actor**

See the full `TmuxControlClient` implementation from the design doc. Key points:
- Uses `Process` with `/bin/sh -c <controlCommand>` to spawn `tmux -CC`
- Reads stdout line-by-line in a background Task
- Feeds lines to `TmuxProtocolParser`, dispatches events
- `CommandQueue` matches `send()` calls to `%begin/%end` responses
- `TmuxControlClientDelegate` (MainActor protocol) receives notifications

Create `Fantastty/Models/TmuxControlMode/TmuxControlClient.swift` with the full implementation (actor, delegate protocol, TmuxWindow struct, TmuxControlError enum). See Task 6 in previous plan revision for complete code.

**Step 2: Write integration tests using a mock process**

The key insight: we don't need a real tmux to test the client. We can pipe crafted protocol lines into the actor's read loop. Extract the line-handling logic so it can be driven by tests.

Add a `processLines(_ lines: [String])` method for testing:

```swift
// In TmuxControlClient — test-accessible entry point
#if DEBUG
func processLine(_ line: String) async {
    await handleLine(line)
}
#endif
```

```swift
// FantasttyTests/TmuxControlClientTests.swift
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
        // We can't easily test the actual pipe write without a real connection,
        // but we can test the hex encoding logic extracted as a helper.
        let data = Data([0x1b, 0x5b, 0x41])  // ESC [ A (up arrow)
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        XCTAssertEqual(hex, "1b 5b 41")
    }
}
```

**Step 3: Run tests — verify they pass**

**Step 4: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxControlClient.swift \
       FantasttyTests/TmuxControlClientTests.swift
git commit -m "feat: add TmuxControlClient actor with connection lifecycle and read loop"
```

---

## Task 7: Layout-to-SplitTree Mapping

Convert N-ary `TmuxLayoutNode` to binary `SplitTree`. Ghostty's `SplitTree` requires `ViewType: NSView & Codable & Identifiable`, so tests use a mock view.

**Reference:** `Fantastty/Splits/SplitTree.swift` — `Split` has `direction: Direction`, `ratio: Double`, `left: Node`, `right: Node`.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxLayoutMapper.swift`
- Create: `FantasttyTests/TmuxLayoutMapperTests.swift`

**Step 1: Write failing tests with a mock NSView**

```swift
// FantasttyTests/TmuxLayoutMapperTests.swift
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
```

**Step 2: Run tests — verify they fail**

**Step 3: Implement TmuxLayoutMapper**

```swift
// Fantastty/Models/TmuxControlMode/TmuxLayoutMapper.swift
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
```

**Step 4: Run tests — verify they pass**

**Step 5: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxLayoutMapper.swift \
       FantasttyTests/TmuxLayoutMapperTests.swift
git commit -m "feat: add TmuxLayoutMapper converting N-ary tmux layouts to binary SplitTree"
```

---

## Task 8: Surface Management — Inert Subprocess + Output Injection

Manage surface creation for tmux panes. Test via a protocol-extracted surface provider.

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxSurfaceManager.swift`
- Create: `FantasttyTests/TmuxSurfaceManagerTests.swift`
- Modify: `Fantastty/GhosttyBridge/SurfaceView_AppKit.swift` (add tmux properties + input interception)

**Step 1: Define a protocol for surface creation**

This allows testing without a real Ghostty app instance.

```swift
// In TmuxSurfaceManager.swift

/// Protocol for creating and injecting into surfaces.
/// Extracted for testability — production uses Ghostty, tests use mocks.
protocol TmuxSurfaceProviding: AnyObject {
    associatedtype Surface: AnyObject
    func createInertSurface(paneID: Int) -> Surface
    func destroySurface(_ surface: Surface)
    func injectOutput(_ surface: Surface, data: Data)
}
```

**Step 2: Write failing tests with a mock provider**

```swift
// FantasttyTests/TmuxSurfaceManagerTests.swift
import XCTest
@testable import Fantastty

final class MockSurface: Equatable {
    let paneID: Int
    var injectedData: [Data] = []
    var destroyed = false

    init(paneID: Int) { self.paneID = paneID }

    static func == (lhs: MockSurface, rhs: MockSurface) -> Bool {
        lhs === rhs
    }
}

final class MockSurfaceProvider: TmuxSurfaceProviding {
    var createdSurfaces: [Int: MockSurface] = [:]

    func createInertSurface(paneID: Int) -> MockSurface {
        let s = MockSurface(paneID: paneID)
        createdSurfaces[paneID] = s
        return s
    }
    func destroySurface(_ surface: MockSurface) {
        surface.destroyed = true
    }
    func injectOutput(_ surface: MockSurface, data: Data) {
        surface.injectedData.append(data)
    }
}

final class TmuxSurfaceManagerTests: XCTestCase {

    func testCreateSurface() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        let surface = manager.createSurface(paneID: 5)
        XCTAssertEqual(surface.paneID, 5)
        XCTAssertEqual(manager.surface(forPaneID: 5)?.paneID, 5)
    }

    func testRemoveSurface() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        let surface = manager.createSurface(paneID: 3)
        let removed = manager.removeSurface(paneID: 3)
        XCTAssertTrue(surface === removed)
        XCTAssertNil(manager.surface(forPaneID: 3))
    }

    func testRemoveNonexistentPaneReturnsNil() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        XCTAssertNil(manager.removeSurface(paneID: 99))
    }

    func testInjectOutput() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        _ = manager.createSurface(paneID: 0)
        let testData = Data("hello".utf8)
        manager.injectOutput(paneID: 0, data: testData)

        let surface = provider.createdSurfaces[0]!
        XCTAssertEqual(surface.injectedData.count, 1)
        XCTAssertEqual(surface.injectedData.first, testData)
    }

    func testInjectOutputToUnknownPaneIsNoOp() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        // Should not crash
        manager.injectOutput(paneID: 99, data: Data("hello".utf8))
    }

    func testRemoveAll() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        _ = manager.createSurface(paneID: 0)
        _ = manager.createSurface(paneID: 1)
        _ = manager.createSurface(paneID: 2)

        let removed = manager.removeAll()
        XCTAssertEqual(removed.count, 3)
        XCTAssertNil(manager.surface(forPaneID: 0))
        XCTAssertNil(manager.surface(forPaneID: 1))
        XCTAssertNil(manager.surface(forPaneID: 2))
    }

    func testPaneIDsTracked() {
        let provider = MockSurfaceProvider()
        let manager = TmuxSurfaceManagerGeneric(provider: provider)

        _ = manager.createSurface(paneID: 5)
        _ = manager.createSurface(paneID: 10)

        XCTAssertEqual(Set(manager.paneIDs), Set([5, 10]))
    }
}
```

**Step 3: Implement TmuxSurfaceManager**

```swift
// Fantastty/Models/TmuxControlMode/TmuxSurfaceManager.swift
import Foundation

/// Generic surface manager, testable with mock providers.
class TmuxSurfaceManagerGeneric<Provider: TmuxSurfaceProviding> {
    private let provider: Provider
    private var surfaces: [Int: Provider.Surface] = [:]

    var paneIDs: Dictionary<Int, Provider.Surface>.Keys { surfaces.keys }

    init(provider: Provider) {
        self.provider = provider
    }

    @discardableResult
    func createSurface(paneID: Int) -> Provider.Surface {
        let surface = provider.createInertSurface(paneID: paneID)
        surfaces[paneID] = surface
        return surface
    }

    @discardableResult
    func removeSurface(paneID: Int) -> Provider.Surface? {
        guard let surface = surfaces.removeValue(forKey: paneID) else { return nil }
        provider.destroySurface(surface)
        return surface
    }

    func injectOutput(paneID: Int, data: Data) {
        guard let surface = surfaces[paneID] else { return }
        provider.injectOutput(surface, data: data)
    }

    func surface(forPaneID paneID: Int) -> Provider.Surface? {
        surfaces[paneID]
    }

    func removeAll() -> [Int: Provider.Surface] {
        let old = surfaces
        surfaces.removeAll()
        return old
    }
}

// Production type alias using Ghostty surfaces — defined separately
// in the integration layer (Task 9).
```

**Step 4: Run tests — verify they pass**

**Step 5: Add tmux properties to SurfaceView**

Modify `Fantastty/GhosttyBridge/SurfaceView_AppKit.swift`. Add stored properties near the top (after existing properties around line 215):

```swift
/// Tmux control mode: pane ID this surface represents.
var tmuxPaneID: Int?
/// Tmux control mode: weak ref to control client for input routing.
weak var tmuxControlClient: TmuxControlClient?
```

**Step 6: Add input interception in `keyAction()`**

In `SurfaceView_AppKit.swift`, at the start of `keyAction()` (around line 1354), before existing logic:

```swift
// Tmux control mode: intercept input and route to control client
if let paneID = tmuxPaneID, let client = tmuxControlClient {
    if let text = text, !text.isEmpty {
        let data = Data(text.utf8)
        Task { await client.sendKeys(paneID: paneID, data: data) }
        return true
    }
}
```

Note: Non-text keys (arrows, function keys) need terminal escape sequence translation. This will be refined during integration testing (Task 15). The initial implementation handles printable text; special keys will be addressed as issues surface.

**Step 7: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxSurfaceManager.swift \
       FantasttyTests/TmuxSurfaceManagerTests.swift \
       Fantastty/GhosttyBridge/SurfaceView_AppKit.swift
git commit -m "feat: add TmuxSurfaceManager and input interception for control mode"
```

---

## Task 9: SessionManager Integration — Attach Flow

Wire the control client into SessionManager. Test delegate callbacks by calling them directly and verifying Session/Tab state.

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`
- Modify: `Fantastty/Models/Session.swift`
- Modify: `Fantastty/Models/TerminalTab.swift`
- Create: `FantasttyTests/SessionManagerAttachTests.swift`

**Step 1: Write failing tests**

```swift
// FantasttyTests/SessionManagerAttachTests.swift
import XCTest
@testable import Fantastty

/// Tests for SessionManager's TmuxControlClientDelegate behavior.
/// These test the delegate methods directly without a real tmux connection.
final class SessionManagerAttachTests: XCTestCase {

    // Helper to create a minimal attached session for testing.
    // Note: this requires SessionManager to be instantiable for tests.
    // If SessionManager requires ghosttyApp, we test the delegate logic
    // through extracted helper methods instead.

    // MARK: - Window add creates tab

    func testWindowAddCreatesTab() {
        // Given an attached session with no tabs
        let session = makeAttachedSession()
        XCTAssertEqual(session.tabs.count, 0)

        // When a window-add notification arrives
        let window = TmuxWindow(windowID: 1, name: "bash", paneIDs: [0])
        simulateWindowAdd(session: session, window: window)

        // Then a tab is created
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.tabs.first?.title, "bash")
        XCTAssertEqual(session.tabs.first?.tmuxWindowID, 1)
    }

    // MARK: - Window close removes tab

    func testWindowCloseRemovesTab() {
        let session = makeAttachedSession()
        simulateWindowAdd(session: session, window: TmuxWindow(windowID: 1, name: "a", paneIDs: [0]))
        simulateWindowAdd(session: session, window: TmuxWindow(windowID: 2, name: "b", paneIDs: [1]))
        XCTAssertEqual(session.tabs.count, 2)

        simulateWindowClose(session: session, windowID: 1)
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.tabs.first?.tmuxWindowID, 2)
    }

    // MARK: - Window rename updates tab title

    func testWindowRenameUpdatesTabTitle() {
        let session = makeAttachedSession()
        simulateWindowAdd(session: session, window: TmuxWindow(windowID: 1, name: "old", paneIDs: [0]))

        simulateWindowRename(session: session, windowID: 1, name: "new-name")
        XCTAssertEqual(session.tabs.first?.title, "new-name")
    }

    // MARK: - Connection state updates session mode

    func testConnectionStateUpdatesMode() {
        let session = makeAttachedSession()

        simulateStateChange(session: session, state: .connected)
        if case .attached(let info) = session.mode {
            XCTAssertEqual(info.connectionState, .connected)
        } else {
            XCTFail("Expected attached mode")
        }

        simulateStateChange(session: session, state: .disconnected(reason: "lost connection"))
        if case .attached(let info) = session.mode {
            XCTAssertEqual(info.connectionState, .disconnected(reason: "lost connection"))
        } else {
            XCTFail("Expected attached mode")
        }
    }

    // MARK: - Selected tab updates on close

    func testSelectedTabUpdatesOnClose() {
        let session = makeAttachedSession()
        simulateWindowAdd(session: session, window: TmuxWindow(windowID: 1, name: "a", paneIDs: [0]))
        simulateWindowAdd(session: session, window: TmuxWindow(windowID: 2, name: "b", paneIDs: [1]))
        session.selectedTabID = session.tabs.first?.id

        simulateWindowClose(session: session, windowID: 1)
        // Should auto-select remaining tab
        XCTAssertEqual(session.selectedTabID, session.tabs.first?.id)
    }

    // MARK: - Helpers

    private func makeAttachedSession() -> Session {
        let info = TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .connecting
        )
        // Create a minimal session — actual initializer may need adjustment
        let session = Session(
            title: "test",
            initialTab: TerminalTab.placeholder(),
            type: .local,
            workspaceID: "test1234"
        )
        session.mode = .attached(info)
        session.tabs = []  // clear placeholder tab
        return session
    }

    // These simulate what the TmuxControlClientDelegate methods do.
    // They test the pure state-manipulation logic.
    private func simulateWindowAdd(session: Session, window: TmuxWindow) {
        let tab = TerminalTab.placeholder()
        tab.title = window.name.isEmpty ? "Window @\(window.windowID)" : window.name
        tab.tmuxWindowID = window.windowID
        session.tabs.append(tab)
        if session.selectedTabID == nil {
            session.selectedTabID = tab.id
        }
    }

    private func simulateWindowClose(session: Session, windowID: Int) {
        guard let idx = session.tabs.firstIndex(where: { $0.tmuxWindowID == windowID }) else { return }
        let tab = session.tabs[idx]
        session.tabs.remove(at: idx)
        if session.selectedTabID == tab.id {
            session.selectedTabID = session.tabs.first?.id
        }
    }

    private func simulateWindowRename(session: Session, windowID: Int, name: String) {
        guard let tab = session.tabs.first(where: { $0.tmuxWindowID == windowID }) else { return }
        tab.title = name
    }

    private func simulateStateChange(session: Session, state: ConnectionState) {
        if case .attached(var info) = session.mode {
            info.connectionState = state
            session.mode = .attached(info)
        }
    }
}
```

**Step 2: Add required properties and helpers**

Add to `TerminalTab.swift`:
```swift
var tmuxWindowID: Int?

/// Minimal placeholder tab for testing and pre-population.
static func placeholder() -> TerminalTab {
    // Create a tab with no real surface — used before control client populates panes
    // Implementation depends on existing TerminalTab initializer flexibility
}
```

Add to `Session.swift` (if not already from Task 5):
```swift
var controlClient: TmuxControlClient?
var tmuxSurfaceManager: TmuxSurfaceManagerGeneric<GhosttySurfaceProvider>?
```

**Step 3: Implement TmuxControlClientDelegate conformance on SessionManager**

Add the delegate extension to SessionManager — see design doc for full code. The delegate methods perform the same state manipulation as the test helpers above, plus surface creation/destruction.

**Step 4: Implement `attachToTmuxSession()` on SessionManager**

This creates the Session, TmuxControlClient, and TmuxSurfaceManager, connects, and populates initial state.

**Step 5: Run tests — verify they pass**

**Step 6: Commit**

```bash
git add Fantastty/Models/SessionManager.swift \
       Fantastty/Models/Session.swift \
       Fantastty/Models/TerminalTab.swift \
       FantasttyTests/SessionManagerAttachTests.swift
git commit -m "feat: integrate TmuxControlClient with SessionManager for attach flow"
```

---

## Task 10: Resize Handling

Notify tmux when surfaces resize. Test that the correct command is generated.

**Files:**
- Modify: `Fantastty/GhosttyBridge/SurfaceView_AppKit.swift`
- Create: `FantasttyTests/TmuxResizeTests.swift`

**Step 1: Write test for resize command generation**

```swift
// FantasttyTests/TmuxResizeTests.swift
import XCTest
@testable import Fantastty

final class TmuxResizeTests: XCTestCase {

    func testResizeCommandFormat() {
        // Verify the command string that would be sent to tmux
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
        // Tmux handles minimum sizes itself
        let paneID = 0
        let cols = 1
        let rows = 1
        let command = "resize-pane -t %\(paneID) -x \(cols) -y \(rows)"
        XCTAssertEqual(command, "resize-pane -t %0 -x 1 -y 1")
    }
}
```

**Step 2: Add resize notification to SurfaceView**

In `SurfaceView_AppKit.swift`, in `sizeDidChange()` (around line 455), after `ghostty_surface_set_size()`:

```swift
if let paneID = tmuxPaneID, let client = tmuxControlClient {
    let surfaceSize = ghostty_surface_size(surface)
    let cols = Int(surfaceSize.columns)
    let rows = Int(surfaceSize.rows)
    Task {
        try? await client.resizePane(paneID: paneID, width: cols, height: rows)
    }
}
```

**Step 3: Run tests — verify they pass**

**Step 4: Commit**

```bash
git add Fantastty/GhosttyBridge/SurfaceView_AppKit.swift \
       FantasttyTests/TmuxResizeTests.swift
git commit -m "feat: notify tmux of pane resize from surface size changes"
```

---

## Task 11: Persistence — Layout & Re-Attach

Persist attached session info. Test round-trip encoding and SSH host storage.

**Files:**
- Modify: `Fantastty/Models/LayoutSnapshot.swift`
- Create: `Fantastty/Models/TmuxControlMode/SSHHostStore.swift`
- Create: `FantasttyTests/PersistenceTests.swift`
- Modify: `Fantastty/Models/SessionManager.swift` (saveLayout + restore)

**Step 1: Write failing tests**

```swift
// FantasttyTests/PersistenceTests.swift
import XCTest
@testable import Fantastty

final class PersistenceTests: XCTestCase {

    // MARK: - WorkspaceLayout round-trip with attachment

    func testWorkspaceLayoutWithAttachmentCodable() throws {
        let attachment = TmuxAttachmentInfo(
            sessionName: "dev",
            host: .ssh(SSHHostInfo(user: "me", hostname: "box", port: 2222)),
            connectionState: .disconnected(reason: nil)
        )
        let layout = WorkspaceLayout(
            workspaceID: "test1234",
            baseSessionName: "",
            tabSessionNames: [],
            selectedTabIndex: 0,
            sessionType: .local,
            attachment: attachment
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        XCTAssertEqual(decoded.workspaceID, "test1234")
        XCTAssertEqual(decoded.attachment?.sessionName, "dev")
        XCTAssertEqual(decoded.attachment?.host, .ssh(SSHHostInfo(user: "me", hostname: "box", port: 2222)))
    }

    func testWorkspaceLayoutWithoutAttachmentCodable() throws {
        let layout = WorkspaceLayout(
            workspaceID: "test1234",
            baseSessionName: "fantastty-ws-test1234",
            tabSessionNames: ["fantastty-ws-test1234-tab-1"],
            selectedTabIndex: 1,
            sessionType: .local,
            attachment: nil
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        XCTAssertNil(decoded.attachment)
        XCTAssertEqual(decoded.baseSessionName, "fantastty-ws-test1234")
    }

    func testLayoutSnapshotWithMixedSessionsCodable() throws {
        let snapshot = LayoutSnapshot(
            workspaces: [
                WorkspaceLayout(
                    workspaceID: "managed1",
                    baseSessionName: "fantastty-ws-managed1",
                    tabSessionNames: [],
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: nil
                ),
                WorkspaceLayout(
                    workspaceID: "attached1",
                    baseSessionName: "",
                    tabSessionNames: [],
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: TmuxAttachmentInfo(
                        sessionName: "external",
                        host: .local,
                        connectionState: .disconnected(reason: nil)
                    )
                ),
            ],
            selectedWorkspaceID: "attached1",
            savedAt: Date()
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(LayoutSnapshot.self, from: data)
        XCTAssertEqual(decoded.workspaces.count, 2)
        XCTAssertNil(decoded.workspaces[0].attachment)
        XCTAssertNotNil(decoded.workspaces[1].attachment)
    }

    // MARK: - SSHHostStore

    func testSSHHostStoreAddAndRemove() {
        // Use a temp file to avoid polluting real config
        let store = SSHHostStore(fileURL: tempFileURL())

        let host = SSHHostInfo(user: "me", hostname: "box", port: nil)
        store.add(host)
        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(store.hosts.first, host)

        // Adding duplicate is no-op
        store.add(host)
        XCTAssertEqual(store.hosts.count, 1)

        store.remove(host)
        XCTAssertEqual(store.hosts.count, 0)
    }

    func testSSHHostStorePersistence() {
        let url = tempFileURL()

        let store1 = SSHHostStore(fileURL: url)
        store1.add(SSHHostInfo(user: nil, hostname: "alpha", port: nil))
        store1.add(SSHHostInfo(user: "root", hostname: "beta", port: 22))

        // New instance from same file should load saved hosts
        let store2 = SSHHostStore(fileURL: url)
        XCTAssertEqual(store2.hosts.count, 2)
        XCTAssertEqual(store2.hosts[0].hostname, "alpha")
        XCTAssertEqual(store2.hosts[1].hostname, "beta")
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-ssh-hosts-\(UUID().uuidString).json")
    }
}
```

**Step 2: Extend WorkspaceLayout**

Add to `WorkspaceLayout` in `LayoutSnapshot.swift`:

```swift
var attachment: TmuxAttachmentInfo?
```

**Step 3: Implement SSHHostStore**

```swift
// Fantastty/Models/TmuxControlMode/SSHHostStore.swift
import Foundation

class SSHHostStore {
    private let fileURL: URL
    private(set) var hosts: [SSHHostInfo] = []

    /// Production initializer using default path.
    convenience init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fantastty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("ssh-hosts.json"))
    }

    /// Testable initializer accepting a custom file URL.
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

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

**Step 4: Update SessionManager saveLayout/restore**

In `saveLayout()`, populate `attachment` field for attached sessions.
In `restoreTmuxSessions()`, handle entries with `attachment != nil`.

**Step 5: Run tests — verify they pass**

**Step 6: Commit**

```bash
git add Fantastty/Models/LayoutSnapshot.swift \
       Fantastty/Models/TmuxControlMode/SSHHostStore.swift \
       Fantastty/Models/SessionManager.swift \
       FantasttyTests/PersistenceTests.swift
git commit -m "feat: persist attached sessions and SSH hosts for re-attach on launch"
```

---

## Task 12: Attach UI — Session Discovery Dialog

SwiftUI sheet with testable logic extracted into pure functions.

**Files:**
- Create: `Fantastty/Views/TmuxAttachSheet.swift`
- Create: `FantasttyTests/TmuxAttachUITests.swift`
- Modify: Sidebar view to present the sheet

**Step 1: Write tests for extracted logic**

```swift
// FantasttyTests/TmuxAttachUITests.swift
import XCTest
@testable import Fantastty

final class TmuxAttachUITests: XCTestCase {

    // MARK: - Host string parsing

    func testParseHostnameOnly() {
        let host = TmuxAttachSheet.parseHostString("dev.example.com")
        XCTAssertNotNil(host)
        XCTAssertNil(host?.user)
        XCTAssertEqual(host?.hostname, "dev.example.com")
        XCTAssertNil(host?.port)
    }

    func testParseUserAtHost() {
        let host = TmuxAttachSheet.parseHostString("deploy@prod.example.com")
        XCTAssertEqual(host?.user, "deploy")
        XCTAssertEqual(host?.hostname, "prod.example.com")
        XCTAssertNil(host?.port)
    }

    func testParseHostnameWithPort() {
        let host = TmuxAttachSheet.parseHostString("dev.example.com:2222")
        XCTAssertNil(host?.user)
        XCTAssertEqual(host?.hostname, "dev.example.com")
        XCTAssertEqual(host?.port, 2222)
    }

    func testParseFullHostString() {
        let host = TmuxAttachSheet.parseHostString("deploy@prod.example.com:2222")
        XCTAssertEqual(host?.user, "deploy")
        XCTAssertEqual(host?.hostname, "prod.example.com")
        XCTAssertEqual(host?.port, 2222)
    }

    func testParseEmptyStringReturnsNil() {
        XCTAssertNil(TmuxAttachSheet.parseHostString(""))
    }

    func testParseJustAtSignReturnsNil() {
        XCTAssertNil(TmuxAttachSheet.parseHostString("@"))
    }

    func testParseIPv4() {
        let host = TmuxAttachSheet.parseHostString("192.168.1.100")
        XCTAssertEqual(host?.hostname, "192.168.1.100")
    }

    func testParseIPv4WithPort() {
        let host = TmuxAttachSheet.parseHostString("192.168.1.100:22")
        XCTAssertEqual(host?.hostname, "192.168.1.100")
        XCTAssertEqual(host?.port, 22)
    }

    // MARK: - Session filtering

    func testFilterByName() {
        let sessions = [
            TmuxAttachSheet.DiscoveredSession(name: "my-project", host: .local, windowCount: 2),
            TmuxAttachSheet.DiscoveredSession(name: "dev-server", host: .local, windowCount: 1),
            TmuxAttachSheet.DiscoveredSession(name: "other", host: .local, windowCount: 3),
        ]
        let filtered = TmuxAttachSheet.filterSessions(sessions, by: "dev")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "dev-server")
    }

    func testFilterByHostname() {
        let sessions = [
            TmuxAttachSheet.DiscoveredSession(name: "work", host: .local, windowCount: 1),
            TmuxAttachSheet.DiscoveredSession(
                name: "work",
                host: .ssh(SSHHostInfo(user: nil, hostname: "prod.example.com", port: nil)),
                windowCount: 1
            ),
        ]
        let filtered = TmuxAttachSheet.filterSessions(sessions, by: "prod")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.host.displayName, "prod.example.com")
    }

    func testEmptyFilterReturnsAll() {
        let sessions = [
            TmuxAttachSheet.DiscoveredSession(name: "a", host: .local, windowCount: 1),
            TmuxAttachSheet.DiscoveredSession(name: "b", host: .local, windowCount: 2),
        ]
        let filtered = TmuxAttachSheet.filterSessions(sessions, by: "")
        XCTAssertEqual(filtered.count, 2)
    }

    func testFilterIsCaseInsensitive() {
        let sessions = [
            TmuxAttachSheet.DiscoveredSession(name: "MyProject", host: .local, windowCount: 1),
        ]
        let filtered = TmuxAttachSheet.filterSessions(sessions, by: "myproject")
        XCTAssertEqual(filtered.count, 1)
    }
}
```

**Step 2: Implement TmuxAttachSheet with extracted static methods**

```swift
// Fantastty/Views/TmuxAttachSheet.swift
import SwiftUI

struct TmuxAttachSheet: View {
    // ... (SwiftUI view body as in earlier plan)

    // MARK: - Extracted testable logic

    struct DiscoveredSession: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let host: TmuxHost
        let windowCount: Int
    }

    static func parseHostString(_ s: String) -> SSHHostInfo? {
        guard !s.isEmpty else { return nil }
        var user: String?
        var hostname = s
        var port: Int?

        if let atIndex = hostname.firstIndex(of: "@") {
            let u = String(hostname[..<atIndex])
            guard !u.isEmpty else { return nil }
            user = u
            hostname = String(hostname[hostname.index(after: atIndex)...])
        }
        guard !hostname.isEmpty else { return nil }

        if let colonIndex = hostname.lastIndex(of: ":") {
            if let p = Int(hostname[hostname.index(after: colonIndex)...]) {
                port = p
                hostname = String(hostname[..<colonIndex])
            }
        }
        guard !hostname.isEmpty else { return nil }
        return SSHHostInfo(user: user, hostname: hostname, port: port)
    }

    static func filterSessions(_ sessions: [DiscoveredSession], by filter: String) -> [DiscoveredSession] {
        guard !filter.isEmpty else { return sessions }
        return sessions.filter {
            $0.name.localizedCaseInsensitiveContains(filter) ||
            $0.host.displayName.localizedCaseInsensitiveContains(filter)
        }
    }
}
```

**Step 3: Add `listAllSessions()` to TmuxManager**

**Step 4: Wire sheet presentation from sidebar**

**Step 5: Run tests — verify they pass**

**Step 6: Commit**

```bash
git add Fantastty/Views/TmuxAttachSheet.swift \
       FantasttyTests/TmuxAttachUITests.swift \
       Fantastty/Models/TmuxManager.swift
git commit -m "feat: add tmux session discovery dialog with testable logic"
```

---

## Task 13: Sidebar — Host Provenance & Connection State

Visual indicators for attached sessions. Test the display model derivation.

**Files:**
- Create: `Fantastty/Models/SessionDisplayInfo.swift`
- Create: `FantasttyTests/SessionDisplayInfoTests.swift`
- Modify: Sidebar session row view

**Step 1: Write tests for display model**

```swift
// FantasttyTests/SessionDisplayInfoTests.swift
import XCTest
@testable import Fantastty

final class SessionDisplayInfoTests: XCTestCase {

    func testManagedSessionHasNoHostLabel() {
        let info = SessionDisplayInfo(mode: .managed)
        XCTAssertNil(info.hostLabel)
        XCTAssertFalse(info.isDisconnected)
        XCTAssertFalse(info.isAttached)
    }

    func testAttachedLocalConnected() {
        let attachment = TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .connected
        )
        let info = SessionDisplayInfo(mode: .attached(attachment))
        XCTAssertEqual(info.hostLabel, "localhost")
        XCTAssertFalse(info.isDisconnected)
        XCTAssertTrue(info.isAttached)
    }

    func testAttachedRemoteDisconnected() {
        let attachment = TmuxAttachmentInfo(
            sessionName: "test",
            host: .ssh(SSHHostInfo(user: "me", hostname: "mybox", port: nil)),
            connectionState: .disconnected(reason: "lost connection")
        )
        let info = SessionDisplayInfo(mode: .attached(attachment))
        XCTAssertEqual(info.hostLabel, "me@mybox")
        XCTAssertTrue(info.isDisconnected)
        XCTAssertEqual(info.disconnectReason, "lost connection")
    }

    func testAttachedConnecting() {
        let attachment = TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .connecting
        )
        let info = SessionDisplayInfo(mode: .attached(attachment))
        XCTAssertTrue(info.isConnecting)
        XCTAssertFalse(info.isDisconnected)
    }
}
```

**Step 2: Implement SessionDisplayInfo**

```swift
// Fantastty/Models/SessionDisplayInfo.swift
import Foundation

/// Pure value type deriving display properties from SessionMode.
struct SessionDisplayInfo {
    let hostLabel: String?
    let isAttached: Bool
    let isConnecting: Bool
    let isDisconnected: Bool
    let disconnectReason: String?

    init(mode: SessionMode) {
        switch mode {
        case .managed:
            hostLabel = nil
            isAttached = false
            isConnecting = false
            isDisconnected = false
            disconnectReason = nil

        case .attached(let info):
            hostLabel = info.host.displayName
            isAttached = true
            switch info.connectionState {
            case .connecting:
                isConnecting = true
                isDisconnected = false
                disconnectReason = nil
            case .connected:
                isConnecting = false
                isDisconnected = false
                disconnectReason = nil
            case .disconnected(let reason):
                isConnecting = false
                isDisconnected = true
                disconnectReason = reason
            }
        }
    }
}
```

**Step 3: Update sidebar row to use SessionDisplayInfo**

**Step 4: Run tests — verify they pass**

**Step 5: Commit**

```bash
git add Fantastty/Models/SessionDisplayInfo.swift \
       FantasttyTests/SessionDisplayInfoTests.swift
git commit -m "feat: add SessionDisplayInfo and sidebar connection state indicators"
```

---

## Task 14: Window Management Commands from Fantastty UI

Route Fantastty's tab/split actions to tmux for attached sessions. Test via a mock control client.

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`
- Create: `FantasttyTests/WindowManagementTests.swift`

**Step 1: Define a protocol for the control client's command interface**

```swift
/// Protocol for sending commands to a tmux session.
/// Allows testing SessionManager without a real TmuxControlClient.
protocol TmuxCommandSending: AnyObject {
    func newWindow() async throws -> String
    func killWindow(windowID: Int) async throws
    func renameWindow(windowID: Int, name: String) async throws
    func splitPane(paneID: Int, horizontal: Bool) async throws
    func killPane(paneID: Int) async throws
}

// TmuxControlClient already conforms — just declare conformance:
extension TmuxControlClient: TmuxCommandSending {}
```

**Step 2: Write failing tests with a mock**

```swift
// FantasttyTests/WindowManagementTests.swift
import XCTest
@testable import Fantastty

final class MockTmuxCommandSender: TmuxCommandSending {
    var newWindowCalls = 0
    var killedWindowIDs: [Int] = []
    var renamedWindows: [(windowID: Int, name: String)] = []
    var splitPaneCalls: [(paneID: Int, horizontal: Bool)] = []
    var killedPaneIDs: [Int] = []

    func newWindow() async throws -> String {
        newWindowCalls += 1
        return ""
    }
    func killWindow(windowID: Int) async throws {
        killedWindowIDs.append(windowID)
    }
    func renameWindow(windowID: Int, name: String) async throws {
        renamedWindows.append((windowID, name))
    }
    func splitPane(paneID: Int, horizontal: Bool) async throws {
        splitPaneCalls.append((paneID, horizontal))
    }
    func killPane(paneID: Int) async throws {
        killedPaneIDs.append(paneID)
    }
}

final class WindowManagementTests: XCTestCase {

    func testCreateTabOnAttachedSessionSendsNewWindow() async throws {
        let mock = MockTmuxCommandSender()
        // Simulate what SessionManager.createTab does for attached sessions
        try await mock.newWindow()
        XCTAssertEqual(mock.newWindowCalls, 1)
    }

    func testCloseTabOnAttachedSessionSendsKillWindow() async throws {
        let mock = MockTmuxCommandSender()
        let windowID = 5
        try await mock.killWindow(windowID: windowID)
        XCTAssertEqual(mock.killedWindowIDs, [5])
    }

    func testSplitOnAttachedSessionSendsSplitPane() async throws {
        let mock = MockTmuxCommandSender()
        try await mock.splitPane(paneID: 3, horizontal: true)
        XCTAssertEqual(mock.splitPaneCalls.count, 1)
        XCTAssertEqual(mock.splitPaneCalls.first?.paneID, 3)
        XCTAssertTrue(mock.splitPaneCalls.first?.horizontal ?? false)
    }

    func testRenameWindowOnAttachedSession() async throws {
        let mock = MockTmuxCommandSender()
        try await mock.renameWindow(windowID: 2, name: "new-name")
        XCTAssertEqual(mock.renamedWindows.count, 1)
        XCTAssertEqual(mock.renamedWindows.first?.name, "new-name")
    }

    func testClosePaneOnAttachedSession() async throws {
        let mock = MockTmuxCommandSender()
        try await mock.killPane(paneID: 7)
        XCTAssertEqual(mock.killedPaneIDs, [7])
    }
}
```

**Step 3: Modify SessionManager's createTab/closeTab/handleNewSplit**

In `createTab()`: if the session has a `controlClient`, call `newWindow()` and return (tab created asynchronously via delegate).

In `closeTab()`: if attached, call `killWindow()` (tab removed via delegate).

In split handler: if attached, call `splitPane()` (layout change arrives via delegate).

**Step 4: Run tests — verify they pass**

**Step 5: Commit**

```bash
git add Fantastty/Models/SessionManager.swift \
       FantasttyTests/WindowManagementTests.swift
git commit -m "feat: route tab/split creation and closure through tmux control client"
```

---

## Task 15: End-to-End Testing & Polish

Manual integration testing against a real tmux instance.

**Step 1: Local attach test**

1. `tmux new-session -s test-session`
2. `Ctrl-b c` (create second window)
3. In Fantastty: "+" → "Attach to tmux session..." → select "test-session"
4. Verify: two tabs appear
5. Type in each tab — verify input reaches correct window
6. In tmux: `Ctrl-b c` — verify new tab appears
7. In tmux: `Ctrl-b &` (kill window) — verify tab disappears
8. In tmux: `Ctrl-b ,` (rename) — verify tab title updates
9. In Fantastty: create new tab — verify tmux window appears
10. In tmux: `Ctrl-b %` (split) — verify two splits appear in tab

**Step 2: Disconnect/reconnect test**

1. Attach to local session
2. `tmux kill-session -s test-session`
3. Verify: disconnected state in sidebar
4. Recreate session, click "Reconnect"
5. Verify: re-attachment works

**Step 3: SSH test** (if remote host available)

1. Add SSH host
2. List remote sessions
3. Attach — verify windows/input work

**Step 4: Persistence test**

1. Attach to session
2. Quit Fantastty
3. Relaunch — verify re-attach
4. Kill tmux before relaunch — verify disconnected state

**Step 5: Fix issues, commit**

```bash
git add -u
git commit -m "fix: address issues from end-to-end testing"
```

---

## File Summary

### New Files (in `Fantastty/Models/TmuxControlMode/`)
| File | Purpose | Tests |
|------|---------|-------|
| `TmuxEvent.swift` | Event enum | TmuxProtocolParserTests |
| `TmuxProtocolParser.swift` | Line→event parser | TmuxProtocolParserTests |
| `TmuxLayoutParser.swift` | Layout string parser | TmuxLayoutParserTests |
| `TmuxLayoutMapper.swift` | Layout→SplitTree mapping | TmuxLayoutMapperTests |
| `CommandQueue.swift` | Command/response FIFO | CommandQueueTests |
| `TmuxAttachmentInfo.swift` | Model types | TmuxAttachmentInfoTests |
| `TmuxControlClient.swift` | Control mode actor | TmuxControlClientTests |
| `TmuxSurfaceManager.swift` | Pane→surface management | TmuxSurfaceManagerTests |
| `SSHHostStore.swift` | Persist SSH hosts | PersistenceTests |

### New Files (in `Fantastty/Views/`)
| File | Purpose | Tests |
|------|---------|-------|
| `TmuxAttachSheet.swift` | Discovery/attach dialog | TmuxAttachUITests |

### New Files (in `Fantastty/Models/`)
| File | Purpose | Tests |
|------|---------|-------|
| `SessionDisplayInfo.swift` | Display state derivation | SessionDisplayInfoTests |

### Test Files (in `FantasttyTests/`)
| File | What it tests |
|------|---------------|
| `TmuxProtocolParserTests.swift` | Protocol line parsing, octal decoding, DCS stripping |
| `TmuxLayoutParserTests.swift` | Layout string → tree parsing |
| `CommandQueueTests.swift` | FIFO enqueue/dequeue, response accumulation |
| `TmuxAttachmentInfoTests.swift` | Codable round-trips, command generation, display names |
| `TmuxControlClientTests.swift` | Event dispatch, delegate callbacks, state transitions |
| `TmuxLayoutMapperTests.swift` | N-ary→binary split conversion, ratios |
| `TmuxSurfaceManagerTests.swift` | Pane→surface CRUD, output injection routing |
| `SessionManagerAttachTests.swift` | Tab lifecycle from control client events |
| `TmuxResizeTests.swift` | Resize command format |
| `PersistenceTests.swift` | Layout Codable round-trip, SSH host store |
| `TmuxAttachUITests.swift` | Host string parsing, session filtering |
| `SessionDisplayInfoTests.swift` | Mode→display state derivation |
| `WindowManagementTests.swift` | Tab/split commands routed to mock control client |

### Modified Files
| File | Changes |
|------|---------|
| `Session.swift` | Add `mode`, `controlClient`, `tmuxSurfaceManager` |
| `TerminalTab.swift` | Add `tmuxWindowID`, `placeholder()` |
| `SessionManager.swift` | Add `attachToTmuxSession()`, `TmuxControlClientDelegate`, modify `createTab`/`closeTab` |
| `SurfaceView_AppKit.swift` | Add `tmuxPaneID`, `tmuxControlClient`; input interception; resize notification |
| `LayoutSnapshot.swift` | Add `attachment` to `WorkspaceLayout` |
| `TmuxManager.swift` | Add `listAllSessions()` |
| Sidebar view | "Attach to tmux session..." entry, host/state UI |
