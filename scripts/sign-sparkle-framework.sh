#!/bin/bash
set -euo pipefail

: "${APP_PATH:?APP_PATH is required}"
: "${DEVELOPER_ID_NAME:?DEVELOPER_ID_NAME is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

sparkle_framework="$APP_PATH/Contents/Frameworks/Sparkle.framework"
sparkle_version_dir="$sparkle_framework/Versions/B"

sparkle_code_paths=(
    "$sparkle_version_dir/XPCServices/Downloader.xpc"
    "$sparkle_version_dir/XPCServices/Installer.xpc"
    "$sparkle_version_dir/Updater.app"
    "$sparkle_version_dir/Autoupdate"
    "$sparkle_framework"
)

for path in "${sparkle_code_paths[@]}"; do
    if [ ! -e "$path" ]; then
        echo "ERROR: Sparkle code not found: $path" >&2
        exit 1
    fi

    codesign --force \
        --sign "$DEVELOPER_ID_NAME" \
        --timestamp \
        --options runtime \
        --preserve-metadata=identifier \
        "$path"

    codesign --verify --strict "$path"

    sign_info="$(codesign -dvv "$path" 2>&1)"
    if ! grep -Fq "TeamIdentifier=$APPLE_TEAM_ID" <<<"$sign_info"; then
        echo "ERROR: Sparkle code was not signed by team $APPLE_TEAM_ID: $path" >&2
        exit 1
    fi

    if ! grep -Fq "Timestamp=" <<<"$sign_info"; then
        echo "ERROR: Sparkle code is missing a secure timestamp: $path" >&2
        exit 1
    fi
done
