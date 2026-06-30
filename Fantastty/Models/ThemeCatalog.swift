import Foundation

/// The set of color themes available to pick from, parsed from Ghostty's bundled
/// theme files. The shared instance reads the `Themes` folder copied into the app
/// bundle; the directory-based initializer keeps loading testable.
final class ThemeCatalog {
    static let shared = ThemeCatalog(
        directory: Bundle.main.resourceURL?.appendingPathComponent("Themes")
    )

    /// All themes, sorted case-insensitively by name.
    let themes: [GhosttyTheme]

    /// The themes that form a light/dark pair, sorted by base name.
    let pairs: [ThemePair]

    private let byName: [String: GhosttyTheme]
    private let urlByName: [String: URL]

    init(directory: URL?) {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else {
            themes = []
            pairs = []
            byName = [:]
            urlByName = [:]
            return
        }

        var urlByName: [String: URL] = [:]
        let parsed = urls
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url -> GhosttyTheme? in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let name = url.lastPathComponent
                urlByName[name] = url
                return GhosttyThemeParser.parse(name: name, contents: contents)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        themes = parsed
        pairs = ThemePairing.pairs(from: parsed)
        byName = Dictionary(parsed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.urlByName = urlByName
    }

    func theme(named name: String) -> GhosttyTheme? {
        byName[name]
    }

    /// The absolute file URL of a bundled theme, used to reference it from the
    /// appearance overlay's `theme` directive.
    func fileURL(named name: String) -> URL? {
        urlByName[name]
    }
}
