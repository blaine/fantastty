import Foundation

final class TerminalLifecycleRouter {
    private let commandSender: TmuxCommandSending

    init(commandSender: TmuxCommandSending) {
        self.commandSender = commandSender
    }

    func closeTerminalTab(_ tab: TerminalTab, in session: Session) async {
        guard tab.kind == .terminal,
              let windowID = tab.tmuxWindowID,
              isConnected(session) else {
            return
        }
        try? await commandSender.killWindow(windowID: windowID)
    }

    func closePane(paneID: Int, in session: Session) async {
        guard isConnected(session) else { return }
        try? await commandSender.killPane(paneID: paneID)
    }

    func requestNewTab(in session: Session) async {
        guard isConnected(session) else { return }
        _ = try? await commandSender.newWindow()
    }

    func moveTerminalTab(
        _ tab: TerminalTab,
        relativeTo target: TerminalTab,
        placement: TmuxWindowMovePlacement,
        in session: Session
    ) async {
        guard tab.kind == .terminal,
              target.kind == .terminal,
              let windowID = tab.tmuxWindowID,
              let targetWindowID = target.tmuxWindowID,
              isConnected(session) else {
            return
        }
        try? await commandSender.moveWindow(windowID: windowID, relativeTo: targetWindowID, placement: placement)
    }

    func requestSplit(paneID: Int, horizontal: Bool, in session: Session) async {
        guard isConnected(session) else { return }
        try? await commandSender.splitPane(paneID: paneID, horizontal: horizontal)
    }

    private func isConnected(_ session: Session) -> Bool {
        guard case .attached(let info) = session.mode else { return false }
        if case .connected = info.connectionState { return true }
        return false
    }
}
