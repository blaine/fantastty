# Attached Tmux Restore Contract Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enforce an attached-only restore/runtime contract where terminal tabs are always derived from live tmux windows and browser tabs restore independently.

**Architecture:** Make `SessionManager` treat tmux as the sole authority for terminal tab shape/order/selection and persistence as authority only for workspace metadata plus browser tabs. Remove managed-runtime branches for local terminal workspaces and route all terminal lifecycle actions through tmux control mode.

**Tech Stack:** Swift, XCTest, tmux 3.6a control mode (`tmux -CC`), existing `TmuxControlClient` + `SessionManager` + persistence models.

---

### Task 1: Lock Contract Tests Before Runtime Changes

**Files:**
- Modify: `FantasttyTests/PersistenceTests.swift`
- Modify: `FantasttyTests/WindowManagementTests.swift`

**Step 1: Add failing restore-order test**

Add a test asserting restored terminal tab order follows tmux window order, not persisted terminal-tab order.

**Step 2: Run only the new test to verify it fails**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/PersistenceTests/<NEW_TEST_NAME> CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with order mismatch.

**Step 3: Add failing active-window selection test**

Add a test asserting selected terminal tab after attach follows tmux active window.

**Step 4: Run only the new test to verify it fails**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/PersistenceTests/<NEW_ACTIVE_TEST_NAME> CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with selected tab mismatch.

**Step 5: Add failing browser-survives-disconnect test**

Add a test asserting browser tabs restore and remain available when tmux attach fails.

**Step 6: Run only the new test to verify it fails**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/PersistenceTests/<NEW_BROWSER_TEST_NAME> CODE_SIGNING_ALLOWED=NO`

Expected: FAIL because restore path drops or misstates browser availability.

**Step 7: Commit test scaffolding**

```bash
git add FantasttyTests/PersistenceTests.swift FantasttyTests/WindowManagementTests.swift
git commit -m "test(restore): codify attached tmux restore contract invariants"
```

### Task 2: Normalize Restore to Tmux-Authority Terminal Reconstruction

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`
- Modify: `Fantastty/Models/Session.swift`

**Step 1: Remove persisted terminal tab replay from attached restore**

Ensure attached restore path initializes only browser tabs from persistence and waits for tmux windows to create terminal tabs.

**Step 2: Run targeted failing contract tests**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/PersistenceTests/testRestoreTmuxSessionsRestoresBrowserTabsFromLayout -only-testing:FantasttyTests/PersistenceTests/<NEW_TEST_NAME> CODE_SIGNING_ALLOWED=NO`

Expected: at least one failure remains.

**Step 3: Apply minimal mapping logic for tmux window order**

In `controlClient(_:didAddWindow:)` and related window reconciliation, ensure terminal tabs are inserted/ordered by tmux windows, never by stale persisted terminal entries.

**Step 4: Run targeted tests again**

Run same command as Step 2 plus `<NEW_ACTIVE_TEST_NAME>`.

Expected: PASS for order and selection tests.

**Step 5: Commit restore normalization**

```bash
git add Fantastty/Models/SessionManager.swift Fantastty/Models/Session.swift
git commit -m "feat(restore): derive attached terminal tabs strictly from tmux state"
```

### Task 3: Make Create Shell Deterministic (Canonical Session, One Initial Window)

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`
- Modify: `FantasttyTests/WindowManagementTests.swift`
- Modify: `FantasttyTests/PersistenceTests.swift`

**Step 1: Add failing Create Shell determinism test**

Add test asserting `createShell(for:)` for placeholder workspace always uses canonical session name and yields exactly one initial tmux-backed terminal window/tab.

**Step 2: Run new test to verify failure**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/WindowManagementTests/<NEW_CREATE_SHELL_TEST_NAME> CODE_SIGNING_ALLOWED=NO`

Expected: FAIL.

**Step 3: Implement minimal create-shell flow tightening**

Ensure create-shell path:
- sets launch mode `.create`
- reconnects via control mode
- does not replay historical terminal tabs
- materializes terminal tabs from tmux window list/events only.

**Step 4: Run create-shell tests**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/WindowManagementTests/testCreateShellForManagedPlaceholderMigratesToAttachedControlMode -only-testing:FantasttyTests/WindowManagementTests/testCreateShellForAttachedLocalPlaceholderMigratesToAttachedControlMode -only-testing:FantasttyTests/WindowManagementTests/<NEW_CREATE_SHELL_TEST_NAME> CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit create-shell fix**

```bash
git add Fantastty/Models/SessionManager.swift FantasttyTests/WindowManagementTests.swift FantasttyTests/PersistenceTests.swift
git commit -m "fix(shell): make placeholder create-shell deterministic and tmux-authoritative"
```

### Task 4: Enforce Terminal Lifecycle Through Tmux Only

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`
- Modify: `FantasttyTests/WindowManagementTests.swift`

**Step 1: Add failing new-tab contract test (if missing)**

Ensure attached `createTab` test asserts no local terminal tab creation before tmux reports new window.

**Step 2: Run new-tab test**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/WindowManagementTests/testCreateTabOnAttachedSessionRequestsTmuxWindowInsteadOfCreatingLocalTab CODE_SIGNING_ALLOWED=NO`

Expected: FAIL if local path still leaks.

**Step 3: Add/extend failing close-tab contract test**

Ensure close terminal tab always dispatches `kill-window` and does not silently local-close in attached mode.

**Step 4: Run close-tab test**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/WindowManagementTests/testCloseTabOnAttachedSessionSendsKillWindow CODE_SIGNING_ALLOWED=NO`

Expected: FAIL if bypass path exists.

**Step 5: Implement minimal action routing cleanup**

Route attached new/close tab actions through tmux commands only.

**Step 6: Re-run both tests**

Run both tests from Steps 2 and 4 in one command.

Expected: PASS.

**Step 7: Commit lifecycle routing**

```bash
git add Fantastty/Models/SessionManager.swift FantasttyTests/WindowManagementTests.swift
git commit -m "feat(attached): route terminal tab lifecycle exclusively through tmux window commands"
```

### Task 5: Remove Remaining Managed Runtime Branches for Local Terminal Workspaces

**Files:**
- Modify: `Fantastty/Models/SessionManager.swift`
- Modify: `Fantastty/Models/LayoutSnapshot.swift`
- Modify: `FantasttyTests/PersistenceTests.swift`
- Modify: `FantasttyTests/WindowManagementTests.swift`

**Step 1: Add failing test for managed-path inaccessibility**

Add test asserting newly created local workspace never enters managed runtime mode.

**Step 2: Run new test**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/WindowManagementTests/testCreateSessionCreatesAttachedControlModeWorkspaceForLocalSessions CODE_SIGNING_ALLOWED=NO`

Expected: FAIL if any managed path still possible.

**Step 3: Remove dead managed local runtime branches**

Keep migration decode support only; eliminate runtime creation/restore branches that instantiate managed local terminal behavior.

**Step 4: Run targeted persistence tests**

Run: `xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/PersistenceTests/testRestoreTmuxSessionsMigratesLegacyManagedLayoutBeforeRestoring -only-testing:FantasttyTests/PersistenceTests/testMigratePersistedWorkspacesToAttachedOnlyBacksUpAndRewritesLegacyManagedLayout CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit runtime simplification**

```bash
git add Fantastty/Models/SessionManager.swift Fantastty/Models/LayoutSnapshot.swift FantasttyTests/PersistenceTests.swift FantasttyTests/WindowManagementTests.swift
git commit -m "refactor(runtime): remove managed local terminal runtime and keep attached-only contract"
```

### Task 6: Full Verification for Restore + Connection Lifecycle

**Files:**
- Modify (if needed): `FantasttyTests/TmuxControlClientTests.swift`
- Modify (if needed): `FantasttyTests/PersistenceTests.swift`
- Modify (if needed): `FantasttyTests/WindowManagementTests.swift`

**Step 1: Run full targeted suite**

Run:
`xcodebuild test -project Fantastty.xcodeproj -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/TmuxControlClientTests -only-testing:FantasttyTests/TmuxConnectFSMTests -only-testing:FantasttyTests/TmuxControlTransportTests -only-testing:FantasttyTests/PersistenceTests -only-testing:FantasttyTests/WindowManagementTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 2: If any failure appears, write one failing regression test per failure first**

Add test(s), then rerun just those tests to confirm RED.

**Step 3: Implement minimal fixes and rerun full targeted suite**

Expected: PASS.

**Step 4: Produce debug build**

Run: `xcodebuild -project Fantastty.xcodeproj -scheme Fantastty -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `** BUILD SUCCEEDED **`.

**Step 5: Commit verification-complete state**

```bash
git add Fantastty/Models/SessionManager.swift Fantastty/Models/LayoutSnapshot.swift FantasttyTests/TmuxControlClientTests.swift FantasttyTests/PersistenceTests.swift FantasttyTests/WindowManagementTests.swift
git commit -m "fix(restore): enforce attached tmux restore contract and lifecycle reliability"
```
