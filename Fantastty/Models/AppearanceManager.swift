import Foundation
import AppKit
import os

/// Persists the user's in-app appearance choices (terminal font family, style,
/// and size for now; color theme later) and writes them to a Ghostty config
/// overlay that is always loaded last. Loading last means these explicit user
/// choices override everything else — the bundled defaults and the user's own
/// `~/.config/ghostty/config` alike — but only for the keys we actually set.
final class AppearanceManager {
    static let shared = AppearanceManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "appearance"
    )

    enum Key {
        static let fontFamily = "appearanceFontFamily"
        static let fontStyle = "appearanceFontStyle"
        static let fontSize = "appearanceFontSize"
        static let themeName = "appearanceThemeName"
    }

    private let defaults = UserDefaults.standard

    private var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fantastty")
    }

    private var overlayURL: URL {
        baseDir.appendingPathComponent("appearance-config")
    }

    /// Path to the appearance overlay, for `Ghostty.Config` to load last. The
    /// file is (re)written whenever settings change, so we keep it current here.
    var overlayPath: String? {
        writeOverlay()
        return FileManager.default.fileExists(atPath: overlayURL.path) ? overlayURL.path : nil
    }

    // MARK: - Stored settings

    var fontFamily: String? {
        get { defaults.string(forKey: Key.fontFamily) }
        set { defaults.set(newValue, forKey: Key.fontFamily) }
    }

    var fontStyle: String? {
        get { defaults.string(forKey: Key.fontStyle) }
        set { defaults.set(newValue, forKey: Key.fontStyle) }
    }

    /// 0 means "inherit" (don't write a font-size directive).
    var fontSize: Double {
        get { defaults.double(forKey: Key.fontSize) }
        set { defaults.set(newValue, forKey: Key.fontSize) }
    }

    /// The name of the chosen color theme, or nil to inherit the base config.
    var themeName: String? {
        get { defaults.string(forKey: Key.themeName) }
        set { defaults.set(newValue, forKey: Key.themeName) }
    }

    // MARK: - Overlay

    /// Build the overlay file's contents from the chosen settings. Only keys the
    /// user has set are emitted, so unset values fall through to the rest of the
    /// config. The theme is inlined verbatim (it is itself valid Ghostty config).
    /// Returns nil when nothing is set, meaning the overlay file should be removed.
    static func overlayText(
        fontFamily: String?,
        fontStyle: String?,
        fontSize: Double,
        themeContents: String?
    ) -> String? {
        var lines: [String] = []
        if let family = fontFamily, !family.isEmpty {
            lines.append("font-family = \(family)")
        }
        if let style = fontStyle, !style.isEmpty {
            lines.append("font-style = \(style)")
        }
        if fontSize > 0 {
            lines.append("font-size = \(Int(fontSize.rounded()))")
        }
        if let theme = themeContents {
            let trimmed = theme.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write the overlay file from the current settings.
    func writeOverlay() {
        let themeContents = themeName.flatMap { ThemeCatalog.shared.theme(named: $0)?.rawContents }
        let content = Self.overlayText(
            fontFamily: fontFamily,
            fontStyle: fontStyle,
            fontSize: fontSize,
            themeContents: themeContents
        )

        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            guard let content else {
                try? FileManager.default.removeItem(at: overlayURL)
                return
            }
            let data = Data(content.utf8)
            if let existing = try? Data(contentsOf: overlayURL), existing == data { return }
            try data.write(to: overlayURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to write appearance overlay: \(error)")
        }
    }
}
