import XCTest
@testable import Fantastty

final class GhosttyThemeParserTests: XCTestCase {

    // MARK: - ThemeColor hex parsing

    func testHexParsesSixDigitColor() {
        let c = ThemeColor(hex: "#282a36")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, Double(0x28) / 255, accuracy: 0.0001)
        XCTAssertEqual(c!.g, Double(0x2a) / 255, accuracy: 0.0001)
        XCTAssertEqual(c!.b, Double(0x36) / 255, accuracy: 0.0001)
    }

    func testHexToleratesMissingHash() {
        XCTAssertEqual(ThemeColor(hex: "ffffff"), ThemeColor(hex: "#ffffff"))
    }

    func testHexRejectsGarbage() {
        XCTAssertNil(ThemeColor(hex: "#xyz"))
        XCTAssertNil(ThemeColor(hex: ""))
        XCTAssertNil(ThemeColor(hex: "#12"))
    }

    // MARK: - Theme parsing

    private let dracula = """
    palette = 0=#21222c
    palette = 1=#ff5555
    palette = 2=#50fa7b
    palette = 3=#f1fa8c
    palette = 4=#bd93f9
    palette = 5=#ff79c6
    palette = 6=#8be9fd
    palette = 7=#f8f8f2
    palette = 8=#6272a4
    palette = 9=#ff6e6e
    palette = 10=#69ff94
    palette = 11=#ffffa5
    palette = 12=#d6acff
    palette = 13=#ff92df
    palette = 14=#a4ffff
    palette = 15=#ffffff
    background = #282a36
    foreground = #f8f8f2
    cursor-color = #f8f8f2
    """

    func testParsesNameBackgroundForegroundCursor() {
        let theme = GhosttyThemeParser.parse(name: "Dracula", contents: dracula)
        XCTAssertEqual(theme.name, "Dracula")
        XCTAssertEqual(theme.background, ThemeColor(hex: "#282a36"))
        XCTAssertEqual(theme.foreground, ThemeColor(hex: "#f8f8f2"))
        XCTAssertEqual(theme.cursor, ThemeColor(hex: "#f8f8f2"))
    }

    func testParsesAllSixteenPaletteColorsInIndexOrder() {
        let theme = GhosttyThemeParser.parse(name: "Dracula", contents: dracula)
        XCTAssertEqual(theme.palette.count, 16)
        XCTAssertEqual(theme.palette[0], ThemeColor(hex: "#21222c"))
        XCTAssertEqual(theme.palette[1], ThemeColor(hex: "#ff5555"))
        XCTAssertEqual(theme.palette[15], ThemeColor(hex: "#ffffff"))
    }

    func testCursorFallsBackToForegroundWhenAbsent() {
        let contents = "background = #000000\nforeground = #abcdef\n"
        let theme = GhosttyThemeParser.parse(name: "Minimal", contents: contents)
        XCTAssertEqual(theme.cursor, ThemeColor(hex: "#abcdef"))
    }

    func testRawContentsPreservedForOverlayInlining() {
        let theme = GhosttyThemeParser.parse(name: "Dracula", contents: dracula)
        XCTAssertEqual(theme.rawContents, dracula)
    }

    func testIgnoresBlankLinesAndUnknownKeys() {
        let contents = """

        background = #101010

        selection-background = #303030
        foreground = #e0e0e0
        """
        let theme = GhosttyThemeParser.parse(name: "Sparse", contents: contents)
        XCTAssertEqual(theme.background, ThemeColor(hex: "#101010"))
        XCTAssertEqual(theme.foreground, ThemeColor(hex: "#e0e0e0"))
    }
}
