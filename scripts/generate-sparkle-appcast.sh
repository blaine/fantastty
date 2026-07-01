#!/bin/bash
set -euo pipefail

: "${DMG_NAME:?DMG_NAME is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
: "${SPARKLE_EDDSA_PRIVATE_KEY:?SPARKLE_EDDSA_PRIVATE_KEY is required}"

release_base_url="${FANTASTTY_RELEASE_BASE_URL:-https://github.com/blaine/fantastty/releases/download}"
updates_dir="${SPARKLE_UPDATES_DIR:-build/sparkle-updates}"
appcast_output="${SPARKLE_APPCAST_OUTPUT:-appcast.xml}"
generate_appcast="${SPARKLE_GENERATE_APPCAST:-}"

if [ -z "$generate_appcast" ]; then
    generate_appcast="$(
        find build/DerivedData/SourcePackages/artifacts \
            -path "*/Sparkle/bin/generate_appcast" \
            -type f \
            -print \
            | head -1
    )"
fi

if [ -z "$generate_appcast" ] || [ ! -x "$generate_appcast" ]; then
    echo "ERROR: Sparkle generate_appcast tool not found" >&2
    exit 1
fi

if [ ! -f "$DMG_NAME" ]; then
    echo "ERROR: DMG not found: $DMG_NAME" >&2
    exit 1
fi

download_prefix="$release_base_url/$GITHUB_REF_NAME/"
expected_archive_url="$download_prefix$DMG_NAME"

rm -rf "$updates_dir"
mkdir -p "$updates_dir"
cp "$DMG_NAME" "$updates_dir/"

printf "%s" "$SPARKLE_EDDSA_PRIVATE_KEY" | "$generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "$download_prefix" \
    -o "$updates_dir/appcast.xml" \
    "$updates_dir"

cp "$updates_dir/appcast.xml" "$appcast_output"

if ! grep -Fq "$expected_archive_url" "$appcast_output"; then
    echo "ERROR: appcast does not reference expected archive URL: $expected_archive_url" >&2
    exit 1
fi
