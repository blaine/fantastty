#!/bin/bash
set -euo pipefail

: "${DMG_NAME:?DMG_NAME is required}"
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_ID_PASSWORD:?APPLE_ID_PASSWORD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

submit_log="$(mktemp)"
trap 'rm -f "$submit_log"' EXIT

set +e
xcrun notarytool submit "$DMG_NAME" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_ID_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait 2>&1 | tee "$submit_log"
submit_status="${PIPESTATUS[0]}"
set -e

submission_id="$(awk '/^[[:space:]]*id: / { id = $2 } END { print id }' "$submit_log")"
notary_status="$(awk '/^[[:space:]]*status: / { print $2; exit }' "$submit_log")"

if [ "$submit_status" -ne 0 ] || [ "$notary_status" != "Accepted" ]; then
    if [ -n "$submission_id" ]; then
        echo "::group::Apple notary log"
        xcrun notarytool log "$submission_id" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_ID_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" || true
        echo "::endgroup::"
    fi
    exit 1
fi

xcrun stapler staple "$DMG_NAME"
