#!/bin/zsh

set -u
umask 077

SCRIPT_PATH="${0:A}"
TRIAL_DIR=''

usage() {
    printf '%s\n' "usage: $SCRIPT_PATH --trial-dir <absolute-trial-directory>" >&2
}

while (( $# > 0 )); do
    case "$1" in
        --trial-dir)
            if (( $# < 2 )); then
                usage
                exit 64
            fi
            TRIAL_DIR="$2"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

if [[ -z "$TRIAL_DIR" || "$TRIAL_DIR" != /* || -L "$TRIAL_DIR" || ! -d "$TRIAL_DIR" ]]; then
    usage
    exit 64
fi

TRIAL_DIR="${TRIAL_DIR:A}"
WORKSPACE_ROOT="${TRIAL_DIR:h}"
if [[ "$WORKSPACE_ROOT" != /private/tmp/ulanzi-lldb.* || ! -f "${WORKSPACE_ROOT}/.hidhogg-ulanzi-lldb-root" || -L "${WORKSPACE_ROOT}/.hidhogg-ulanzi-lldb-root" ]]; then
    printf '%s\n' 'refusing hash: trial directory is not a direct child of a prepared LLDB workspace' >&2
    exit 65
fi

CAPTURE_FILES=("${TRIAL_DIR}"/*.bin(N.))
if (( ${#CAPTURE_FILES} == 0 )); then
    printf '%s\n' "refusing hash: no regular .bin captures exist in $TRIAL_DIR" >&2
    exit 66
fi

MANIFEST_PATH="${TRIAL_DIR}/captures.sha256"
TEMP_MANIFEST="$(/usr/bin/mktemp "${TRIAL_DIR}/.captures.sha256.XXXXXX")" || exit 73

cleanup_temp_manifest() {
    if [[ -n "${TEMP_MANIFEST:-}" && -f "$TEMP_MANIFEST" ]]; then
        /bin/rm -- "$TEMP_MANIFEST"
    fi
}
trap cleanup_temp_manifest EXIT

for capture_file in "${CAPTURE_FILES[@]}"; do
    capture_name="${capture_file:t}"
    if [[ "$capture_name" == *[^A-Za-z0-9._-]* ]]; then
        printf '%s\n' "refusing hash: capture filename is outside the safe naming set: $capture_name" >&2
        exit 65
    fi
    sha_output="$(/usr/bin/shasum --algorithm 256 -- "$capture_file")" || exit 74
    capture_sha256="${sha_output%% *}"
    capture_bytes="$(/usr/bin/stat -f '%z' "$capture_file")" || exit 74
    printf '%s  %s  %s\n' "${capture_sha256:l}" "$capture_bytes" "$capture_name" >> "$TEMP_MANIFEST" || exit 74
done

/bin/mv "$TEMP_MANIFEST" "$MANIFEST_PATH" || exit 73
TEMP_MANIFEST=''
trap - EXIT

printf '%s\n' "capture_count=${#CAPTURE_FILES}"
printf '%s\n' "manifest=$MANIFEST_PATH"
