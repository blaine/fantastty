import Foundation

/// Pure value type deriving display properties from SessionMode.
struct SessionDisplayInfo {
    let hostLabel: String?
    let isAttached: Bool
    let isConnecting: Bool
    let isReconnecting: Bool
    let isDisconnected: Bool
    let isMissingBacking: Bool
    let disconnectReason: String?
    let statusMessage: String
    let accessibilityLabel: String
    let showsStatusOverlay: Bool

    init(mode: SessionMode, backingState: SessionBackingState = .available) {
        let info: TmuxAttachmentInfo
        switch mode {
        case .attached(let attachedInfo):
            info = attachedInfo
        }

        hostLabel = info.host.displayName
        isAttached = true
        switch (info.connectionState, backingState) {
        case (_, .missingAttachedBacking(let reason)):
            isConnecting = false
            isReconnecting = false
            isDisconnected = true
            isMissingBacking = true
            disconnectReason = reason
            statusMessage = Self.unavailableMessage(reason: reason, transport: info.transport)
            accessibilityLabel = "Workspace backing unavailable"
            showsStatusOverlay = false
        case (.connecting, _):
            isConnecting = true
            isReconnecting = false
            isDisconnected = false
            isMissingBacking = false
            disconnectReason = nil
            statusMessage = Self.connectingMessage(transport: info.transport)
            accessibilityLabel = Self.connectingAccessibilityLabel(transport: info.transport)
            showsStatusOverlay = false
        case (.reconnecting(let reason), _):
            isConnecting = true
            isReconnecting = true
            isDisconnected = false
            isMissingBacking = false
            disconnectReason = reason
            statusMessage = Self.reconnectingMessage(transport: info.transport)
            accessibilityLabel = Self.reconnectingAccessibilityLabel(transport: info.transport)
            showsStatusOverlay = info.transport == .remoteEngine
        case (.connected, _):
            isConnecting = false
            isReconnecting = false
            isDisconnected = false
            isMissingBacking = false
            disconnectReason = nil
            statusMessage = Self.connectedMessage(transport: info.transport)
            accessibilityLabel = Self.connectedAccessibilityLabel(transport: info.transport)
            showsStatusOverlay = false
        case (.disconnected(let reason), _):
            isConnecting = false
            isReconnecting = false
            isDisconnected = true
            isMissingBacking = false
            disconnectReason = reason
            statusMessage = Self.unavailableMessage(reason: reason, transport: info.transport)
            accessibilityLabel = Self.disconnectedAccessibilityLabel(transport: info.transport)
            showsStatusOverlay = false
        }
    }

    private static func connectingMessage(transport: TmuxAttachmentTransport) -> String {
        switch transport {
        case .remoteEngine:
            return "Connecting remote engine..."
        case .tmuxControl:
            return "Connecting to tmux session..."
        }
    }

    private static func reconnectingMessage(transport: TmuxAttachmentTransport) -> String {
        switch transport {
        case .remoteEngine:
            return "Reconnecting remote engine. Existing panes are preserved while Fantastty resumes the session."
        case .tmuxControl:
            return "Reconnecting to tmux session..."
        }
    }

    private static func connectedMessage(transport: TmuxAttachmentTransport) -> String {
        switch transport {
        case .remoteEngine:
            return "Remote engine connected. Waiting for panes..."
        case .tmuxControl:
            return "Connected to tmux session. Waiting for windows..."
        }
    }

    private static func unavailableMessage(reason: String?, transport: TmuxAttachmentTransport) -> String {
        let subject = transport == .remoteEngine ? "remote engine" : "tmux session"
        if let reason, !reason.isEmpty {
            return "This workspace was restored, but its \(subject) is unavailable: \(reason)"
        }
        return "This workspace was restored, but its \(subject) is unavailable."
    }

    private static func connectingAccessibilityLabel(transport: TmuxAttachmentTransport) -> String {
        transport == .remoteEngine ? "Remote engine connecting" : "Tmux session connecting"
    }

    private static func reconnectingAccessibilityLabel(transport: TmuxAttachmentTransport) -> String {
        transport == .remoteEngine ? "Remote engine reconnecting" : "Tmux session reconnecting"
    }

    private static func connectedAccessibilityLabel(transport: TmuxAttachmentTransport) -> String {
        transport == .remoteEngine ? "Remote engine connected" : "Tmux session connected"
    }

    private static func disconnectedAccessibilityLabel(transport: TmuxAttachmentTransport) -> String {
        transport == .remoteEngine ? "Remote engine disconnected" : "Tmux session disconnected"
    }
}
