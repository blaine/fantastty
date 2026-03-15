import Foundation

/// Pure value type deriving display properties from SessionMode.
struct SessionDisplayInfo {
    let hostLabel: String?
    let isAttached: Bool
    let isConnecting: Bool
    let isDisconnected: Bool
    let isMissingBacking: Bool
    let disconnectReason: String?

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
            isDisconnected = true
            isMissingBacking = true
            disconnectReason = reason
        case (.connecting, _):
            isConnecting = true
            isDisconnected = false
            isMissingBacking = false
            disconnectReason = nil
        case (.connected, _):
            isConnecting = false
            isDisconnected = false
            isMissingBacking = false
            disconnectReason = nil
        case (.disconnected(let reason), _):
            isConnecting = false
            isDisconnected = true
            isMissingBacking = false
            disconnectReason = reason
        }
    }
}
