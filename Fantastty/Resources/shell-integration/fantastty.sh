#!/bin/bash
# Fantastty Shell Integration
# Source this file in your shell rc file:
#   source ~/.fantastty/shell-integration/fantastty.sh

# fantastty-note - Add a note to the current Fantastty session
# Usage: fantastty-note "Your note content here"
#        fantastty-note Your note content here
#
# Notes are added to the session's timestamped log and are visible
# in the Notes panel. Works through SSH, tmux, and mosh.
fantastty-note() {
    local content="$*"

    # Don't send empty notes
    if [[ -z "$content" ]]; then
        echo "Usage: fantastty-note <note content>" >&2
        return 1
    fi

    local payload="fantastty:note;${content}"

    if [[ -n "$TMUX" ]]; then
        # tmux passthrough: wrap the escape sequence
        printf '\ePtmux;\e\e]9;%s\a\e\\' "$payload"
    elif [[ "$TERM" == screen* ]]; then
        # GNU screen passthrough
        printf '\eP\e]9;%s\a\e\\' "$payload"
    else
        # Direct output (works in Fantastty, over SSH, and in mosh)
        printf '\e]9;%s\a' "$payload"
    fi
}

# Alias for shorter typing
alias fn='fantastty-note'

# Export the function so it's available in subshells
export -f fantastty-note 2>/dev/null || true
