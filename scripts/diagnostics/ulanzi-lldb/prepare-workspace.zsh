#!/bin/zsh

set -u
umask 077

EXPECTED_EXECUTABLE_SHA256='b64e598411c0d67fc44b08b09820e0b5fea12ce26052c44098e96bbd9b2c3022'
WORKSPACE_ROOT="$(/usr/bin/mktemp -d /private/tmp/ulanzi-lldb.XXXXXX)" || {
    printf '%s\n' 'unable to create a unique temporary LLDB workspace' >&2
    exit 73
}

/bin/chmod 700 "$WORKSPACE_ROOT" || exit 73
: > "${WORKSPACE_ROOT}/.hidhogg-ulanzi-lldb-root" || exit 73

cat > "${WORKSPACE_ROOT}/README.txt" <<EOF
Temporary bounded Ulanzi Studio LLDB evidence workspace.

Raw captures belong only in this temporary directory and must not be committed by default.
Do not record device serials, account identifiers, usernames, unrelated paths, or existing profile data.
Reviewed executable SHA-256: ${EXPECTED_EXECUTABLE_SHA256}
EOF

for trial_id in T01-connect-baseline T02-connect-repeat; do
    trial_dir="${WORKSPACE_ROOT}/${trial_id}"
    /bin/mkdir "$trial_dir" || exit 73
    cat > "${trial_dir}/metadata.txt" <<EOF
trial_id=${trial_id}
absolute_date_time=not-recorded
application_sha256=${EXPECTED_EXECUTABLE_SHA256}
device_model=D200X
firmware_version=unknown
initial_device_state=not-recorded
single_variable_changed=none
expected_command=connection-baseline
result_status=not-run
uncertainties=not-recorded
EOF
done

printf '%s\n' "workspace_root=$WORKSPACE_ROOT"
printf '%s\n' "trial_1=${WORKSPACE_ROOT}/T01-connect-baseline"
printf '%s\n' "trial_2=${WORKSPACE_ROOT}/T02-connect-repeat"
printf '%s\n' 'application_launch=not-attempted'
printf '%s\n' 'hid_access=not-attempted'
