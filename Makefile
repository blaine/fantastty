.PHONY: xcframework clean

# Build the GhosttyKit xcframework from the vendored Ghostty source.
# Prerequisites: zig (check vendor/ghostty/build.zig.zon for required version)
xcframework:
	cd vendor/ghostty && zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native
	mkdir -p xcframework
	cp -R vendor/ghostty/macos/GhosttyKit.xcframework xcframework/

clean:
	rm -rf xcframework/GhosttyKit.xcframework
