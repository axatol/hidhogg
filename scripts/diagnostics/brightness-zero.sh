#!/bin/zsh

set -u

SCRIPT_DIR="${0:A:h}"
. "${SCRIPT_DIR}/common.zsh"

diagnostic_run_brightness_zero "$@"
exit $?
