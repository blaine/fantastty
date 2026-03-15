import Foundation
import os

/// Writes default Fantastty light/dark theme files and a Ghostty config overlay
/// to ~/.fantastty/ so that color scheme switching works out of the box.
class ThemeManager {
    static let shared = ThemeManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "themes"
    )

    private var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fantastty")
    }

    private var themesDir: URL {
        baseDir.appendingPathComponent("themes")
    }

    /// Whether the user has their own Ghostty config file.
    var userHasGhosttyConfig: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(".config/ghostty/config")
        return FileManager.default.fileExists(atPath: configPath.path)
    }

    /// Path to the Fantastty config overlay that sets the light/dark theme pair.
    /// Returns nil if the user already has a Ghostty config.
    var configOverlayPath: String? {
        guard !userHasGhosttyConfig else { return nil }
        let path = baseDir.appendingPathComponent("ghostty-config").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Write default theme files and config overlay, but only if the user
    /// doesn't already have a Ghostty config file.
    func ensureInstalled() {
        guard !userHasGhosttyConfig else {
            Self.logger.info("User has Ghostty config, skipping default theme install")
            return
        }

        let fm = FileManager.default

        do {
            try fm.createDirectory(at: themesDir, withIntermediateDirectories: true)

            let lightPath = themesDir.appendingPathComponent("Fantastty Light")
            let darkPath = themesDir.appendingPathComponent("Fantastty Dark")

            try writeIfChanged(lightPath, content: lightTheme)
            try writeIfChanged(darkPath, content: darkTheme)

            let overlay = """
            theme = light:\(lightPath.path),dark:\(darkPath.path)
            window-theme = auto
            """
            try writeIfChanged(
                baseDir.appendingPathComponent("ghostty-config"),
                content: overlay
            )

            Self.logger.info("Default theme files installed at \(self.themesDir.path)")
        } catch {
            Self.logger.error("Failed to install theme files: \(error)")
        }
    }

    // MARK: - Private

    private func writeIfChanged(_ url: URL, content: String) throws {
        let data = Data(content.utf8)
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Theme Content

    /// Ghostty dark theme matching default colors.
    private let darkTheme = """
    background = #282C34
    foreground = #FFFFFF
    cursor-color = #FFFFFF
    selection-background = #3E4451
    selection-foreground = #FFFFFF
    palette = 0=#1E2127
    palette = 1=#E06C75
    palette = 2=#98C379
    palette = 3=#D19A66
    palette = 4=#61AFEF
    palette = 5=#C678DD
    palette = 6=#56B6C2
    palette = 7=#ABB2BF
    palette = 8=#5C6370
    palette = 9=#E06C75
    palette = 10=#98C379
    palette = 11=#D19A66
    palette = 12=#61AFEF
    palette = 13=#C678DD
    palette = 14=#56B6C2
    palette = 15=#FFFFFF
    """

    /// Light theme with readable contrast.
    private let lightTheme = """
    background = #FFFFFF
    foreground = #383A42
    cursor-color = #383A42
    selection-background = #BFCEFF
    selection-foreground = #383A42
    palette = 0=#383A42
    palette = 1=#E45649
    palette = 2=#50A14F
    palette = 3=#C18401
    palette = 4=#4078F2
    palette = 5=#A626A4
    palette = 6=#0184BC
    palette = 7=#A0A1A7
    palette = 8=#4F525E
    palette = 9=#E45649
    palette = 10=#50A14F
    palette = 11=#C18401
    palette = 12=#4078F2
    palette = 13=#A626A4
    palette = 14=#0184BC
    palette = 15=#FFFFFF
    """
}
