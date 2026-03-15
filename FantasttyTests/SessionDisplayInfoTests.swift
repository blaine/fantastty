import XCTest
@testable import Fantastty

final class SessionDisplayInfoTests: XCTestCase {

    func testAttachedSessionShowsHostLabel() {
        let attachment = Fantastty.TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .connected
        )
        let info = SessionDisplayInfo(mode: .attached(attachment), backingState: .available)
        XCTAssertEqual(info.hostLabel, "localhost")
        XCTAssertFalse(info.isDisconnected)
        XCTAssertTrue(info.isAttached)
    }

    func testAttachedLocalConnected() {
        let attachment = Fantastty.TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .connected
        )
        let info = SessionDisplayInfo(mode: .attached(attachment), backingState: .available)
        XCTAssertEqual(info.hostLabel, "localhost")
        XCTAssertFalse(info.isDisconnected)
        XCTAssertTrue(info.isAttached)
    }

    func testAttachedRemoteDisconnected() {
        let attachment = Fantastty.TmuxAttachmentInfo(
            sessionName: "test",
            host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "mybox", port: nil)),
            connectionState: .disconnected(reason: "lost connection")
        )
        let info = SessionDisplayInfo(mode: .attached(attachment), backingState: .available)
        XCTAssertEqual(info.hostLabel, "me@mybox")
        XCTAssertTrue(info.isDisconnected)
        XCTAssertEqual(info.disconnectReason, "lost connection")
    }

    func testAttachedConnecting() {
        let attachment = Fantastty.TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .connecting
        )
        let info = SessionDisplayInfo(mode: .attached(attachment), backingState: .available)
        XCTAssertTrue(info.isConnecting)
        XCTAssertFalse(info.isDisconnected)
    }

    func testRemoteAttachedSessionCanBeMarkedMissingWithoutChangingMode() {
        let session = Session(title: "Workspace", type: .local, workspaceID: "missing-local")
        let attachment = Fantastty.TmuxAttachmentInfo(
            sessionName: "missing-local",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        session.mode = .attached(attachment)
        session.backingState = .missingAttachedBacking(reason: nil)

        XCTAssertEqual(session.mode, .attached(attachment))
        XCTAssertEqual(session.backingState, .missingAttachedBacking(reason: nil))

        let info = SessionDisplayInfo(mode: session.mode, backingState: session.backingState)
        XCTAssertTrue(info.isMissingBacking)
        XCTAssertTrue(info.isAttached)
        XCTAssertEqual(info.hostLabel, "localhost")
        XCTAssertNil(info.disconnectReason)
    }

    func testAttachedSessionCanBeMarkedMissingWithoutChangingMode() {
        let attachment = Fantastty.TmuxAttachmentInfo(
            sessionName: "remote",
            host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "mybox", port: nil)),
            connectionState: .disconnected(reason: "host unavailable")
        )
        let session = Session(title: "Remote", type: .local, workspaceID: "missing-attached")
        session.mode = .attached(attachment)
        session.backingState = .missingAttachedBacking(reason: "host unavailable")

        XCTAssertEqual(session.mode, .attached(attachment))
        XCTAssertEqual(session.backingState, .missingAttachedBacking(reason: "host unavailable"))

        let info = SessionDisplayInfo(mode: session.mode, backingState: session.backingState)
        XCTAssertTrue(info.isMissingBacking)
        XCTAssertTrue(info.isAttached)
        XCTAssertEqual(info.hostLabel, "me@mybox")
        XCTAssertEqual(info.disconnectReason, "host unavailable")
    }
}

@MainActor
final class ThumbnailRefreshControllerTests: XCTestCase {

    func testStartupSuspensionResumesAfterDebounce() async {
        let controller = SessionManager.ThumbnailRefreshController(
            startupResumeDelay: 0.05,
            scrollResumeDelay: 0.05
        )

        controller.beginStartup()
        XCTAssertTrue(controller.isSuspended)

        controller.endStartup()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(controller.isSuspended)

        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(controller.isSuspended)
    }

    func testScrollActivityExtendsSuspensionWindow() async {
        let controller = SessionManager.ThumbnailRefreshController(
            startupResumeDelay: 0.05,
            scrollResumeDelay: 0.05
        )

        controller.noteScrollActivity()
        XCTAssertTrue(controller.isSuspended)

        try? await Task.sleep(nanoseconds: 30_000_000)
        controller.noteScrollActivity()

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(controller.isSuspended)

        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(controller.isSuspended)
    }

    func testStartupAndScrollBothMustClearBeforeResume() async {
        let controller = SessionManager.ThumbnailRefreshController(
            startupResumeDelay: 0.05,
            scrollResumeDelay: 0.05
        )

        controller.beginStartup()
        controller.noteScrollActivity()
        controller.endStartup()

        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(controller.isSuspended)
    }
}
