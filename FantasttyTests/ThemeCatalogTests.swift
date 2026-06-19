import XCTest
@testable import Fantastty

final class ThemeCatalogTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-catalog-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeTheme(_ name: String, _ contents: String) throws {
        try contents.write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testLoadsAndParsesThemesSortedCaseInsensitively() throws {
        try writeTheme("Zebra", "background = #000000\nforeground = #ffffff\n")
        try writeTheme("apple", "background = #111111\nforeground = #eeeeee\n")
        try writeTheme("Mango", "background = #222222\nforeground = #dddddd\n")

        let catalog = ThemeCatalog(directory: tempDir)

        XCTAssertEqual(catalog.themes.map(\.name), ["apple", "Mango", "Zebra"])
        XCTAssertEqual(catalog.themes[1].background, ThemeColor(hex: "#222222"))
    }

    func testIgnoresHiddenFiles() throws {
        try writeTheme("Real", "background = #000000\n")
        try writeTheme(".DS_Store", "garbage")

        let catalog = ThemeCatalog(directory: tempDir)

        XCTAssertEqual(catalog.themes.map(\.name), ["Real"])
    }

    func testLookupByName() throws {
        try writeTheme("Dracula", "background = #282a36\nforeground = #f8f8f2\n")

        let catalog = ThemeCatalog(directory: tempDir)

        XCTAssertEqual(catalog.theme(named: "Dracula")?.foreground, ThemeColor(hex: "#f8f8f2"))
        XCTAssertNil(catalog.theme(named: "Nonexistent"))
    }

    func testMissingDirectoryYieldsEmptyCatalog() {
        let catalog = ThemeCatalog(directory: tempDir.appendingPathComponent("does-not-exist"))
        XCTAssertTrue(catalog.themes.isEmpty)
    }
}
