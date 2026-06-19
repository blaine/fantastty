import Foundation
import SwiftUI

/// A simple sRGB color parsed from a Ghostty theme file's `#rrggbb` hex value.
/// Kept separate from SwiftUI/AppKit color types so the theme parser stays pure
/// and unit-testable.
struct ThemeColor: Hashable {
    let r: Double
    let g: Double
    let b: Double

    /// Parse a `#rrggbb` (or bare `rrggbb`) hex string. Returns nil for anything
    /// that isn't exactly six hex digits.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        r = Double((value >> 16) & 0xff) / 255
        g = Double((value >> 8) & 0xff) / 255
        b = Double(value & 0xff) / 255
    }

    var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// A parsed Ghostty color theme: the colors needed to render a truthful preview,
/// plus the original file contents so the exact theme can be inlined into the
/// appearance config overlay.
struct GhosttyTheme: Identifiable, Hashable {
    let name: String
    let background: ThemeColor
    let foreground: ThemeColor
    let cursor: ThemeColor
    /// The 16 ANSI palette colors, in index order (0–15).
    let palette: [ThemeColor]
    /// The verbatim theme-file text, applied by appending it to the overlay.
    let rawContents: String

    var id: String { name }
}

/// Parses a Ghostty theme file. The format is one `key = value` per line, where
/// colors are `#rrggbb` and palette entries look like `palette = N=#rrggbb`.
enum GhosttyThemeParser {
    static func parse(name: String, contents: String) -> GhosttyTheme {
        var background = ThemeColor(hex: "#000000")!
        var foreground = ThemeColor(hex: "#ffffff")!
        var cursor: ThemeColor?
        var palette = [ThemeColor?](repeating: nil, count: 16)

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = rawLine.firstIndex(of: "=") else { continue }
            let key = rawLine[..<eq].trimmingCharacters(in: .whitespaces)
            let value = rawLine[rawLine.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "background":
                if let c = ThemeColor(hex: value) { background = c }
            case "foreground":
                if let c = ThemeColor(hex: value) { foreground = c }
            case "cursor-color":
                cursor = ThemeColor(hex: value)
            case "palette":
                // value is "N=#rrggbb"
                guard let inner = value.firstIndex(of: "=") else { break }
                let indexText = value[..<inner].trimmingCharacters(in: .whitespaces)
                let hex = value[value.index(after: inner)...].trimmingCharacters(in: .whitespaces)
                if let index = Int(indexText), palette.indices.contains(index),
                   let c = ThemeColor(hex: hex) {
                    palette[index] = c
                }
            default:
                break
            }
        }

        let resolvedPalette = palette.map { $0 ?? foreground }
        return GhosttyTheme(
            name: name,
            background: background,
            foreground: foreground,
            cursor: cursor ?? foreground,
            palette: resolvedPalette,
            rawContents: contents
        )
    }
}
