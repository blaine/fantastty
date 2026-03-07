import XCTest
@testable import Fantastty

final class SessionDisplayInfoTests: XCTestCase {

    func testManagedSessionHasNoHostLabel() {
        let info = SessionDisplayInfo(mode: .managed)
        XCTAssertNil(info.hostLabel)
        XCTAssertFalse(info.isDisconnected)
        XCTAssertFalse(info.isAttached)
    }

    func testAttachedLocalConnected() {
        let attachment = TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .connected
        )
        let info = SessionDisplayInfo(mode: .attached(attachment))
        XCTAssertEqual(info.hostLabel, "localhost")
        XCTAssertFalse(info.isDisconnected)
        XCTAssertTrue(info.isAttached)
    }

    func testAttachedRemoteDisconnected() {
        let attachment = TmuxAttachmentInfo(
            sessionName: "test",
            host: .ssh(SSHHostInfo(user: "me", hostname: "mybox", port: nil)),
            connectionState: .disconnected(reason: "lost connection")
        )
        let info = SessionDisplayInfo(mode: .attached(attachment))
        XCTAssertEqual(info.hostLabel, "me@mybox")
        XCTAssertTrue(info.isDisconnected)
        XCTAssertEqual(info.disconnectReason, "lost connection")
    }

    func testAttachedConnecting() {
        let attachment = TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .connecting
        )
        let info = SessionDisplayInfo(mode: .attached(attachment))
        XCTAssertTrue(info.isConnecting)
        XCTAssertFalse(info.isDisconnected)
    }
}
