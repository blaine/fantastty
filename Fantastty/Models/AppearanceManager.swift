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

    // MARK: - Overlay

    /// Write the overlay file from the current settings. Only keys the user has
    /// chosen are emitted, so unset values fall through to the rest of the
    /// config.
    func writeOverlay() {
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

        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            if lines.isEmpty {
                try? FileManager.default.removeItem(at: overlayURL)
                return
            }
            let content = lines.joined(separator: "\n") + "\n"
            let data = Data(content.utf8)
            if let existing = try? Data(contentsOf: overlayURL), existing == data { return }
            try data.write(to: overlayURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to write appearance overlay: \(error)")
        }
    }
}
