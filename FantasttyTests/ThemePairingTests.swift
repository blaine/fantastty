import XCTest
@testable import Fantastty

final class ThemePairingTests: XCTestCase {

    private func theme(_ name: String) -> GhosttyTheme {
        GhosttyThemeParser.parse(name: name, contents: "background = #000000\nforeground = #ffffff\n")
    }

    // MARK: - baseAndRole

    func testBaseAndRoleStripsWholeWordLightDarkToken() {
        XCTAssertEqual(ThemePairing.baseAndRole("Gruvbox Light")?.base, "Gruvbox")
        XCTAssertEqual(ThemePairing.baseAndRole("Gruvbox Light")?.isDark, false)
        XCTAssertEqual(ThemePairing.baseAndRole("Gruvbox Dark")?.isDark, true)
    }

    func testBaseAndRoleStripsTokenFromTheMiddle() {
        XCTAssertEqual(ThemePairing.baseAndRole("GitHub Light Default")?.base, "GitHub Default")
        XCTAssertEqual(ThemePairing.baseAndRole("GitHub Dark Default")?.base, "GitHub Default")
    }

    func testBaseAndRoleIsNilWithoutWholeWordToken() {
        XCTAssertNil(ThemePairing.baseAndRole("Starlight"))
        XCTAssertNil(ThemePairing.baseAndRole("Twilight"))
        XCTAssertNil(ThemePairing.baseAndRole("Bright Lights"))
        XCTAssertNil(ThemePairing.baseAndRole("Dracula"))
    }

    // MARK: - pairs

    func testPairsMatchesLightAndDarkSiblings() {
        let pairs = ThemePairing.pairs(from: [
            theme("Gruvbox Dark"),
            theme("Gruvbox Light"),
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].base, "Gruvbox")
        XCTAssertEqual(pairs[0].light.name, "Gruvbox Light")
        XCTAssertEqual(pairs[0].dark.name, "Gruvbox Dark")
    }

    func testPairsDropsThemesWithoutACounterpart() {
        let pairs = ThemePairing.pairs(from: [
            theme("Selenized Dark"),
            theme("Dracula"),
            theme("Starlight"),
        ])
        XCTAssertTrue(pairs.isEmpty)
    }

    func testPairsSortedByBaseCaseInsensitively() {
        let pairs = ThemePairing.pairs(from: [
            theme("Xcode Light"), theme("Xcode Dark"),
            theme("aizen Light"), theme("aizen Dark"),
            theme("GitHub Light Default"), theme("GitHub Dark Default"),
        ])
        XCTAssertEqual(pairs.map(\.base), ["aizen", "GitHub Default", "Xcode"])
    }
}
