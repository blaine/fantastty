import XCTest
@testable import Fantastty

final class AppearanceOverlayTests: XCTestCase {

    func testFontOnly() {
        let text = AppearanceManager.overlayText(
            fontFamily: "JetBrains Mono",
            fontStyle: "Bold",
            fontSize: 14,
            lightThemePath: nil,
            darkThemePath: nil
        )
        XCTAssertEqual(text, "font-family = JetBrains Mono\nfont-style = Bold\nfont-size = 14\n")
    }

    func testThemePairWritesLightDarkDirective() {
        let text = AppearanceManager.overlayText(
            fontFamily: nil,
            fontStyle: nil,
            fontSize: 0,
            lightThemePath: "/themes/Gruvbox Light",
            darkThemePath: "/themes/Gruvbox Dark"
        )
        XCTAssertEqual(text, "theme = light:/themes/Gruvbox Light,dark:/themes/Gruvbox Dark\n")
    }

    func testFontAndThemeTogether() {
        let text = AppearanceManager.overlayText(
            fontFamily: "Menlo",
            fontStyle: nil,
            fontSize: 13,
            lightThemePath: "/t/L",
            darkThemePath: "/t/D"
        )
        XCTAssertEqual(text, "font-family = Menlo\nfont-size = 13\ntheme = light:/t/L,dark:/t/D\n")
    }

    func testThemeRequiresBothPaths() {
        // A half-set pair (only one side) is ignored, not written.
        let text = AppearanceManager.overlayText(
            fontFamily: nil, fontStyle: nil, fontSize: 0,
            lightThemePath: "/t/L", darkThemePath: nil
        )
        XCTAssertNil(text)
    }

    func testNothingSetYieldsNil() {
        XCTAssertNil(AppearanceManager.overlayText(
            fontFamily: nil, fontStyle: "", fontSize: 0,
            lightThemePath: nil, darkThemePath: nil
        ))
    }
}
