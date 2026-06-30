.PHONY: xcframework clean

# Build the GhosttyKit xcframework from the vendored Ghostty source.
# Prerequisites: zig (check vendor/ghostty/build.zig.zon for required version)
xcframework:
	cd vendor/ghostty && git apply ../../patches/ghostty-inject-output.patch 2>/dev/null || true
	cd vendor/ghostty && git apply ../../patches/ghostty-tmux-child-write.patch 2>/dev/null || true
	cd vendor/ghostty && zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native
	mkdir -p xcframework
	cp -R vendor/ghostty/macos/GhosttyKit.xcframework xcframework/
	cd vendor/ghostty && git checkout -- . 2>/dev/null || true

clean:
	rm -rf xcframework/GhosttyKit.xcframework

.PHONY: remote-engine-app-artifacts remote-engine-verify-app-artifacts

remote-engine-app-artifacts:
	tools/remote-engine-helper/package_app_artifacts.sh

remote-engine-verify-app-artifacts:
	@test -n "$$APP" || (echo "usage: APP=/path/to/Fantastty.app make remote-engine-verify-app-artifacts" >&2; exit 2)
	tools/remote-engine-helper/verify_app_artifacts.py "$$APP"
