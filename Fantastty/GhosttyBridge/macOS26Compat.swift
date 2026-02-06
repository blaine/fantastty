/// Compatibility shims for macOS 26 APIs used by Ghostty's latest source
/// that aren't available in the current SDK.

import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - NSScreen extensions

extension NSScreen {
    /// Compatibility for NSScreen.displayID (macOS 26+)
    /// Returns the CGDirectDisplayID for this screen.
    var displayID: UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    /// Compatibility for NSScreen.hasDock (macOS 26+)
    /// Returns whether the dock is on this screen.
    var hasDock: Bool {
        // The dock is on the screen that contains the visible frame inset
        // Different visible frame vs frame means dock/menu is present
        let hasInset = frame.size != visibleFrame.size
        return hasInset
    }
}

// MARK: - NSApplication presentation option management

extension NSApplication {
    /// Compatibility for NSApp.acquirePresentationOption (macOS 26+)
    func acquirePresentationOption(_ option: NSApplication.PresentationOptions) {
        presentationOptions.insert(option)
    }

    /// Compatibility for NSApp.releasePresentationOption (macOS 26+)
    func releasePresentationOption(_ option: NSApplication.PresentationOptions) {
        presentationOptions.remove(option)
    }
}

// MARK: - NSWindow extensions

extension NSWindow {
    /// Compatibility for NSWindow.hasTitleBar (macOS 26+)
    var hasTitleBar: Bool {
        return styleMask.contains(.titled)
    }
}

// MARK: - NSWorkspace extensions

extension NSWorkspace {
    /// Compatibility for NSWorkspace.defaultApplicationURL(forExtension:) (macOS 26+)
    func defaultApplicationURL(forExtension ext: String) -> URL? {
        // Use the older API to get the default app for a file extension
        guard let uti = UTType(filenameExtension: ext) else { return nil }
        return urlForApplication(toOpen: uti)
    }

    /// Compatibility for NSWorkspace.defaultTextEditor (macOS 26+)
    var defaultTextEditor: URL? {
        // Use the UTType for plain text to find the default editor
        return urlForApplication(toOpen: UTType.plainText)
    }
}
