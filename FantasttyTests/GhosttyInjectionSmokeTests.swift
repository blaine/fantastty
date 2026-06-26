import AppKit
import XCTest
@testable import Fantastty
import GhosttyKit

@MainActor
final class GhosttyInjectionSmokeTests: XCTestCase {
    func testClipboardReadReturnsNilForNonTextPasteboardContent() {
        let pasteboard = NSPasteboard(name: .init("fantastty-non-text-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(size: NSSize(width: 1, height: 1))])

        XCTAssertNil(Fantastty.Ghostty.App.readableClipboardString(from: pasteboard))
    }

    func testRemotePanePasteDataUsesOpinionatedPasteboardContents() throws {
        let pasteboard = NSPasteboard(name: .init("fantastty-remote-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let fileURL = URL(fileURLWithPath: "/tmp/fantastty paste file.txt")
        pasteboard.writeObjects([fileURL as NSURL])

        let data = try XCTUnwrap(Fantastty.Ghostty.SurfaceView.remotePanePasteData(from: pasteboard))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), Ghostty.Shell.escape(fileURL.path))
    }

    func testCoalescingInjectorInjectsBytesIntoVisibleTerminalState() async throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fantastty-ghostty-injection-\(UUID().uuidString).conf")
        try Data("window-vsync = false\n".utf8).write(to: configURL)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let app = Fantastty.Ghostty.App(configPath: configURL.path)
        guard let cApp = app.app else {
            XCTFail("Ghostty app failed to initialize")
            return
        }

        var config = Fantastty.Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        let surface = Fantastty.Ghostty.SurfaceView(cApp, baseConfig: config)
        XCTAssertNotNil(surface.surface)

        let injector = CoalescingInjector(paneID: 7, surface: surface)
        let marker = "fantastty-injection-\(UUID().uuidString)"
        injector.enqueue(Data("\u{1b}[31m\(marker)\r\n\u{1b}[0m".utf8))

        let deadline = Date().addingTimeInterval(3.0)
        var lastVisibleText = ""
        while Date() < deadline {
            lastVisibleText = readVisibleText(from: surface)
            if lastVisibleText.contains(marker) {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Injected marker never appeared in visible terminal text. Last visible text: \(lastVisibleText)")
    }

    private func readVisibleText(from surfaceView: Fantastty.Ghostty.SurfaceView) -> String {
        guard let surface = surfaceView.surface else { return "" }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0),
            rectangle: false)

        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let textPointer = text.text else { return "" }

        let buffer = UnsafeRawBufferPointer(start: textPointer, count: Int(text.text_len))
        return String(decoding: buffer, as: UTF8.self)
    }
}
