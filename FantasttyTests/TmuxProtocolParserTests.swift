import XCTest
@testable import Fantastty

final class TmuxProtocolParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testNonPercentLineReturnsNil() {
        var parser = TmuxProtocolParser()
        XCTAssertNil(parser.parse(line: "some data line"))
    }

    func testEmptyLineReturnsNil() {
        var parser = TmuxProtocolParser()
        XCTAssertNil(parser.parse(line: ""))
    }

    func testCarriageReturnStripping() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%sessions-changed\r")
        XCTAssertEqual(event, .sessionsChanged)
    }

    // MARK: - DCS Prefix Stripping

    func testDCSPrefixStrippedOnFirstLine() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "\u{1b}P1000p%sessions-changed")
        XCTAssertEqual(event, .sessionsChanged)
    }

    func testDCSPrefixNotStrippedOnSecondLine() {
        var parser = TmuxProtocolParser()
        // First line: consume DCS stripping opportunity
        _ = parser.parse(line: "%sessions-changed")
        // Second line: DCS prefix should NOT be stripped
        let event = parser.parse(line: "\u{1b}P1000p%sessions-changed")
        XCTAssertNil(event, "DCS prefix should only be stripped from the first line")
    }

    // MARK: - Window Notifications

    func testWindowAdd() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%window-add @1")
        XCTAssertEqual(event, .windowAdd(windowID: 1))
    }

    func testWindowClose() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%window-close @42")
        XCTAssertEqual(event, .windowClose(windowID: 42))
    }

    func testWindowRenamed() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%window-renamed @3 my window")
        XCTAssertEqual(event, .windowRenamed(windowID: 3, name: "my window"))
    }

    func testWindowRenamedWithSpaces() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%window-renamed @7 a long window name with spaces")
        XCTAssertEqual(event, .windowRenamed(windowID: 7, name: "a long window name with spaces"))
    }

    // MARK: - Session Notifications

    func testSessionChanged() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%session-changed $1 my-session")
        XCTAssertEqual(event, .sessionChanged(sessionID: 1, name: "my-session"))
    }

    func testSessionsChanged() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%sessions-changed")
        XCTAssertEqual(event, .sessionsChanged)
    }

    // MARK: - Layout Change

    func testLayoutChange() {
        var parser = TmuxProtocolParser()
        let layout = "b]d1,204x52,0,0{102x52,0,0,3,101x52,103,0,6}"
        let event = parser.parse(line: "%layout-change @1 \(layout)")
        XCTAssertEqual(event, .layoutChange(windowID: 1, layout: layout))
    }

    // MARK: - Pane Mode Changed

    func testPaneModeChanged() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%pane-mode-changed %5")
        XCTAssertEqual(event, .paneModeChanged(paneID: 5))
    }

    // MARK: - Exit

    func testExitWithReason() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%exit server exited")
        XCTAssertEqual(event, .exit(reason: "server exited"))
    }

    func testExitWithoutReason() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%exit")
        XCTAssertEqual(event, .exit(reason: nil))
    }

    // MARK: - Unknown Notifications

    func testUnknownNotification() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%some-future-notification arg1 arg2")
        XCTAssertEqual(event, .unknown("%some-future-notification arg1 arg2"))
    }

    // MARK: - Output

    func testOutputSimpleText() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%output %0 hello world")
        XCTAssertEqual(event, .output(paneID: 0, data: Data("hello world".utf8)))
    }

    func testOutputOctalCRLF() {
        var parser = TmuxProtocolParser()
        // \015 = CR (13), \012 = LF (10)
        let event = parser.parse(line: "%output %1 line1\\015\\012line2")
        let expected = Data([
            UInt8(ascii: "l"), UInt8(ascii: "i"), UInt8(ascii: "n"), UInt8(ascii: "e"), UInt8(ascii: "1"),
            13, 10,
            UInt8(ascii: "l"), UInt8(ascii: "i"), UInt8(ascii: "n"), UInt8(ascii: "e"), UInt8(ascii: "2"),
        ])
        XCTAssertEqual(event, .output(paneID: 1, data: expected))
    }

    func testOutputBackslashEscape() {
        var parser = TmuxProtocolParser()
        // \134 = backslash (92)
        let event = parser.parse(line: "%output %2 path\\134file")
        let expected = Data("path\\file".utf8)
        XCTAssertEqual(event, .output(paneID: 2, data: expected))
    }

    func testOutputESCSequence() {
        var parser = TmuxProtocolParser()
        // \033 = ESC (27), followed by [0m (SGR reset)
        let event = parser.parse(line: "%output %0 \\033[0m")
        let expected = Data([27, UInt8(ascii: "["), UInt8(ascii: "0"), UInt8(ascii: "m")])
        XCTAssertEqual(event, .output(paneID: 0, data: expected))
    }

    func testOutputEmptyData() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%output %0 ")
        XCTAssertEqual(event, .output(paneID: 0, data: Data()))
    }

    // MARK: - Begin/End/Error Blocks

    func testBeginBlock() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%begin 1609459200 42 0")
        XCTAssertEqual(event, .beginBlock(id: 42, flags: 0))
    }

    func testEndBlock() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%end 1609459200 42 0")
        XCTAssertEqual(event, .endBlock(id: 42, flags: 0))
    }

    func testErrorBlock() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%error 1609459200 42 1")
        XCTAssertEqual(event, .errorBlock(id: 42, flags: 1))
    }

    func testBeginBlockWithDifferentFlags() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%begin 1700000000 100 255")
        XCTAssertEqual(event, .beginBlock(id: 100, flags: 255))
    }

    // MARK: - ID Parsing Helpers

    func testParseAtID() {
        XCTAssertEqual(TmuxProtocolParser.parseAtID("@0"), 0)
        XCTAssertEqual(TmuxProtocolParser.parseAtID("@123"), 123)
        XCTAssertNil(TmuxProtocolParser.parseAtID("123"))
        XCTAssertNil(TmuxProtocolParser.parseAtID("%5"))
    }

    func testParsePercentID() {
        XCTAssertEqual(TmuxProtocolParser.parsePercentID("%0"), 0)
        XCTAssertEqual(TmuxProtocolParser.parsePercentID("%99"), 99)
        XCTAssertNil(TmuxProtocolParser.parsePercentID("@1"))
        XCTAssertNil(TmuxProtocolParser.parsePercentID("99"))
    }

    func testParseDollarID() {
        XCTAssertEqual(TmuxProtocolParser.parseDollarID("$0"), 0)
        XCTAssertEqual(TmuxProtocolParser.parseDollarID("$5"), 5)
        XCTAssertNil(TmuxProtocolParser.parseDollarID("@1"))
        XCTAssertNil(TmuxProtocolParser.parseDollarID("5"))
    }

    // MARK: - Octal Escape Decoding

    func testDecodeOctalEscapesPlainText() {
        let data = TmuxProtocolParser.decodeOctalEscapes("hello")
        XCTAssertEqual(data, Data("hello".utf8))
    }

    func testDecodeOctalEscapesCRLF() {
        let data = TmuxProtocolParser.decodeOctalEscapes("a\\015\\012b")
        XCTAssertEqual(data, Data([UInt8(ascii: "a"), 13, 10, UInt8(ascii: "b")]))
    }

    func testDecodeOctalEscapesBackslash() {
        // \134 = 92 = backslash
        let data = TmuxProtocolParser.decodeOctalEscapes("\\134")
        XCTAssertEqual(data, Data([92]))
    }

    func testDecodeOctalEscapesESC() {
        // \033 = 27 = ESC
        let data = TmuxProtocolParser.decodeOctalEscapes("\\033[0m")
        XCTAssertEqual(data, Data([27, UInt8(ascii: "["), UInt8(ascii: "0"), UInt8(ascii: "m")]))
    }

    func testDecodeOctalEscapesEmptyString() {
        let data = TmuxProtocolParser.decodeOctalEscapes("")
        XCTAssertEqual(data, Data())
    }

    func testDecodeOctalEscapesMultipleEscapes() {
        // \001\002\003
        let data = TmuxProtocolParser.decodeOctalEscapes("\\001\\002\\003")
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    // MARK: - Edge Cases

    func testMultipleEventsInSequence() {
        var parser = TmuxProtocolParser()
        let e1 = parser.parse(line: "%window-add @1")
        let e2 = parser.parse(line: "some data")
        let e3 = parser.parse(line: "%window-close @1")
        XCTAssertEqual(e1, .windowAdd(windowID: 1))
        XCTAssertNil(e2)
        XCTAssertEqual(e3, .windowClose(windowID: 1))
    }

    func testOutputWithLargePaneID() {
        var parser = TmuxProtocolParser()
        let event = parser.parse(line: "%output %999 data")
        XCTAssertEqual(event, .output(paneID: 999, data: Data("data".utf8)))
    }
}
