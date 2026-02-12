import SwiftUI
import GhosttyKit

struct AppCommands: Commands {
    @ObservedObject var sessionManager: SessionManager
    var body: some Commands {
        // Replace the default "New Window" command
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                sessionManager.createTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("New Browser Tab") {
                sessionManager.createBrowserTab()
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("New Workspace") {
                sessionManager.createSession()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New SSH Workspace...") {
                sessionManager.showSSHSheet = true
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("Split Right") {
                sessionManager.newSplit(direction: .right)
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Split Down") {
                sessionManager.newSplit(direction: .down)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                if let surface = sessionManager.focusedSurfaceView?.surface {
                    let action = "copy_to_clipboard"
                    ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
                }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Paste") {
                if let surface = sessionManager.focusedSurfaceView?.surface {
                    let action = "paste_from_clipboard"
                    ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
                }
            }
            .keyboardShortcut("v", modifiers: .command)
        }

        // Tab navigation (top tabs within session)
        CommandGroup(after: .windowArrangement) {
            Button("Select Next Tab") {
                sessionManager.selectedSession?.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Select Previous Tab") {
                sessionManager.selectedSession?.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            // Cmd+1-9 for top tabs within current session
            if let session = sessionManager.selectedSession {
                ForEach(Array(session.tabs.enumerated().prefix(9)), id: \.element.id) { index, tab in
                    Button("Select Tab \(index + 1)") {
                        session.selectedTabID = tab.id
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }

            Divider()

            // Sidebar navigation - Cmd+` cycles forward (hijacks window switch)
            Button("Select Next Workspace") {
                sessionManager.selectNextSession()
            }
            .keyboardShortcut("`", modifiers: .command)

            Button("Select Previous Workspace") {
                sessionManager.selectPreviousSession()
            }
            .keyboardShortcut("`", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .windowSize) {
            Button("Toggle Notes") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sessionManager.notesExpanded.toggle()
                }
            }
            .keyboardShortcut(".", modifiers: .command)

            Divider()

            Button("Close Tab") {
                sessionManager.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Close Workspace") {
                if let id = sessionManager.selectedSessionID {
                    sessionManager.closeSession(id: id)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        // Workspace commands
        CommandMenu("Workspace") {
            Button("Toggle Attention Flag") {
                sessionManager.selectedSession?.toggleAttention()
            }
            .keyboardShortcut("!", modifiers: [.command, .shift])

            Button("Clear All Attention Flags") {
                for session in sessionManager.sessions {
                    session.clearAttention()
                }
            }

            Divider()

            Button("Show Next Flagged Workspace") {
                // Find next session with attention flag
                let flagged = sessionManager.sessions.filter { $0.needsAttention }
                if let first = flagged.first {
                    sessionManager.selectedSessionID = first.id
                }
            }
            .keyboardShortcut("!", modifiers: .command)
        }

        // Debug menu for testing
        CommandMenu("Debug") {
            Button("Test Bell (Set Attention)") {
                // Directly set attention on current session
                if let session = sessionManager.selectedSession {
                    session.needsAttention = true
                    print("DEBUG: Set attention on session \(session.id)")
                }
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Button("Simulate Bell Notification") {
                // Post a fake bell notification to test the handler
                if let surface = sessionManager.focusedSurfaceView {
                    NotificationCenter.default.post(
                        name: .ghosttyBellDidRing,
                        object: surface
                    )
                    print("DEBUG: Posted bell notification for surface")
                }
            }
            .keyboardShortcut("b", modifiers: [.command, .option, .shift])

            Divider()

            Button("Print Session Info") {
                for session in sessionManager.sessions {
                    print("Session \(session.id): needsAttention=\(session.needsAttention), title=\(session.title)")
                }
            }
        }
    }
}
