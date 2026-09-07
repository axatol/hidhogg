#!/bin/zsh

set -u

SCRIPT_PATH="${0:A}"
LEFT_TRIAL=''
RIGHT_TRIAL=''

usage() {
    printf '%s\n' "usage: $SCRIPT_PATH --left-trial <absolute-trial-directory> --right-trial <absolute-trial-directory>" >&2
}

while (( $# > 0 )); do
    case "$1" in
        --left-trial)
            if (( $# < 2 )); then
                usage
                exit 64
            fi
            LEFT_TRIAL="$2"
            shift 2
            ;;
        --right-trial)
            if (( $# < 2 )); then
                usage
                exit 64
            fi
            RIGHT_TRIAL="$2"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

validate_trial() {
    local trial_dir="$1"
    if [[ -z "$trial_dir" || "$trial_dir" != /* || -L "$trial_dir" || ! -d "$trial_dir" ]]; then
        return 1
    fi
    trial_dir="${trial_dir:A}"
    local workspace_root="${trial_dir:h}"
    [[ "$workspace_root" == /private/tmp/ulanzi-lldb.* ]] || return 1
    [[ -f "${workspace_root}/.hidhogg-ulanzi-lldb-root" && ! -L "${workspace_root}/.hidhogg-ulanzi-lldb-root" ]] || return 1
    [[ -f "${trial_dir}/captures.sha256" && ! -L "${trial_dir}/captures.sha256" ]] || return 1
}

if ! validate_trial "$LEFT_TRIAL" || ! validate_trial "$RIGHT_TRIAL"; then
    printf '%s\n' 'refusing comparison: both arguments must be prepared trial directories with capture manifests' >&2
    exit 65
fi

LEFT_TRIAL="${LEFT_TRIAL:A}"
RIGHT_TRIAL="${RIGHT_TRIAL:A}"
LEFT_MANIFEST="${LEFT_TRIAL}/captures.sha256"
RIGHT_MANIFEST="${RIGHT_TRIAL}/captures.sha256"

/usr/bin/diff --unified "$LEFT_MANIFEST" "$RIGHT_MANIFEST"
diff_status=$?

if (( diff_status == 0 )); then
    printf '%s\n' 'comparison_status=identical'
    exit 0
fi

if (( diff_status == 1 )); then
    printf '%s\n' 'comparison_status=different'
    exit 0
fi

printf '%s\n' 'comparison_status=error' >&2
exit 74
