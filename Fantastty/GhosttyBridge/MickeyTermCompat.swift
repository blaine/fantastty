/// Compatibility stubs for types referenced by Ghostty bridge files
/// that are part of Ghostty's app layer and not available in Fantastty.

import AppKit
import SwiftUI
import GhosttyKit

// MARK: - BaseTerminalController stub

/// Stub for BaseTerminalController referenced in Ghostty.App action handlers.
/// We don't use NSWindowController-based architecture so these code paths
/// will return false/early exit gracefully.
class BaseTerminalController: NSWindowController {
    var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init(root: nil, zoomed: nil)
    var focusedSurface: Ghostty.SurfaceView? { nil }
    var commandPaletteIsShowing: Bool { false }
    var focusFollowsMouse: Bool { false }

    func promptTabTitle() {}
    func toggleBackgroundOpacity() {}

    @objc func changeTabTitle(_ sender: Any?) {}
}

// MARK: - TerminalWindow stub

/// Stub for TerminalWindow referenced in the float window action handler.
class TerminalWindow: NSWindow {
    func isTabBar(_ c: NSTitlebarAccessoryViewController) -> Bool { false }
}

// MARK: - HiddenTitlebarTerminalWindow stub

class HiddenTitlebarTerminalWindow: TerminalWindow {}

// MARK: - QuickTerminal types

enum QuickTerminalPosition: String {
    case top, bottom, left, right, center
}

enum QuickTerminalScreen: String {
    case main, cursor, all

    init?(fromGhosttyConfig str: String) {
        self.init(rawValue: str)
    }
}

enum QuickTerminalSpaceBehavior: String {
    case move, stay

    init?(fromGhosttyConfig str: String) {
        self.init(rawValue: str)
    }
}

struct QuickTerminalSize {
    var width: Double = 0.8
    var height: Double = 0.5

    init() {}

    init(from v: ghostty_config_quick_terminal_size_s) {
        // ghostty_config_quick_terminal_size_s has .primary and .secondary fields
        // For our compat stub, extract percentage values if available
        if v.primary.tag.rawValue == 0 { // percentage tag
            self.width = Double(v.primary.value.percentage)
        }
        if v.secondary.tag.rawValue == 0 {
            self.height = Double(v.secondary.value.percentage)
        }
    }
}

// MARK: - InspectableSurface replacement

extension Ghostty {
    /// Simplified InspectableSurface that just wraps SurfaceWrapper
    /// (we don't support the inspector in Fantastty).
    struct InspectableSurface: View {
        @ObservedObject var surfaceView: SurfaceView
        var isSplit: Bool = false

        var body: some View {
            SurfaceWrapper(surfaceView: surfaceView, isSplit: isSplit)
        }
    }
}

// MARK: - TerminalRestoreError

enum TerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case windowDidNotLoad
}

// MARK: - AppDelegate protocol extensions

/// The Ghostty bridge files reference `AppDelegate` in several places.
/// Our AppDelegate already exists in Fantastty/App/AppDelegate.swift with
/// the correct interface. These are helpers for additional APIs referenced.
extension AppDelegate {
    /// Bridge files reference appDelegate.ghostty to get the Ghostty.App instance
    var ghostty: Ghostty.App { ghosttyApp }

    func checkForUpdates(_ sender: Any?) {}
    func toggleVisibility(_ sender: Any?) {}
    func toggleQuickTerminal(_ sender: Any?) {}
    func closeAllWindows(_ sender: Any?) {
        NSApplication.shared.windows.forEach { $0.close() }
    }
    func setSecureInput(_ mode: Ghostty.SetSecureInput) {}
    func syncFloatOnTopMenu(_ window: NSWindow) {}
}
