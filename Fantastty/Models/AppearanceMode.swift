import AppKit

/// The user's preferred app appearance, stored in UserDefaults.
enum AppearanceMode: String, CaseIterable, Identifiable {
    static let userDefaultsKey = "appearance"

    case system
    case light
    case dark

    var id: String { rawValue }

    /// The display name for the settings picker.
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The current mode from UserDefaults.
    static var current: AppearanceMode {
        AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: userDefaultsKey) ?? "system"
        ) ?? .system
    }

    /// Whether this mode resolves to a dark appearance.
    var isDark: Bool {
        switch self {
        case .dark: return true
        case .light: return false
        case .system: return NSApp.effectiveAppearance.isDark
        }
    }

    /// Apply this appearance mode to the app chrome.
    static func applyCurrent() {
        let mode = current
        switch mode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil
        }
    }
}
