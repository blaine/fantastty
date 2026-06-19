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

    private let byName: [String: GhosttyTheme]

    init(directory: URL?) {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else {
            themes = []
            byName = [:]
            return
        }

        let parsed = urls
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url -> GhosttyTheme? in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return GhosttyThemeParser.parse(name: url.lastPathComponent, contents: contents)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        themes = parsed
        byName = Dictionary(parsed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func theme(named name: String) -> GhosttyTheme? {
        byName[name]
    }
}
