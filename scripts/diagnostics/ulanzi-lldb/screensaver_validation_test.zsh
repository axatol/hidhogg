#!/bin/zsh

set -u
umask 077

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
PYTHON_PATH="$(command -v python3 2>/dev/null)"

if [[ -z "$PYTHON_PATH" || ! -x "$PYTHON_PATH" ]]; then
    printf '%s\n' 'screensaver validation requires python3' >&2
    exit 69
fi

if (( $# != 0 )); then
    printf '%s\n' "usage: $SCRIPT_PATH" >&2
    exit 64
fi

exec "$PYTHON_PATH" "$SCRIPT_DIR/screensaver_capture_test.py"
