#!/bin/zsh

set -u
umask 077

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
PYTHON_PATH="$(command -v python3 2>/dev/null)"

usage() {
    printf '%s\n' "usage: $SCRIPT_PATH --trial-dir <absolute-SS-U0..SS-U3-directory> [--specimen A|B]" >&2
}

if [[ -z "$PYTHON_PATH" || ! -x "$PYTHON_PATH" ]]; then
    printf '%s\n' 'refusing screensaver preparation: python3 is unavailable' >&2
    exit 69
fi

if (( $# == 0 )); then
    usage
    exit 64
fi

exec "$PYTHON_PATH" "$SCRIPT_DIR/screensaver_capture.py" prepare-capture "$@"
