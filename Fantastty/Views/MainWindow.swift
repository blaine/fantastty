import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var ghosttyApp: Ghostty.App

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let selectedID = sessionManager.selectedSessionID,
               let session = sessionManager.sessions.first(where: { $0.id == selectedID }) {
                SessionDetailView(session: session)
                    .id(session.id) // Force recreation on tab switch
            } else {
                Text("No session selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("")
        .frame(minWidth: 800, minHeight: 500)
        .background(WindowAccessor(onWindow: appDelegate.registerMainWindow))
        .sheet(item: $sessionManager.sessionLauncherRequest) { request in
            SessionLauncherSheet(request: request)
                .environmentObject(sessionManager)
        }
    }
}

/// Captures the hosting NSWindow once SwiftUI attaches it and hands it to the
/// AppDelegate, which makes the window non-closable.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowCapturingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// An NSView that reports its hosting window when it is actually added to one.
/// `viewDidMoveToWindow` is reliable (unlike reading `view.window` immediately,
/// which is nil before attachment); the async hop lets SwiftUI finish its own
/// window setup first.
private final class WindowCapturingView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let window else { return }
            self?.onWindow?(window)
        }
    }
}
