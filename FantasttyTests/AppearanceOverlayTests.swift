import XCTest
@testable import Fantastty

final class AppearanceOverlayTests: XCTestCase {

    func testFontOnly() {
        let text = AppearanceManager.overlayText(
            fontFamily: "JetBrains Mono",
            fontStyle: "Bold",
            fontSize: 14,
            themeContents: nil
        )
        XCTAssertEqual(text, "font-family = JetBrains Mono\nfont-style = Bold\nfont-size = 14\n")
    }

    func testThemeOnlyIsInlinedVerbatim() {
        let theme = "background = #282a36\nforeground = #f8f8f2"
        let text = AppearanceManager.overlayText(
            fontFamily: nil,
            fontStyle: nil,
            fontSize: 0,
            themeContents: theme
        )
        XCTAssertEqual(text, "background = #282a36\nforeground = #f8f8f2\n")
    }

    func testFontAndThemeTogether() {
        let theme = "background = #000000\nforeground = #ffffff"
        let text = AppearanceManager.overlayText(
            fontFamily: "Menlo",
            fontStyle: nil,
            fontSize: 13,
            themeContents: theme
        )
        XCTAssertEqual(
            text,
            "font-family = Menlo\nfont-size = 13\nbackground = #000000\nforeground = #ffffff\n"
        )
    }

    func testNothingSetYieldsNil() {
        XCTAssertNil(AppearanceManager.overlayText(
            fontFamily: nil, fontStyle: "", fontSize: 0, themeContents: "  \n "
        ))
    }
}
