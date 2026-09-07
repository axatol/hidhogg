#!/bin/zsh

set -u
umask 077

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
EXPECTED_EXECUTABLE_SHA256='b64e598411c0d67fc44b08b09820e0b5fea12ce26052c44098e96bbd9b2c3022'
LLDB_PATH='/Volumes/Data/Applications/Xcode.app/Contents/Developer/usr/bin/lldb'
APP_BUNDLE=''

usage() {
    printf '%s\n' "usage: $SCRIPT_PATH --app-bundle <absolute-app-bundle>" >&2
}

while (( $# > 0 )); do
    case "$1" in
        --app-bundle)
            if (( $# < 2 )); then
                usage
                exit 64
            fi
            APP_BUNDLE="$2"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

if [[ -z "$APP_BUNDLE" || "$APP_BUNDLE" != /* ]]; then
    usage
    exit 64
fi

if [[ -L "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
    printf '%s\n' "refusing preflight: app bundle is missing, not a directory, or a symbolic link: $APP_BUNDLE" >&2
    exit 66
fi

APP_BUNDLE="${APP_BUNDLE:A}"
APP_EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/UlanziDeck"
BREAKPOINTS_FILE="${SCRIPT_DIR}/breakpoints.lldb"

if [[ -L "$APP_EXECUTABLE" || ! -f "$APP_EXECUTABLE" ]]; then
    printf '%s\n' "refusing preflight: expected executable is missing, not a regular file, or a symbolic link: $APP_EXECUTABLE" >&2
    exit 66
fi

if [[ ! -x "$LLDB_PATH" ]]; then
    printf '%s\n' "refusing preflight: LLDB is unavailable at the reviewed path: $LLDB_PATH" >&2
    exit 69
fi

if [[ ! -f "$BREAKPOINTS_FILE" || -L "$BREAKPOINTS_FILE" ]]; then
    printf '%s\n' "refusing preflight: breakpoint command file is unavailable: $BREAKPOINTS_FILE" >&2
    exit 66
fi

SHA_OUTPUT="$(/usr/bin/shasum --algorithm 256 -- "$APP_EXECUTABLE")" || {
    printf '%s\n' 'refusing preflight: unable to hash the executable' >&2
    exit 74
}
ACTUAL_SHA256="${SHA_OUTPUT%% *}"
ACTUAL_SHA256="${ACTUAL_SHA256:l}"

if [[ "$ACTUAL_SHA256" != "$EXPECTED_EXECUTABLE_SHA256" ]]; then
    printf '%s\n' 'refusing preflight: executable SHA-256 does not match the reviewed specimen' >&2
    printf '%s\n' "expected_sha256=$EXPECTED_EXECUTABLE_SHA256" >&2
    printf '%s\n' "actual_sha256=$ACTUAL_SHA256" >&2
    exit 65
fi

FILE_DESCRIPTION="$(/usr/bin/file "$APP_EXECUTABLE")" || {
    printf '%s\n' 'refusing preflight: unable to inspect executable format' >&2
    exit 74
}
if [[ "$FILE_DESCRIPTION" != *'Mach-O 64-bit executable arm64'* ]]; then
    printf '%s\n' "refusing preflight: expected an arm64 Mach-O executable: $FILE_DESCRIPTION" >&2
    exit 65
fi

printf '%s\n' 'static_preflight=running'
printf '%s\n' "application_sha256=$ACTUAL_SHA256"
printf '%s\n' 'application_architecture=arm64'
printf '%s\n' 'application_launch=prohibited'

"$LLDB_PATH" \
    --batch \
    --file "$APP_EXECUTABLE" \
    --source "$BREAKPOINTS_FILE" || {
        printf '%s\n' 'static_preflight=fail' >&2
        printf '%s\n' 'application_launch=not-attempted' >&2
        exit 65
    }

printf '%s\n' 'static_preflight=pass'
printf '%s\n' 'application_launch=not-attempted'
printf '%s\n' 'hid_access=not-attempted'
