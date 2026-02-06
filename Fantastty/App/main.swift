import AppKit
import GhosttyKit

// Initialize Ghostty global state before starting the app
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    Ghostty.logger.critical("ghostty_init failed")
    exit(1)
}

// Start the SwiftUI application
FantasttyApp.main()
