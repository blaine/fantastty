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
        static let themePairBase = "appearanceThemePairBase"
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

    /// The base name of the chosen light/dark theme pair (e.g. "Gruvbox"), or
    /// nil to inherit the base config.
    var themePairBase: String? {
        get { defaults.string(forKey: Key.themePairBase) }
        set { defaults.set(newValue, forKey: Key.themePairBase) }
    }

    // MARK: - Overlay

    /// Build the overlay file's contents from the chosen settings. Only keys the
    /// user has set are emitted, so unset values fall through to the rest of the
    /// config. A theme pair is written as a `theme = light:…,dark:…` directive so
    /// Ghostty switches between the two with the system appearance. Returns nil
    /// when nothing is set, meaning the overlay file should be removed.
    static func overlayText(
        fontFamily: String?,
        fontStyle: String?,
        fontSize: Double,
        lightThemePath: String?,
        darkThemePath: String?
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
        if let light = lightThemePath, let dark = darkThemePath {
            lines.append("theme = light:\(light),dark:\(dark)")
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write the overlay file from the current settings.
    func writeOverlay() {
        let pair = themePairBase.flatMap { base in
            ThemeCatalog.shared.pairs.first { $0.base == base }
        }
        let lightPath = pair.flatMap { ThemeCatalog.shared.fileURL(named: $0.light.name)?.path }
        let darkPath = pair.flatMap { ThemeCatalog.shared.fileURL(named: $0.dark.name)?.path }

        let content = Self.overlayText(
            fontFamily: fontFamily,
            fontStyle: fontStyle,
            fontSize: fontSize,
            lightThemePath: lightPath,
            darkThemePath: darkPath
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
