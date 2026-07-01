# Sparkle GitHub Releases Auto-Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Sparkle 2 auto-updates to Fantastty using GitHub Releases for both update archives and the appcast feed.

**Architecture:** Fantastty will link Sparkle through XcodeGen/SPM, configure the updater through `Info.plist`, and expose the standard Sparkle check-for-updates menu action through the existing SwiftUI command structure. The release workflow will continue to build/sign/notarize the DMG on tag pushes, then generate a Sparkle appcast and upload it with the DMG to the same GitHub Release.

**Tech Stack:** SwiftUI, Sparkle 2.9.3, XcodeGen, GitHub Actions, GitHub Releases, Python unittest for repo release-contract tests.

---

### Task 1: Add release-contract tests

**Files:**
- Create: `tools/sparkle_release_config_test.py`
- Test: `tools/sparkle_release_config_test.py`

- [ ] **Step 1: Write failing tests for the Sparkle release contract**

Create `tools/sparkle_release_config_test.py` with tests that parse `Fantastty/Info.plist` via `plistlib`, verify `project.yml` declares Sparkle as an SPM package dependency, verify `Fantastty.xcodeproj/project.pbxproj` contains the generated Sparkle product dependency, verify `.github/workflows/build-and-release.yml` references the `SPARKLE_EDDSA_PRIVATE_KEY` secret and uploads `appcast.xml`, and verify `doc/GITHUB_ACTIONS_SETUP.md` documents the new secret.

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tools.sparkle_release_config_test`
Expected: FAIL because Sparkle keys, project dependency, and workflow appcast generation are not present yet.

### Task 2: Add Sparkle app integration

**Files:**
- Modify: `project.yml`
- Modify: `Fantastty/Info.plist`
- Modify: `Fantastty/App/MickeyTermApp.swift`
- Modify: `Fantastty/App/AppCommands.swift`
- Regenerate: `Fantastty.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add Sparkle to XcodeGen**

Add top-level `packages: Sparkle: url: https://github.com/sparkle-project/Sparkle; from: 2.9.3` and add target dependency `package: Sparkle, product: Sparkle`.

- [ ] **Step 2: Add Sparkle plist keys**

Add `SUFeedURL` set to `https://github.com/blaine/fantastty/releases/latest/download/appcast.xml` and `SUPublicEDKey` set to the generated public key.

- [ ] **Step 3: Wire SwiftUI updater UI**

Create a retained `SPUStandardUpdaterController` in `FantasttyApp`, pass `updaterController.updater` into `AppCommands`, and add a `CheckForUpdatesView` command group after `.appInfo`.

- [ ] **Step 4: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: project generation succeeds and the pbxproj includes Sparkle package references.

- [ ] **Step 5: Run tests to verify app integration**

Run: `python3 -m unittest tools.sparkle_release_config_test`
Expected: workflow assertions still fail until Task 3, while plist/project assertions pass.

### Task 3: Add release appcast generation and docs

**Files:**
- Modify: `.github/workflows/build-and-release.yml`
- Modify: `doc/GITHUB_ACTIONS_SETUP.md`
- Modify: `README.md`

- [ ] **Step 1: Update workflow after notarization**

For tag refs, locate Sparkle's `generate_appcast` tool from resolved SPM artifacts, generate `appcast.xml` from a temporary updates directory containing the notarized DMG, sign with `SPARKLE_EDDSA_PRIVATE_KEY` via stdin, rewrite enclosure URLs to the versioned GitHub Release asset URL if required, and upload both DMG and `appcast.xml` to the GitHub Release.

- [ ] **Step 2: Document secret and release behavior**

Add `SPARKLE_EDDSA_PRIVATE_KEY` to `doc/GITHUB_ACTIONS_SETUP.md`, explain GitHub Releases appcast distribution, and add the update feed to `README.md` release docs.

- [ ] **Step 3: Run focused tests**

Run: `python3 -m unittest tools.sparkle_release_config_test tools.remote-engine-helper.package_app_artifacts_test`
Expected: PASS.

### Task 4: Verify build, commit, and set secret

**Files:**
- GitHub Actions repository secret: `SPARKLE_EDDSA_PRIVATE_KEY`

- [ ] **Step 1: Resolve packages and build/test locally**

Run: `xcodebuild -resolvePackageDependencies -scheme Fantastty` and `xcodebuild -scheme Fantastty -destination 'platform=macOS' test`.
Expected: PASS.

- [ ] **Step 2: Store private key in GitHub Actions**

Run: `gh secret set SPARKLE_EDDSA_PRIVATE_KEY --repo blaine/fantastty --body-file <private-key-file>`.
Expected: secret exists by name in `gh secret list`.

- [ ] **Step 3: Commit changes**

Run: `git add` with explicit paths, then commit with a detailed message.
Expected: clean branch with one implementation commit.
