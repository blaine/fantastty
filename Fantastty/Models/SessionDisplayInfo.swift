import Foundation

/// Pure value type deriving display properties from SessionMode.
struct SessionDisplayInfo {
    let hostLabel: String?
    let isAttached: Bool
    let isConnecting: Bool
    let isDisconnected: Bool
    let disconnectReason: String?

    init(mode: SessionMode) {
        switch mode {
        case .managed:
            hostLabel = nil
            isAttached = false
            isConnecting = false
            isDisconnected = false
            disconnectReason = nil

        case .attached(let info):
            hostLabel = info.host.displayName
            isAttached = true
            switch info.connectionState {
            case .connecting:
                isConnecting = true
                isDisconnected = false
                disconnectReason = nil
            case .connected:
                isConnecting = false
                isDisconnected = false
                disconnectReason = nil
            case .disconnected(let reason):
                isConnecting = false
                isDisconnected = true
                disconnectReason = reason
            }
        }
    }
}
