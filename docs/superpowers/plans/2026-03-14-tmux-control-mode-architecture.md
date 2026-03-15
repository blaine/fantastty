# Tmux Control Mode Architecture Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose the monolithic SessionManager into focused modules with clear responsibility boundaries, rename SessionManagerV2 to TmuxSessionBridge, introduce TmuxWindowController and TmuxPaneController, extract TerminalLifecycleRouter, and write contract tests at every level.

**Architecture:** The tmux event chain mirrors the tmux object hierarchy: TmuxSessionBridge (session) -> TmuxWindowController (window/tab) -> TmuxPaneController (pane/surface). UI actions route through TerminalLifecycleRouter. Layout persistence, notification routing, and activity tracking are extracted into standalone modules. SessionManager becomes a thin composition root.

**Tech Stack:** Swift, XCTest, tmux 3.6a control mode, GhosttyKit (libghostty), SwiftUI.

**Spec:** `docs/superpowers/specs/2026-03-14-tmux-control-mode-architecture-design.md`

---

## Chunk 1: TmuxPaneController — Extract and Test

The simplest leaf in the hierarchy. Owns one surface, injects output, buffers when not ready.

### Task 1: Create TmuxPaneController with Contract Tests

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxPaneController.swift`
- Create: `FantasttyTests/TmuxPaneControllerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `FantasttyTests/TmuxPaneControllerTests.swift`:

```swift
import XCTest
@testable import Fantastty

final class TmuxPaneControllerTests: XCTestCase {

    // MARK: - Output Injection

    func testOutputDataIsInjectedIntoSurface() {
        var injectedData: [Data] = []
        let controller = TmuxPaneController(
            paneID: 7,
            injector: { data in injectedData.append(data); return true }
        )

        controller.deliver(Data("hello".utf8))

        XCTAssertEqual(injectedData.count, 1)
        XCTAssertEqual(String(data: injectedData[0], encoding: .utf8), "hello")
    }

    func testOutputBeforeSurfaceReadyIsBuffered() {
        let controller = TmuxPaneController(paneID: 7, injector: nil)

        controller.deliver(Data("early".utf8))
        controller.deliver(Data("data".utf8))

        XCTAssertEqual(controller.bufferedOutputCount, 2)
    }

    func testBufferedOutputFlushesWhenInjectorIsSet() {
        var injectedData: [Data] = []
        let controller = TmuxPaneController(paneID: 7, injector: nil)

        controller.deliver(Data("early".utf8))
        controller.deliver(Data("data".utf8))

        controller.setInjector { data in injectedData.append(data); return true }

        XCTAssertEqual(injectedData.count, 2)
        XCTAssertEqual(String(data: injectedData[0], encoding: .utf8), "early")
        XCTAssertEqual(String(data: injectedData[1], encoding: .utf8), "data")
        XCTAssertEqual(controller.bufferedOutputCount, 0)
    }

    func testNoOutputDeliveredAfterTeardown() {
        var injectedData: [Data] = []
        let controller = TmuxPaneController(
            paneID: 7,
            injector: { data in injectedData.append(data); return true }
        )

        controller.teardown()
        controller.deliver(Data("late".utf8))

        XCTAssertTrue(injectedData.isEmpty)
    }

    func testFailedInjectionBuffersData() {
        var attempts = 0
        let controller = TmuxPaneController(
            paneID: 7,
            injector: { _ in attempts += 1; return false }
        )

        controller.deliver(Data("fail".utf8))

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(controller.bufferedOutputCount, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/TmuxPaneControllerTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: Build failure — `TmuxPaneController` not defined.

- [ ] **Step 3: Write TmuxPaneController implementation**

Create `Fantastty/Models/TmuxControlMode/TmuxPaneController.swift`:

```swift
import Foundation

final class TmuxPaneController {
    typealias Injector = (Data) -> Bool

    let paneID: Int
    private var injector: Injector?
    private var buffer: [Data] = []
    private var tornDown = false

    var bufferedOutputCount: Int { buffer.count }

    init(paneID: Int, injector: Injector?) {
        self.paneID = paneID
        self.injector = injector
    }

    func deliver(_ data: Data) {
        guard !tornDown else { return }

        if let injector, injector(data) {
            return
        }
        buffer.append(data)
    }

    func setInjector(_ injector: @escaping Injector) {
        self.injector = injector
        flushBuffer()
    }

    func teardown() {
        tornDown = true
        injector = nil
        buffer.removeAll()
    }

    private func flushBuffer() {
        guard let injector else { return }
        let pending = buffer
        buffer.removeAll()
        for data in pending {
            if !injector(data) {
                buffer.append(data)
            }
        }
    }
}
```

- [ ] **Step 4: Register files in Xcode project**

Run:
```bash
python3 scripts/add_to_xcode.py --source Fantastty/Models/TmuxControlMode/TmuxPaneController.swift
python3 scripts/add_to_xcode.py --test FantasttyTests/TmuxPaneControllerTests.swift
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/TmuxPaneControllerTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: All 5 tests PASS.

- [ ] **Step 6: Run full test suite to verify no regressions**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxPaneController.swift FantasttyTests/TmuxPaneControllerTests.swift Fantastty.xcodeproj/project.pbxproj
git commit -m "feat(tmux): add TmuxPaneController with contract tests"
```

---

## Chunk 2: TmuxWindowController — Extract and Test

Owns one TerminalTab, its SplitTree, and a map of TmuxPaneControllers. Receives layout strings, builds the tree, routes output to panes.

### Task 2: Create TmuxWindowController with Contract Tests

**Files:**
- Create: `Fantastty/Models/TmuxControlMode/TmuxWindowController.swift`
- Create: `FantasttyTests/TmuxWindowControllerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `FantasttyTests/TmuxWindowControllerTests.swift`:

```swift
import XCTest
@testable import Fantastty
import GhosttyKit

@MainActor
private enum TmuxWindowControllerTestSupport {
    static let ghosttyApp = Fantastty.Ghostty.App()
}

final class TmuxWindowControllerTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeController(
        windowID: Int = 1,
        title: String = "main",
        windowIndex: Int = 0
    ) -> TmuxWindowController {
        let app = TmuxWindowControllerTestSupport.ghosttyApp.app!
        return TmuxWindowController(
            windowID: windowID,
            title: title,
            windowIndex: windowIndex,
            surfaceFactory: { paneID in
                let surface = Ghostty.SurfaceView(app, baseConfig: nil)
                surface.tmuxPaneID = paneID
                return surface
            }
        )
    }

    // MARK: - Layout Contracts

    @MainActor
    func testLayoutProducesCorrectSplitTreeShape() {
        let controller = makeController()
        // Single pane layout
        controller.applyLayout("bb62,213x55,0,0,7")

        XCTAssertEqual(controller.paneControllers.count, 1)
        XCTAssertNotNil(controller.paneControllers[7])
        XCTAssertEqual(controller.tab.surfaceTree?.root?.leaves().count, 1)
    }

    @MainActor
    func testLayoutWithSplitCreatesMultiplePaneControllers() {
        let controller = makeController()
        // Two-pane horizontal split
        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")

        XCTAssertEqual(controller.paneControllers.count, 2)
        XCTAssertNotNil(controller.paneControllers[7])
        XCTAssertNotNil(controller.paneControllers[9])
        XCTAssertEqual(controller.tab.surfaceTree?.root?.leaves().count, 2)
    }

    @MainActor
    func testLayoutChangePreservesExistingPaneControllers() {
        let controller = makeController()
        controller.applyLayout("bb62,213x55,0,0,7")
        let originalController = controller.paneControllers[7]

        // Add a split — pane 7 should keep its controller
        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")

        XCTAssertTrue(controller.paneControllers[7] === originalController)
        XCTAssertNotNil(controller.paneControllers[9])
    }

    @MainActor
    func testLayoutChangeDestroysRemovedPaneControllers() {
        let controller = makeController()
        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")
        XCTAssertEqual(controller.paneControllers.count, 2)

        // Remove pane 9
        controller.applyLayout("bb62,213x55,0,0,7")

        XCTAssertEqual(controller.paneControllers.count, 1)
        XCTAssertNil(controller.paneControllers[9])
    }

    // MARK: - Output Routing

    @MainActor
    func testOutputRoutedToCorrectPane() {
        var injected: [(paneID: Int, data: Data)] = []
        let app = TmuxWindowControllerTestSupport.ghosttyApp.app!
        let controller = TmuxWindowController(
            windowID: 1, title: "main", windowIndex: 0,
            surfaceFactory: { paneID in
                let surface = Ghostty.SurfaceView(app, baseConfig: nil)
                surface.tmuxPaneID = paneID
                return surface
            },
            paneInjectorFactory: { paneID in
                return { data in injected.append((paneID, data)); return true }
            }
        )
        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")

        controller.deliverOutput(paneID: 7, data: Data("hello".utf8))
        controller.deliverOutput(paneID: 9, data: Data("world".utf8))

        XCTAssertEqual(injected.count, 2)
        XCTAssertEqual(injected[0].paneID, 7)
        XCTAssertEqual(injected[1].paneID, 9)
    }

    @MainActor
    func testOutputForUnknownPaneIsBufferedThenFlushedOnLayout() {
        var injected: [Data] = []
        let app = TmuxWindowControllerTestSupport.ghosttyApp.app!
        let controller = TmuxWindowController(
            windowID: 1, title: "main", windowIndex: 0,
            surfaceFactory: { paneID in
                let surface = Ghostty.SurfaceView(app, baseConfig: nil)
                surface.tmuxPaneID = paneID
                return surface
            },
            paneInjectorFactory: { _ in
                return { data in injected.append(data); return true }
            }
        )

        // Output arrives before any layout
        controller.deliverOutput(paneID: 7, data: Data("early".utf8))
        XCTAssertTrue(injected.isEmpty)
        XCTAssertTrue(controller.paneControllers.isEmpty)

        // Layout arrives — buffered output should flush
        controller.applyLayout("bb62,213x55,0,0,7")

        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(String(data: injected[0], encoding: .utf8), "early")
    }

    // MARK: - Teardown

    @MainActor
    func testTeardownClearsAllPaneControllers() {
        let controller = makeController()
        controller.applyLayout("bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}")
        XCTAssertEqual(controller.paneControllers.count, 2)

        controller.teardown()

        XCTAssertTrue(controller.paneControllers.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/TmuxWindowControllerTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: Build failure — `TmuxWindowController` not defined.

- [ ] **Step 3: Write TmuxWindowController implementation**

Create `Fantastty/Models/TmuxControlMode/TmuxWindowController.swift`:

```swift
import Foundation
import GhosttyKit

@MainActor
final class TmuxWindowController {
    typealias SurfaceFactory = (Int) -> Ghostty.SurfaceView
    typealias PaneInjectorFactory = (Int) -> TmuxPaneController.Injector

    let windowID: Int
    let tab: TerminalTab

    private let surfaceFactory: SurfaceFactory
    private let paneInjectorFactory: PaneInjectorFactory?
    private(set) var paneControllers: [Int: TmuxPaneController] = [:]
    private var pendingOutput: [Int: [Data]] = [:]

    init(
        windowID: Int,
        title: String,
        windowIndex: Int,
        surfaceFactory: @escaping SurfaceFactory,
        paneInjectorFactory: PaneInjectorFactory? = nil
    ) {
        self.windowID = windowID
        self.surfaceFactory = surfaceFactory
        self.paneInjectorFactory = paneInjectorFactory

        self.tab = TerminalTab(type: .local, title: title)
        self.tab.tmuxWindowID = windowID
        self.tab.tmuxWindowIndex = windowIndex
    }

    func applyLayout(_ layout: String) {
        let buildResult = AttachedTmuxWindowRuntime.buildLayoutTree(
            layout: layout,
            existingTree: tab.surfaceTree
        ) { [surfaceFactory] paneID in
            surfaceFactory(paneID)
        }

        let newPaneIDs = buildResult.paneIDs

        // Remove controllers for panes no longer in layout
        for (paneID, controller) in paneControllers where !newPaneIDs.contains(paneID) {
            controller.teardown()
            paneControllers.removeValue(forKey: paneID)
        }

        // Add controllers for new panes
        for paneID in newPaneIDs where paneControllers[paneID] == nil {
            let injector = paneInjectorFactory?(paneID)
            let controller = TmuxPaneController(paneID: paneID, injector: injector)
            paneControllers[paneID] = controller

            // Flush any pending output for this pane
            if let pending = pendingOutput.removeValue(forKey: paneID) {
                for data in pending {
                    controller.deliver(data)
                }
            }
        }

        tab.surfaceTree = SplitTree(root: buildResult.root, zoomed: nil)

        // Set initial focus
        let leaves = tab.surfaceTree?.root?.leaves() ?? []
        if let focused = tab.focusedSurface, !leaves.contains(where: { $0 === focused }) {
            tab.focusedSurface = leaves.first
        } else if tab.focusedSurface == nil {
            tab.focusedSurface = leaves.first
        }
    }

    func deliverOutput(paneID: Int, data: Data) {
        if let controller = paneControllers[paneID] {
            controller.deliver(data)
        } else {
            pendingOutput[paneID, default: []].append(data)
        }
    }

    func setActivePane(_ paneID: Int) {
        guard let surface = tab.surfaceTree?.root?.leaves().first(where: { $0.tmuxPaneID == paneID }) else {
            return
        }
        tab.focusedSurface = surface
    }

    func teardown() {
        for (_, controller) in paneControllers {
            controller.teardown()
        }
        paneControllers.removeAll()
        pendingOutput.removeAll()
    }
}
```

- [ ] **Step 4: Register files in Xcode project**

Run:
```bash
python3 scripts/add_to_xcode.py --source Fantastty/Models/TmuxControlMode/TmuxWindowController.swift
python3 scripts/add_to_xcode.py --test FantasttyTests/TmuxWindowControllerTests.swift
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/TmuxWindowControllerTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: All tests PASS.

- [ ] **Step 6: Run full test suite**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Fantastty/Models/TmuxControlMode/TmuxWindowController.swift FantasttyTests/TmuxWindowControllerTests.swift Fantastty.xcodeproj/project.pbxproj
git commit -m "feat(tmux): add TmuxWindowController with contract tests"
```

---

## Chunk 3: Rename SessionManagerV2 to TmuxSessionBridge

Mechanical rename before we add new contracts or change behavior.

### Task 3: Rename SessionManagerV2 to TmuxSessionBridge

**Files:**
- Rename: `Fantastty/Models/SessionManagerV2.swift` -> `Fantastty/Models/TmuxSessionBridge.swift`
- Rename: `FantasttyTests/SessionManagerV2Tests.swift` -> `FantasttyTests/TmuxSessionBridgeTests.swift`
- Modify: `Fantastty/Models/SessionManager.swift` (update references)
- Modify: `Fantastty.xcodeproj/project.pbxproj` (update file references)

- [ ] **Step 1: Rename the class, property, and all references**

Use find-and-replace across all `.swift` files:
- `class SessionManagerV2` -> `class TmuxSessionBridge`
- `SessionManagerV2TestSupport` -> `TmuxSessionBridgeTestSupport`
- `SessionManagerV2Tests` -> `TmuxSessionBridgeTests`
- `SessionManagerV2.` -> `TmuxSessionBridge.` (static references)
- `SessionManagerV2()` -> `TmuxSessionBridge()` (construction)

In `Fantastty/Models/SessionManager.swift`, also rename the property:
- `attachedSessionManagerV2` -> `tmuxSessionBridge`

This includes all usages of the property throughout SessionManager (in init, didSet observers, forwarding methods, etc.).

- [ ] **Step 2: Rename the source files on disk**

```bash
git mv Fantastty/Models/SessionManagerV2.swift Fantastty/Models/TmuxSessionBridge.swift
git mv FantasttyTests/SessionManagerV2Tests.swift FantasttyTests/TmuxSessionBridgeTests.swift
```

- [ ] **Step 3: Update pbxproj file references**

Update the file name references in `Fantastty.xcodeproj/project.pbxproj` from `SessionManagerV2` to `TmuxSessionBridge` (both source and test file entries).

- [ ] **Step 4: Rename the V2 directory to just be part of TmuxControlMode**

The `V2/` subdirectory under `TmuxControlMode` is vestigial naming. Leave file locations as-is for now — renaming the directory would require extensive pbxproj changes with no functional benefit. The class rename is what matters.

- [ ] **Step 5: Run full test suite to verify rename is clean**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Fantastty/Models/TmuxSessionBridge.swift Fantastty/Models/SessionManager.swift FantasttyTests/TmuxSessionBridgeTests.swift Fantastty.xcodeproj/project.pbxproj
git commit -m "refactor(tmux): rename SessionManagerV2 to TmuxSessionBridge"
```

---

## Chunk 4: TmuxSessionBridge Contract Tests

Lock down existing behavior of TmuxSessionBridge before refactoring its internals to use TmuxWindowController.

### Task 4: Add Contract Tests to TmuxSessionBridgeTests

**Depends on:** Chunk 3 (rename) must be completed first.

**Files:**
- Modify: `FantasttyTests/TmuxSessionBridgeTests.swift`

These tests augment the existing tests. Many of these behaviors are already partially tested; these contracts make the invariants explicit and complete.

- [ ] **Step 1: Add window-add ordering contract test**

Append to `TmuxSessionBridgeTests.swift`:

```swift
@MainActor
func testWindowAddCreatesTabAtCorrectIndexOrder() {
    let manager = TmuxSessionBridge()
    manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
    let session = makeAttachedSession(workspaceID: "bridge-order")
    manager.registerAttachedSession(session)
    guard let client = session.controlClient else {
        return XCTFail("Expected control client")
    }

    // Add windows out of order
    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 2, name: "second", paneIDs: [], windowIndex: 2, isActive: false))
    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 1, name: "first", paneIDs: [], windowIndex: 0, isActive: false))
    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 3, name: "third", paneIDs: [], windowIndex: 1, isActive: false))

    let terminalTabs = session.tabs.filter { $0.kind == .terminal }
    XCTAssertEqual(terminalTabs.count, 3)
    XCTAssertEqual(terminalTabs[0].tmuxWindowIndex, 0)
    XCTAssertEqual(terminalTabs[1].tmuxWindowIndex, 1)
    XCTAssertEqual(terminalTabs[2].tmuxWindowIndex, 2)
}
```

- [ ] **Step 2: Add window-close selects-adjacent contract test**

```swift
@MainActor
func testWindowCloseRemovesTabAndSelectsAdjacent() {
    let manager = TmuxSessionBridge()
    manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
    let session = makeAttachedSession(workspaceID: "bridge-close")
    manager.registerAttachedSession(session)
    guard let client = session.controlClient else {
        return XCTFail("Expected control client")
    }

    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 1, name: "one", paneIDs: [], windowIndex: 0, isActive: true))
    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 2, name: "two", paneIDs: [], windowIndex: 1, isActive: false))

    // Select window 2, then close it
    manager.controlClient(client, didChangeActiveWindowID: 2)
    XCTAssertEqual(session.selectedTab?.tmuxWindowID, 2)

    manager.controlClient(client, didCloseWindowID: 2)

    XCTAssertEqual(session.tabs.filter { $0.kind == .terminal }.count, 1)
    XCTAssertNotNil(session.selectedTabID)
}
```

- [ ] **Step 3: Add active-window-change no-echo contract test**

```swift
@MainActor
func testActiveWindowChangeDoesNotEchoSelectWindow() {
    let manager = TmuxSessionBridge()
    manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
    let session = makeAttachedSession(workspaceID: "bridge-noecho")
    manager.registerAttachedSession(session)
    guard let client = session.controlClient else {
        return XCTFail("Expected control client")
    }

    var selectWindowCalls: [Int] = []
    manager.tmuxWindowSelector = { _, windowID in
        selectWindowCalls.append(windowID)
    }

    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 1, name: "one", paneIDs: [], windowIndex: 0, isActive: true))
    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 2, name: "two", paneIDs: [], windowIndex: 1, isActive: false))

    // Tmux tells us window 2 is now active — should NOT echo select-window back
    manager.controlClient(client, didChangeActiveWindowID: 2)

    XCTAssertEqual(session.selectedTab?.tmuxWindowID, 2)
    XCTAssertTrue(selectWindowCalls.isEmpty)
}
```

- [ ] **Step 4: Add client-exit teardown contract test**

```swift
@MainActor
func testClientExitTearsDownAndSetsDisconnected() {
    let manager = TmuxSessionBridge()
    manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
    let session = makeAttachedSession(workspaceID: "bridge-exit")
    manager.registerAttachedSession(session)
    guard let client = session.controlClient else {
        return XCTFail("Expected control client")
    }

    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 1, name: "main", paneIDs: [], windowIndex: 0, isActive: true))
    manager.controlClient(client, didChangeLayoutForWindowID: 1, layout: "bb62,213x55,0,0,7")

    manager.controlClientDidExit(client, reason: "connection lost")

    if case .attached(let info) = session.mode {
        if case .disconnected(let reason) = info.connectionState {
            XCTAssertEqual(reason, "connection lost")
        } else {
            XCTFail("Expected disconnected state")
        }
    } else {
        XCTFail("Expected attached mode")
    }
}
```

- [ ] **Step 5: Add window-renamed contract test**

```swift
@MainActor
func testWindowRenamedUpdatesTabTitle() {
    let manager = TmuxSessionBridge()
    manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
    let session = makeAttachedSession(workspaceID: "bridge-rename")
    manager.registerAttachedSession(session)
    guard let client = session.controlClient else {
        return XCTFail("Expected control client")
    }

    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 1, name: "original", paneIDs: [], windowIndex: 0, isActive: true))
    XCTAssertEqual(session.tabs.first?.title, "original")

    manager.controlClient(client, didRenameWindowID: 1, to: "renamed")
    XCTAssertEqual(session.tabs.first?.title, "renamed")
}
```

- [ ] **Step 6: Add output-before-window-add buffering contract test**

```swift
@MainActor
func testOutputBeforeWindowAddIsBufferedAndFlushed() {
    let manager = TmuxSessionBridge()
    manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
    let session = makeAttachedSession(workspaceID: "bridge-buffer")
    manager.registerAttachedSession(session)
    guard let client = session.controlClient else {
        return XCTFail("Expected control client")
    }

    var injected: [(paneID: Int, text: String)] = []
    manager.tmuxOutputInjector = { surface, data in
        guard let paneID = surface.tmuxPaneID,
              let text = String(data: data, encoding: .utf8) else { return false }
        injected.append((paneID, text))
        return true
    }

    // Output arrives before window-add
    manager.controlClient(client, didReceiveOutput: Data("early".utf8), forPaneID: 7)
    XCTAssertTrue(injected.isEmpty)

    // Window-add arrives, then layout
    manager.controlClient(client, didAddWindow: TmuxWindow(windowID: 1, name: "main", paneIDs: [], windowIndex: 0, isActive: true))
    manager.controlClient(client, didChangeLayoutForWindowID: 1, layout: "bb62,213x55,0,0,7")

    // Buffered output should have flushed
    XCTAssertEqual(injected.count, 1)
    XCTAssertEqual(injected[0].paneID, 7)
    XCTAssertEqual(injected[0].text, "early")
}
```

- [ ] **Step 7: Run contract tests**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/TmuxSessionBridgeTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: All tests PASS (these test existing behavior).

- [ ] **Step 8: Commit**

```bash
git add FantasttyTests/TmuxSessionBridgeTests.swift
git commit -m "test(tmux): add contract tests for TmuxSessionBridge invariants"
```

---

## Chunk 5: TerminalLifecycleRouter — Extract and Test

This is where the bugs live. Close-tab must send kill-window, close-surface must send kill-pane. Currently neither happens.

### Task 5: Create TerminalLifecycleRouter with Contract Tests

**Files:**
- Create: `Fantastty/Models/TerminalLifecycleRouter.swift`
- Create: `FantasttyTests/TerminalLifecycleRouterTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `FantasttyTests/TerminalLifecycleRouterTests.swift`:

```swift
import XCTest
@testable import Fantastty

final class TerminalLifecycleRouterTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeSession(workspaceID: String = "router-test") -> (Session, MockTmuxCommandSender) {
        let info = TmuxAttachmentInfo(
            sessionName: "tmux-\(workspaceID)",
            host: .local,
            connectionState: .connected
        )
        let session = Session(title: "Test", type: .local, workspaceID: workspaceID)
        session.mode = .attached(info)

        let sender = MockTmuxCommandSender()
        return (session, sender)
    }

    @MainActor
    private func makeTerminalTab(tmuxWindowID: Int, paneIDs: [Int] = []) -> TerminalTab {
        let tab = TerminalTab(type: .local, title: "tab-\(tmuxWindowID)")
        tab.tmuxWindowID = tmuxWindowID
        return tab
    }

    // MARK: - Close Tab Contracts

    @MainActor
    func testCloseTerminalTabSendsKillWindow() async {
        let (session, sender) = makeSession()
        let tab = makeTerminalTab(tmuxWindowID: 1)
        session.tabs = [tab]
        session.selectedTabID = tab.id

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.closeTerminalTab(tab, in: session)

        XCTAssertEqual(sender.killedWindowIDs, [1])
    }

    @MainActor
    func testClosePaneSendsKillPane() async {
        let (session, sender) = makeSession()
        let tab = makeTerminalTab(tmuxWindowID: 1)
        session.tabs = [tab]

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.closePane(paneID: 7, in: session)

        XCTAssertEqual(sender.killedPaneIDs, [7])
    }

    @MainActor
    func testCloseLastTerminalTabSendsKillWindowButDoesNotKillSession() async {
        let (session, sender) = makeSession()
        let tab = makeTerminalTab(tmuxWindowID: 1)
        session.tabs = [tab]
        session.selectedTabID = tab.id

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.closeTerminalTab(tab, in: session)

        // Router sends kill-window; it does NOT remove the tab or kill the session.
        // Tab removal happens when tmux sends %window-close.
        // Placeholder state is set by the caller (SessionManager) when the last
        // terminal tab is removed — tested in Chunk 6 integration tests.
        XCTAssertEqual(sender.killedWindowIDs, [1])
    }

    @MainActor
    func testNewTabSendsNewWindow() async {
        let (session, sender) = makeSession()

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.requestNewTab(in: session)

        XCTAssertEqual(sender.newWindowCalls, 1)
    }

    @MainActor
    func testSplitSendsSplitPane() async {
        let (session, sender) = makeSession()

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.requestSplit(paneID: 7, horizontal: true, in: session)

        XCTAssertEqual(sender.splitPaneCalls.count, 1)
        XCTAssertEqual(sender.splitPaneCalls[0].paneID, 7)
        XCTAssertTrue(sender.splitPaneCalls[0].horizontal)
    }

    @MainActor
    func testActionsNoOpWhenDisconnected() async {
        let info = TmuxAttachmentInfo(
            sessionName: "tmux-disconnected",
            host: .local,
            connectionState: .disconnected(reason: "gone")
        )
        let session = Session(title: "Test", type: .local, workspaceID: "router-disconnected")
        session.mode = .attached(info)
        let sender = MockTmuxCommandSender()

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.requestNewTab(in: session)

        XCTAssertEqual(sender.newWindowCalls, 0)
    }

    @MainActor
    func testCloseBrowserTabSendsNoTmuxCommand() async {
        let (session, sender) = makeSession()
        let browserTab = TerminalTab(url: URL(string: "https://example.com")!)
        session.tabs = [browserTab]

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.closeTerminalTab(browserTab, in: session)

        XCTAssertTrue(sender.killedWindowIDs.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/TerminalLifecycleRouterTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: Build failure — `TerminalLifecycleRouter` not defined.

- [ ] **Step 3: Write TerminalLifecycleRouter implementation**

Create `Fantastty/Models/TerminalLifecycleRouter.swift`:

```swift
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
```

- [ ] **Step 4: Register files in Xcode project**

Run:
```bash
python3 scripts/add_to_xcode.py --source Fantastty/Models/TerminalLifecycleRouter.swift
python3 scripts/add_to_xcode.py --test FantasttyTests/TerminalLifecycleRouterTests.swift
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/TerminalLifecycleRouterTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: All 7 tests PASS.

- [ ] **Step 6: Run full test suite**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Fantastty/Models/TerminalLifecycleRouter.swift FantasttyTests/TerminalLifecycleRouterTests.swift Fantastty.xcodeproj/project.pbxproj
git commit -m "feat(tmux): add TerminalLifecycleRouter with contract tests for kill-window/kill-pane"
```

---

## Chunk 6: Wire TerminalLifecycleRouter into SessionManager

Replace the broken closeTab/closeSurface paths with routing through TerminalLifecycleRouter.

### Task 6: Wire TerminalLifecycleRouter into SessionManager

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`

- [ ] **Step 1: Add TerminalLifecycleRouter as a property**

In `SessionManager`, add the router property and wire it in `configureAttachedSession`:

Near the `attachedSessionManagerV2` property (which will now be named `tmuxSessionBridge`), add:

```swift
private var lifecycleRouterByWorkspaceID: [String: TerminalLifecycleRouter] = [:]
```

- [ ] **Step 2: Create router when configuring attached sessions**

In `configureAttachedSession(_:with:)`, after creating the client, create a router:

```swift
lifecycleRouterByWorkspaceID[session.workspaceID] = TerminalLifecycleRouter(commandSender: client)
```

- [ ] **Step 3: Update closeTab to route through TerminalLifecycleRouter**

In `closeTab(id:)`, before removing the tab, send `kill-window` for terminal tabs:

```swift
func closeTab(id: UUID) {
    guard let session = sessions.first(where: { $0.tabs.contains { $0.id == id } }) else { return }
    guard let tab = session.tabs.first(where: { $0.id == id }) else { return }

    if tab.kind == .terminal, let router = lifecycleRouterByWorkspaceID[session.workspaceID] {
        Task {
            await router.closeTerminalTab(tab, in: session)
        }
        // Tab removal happens when tmux sends %window-close back
        return
    }

    // Browser tabs close locally
    deregisterSurfaces(in: tab)
    let shouldCloseSession = session.closeTab(id: id)
    if shouldCloseSession {
        closeSession(id: session.id)
    }
}
```

- [ ] **Step 4: Update closeSurface to route through TerminalLifecycleRouter**

In `closeSurface(_:)`, for attached panes send `kill-pane`:

```swift
func closeSurface(_ surfaceView: Ghostty.SurfaceView) {
    guard let (session, tab) = findSessionAndTab(for: surfaceView) else { return }

    if let paneID = surfaceView.tmuxPaneID,
       let router = lifecycleRouterByWorkspaceID[session.workspaceID] {
        Task {
            await router.closePane(paneID: paneID, in: session)
        }
        // Pane removal happens when tmux sends %layout-change back
        return
    }

    // Non-tmux surface handling (shouldn't happen in attached-only mode)
    surfaceIndex.removeValue(forKey: ObjectIdentifier(surfaceView))
    guard let node = tab.surfaceTree?.root?.node(view: surfaceView) else { return }
    if let newRoot = tab.surfaceTree?.root?.remove(node) {
        tab.surfaceTree = SplitTree(root: newRoot, zoomed: nil)
        if let firstView = firstLeafView(in: newRoot) {
            tab.focusedSurface = firstView
        }
    } else {
        closeTab(id: tab.id)
    }
}
```

- [ ] **Step 5: Clean up router on session close/unregister**

In `closeSession(id:killTmux:)`, add cleanup:

```swift
lifecycleRouterByWorkspaceID.removeValue(forKey: session.workspaceID)
```

- [ ] **Step 6: Add integration test verifying SessionManager.closeTab routes through router**

Add to `FantasttyTests/WindowManagementTests.swift`:

```swift
@MainActor
func testCloseTerminalTabSendsKillWindowThroughRouter() {
    let manager = SessionManager()
    manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp
    manager.attachedSessionReconnectStarter = { _ in }
    let sender = MockTmuxCommandSender()
    manager.attachedTmuxNewWindowSender = { _ in "" }

    let session = manager.makeAttachedSession(
        info: TmuxAttachmentInfo(
            sessionName: "router-integration",
            host: .local,
            connectionState: .connected
        ),
        workspaceID: "router-int"
    )
    manager.sessions.append(session)
    manager.selectedSessionID = session.id

    // Simulate tmux adding a window
    guard let client = session.controlClient else {
        return XCTFail("Expected control client")
    }
    // Wire the mock sender as the lifecycle router's command sender
    manager.lifecycleRouterByWorkspaceID["router-int"] = TerminalLifecycleRouter(commandSender: sender)

    // Manually add a terminal tab as if tmux created it
    let tab = TerminalTab(type: .local, title: "test")
    tab.tmuxWindowID = 1
    session.tabs.append(tab)
    session.selectedTabID = tab.id

    manager.closeTab(id: tab.id)

    // Give the Task a moment to execute
    let expectation = expectation(description: "kill-window sent")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        XCTAssertEqual(sender.killedWindowIDs, [1])
        // Tab should NOT be removed yet (waits for %window-close from tmux)
        expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
}
```

**Note:** The `%window-close` event handler (in `TmuxSessionBridge`) must call `deregisterSurfaces(in: tab)` before removing the tab, since `closeTab` no longer does this for terminal tabs. Verify this is handled in the `removeWindow` action path.

- [ ] **Step 7: Run full test suite**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 8: Verify build**

Run: `xcodebuild -project Fantastty.xcodeproj -scheme Fantastty -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
git add Fantastty/Models/SessionManager.swift
git commit -m "fix(tmux): route closeTab and closeSurface through TerminalLifecycleRouter

closeTab now sends kill-window for terminal tabs instead of removing
them locally. closeSurface sends kill-pane. Tab/pane removal happens
when tmux confirms via %window-close or %layout-change."
```

---

## Chunk 7: Wire TmuxSessionBridge to use TmuxWindowController

Refactor TmuxSessionBridge internals to delegate per-window work to TmuxWindowController instead of doing it inline. The contract tests from Chunk 4 ensure behavior is preserved.

### Task 7: Refactor TmuxSessionBridge to Use TmuxWindowController

**Files:**
- Modify: `Fantastty/Models/TmuxSessionBridge.swift` (was `SessionManagerV2.swift`)

- [ ] **Step 1: Add windowControllers map**

Replace the inline layout/output/pane logic with delegation to `TmuxWindowController` instances. Add:

```swift
private var windowControllersByWorkspace: [String: [Int: TmuxWindowController]] = [:]
```

- [ ] **Step 2: Refactor upsertWindow to create TmuxWindowController**

The `upsertWindow` method should create a `TmuxWindowController` and let it own the tab:

```swift
func upsertWindow(_ snapshot: AttachedWindowSnapshotV2, in session: Session, client: TmuxControlClient) {
    let wsID = session.workspaceID
    if windowControllersByWorkspace[wsID]?[snapshot.windowID] != nil {
        // Update existing
        let controller = windowControllersByWorkspace[wsID]![snapshot.windowID]!
        controller.tab.title = snapshot.title
        controller.tab.tmuxWindowIndex = snapshot.windowIndex
        if snapshot.isActive {
            activeWindowIDByWorkspaceID[session.workspaceID] = snapshot.windowID
            withSuppressedTabSelectionSync(for: session.workspaceID) {
                session.selectedTabID = controller.tab.id
            }
        }
        return
    }

    let controller = TmuxWindowController(
        windowID: snapshot.windowID,
        title: snapshot.title,
        windowIndex: snapshot.windowIndex ?? 0,
        surfaceFactory: { [weak self] paneID in
            guard let app = self?.ghosttyApp?.app else {
                fatalError("Ghostty app not available for surface creation")
            }
            let surface = Ghostty.SurfaceView(app, baseConfig: Self.attachedTmuxSurfaceConfiguration())
            surface.tmuxPaneID = paneID
            surface.tmuxControlClient = client
            return surface
        }
    )

    windowControllersByWorkspace[wsID, default: [:]][snapshot.windowID] = controller

    let window = TmuxWindow(windowID: snapshot.windowID, name: snapshot.title, paneIDs: [], windowIndex: snapshot.windowIndex, isActive: snapshot.isActive)
    let insertIndex = AttachedTmuxWindowRuntime.terminalInsertIndex(for: window, tabs: session.tabs)
    session.tabs.insert(controller.tab, at: insertIndex)

    if snapshot.isActive || session.selectedTabID == nil {
        if snapshot.isActive {
            activeWindowIDByWorkspaceID[session.workspaceID] = snapshot.windowID
        } else if activeWindowIDByWorkspaceID[session.workspaceID] == nil {
            activeWindowIDByWorkspaceID[session.workspaceID] = snapshot.windowID
        }
        withSuppressedTabSelectionSync(for: session.workspaceID) {
            session.selectedTabID = controller.tab.id
        }
    }
}
```

- [ ] **Step 3: Refactor applyLayout to delegate to window controller**

```swift
func applyLayout(_ layout: String, windowID: Int, session: Session, client: TmuxControlClient) {
    guard let controller = windowControllersByWorkspace[session.workspaceID]?[windowID] else {
        return
    }
    controller.applyLayout(layout)

    // Rebind surfaces to current client
    let leaves = controller.tab.surfaceTree?.root?.leaves() ?? []
    for surface in leaves {
        surface.tmuxControlClient = client
    }
}
```

- [ ] **Step 4: Refactor deliverPaneOutput to delegate to window controller**

```swift
case .deliverPaneOutput(let windowID, let paneID, let data):
    guard let controller = windowControllersByWorkspace[session.workspaceID]?[windowID] else {
        continue
    }
    controller.deliverOutput(paneID: paneID, data: data)
    controller.tab.requestThumbnailRefresh()
```

- [ ] **Step 5: Refactor removeWindow to tear down window controller**

```swift
case .removeWindow(let windowID):
    cleanupAttachedTmuxWindowState(for: client, windowID: windowID)
    if let controller = windowControllersByWorkspace[session.workspaceID]?.removeValue(forKey: windowID) {
        controller.teardown()
        if let index = session.tabs.firstIndex(where: { $0.id == controller.tab.id }) {
            session.tabs.remove(at: index)
            // handle selection
        }
    }
```

- [ ] **Step 6: Clean up controllers on client exit and unregister**

In `controlClientDidExit` and `unregisterSession`, tear down all window controllers:

```swift
if let controllers = windowControllersByWorkspace.removeValue(forKey: session.workspaceID) {
    for (_, controller) in controllers {
        controller.teardown()
    }
}
```

- [ ] **Step 7: Run TmuxSessionBridge contract tests**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/TmuxSessionBridgeTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: All tests PASS (contract tests from Chunk 4 catch any regressions).

- [ ] **Step 8: Run full test suite**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
git add Fantastty/Models/TmuxSessionBridge.swift
git commit -m "refactor(tmux): delegate per-window work to TmuxWindowController

TmuxSessionBridge now creates TmuxWindowController instances for each
tmux window. Layout building, output routing, and pane management are
delegated to the window controller. The V2 runtime state machines
remain as the event-to-action core."
```

---

## Chunk 8: Extract LayoutPersistence

### Task 8: Extract LayoutPersistence from SessionManager

**Files:**
- Create: `Fantastty/Models/LayoutPersistence.swift`
- Create: `FantasttyTests/LayoutPersistenceTests.swift`
- Modify: `Fantastty/Models/SessionManager.swift`

- [ ] **Step 1: Write contract tests**

Create `FantasttyTests/LayoutPersistenceTests.swift`:

```swift
import XCTest
@testable import Fantastty

final class LayoutPersistenceTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutPersistenceTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testSaveExcludesTerminalTabs() {
        let persistence = LayoutPersistence(layoutURL: tempURL)
        let session = Session(title: "test", type: .local, workspaceID: "lp-test")
        let terminalTab = TerminalTab(type: .local, title: "terminal")
        terminalTab.tmuxWindowID = 1
        let browserTab = TerminalTab(url: URL(string: "https://example.com")!)
        session.tabs = [terminalTab, browserTab]

        let snapshot = persistence.buildSnapshot(
            sessions: [session],
            selectedWorkspaceID: session.workspaceID
        )

        let tabs = snapshot.workspaces.first?.tabs ?? []
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.kind, .browser)
    }

    func testSaveAndLoadRoundTripPreservesBrowserTabLayouts() {
        let persistence = LayoutPersistence(layoutURL: tempURL)
        let snapshot = LayoutSnapshot(
            workspaces: [
                WorkspaceLayout(
                    workspaceID: "lp-restore",
                    selectedTabIndex: nil,
                    sessionType: nil,
                    attachment: TmuxAttachmentInfo(
                        sessionName: "test",
                        host: .local,
                        connectionState: .disconnected(reason: nil)
                    ),
                    tabs: [
                        WorkspaceTabLayout(kind: .browser, url: URL(string: "https://example.com")),
                    ]
                )
            ],
            selectedWorkspaceID: "lp-restore",
            savedAt: Date()
        )

        persistence.save(snapshot)
        guard let loaded = persistence.load() else {
            return XCTFail("Expected to load snapshot")
        }

        let tabs = loaded.workspaces.first?.tabs ?? []
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.kind, .browser)
    }

    func testMissingLayoutFileReturnsNil() {
        let persistence = LayoutPersistence(
            layoutURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        )

        XCTAssertNil(persistence.load())
    }

    func testCorruptLayoutFileReturnsNil() {
        let persistence = LayoutPersistence(layoutURL: tempURL)
        try! Data("not json".utf8).write(to: tempURL)

        XCTAssertNil(persistence.load())
    }
}
```

- [ ] **Step 2: Write LayoutPersistence implementation**

Create `Fantastty/Models/LayoutPersistence.swift`:

```swift
import Foundation
import os

final class LayoutPersistence {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "layout-persistence"
    )

    private let layoutURL: URL

    init(layoutURL: URL? = nil) {
        if let layoutURL {
            self.layoutURL = layoutURL
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            self.layoutURL = homeDir.appendingPathComponent(".fantastty/layout.json")
        }
    }

    func buildSnapshot(
        sessions: [Session],
        selectedWorkspaceID: String?
    ) -> LayoutSnapshot {
        var workspaces: [WorkspaceLayout] = []

        for session in sessions {
            guard case .attached(let info) = session.mode else { continue }

            let browserTabs = session.tabs.compactMap { tab -> WorkspaceTabLayout? in
                guard tab.kind == .browser else { return nil }
                return WorkspaceTabLayout(kind: .browser, url: tab.url)
            }

            let selectedBrowserIndex: Int?
            if let selectedID = session.selectedTabID,
               let selectedIndex = session.tabs.firstIndex(where: { $0.id == selectedID }),
               session.tabs[selectedIndex].kind == .browser {
                selectedBrowserIndex = session.tabs[..<selectedIndex]
                    .filter { $0.kind == .browser }
                    .count
            } else {
                selectedBrowserIndex = nil
            }

            var persistedInfo = info
            persistedInfo.connectionState = .disconnected(reason: nil)
            persistedInfo.launchMode = .attach

            workspaces.append(WorkspaceLayout(
                workspaceID: session.workspaceID,
                selectedTabIndex: selectedBrowserIndex,
                sessionType: session.type == .local ? nil : session.type,
                attachment: persistedInfo,
                tabs: browserTabs
            ))
        }

        return LayoutSnapshot(
            workspaces: workspaces,
            selectedWorkspaceID: selectedWorkspaceID,
            savedAt: Date()
        )
    }

    func save(_ snapshot: LayoutSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: layoutURL, options: .atomic)
            Self.logger.info("Saved layout snapshot with \(snapshot.workspaces.count) workspaces")
        } catch {
            Self.logger.error("Failed to save layout: \(error)")
        }
    }

    func load() -> LayoutSnapshot? {
        guard FileManager.default.fileExists(atPath: layoutURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: layoutURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LayoutSnapshot.self, from: data)
        } catch {
            Self.logger.warning("Failed to load layout snapshot: \(error)")
            return nil
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: layoutURL)
    }
}
```

- [ ] **Step 3: Register files in Xcode project**

Run:
```bash
python3 scripts/add_to_xcode.py --source Fantastty/Models/LayoutPersistence.swift
python3 scripts/add_to_xcode.py --test FantasttyTests/LayoutPersistenceTests.swift
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/LayoutPersistenceTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: All 4 tests PASS.

- [ ] **Step 5: Update SessionManager to use LayoutPersistence**

Replace `saveLayout()`, `loadLayout()`, `deleteLayout()` in SessionManager with calls to `LayoutPersistence`:

```swift
private let layoutPersistence = LayoutPersistence()

func saveLayout() {
    guard persistentSessionsEnabled else { return }
    let snapshot = layoutPersistence.buildSnapshot(
        sessions: sessions,
        selectedWorkspaceID: selectedSession?.workspaceID
    )
    layoutPersistence.save(snapshot)
}
```

Remove the old `loadLayout()`, `deleteLayout()`, `layoutURL`, `defaultLayoutURL`, and `layoutURLOverride` properties. Replace usages in `restoreTmuxSessions()`.

- [ ] **Step 6: Run full test suite**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Fantastty/Models/LayoutPersistence.swift FantasttyTests/LayoutPersistenceTests.swift Fantastty/Models/SessionManager.swift Fantastty.xcodeproj/project.pbxproj
git commit -m "refactor(persistence): extract LayoutPersistence from SessionManager"
```

---

## Chunk 9: Clean Up SessionManager — Remove Debug Noise, Extract NotificationRouter and ActivityTracker

### Task 9: Strip Debug Logging Noise

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`

- [ ] **Step 1: Replace verbose debug logging with concise os.Logger calls**

In the notification handlers (`handleBellDidRing`, `handleCommandFinished`, `handleSessionNote`, `handleKeyInput`, etc.), remove all `Self.debugLog("NOTIFICATION: ...")`, `Self.debugLog("BELL STATE: ...")`, `Self.debugLog("COMMAND_FINISHED: ...")` calls. Replace with single-line `Self.logger.debug(...)` where the log actually adds value. Remove redundant logging like "Observer registered" and "Looking for session...".

- [ ] **Step 2: Run full test suite**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Fantastty/Models/SessionManager.swift
git commit -m "chore(cleanup): strip verbose debug logging from SessionManager notification handlers"
```

### Task 10: Extract NotificationRouter

**Files:**
- Create: `Fantastty/Models/NotificationRouter.swift`
- Modify: `Fantastty/Models/SessionManager.swift`

- [ ] **Step 1: Create NotificationRouter**

Extract all `@objc` notification handlers and `setupNotificationObservers()` into a new class. The router resolves surface→session/tab and calls typed closures:

```swift
import Foundation
import GhosttyKit

final class NotificationRouter {
    typealias SurfaceResolver = (Ghostty.SurfaceView) -> (Session, TerminalTab)?

    var surfaceResolver: SurfaceResolver?
    var onNewTab: (() -> Void)?
    var onCloseSurface: ((Ghostty.SurfaceView) -> Void)?
    var onNewSplit: ((Ghostty.SurfaceView, SplitTree<Ghostty.SurfaceView>.NewDirection) -> Void)?
    var onGotoTab: ((ghostty_action_goto_tab_e) -> Void)?
    var onFocusSplit: ((Ghostty.SurfaceView, Ghostty.SplitFocusDirection) -> Void)?
    var onBell: ((Session, TerminalTab) -> Void)?
    var onKeyInput: ((Session, TerminalTab) -> Void)?
    var onSessionNote: ((Session, String) -> Void)?
    var onTicketURL: ((Session, String) -> Void)?
    var onPullRequestURL: ((Session, String) -> Void)?

    func register() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleNewTab), name: Ghostty.Notification.ghosttyNewTab, object: nil)
        center.addObserver(self, selector: #selector(handleCloseSurface), name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
        // ... register all handlers
    }

    // Each @objc handler resolves the surface and calls the appropriate closure
}
```

- [ ] **Step 2: Write contract tests for NotificationRouter**

Create `FantasttyTests/NotificationRouterTests.swift`:

```swift
import XCTest
@testable import Fantastty

final class NotificationRouterTests: XCTestCase {

    @MainActor
    func testNewTabNotificationCallsOnNewTab() {
        let router = NotificationRouter()
        var called = false
        router.onNewTab = { called = true }
        router.register()

        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil
        )

        XCTAssertTrue(called)
    }

    @MainActor
    func testCloseSurfaceNotificationCallsOnCloseSurface() {
        let router = NotificationRouter()
        var closedSurface: Ghostty.SurfaceView?
        router.onCloseSurface = { surface in closedSurface = surface }
        router.register()

        let app = Ghostty.App()
        guard let ghosttyApp = app.app else { return }
        let surface = Ghostty.SurfaceView(ghosttyApp, baseConfig: nil)
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: surface
        )

        XCTAssertTrue(closedSurface === surface)
    }
}
```

- [ ] **Step 3: Wire SessionManager to use NotificationRouter**

Replace `setupNotificationObservers()` with router setup. SessionManager provides closures that implement the actual business logic.

- [ ] **Step 4: Register test file in Xcode project**

Run:
```bash
python3 scripts/add_to_xcode.py --test FantasttyTests/NotificationRouterTests.swift
```

- [ ] **Step 5: Run full test suite**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Fantastty/Models/NotificationRouter.swift FantasttyTests/NotificationRouterTests.swift Fantastty/Models/SessionManager.swift Fantastty.xcodeproj/project.pbxproj
git commit -m "refactor(notifications): extract NotificationRouter from SessionManager"
```

### Task 11: Extract ActivityTracker

**Files:**
- Create: `Fantastty/Models/ActivityTracker.swift`
- Modify: `Fantastty/Models/SessionManager.swift`

- [ ] **Step 1: Create ActivityTracker**

Move `ThumbnailRefreshController`, `activityTick()`, `flushActiveTimes()`, idle detection timer, mouse monitor, and `lastKeyInputAt` into a standalone class:

```swift
import Foundation
import AppKit
import Combine

final class ActivityTracker: ObservableObject {
    @Published private(set) var areThumbnailRefreshesSuspended = false

    // ... ThumbnailRefreshController (already self-contained)
    // ... idle detection, time accumulation, mouse monitor
}
```

- [ ] **Step 2: Wire SessionManager to compose ActivityTracker**

Replace inline activity-tracking code with `activityTracker` property.

- [ ] **Step 3: Run full test suite**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Fantastty/Models/ActivityTracker.swift Fantastty/Models/SessionManager.swift Fantastty.xcodeproj/project.pbxproj
git commit -m "refactor(activity): extract ActivityTracker from SessionManager"
```

---

## Chunk 10: Full Verification

### Task 12: Full Test Suite and Build Verification

- [ ] **Step 1: Run full test suite**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Debug build**

Run: `xcodebuild -project Fantastty.xcodeproj -scheme Fantastty -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Verify SessionManager line count reduction**

Run: `wc -l Fantastty/Models/SessionManager.swift`

Expected: Significantly less than current 1636 lines.

- [ ] **Step 4: Verify new module sizes are focused**

Run:
```bash
wc -l Fantastty/Models/TmuxControlMode/TmuxPaneController.swift
wc -l Fantastty/Models/TmuxControlMode/TmuxWindowController.swift
wc -l Fantastty/Models/TmuxSessionBridge.swift
wc -l Fantastty/Models/TerminalLifecycleRouter.swift
wc -l Fantastty/Models/LayoutPersistence.swift
wc -l Fantastty/Models/NotificationRouter.swift
wc -l Fantastty/Models/ActivityTracker.swift
```

Expected: Each under 200 lines.
