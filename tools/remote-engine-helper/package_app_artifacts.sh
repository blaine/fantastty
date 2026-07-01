#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${FANTASTTY_REPO_ROOT:-$(git rev-parse --show-toplevel)}"
OUTPUT_DIR="${FANTASTTY_REMOTE_ENGINE_ARTIFACTS_OUTPUT:-$ROOT/Fantastty/Resources/RemoteEngine}"
DEFAULT_BUILD_TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
DEFAULT_BUILD_TMP="${DEFAULT_BUILD_TMP%/}"
mkdir -p "$DEFAULT_BUILD_TMP"
BUILD_ROOT="${FANTASTTY_REMOTE_ENGINE_BUILD_ROOT:-$(mktemp -d "$DEFAULT_BUILD_TMP/fantastty-remote-engine-artifacts.XXXXXX")}"
VERSION="${FANTASTTY_REMOTE_ENGINE_VERSION:-$(git -C "$ROOT" rev-parse --short HEAD)}"
HELPER_DIR="$ROOT/tools/remote-engine-helper/helper"
MANIFEST_ROWS="$BUILD_ROOT/manifest.tsv"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    exit 127
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi
  sha256sum "$1" | awk '{print $1}'
}

package_target() {
  local label="$1"
  local goos="$2"
  local goarch="$3"
  local zig_target="$4"
  local library_name="$5"
  local install_dir="$BUILD_ROOT/$label/ghostty-vt"
  local output_tmp="$OUTPUT_DIR/$label.tmp"
  local output_target="$OUTPUT_DIR/$label"
  local helper_rel="$label/fantastty-helper"
  local library_rel="$label/lib/$library_name"
  local helper_path="$output_tmp/fantastty-helper"
  local library_path="$output_tmp/lib/$library_name"
  local installed_library="$install_dir/lib/$library_name"
  local pkg_config_path="$install_dir/share/pkgconfig/libghostty-vt.pc"

  rm -rf "$install_dir" "$output_tmp"
  mkdir -p "$output_tmp/lib"

  printf '[remote-engine-artifacts] building libghostty-vt target=%s\n' "$zig_target"
  (
    cd "$ROOT/vendor/ghostty"
    zig build install -Demit-lib-vt=true -Dtarget="$zig_target" -Doptimize=ReleaseFast --prefix "$install_dir"
  )
  if [ ! -f "$installed_library" ]; then
    printf '[remote-engine-artifacts] missing %s after libghostty-vt build\n' "$installed_library" >&2
    find "$install_dir" -maxdepth 4 -print >&2 || true
    exit 1
  fi
  if [ ! -f "$pkg_config_path" ]; then
    printf '[remote-engine-artifacts] missing %s after libghostty-vt build\n' "$pkg_config_path" >&2
    find "$install_dir" -maxdepth 4 -print >&2 || true
    exit 1
  fi

  printf '[remote-engine-artifacts] building helper label=%s arch=%s\n' "$label" "$goarch"
  (
    cd "$HELPER_DIR"
    env \
      CGO_ENABLED=1 \
      GOOS="$goos" \
      GOARCH="$goarch" \
      CC="zig cc -target $zig_target" \
      PKG_CONFIG_LIBDIR="$install_dir/share/pkgconfig" \
      PKG_CONFIG_PATH= \
      go build -tags ghostty_vt -ldflags "-X main.version=$VERSION -X main.arch=$goarch" -o "$helper_path" .
  )

  cp "$installed_library" "$library_path"
  chmod 700 "$helper_path"
  chmod 600 "$library_path"

  rm -rf "$output_target"
  mv "$output_tmp" "$output_target"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" \
    "$goos" \
    "$goarch" \
    "$helper_rel" \
    "$(sha256_file "$OUTPUT_DIR/$helper_rel")" \
    "$library_rel" \
    "$(sha256_file "$OUTPUT_DIR/$library_rel")" \
    >>"$MANIFEST_ROWS"
}

write_manifest() {
  local manifest_tmp="$OUTPUT_DIR/manifest.json.tmp"
  python3 - "$VERSION" "$MANIFEST_ROWS" "$manifest_tmp" <<'PY'
import json
import sys
from pathlib import Path

version, rows_path, manifest_path = sys.argv[1:]
artifacts = {}
for line in Path(rows_path).read_text().splitlines():
    label, os_name, arch, helper, helper_sha256, library, library_sha256 = line.split("\t")
    artifacts[label] = {
        "os": os_name,
        "arch": arch,
        "helper": helper,
        "helper_sha256": helper_sha256,
        "library": library,
        "library_sha256": library_sha256,
    }

Path(manifest_path).write_text(json.dumps({
    "version": version,
    "artifacts": artifacts,
}, indent=2, sort_keys=True) + "\n")
PY
  mv "$manifest_tmp" "$OUTPUT_DIR/manifest.json"
}

require_cmd zig
require_cmd go
require_cmd awk
require_cmd python3

mkdir -p "$OUTPUT_DIR" "$BUILD_ROOT"
: >"$MANIFEST_ROWS"

package_target linux-amd64 linux amd64 x86_64-linux-gnu libghostty-vt.so.0.1.0
package_target linux-arm64 linux arm64 aarch64-linux-gnu libghostty-vt.so.0.1.0
package_target darwin-arm64 darwin arm64 aarch64-macos libghostty-vt.dylib
write_manifest

printf '[remote-engine-artifacts] wrote %s\n' "$OUTPUT_DIR/manifest.json"
