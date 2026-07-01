# Release Engineering

This is the release checklist for Fantastty. Follow it exactly; the expensive failure mode is tagging or shipping from the wrong branch.

## Release Model

- `main` is the branch users should be able to trust.
- Versioned releases are Git tags named `vX.Y.Z`.
- The `Build and Release` GitHub Actions workflow creates the GitHub Release only for pushed `v*` tags.
- Tag builds derive the app marketing version from the tag name. Do not rely on `project.yml`'s default `MARKETING_VERSION` to identify a release.
- `project.yml` is the source of truth for XcodeGen-managed build phases, including remote-engine artifact packaging.

## Before Merging to `main`

1. Fetch the current remote state:

   ```sh
   git fetch --prune --tags origin
   ```

2. Confirm the branch contains exactly what you intend to ship:

   ```sh
   git log --oneline origin/main..HEAD
   git log --oneline HEAD..origin/main
   git describe --tags --abbrev=12 --always --dirty
   ```

   Stop if the branch contains unrelated work, misses expected release-stack commits, or `origin/main` has commits that are not in `HEAD`.

3. Run the release gate locally:

   ```sh
   xcodebuild -scheme Fantastty -destination 'platform=macOS' test
   go test ./...
   python3 -m unittest tools.remote-engine-helper.package_app_artifacts_test
   git diff --check
   ```

   Run the Go command from `tools/remote-engine-helper/helper`.

4. If a test fails, identify the root cause before merging. Do not dismiss a red full suite because focused tests passed.

## Merge to `main`

Use a fast-forward merge when possible so `main` points at the exact tested commit:

```sh
git switch main
git pull --ff-only origin main
git merge --ff-only <release-branch>
```

If fast-forward is not possible, stop and inspect the branch graph before creating a merge commit.

After the merge, rerun the release gate on `main`.

## Tagging a Release

1. Pick the next patch version unless the shipped behavior warrants a minor or major bump.
2. Verify the tag does not exist locally or remotely:

   ```sh
   git tag --list 'vX.Y.Z'
   git ls-remote --tags origin 'vX.Y.Z'
   ```

3. Create an annotated tag on `main`:

   ```sh
   git tag -a vX.Y.Z -m "Release vX.Y.Z"
   ```

4. Push `main` and then the tag:

   ```sh
   git push origin main
   git push origin vX.Y.Z
   ```

Never move or force-push a release tag. If a tag build fails after publication, fix forward with the next patch version.

## Verify GitHub Actions

After pushing the tag, verify the live workflow. Do not infer success from local tests.

```sh
gh run list --workflow 'Build and Release' --branch vX.Y.Z --limit 5
gh run watch <run-id> --exit-status
```

The tag run must complete these release-specific steps:

- Select Xcode 26.2 through `maxim-lobanov/setup-xcode@v1`.
- Build GhosttyKit or restore the cache keyed by Ghostty sources and patches.
- Build with `FANTASTTY_PACKAGE_REMOTE_ENGINE_ARTIFACTS=1`.
- Pass `make remote-engine-verify-app-artifacts` for the app bundle.
- Sign the bundled macOS remote-engine artifacts before app signature verification.
- Sign, notarize, and staple the DMG.
- Create a GitHub Release with `Fantastty-vX.Y.Z.dmg` attached.

Then verify the published release:

```sh
gh release view vX.Y.Z --json name,tagName,isLatest,assets
gh release download vX.Y.Z --pattern 'Fantastty-vX.Y.Z.dmg' --dir /tmp/fantastty-release-check
```

## Failure Rules

- If `main` is behind a published release tag, merge the release stack back to `main` before cutting another tag.
- If a tag points at a failed build, do not retag it. Cut the next patch version.
- If GitHub Actions fails, inspect the live run logs before changing local release scripts.
- If notarization fails, use the Apple notary log emitted by `scripts/notarize-dmg.sh`; do not debug from stapler output alone.
- If local Xcode tests fail on Ghostty ABI symbols, check whether the checked-in `xcframework/GhosttyKit.xcframework` is stale before blaming the release workflow. The workflow rebuilds the xcframework when the cache key changes.
- If remote-engine artifacts are missing from the app bundle, check `project.yml` and the generated phase order. Do not patch only `Fantastty.xcodeproj`.

## Current Known Release Pitfalls

- `project.yml` currently has `MARKETING_VERSION: "0.1.0"`; tag builds override it, but main snapshot builds use that default.
- Main can drift behind release branches if a release is cut from a side branch. Always inspect `origin/main..HEAD` and tag containment before releasing.
- The remote-engine packaging phase is opt-in through `FANTASTTY_PACKAGE_REMOTE_ENGINE_ARTIFACTS=1`; release builds must set it.
