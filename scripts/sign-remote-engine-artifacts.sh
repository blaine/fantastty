#!/bin/bash
set -euo pipefail

: "${APP_PATH:?APP_PATH is required}"
: "${DEVELOPER_ID_NAME:?DEVELOPER_ID_NAME is required}"

remote_engine_dir="$APP_PATH/Contents/Resources/RemoteEngine/darwin-arm64"
helper_path="$remote_engine_dir/fantastty-helper"
library_path="$remote_engine_dir/lib/libghostty-vt.dylib"

for path in "$helper_path" "$library_path"; do
    if [ ! -f "$path" ]; then
        echo "ERROR: RemoteEngine macOS artifact not found: $path" >&2
        exit 1
    fi

    codesign --force \
        --sign "$DEVELOPER_ID_NAME" \
        --timestamp \
        --options runtime \
        "$path"
done

codesign --force \
    --sign "$DEVELOPER_ID_NAME" \
    --timestamp \
    --options runtime \
    --entitlements Fantastty/Fantastty.entitlements \
    "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH"
