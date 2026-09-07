#!/bin/zsh

set -u
umask 077

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
TMP_ROOT="$(mktemp -d /tmp/hidhoggdiag-archive-validation.XXXXXX)" || exit 1
trap 'rm -rf -- "$TMP_ROOT"' EXIT

JQ_PATH="$(command -v jq 2>/dev/null)"
PYTHON_PATH="$(command -v python3 2>/dev/null)"
WC_PATH="$(command -v wc 2>/dev/null)"
RUBY_PATH="$(command -v ruby 2>/dev/null)"
UNAME_PATH="$(command -v uname 2>/dev/null)"
if [[ -z "$JQ_PATH" || -z "$PYTHON_PATH" || -z "$WC_PATH" ]]; then
    print -u2 -- 'jq, python3, and wc are required for archive validation regression'
    exit 1
fi

mkdir -p "$TMP_ROOT/jq-bin" "$TMP_ROOT/python-bin"
ln -s "$JQ_PATH" "$TMP_ROOT/jq-bin/jq"
ln -s "$PYTHON_PATH" "$TMP_ROOT/python-bin/python3"
ln -s "$WC_PATH" "$TMP_ROOT/jq-bin/wc"
ln -s "$WC_PATH" "$TMP_ROOT/python-bin/wc"
if [[ -n "$RUBY_PATH" ]]; then
    mkdir -p "$TMP_ROOT/ruby-bin"
    ln -s "$RUBY_PATH" "$TMP_ROOT/ruby-bin/ruby"
    ln -s "$WC_PATH" "$TMP_ROOT/ruby-bin/wc"
    ln -s "$UNAME_PATH" "$TMP_ROOT/ruby-bin/uname"
fi

write_input() {
    local file_path="$1"
    print -r -- '{"event":"input","mode":"brightness-zero","stage":"captured-input","status":"pass","sequence":7,"phase":"baseline","decoded":true,"malformed":false,"marker":"button","action":"pressed","classification":"expected","boundary":7,"wire_index":0}' >> "$file_path"
}

write_valid_archive() {
    local file_path="$1"
    {
        print -r -- '{"event":"diagnostic","mode":"brightness-zero","status":"pass","stage":"normal-startup","boundary":0}'
        print -r -- '{"event":"diagnostic","mode":"brightness-zero","status":"pass","stage":"brightness-zero-baseline","boundary":1}'
        print -r -- '{"event":"diagnostic","mode":"brightness-zero","status":"pass","stage":"brightness-zero-write","boundary":2}'
        print -r -- '{"event":"diagnostic","mode":"brightness-zero","status":"pass","stage":"brightness-zero-attestation","brightness_attestation":"BRIGHTNESS_100_OBSERVED","boundary":3}'
        print -r -- '{"event":"diagnostic","mode":"brightness-zero","status":"pass","stage":"brightness-restore","boundary":4}'
        print -r -- '{"event":"diagnostic","mode":"brightness-zero","status":"pass","stage":"brightness-zero-matrix","boundary":5}'
        print -r -- '{"event":"diagnostic","mode":"brightness-zero","status":"pass","stage":"brightness-zero-recovery","boundary":6}'
    } > "$file_path"
    write_input "$file_path"
}

write_pre_cue_record() {
    local schema="$1"
    local sequence="$2"
    local elapsed="$3"
    case "$schema" in
        decoded-known)
            print -r -- "{\"event\":\"input\",\"mode\":\"keepalive-prevention\",\"stage\":\"keepalive-prevention-input\",\"status\":\"pass\",\"input_class\":\"square\",\"wire_index\":7,\"marker\":\"button\",\"action\":\"pressed\",\"detail\":\"pre-cue observation retained outside endpoint classification\",\"sequence\":$sequence,\"decoded\":true,\"malformed\":false,\"classification\":\"pre-cue\",\"boundary\":$sequence,\"input_elapsed_ns\":$elapsed}"
            ;;
        decoded-unknown)
            print -r -- "{\"event\":\"input\",\"mode\":\"keepalive-prevention\",\"stage\":\"keepalive-prevention-input\",\"status\":\"pass\",\"wire_index\":200,\"marker\":\"unknown\",\"action\":\"unknown\",\"detail\":\"pre-cue observation retained outside endpoint classification\",\"sequence\":$sequence,\"decoded\":true,\"malformed\":false,\"classification\":\"pre-cue\",\"boundary\":$sequence,\"input_elapsed_ns\":$elapsed}"
            ;;
        nondecoded)
            print -r -- "{\"event\":\"input\",\"mode\":\"keepalive-prevention\",\"stage\":\"keepalive-prevention-input\",\"status\":\"pass\",\"marker\":\"unknown\",\"action\":\"unknown\",\"detail\":\"pre-cue observation retained outside endpoint classification\",\"sequence\":$sequence,\"decoded\":false,\"malformed\":false,\"classification\":\"pre-cue\",\"boundary\":$sequence,\"input_elapsed_ns\":$elapsed}"
            ;;
        malformed)
            print -r -- "{\"event\":\"input\",\"mode\":\"keepalive-prevention\",\"stage\":\"keepalive-prevention-input\",\"status\":\"pass\",\"marker\":\"unknown\",\"action\":\"unknown\",\"detail\":\"pre-cue observation retained outside endpoint classification\",\"sequence\":$sequence,\"decoded\":false,\"malformed\":true,\"classification\":\"pre-cue\",\"boundary\":$sequence,\"input_elapsed_ns\":$elapsed}"
            ;;
        *)
            return 1
            ;;
    esac
}

write_valid_keepalive_archive() {
    local file_path="$1"
    local pre_cue_mode="${2:-none}"
    local -a pre_cue_schemas=()
    case "$pre_cue_mode" in
        none)
            ;;
        one)
            pre_cue_schemas=(decoded-known)
            ;;
        all)
            pre_cue_schemas=(decoded-known decoded-unknown nondecoded malformed)
            ;;
        multiple)
            pre_cue_schemas=(decoded-known nondecoded)
            ;;
        *)
            return 1
            ;;
    esac
    local pre_cue_count=${#pre_cue_schemas}
    local pressed_sequence=$((11 + pre_cue_count))
    local released_sequence=$((pressed_sequence + 1))
    {
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-same-process-preflight","status":"pass","detail":"fixed endpoint cue and exact owner-heard token checked before runner construction"}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"normal-startup","status":"pass","detail":"configured page and input stream initialized"}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-start","status":"pass","detail":"one HID session started with a monotonic keepalive schedule"}'
        for boundary in 1 2 3 4; do
            print -r -- "{\"event\":\"diagnostic\",\"mode\":\"keepalive-prevention\",\"stage\":\"keepalive-prevention-boundary\",\"status\":\"pass\",\"command\":\"enable-input-stream\",\"detail\":\"one enable-input-stream frame sent at the scheduled boundary\",\"boundary\":$boundary}"
        done
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-schedule","status":"pass","detail":"duration completed after all scheduled input-enable boundaries exactly once","boundary":4}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-capture-health","status":"pass","detail":"capture health checked without retaining transport or device identity","classification":"healthy","boundary":4}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-endpoint-cue","status":"pass","detail":"fixed local endpoint cue executed once without a shell","boundary":4,"cue_start_elapsed_ns":128000000000,"cue_completion_elapsed_ns":129000000000,"cue_duration_ns":1000000000}'
        local pre_cue_index=0
        for schema in "${pre_cue_schemas[@]}"; do
            pre_cue_index=$((pre_cue_index + 1))
            write_pre_cue_record "$schema" $((10 + pre_cue_index)) $((127000000000 + pre_cue_index * 100000000))
        done
        print -r -- "{\"event\":\"input\",\"mode\":\"keepalive-prevention\",\"stage\":\"keepalive-prevention-input\",\"status\":\"pass\",\"input_class\":\"square\",\"wire_index\":0,\"marker\":\"button\",\"action\":\"pressed\",\"detail\":\"bounded input observation retained\",\"sequence\":$pressed_sequence,\"decoded\":true,\"malformed\":false,\"classification\":\"observed\",\"boundary\":$pressed_sequence,\"input_elapsed_ns\":130000000000}"
        print -r -- "{\"event\":\"input\",\"mode\":\"keepalive-prevention\",\"stage\":\"keepalive-prevention-input\",\"status\":\"pass\",\"input_class\":\"square\",\"wire_index\":0,\"marker\":\"button\",\"action\":\"released\",\"detail\":\"bounded input observation retained\",\"sequence\":$released_sequence,\"decoded\":true,\"malformed\":false,\"classification\":\"observed\",\"boundary\":$released_sequence,\"input_elapsed_ns\":131000000000}"
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-final-verification","status":"pass","detail":"active-at-cue attestation and one canonical 0_0 pair were verified in the endpoint window","boundary":4,"attestation":"ACTIVE_AT_CUE","cue_completion_elapsed_ns":129000000000,"window_start_elapsed_ns":128000000000,"planned_close_elapsed_ns":134000000000,"actual_timer_wake_elapsed_ns":134000000000,"actual_capture_stop_elapsed_ns":134000000000,"window_duration_ns":6000000000}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-result","status":"pass","detail":"keepalive prevention requires the coupled visual and canonical-input endpoint","boundary":4}'
    } > "$file_path"
}

write_valid_k150_keepalive_archive() {
    local file_path="$1"
    {
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-same-process-preflight","status":"pass","detail":"fixed endpoint cue and exact owner-heard token checked before runner construction"}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"normal-startup","status":"pass","detail":"configured page and input stream initialized"}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-start","status":"pass","detail":"one HID session started with a monotonic keepalive schedule"}'
        for boundary in 1 2 3 4; do
            local planned=$((boundary * 50000000000))
            print -r -- "{\"event\":\"diagnostic\",\"mode\":\"keepalive-prevention\",\"stage\":\"keepalive-prevention-boundary\",\"status\":\"pass\",\"command\":\"enable-input-stream\",\"detail\":\"one enable-input-stream frame sent at the scheduled boundary\",\"boundary\":$boundary,\"timing_contract\":\"k1-50-v1\",\"planned_boundary_elapsed_ns\":$planned,\"actual_timer_wake_elapsed_ns\":$planned,\"write_start_elapsed_ns\":$planned,\"write_completion_elapsed_ns\":$planned}"
        done
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-schedule","status":"pass","detail":"duration completed after all scheduled input-enable boundaries exactly once","boundary":4}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-capture-health","status":"pass","detail":"capture health checked without retaining transport or device identity","classification":"healthy","boundary":4}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-endpoint-cue","status":"pass","detail":"fixed local endpoint cue executed once without a shell","boundary":4,"cue_start_elapsed_ns":201000000000,"cue_completion_elapsed_ns":201500000000,"cue_duration_ns":500000000}'
        print -r -- '{"event":"input","mode":"keepalive-prevention","stage":"keepalive-prevention-input","status":"pass","input_class":"square","wire_index":0,"marker":"button","action":"pressed","detail":"bounded input observation retained","sequence":11,"decoded":true,"malformed":false,"classification":"observed","boundary":11,"input_elapsed_ns":202000000000}'
        print -r -- '{"event":"input","mode":"keepalive-prevention","stage":"keepalive-prevention-input","status":"pass","input_class":"square","wire_index":0,"marker":"button","action":"released","detail":"bounded input observation retained","sequence":12,"decoded":true,"malformed":false,"classification":"observed","boundary":12,"input_elapsed_ns":202100000000}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-final-verification","status":"pass","detail":"active-at-cue attestation and one canonical 0_0 pair were verified in the endpoint window","boundary":4,"attestation":"ACTIVE_AT_CUE","cue_completion_elapsed_ns":201500000000,"window_start_elapsed_ns":201000000000,"planned_close_elapsed_ns":206500000000,"actual_timer_wake_elapsed_ns":206500000000,"actual_capture_stop_elapsed_ns":206500000000,"window_duration_ns":5500000000}'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-result","status":"pass","detail":"keepalive prevention requires the coupled visual and canonical-input endpoint","boundary":4}'
    } > "$file_path"
}

VALID_ARCHIVE="$TMP_ROOT/valid.jsonl"
UNKNOWN_ARCHIVE="$TMP_ROOT/unknown.jsonl"
RAW_ARCHIVE="$TMP_ROOT/raw.jsonl"
MISSING_WIRE_ARCHIVE="$TMP_ROOT/missing-wire.jsonl"
MISSING_BRIGHTNESS_ATTESTATION_ARCHIVE="$TMP_ROOT/missing-brightness-attestation.jsonl"
MALFORMED_BRIGHTNESS_ATTESTATION_ARCHIVE="$TMP_ROOT/malformed-brightness-attestation.jsonl"
TRAILING_BRIGHTNESS_ATTESTATION_ARCHIVE="$TMP_ROOT/trailing-brightness-attestation.jsonl"
DUPLICATE_BRIGHTNESS_ATTESTATION_ARCHIVE="$TMP_ROOT/duplicate-brightness-attestation.jsonl"
WRONG_STAGE_BRIGHTNESS_ATTESTATION_ARCHIVE="$TMP_ROOT/wrong-stage-brightness-attestation.jsonl"
NOT_OBSERVED_BRIGHTNESS_ATTESTATION_ARCHIVE="$TMP_ROOT/not-observed-brightness-attestation.jsonl"
UNCERTAIN_BRIGHTNESS_ATTESTATION_ARCHIVE="$TMP_ROOT/uncertain-brightness-attestation.jsonl"
NULL_DIAGNOSTIC_BRIGHTNESS_ATTESTATION_ARCHIVE="$TMP_ROOT/null-diagnostic-brightness-attestation.jsonl"
NULL_INPUT_BRIGHTNESS_ATTESTATION_ARCHIVE="$TMP_ROOT/null-input-brightness-attestation.jsonl"
TRAILING_INPUT_BRIGHTNESS_ARCHIVE="$TMP_ROOT/trailing-input-brightness.jsonl"
NONPASS_INPUT_BRIGHTNESS_ARCHIVE="$TMP_ROOT/nonpass-input-brightness.jsonl"
KEEPALIVE_VALID_ARCHIVE="$TMP_ROOT/keepalive-valid.jsonl"
KEEPALIVE_VALID_PRE_CUE_ONE_ARCHIVE="$TMP_ROOT/keepalive-valid-pre-cue-one.jsonl"
KEEPALIVE_VALID_PRE_CUE_ALL_ARCHIVE="$TMP_ROOT/keepalive-valid-pre-cue-all.jsonl"
KEEPALIVE_VALID_PRE_CUE_MULTIPLE_ARCHIVE="$TMP_ROOT/keepalive-valid-pre-cue-multiple.jsonl"
KEEPALIVE_UNKNOWN_ARCHIVE="$TMP_ROOT/keepalive-unknown.jsonl"
KEEPALIVE_RAW_ARCHIVE="$TMP_ROOT/keepalive-raw.jsonl"
KEEPALIVE_OBSERVED_GAP_ARCHIVE="$TMP_ROOT/keepalive-observed-gap.jsonl"
KEEPALIVE_PRE_CUE_TIMING_ARCHIVE="$TMP_ROOT/keepalive-pre-cue-timing.jsonl"
KEEPALIVE_PRE_CUE_ORDER_ARCHIVE="$TMP_ROOT/keepalive-pre-cue-order.jsonl"
KEEPALIVE_PRE_CUE_KEYS_ARCHIVE="$TMP_ROOT/keepalive-pre-cue-keys.jsonl"
KEEPALIVE_PRE_CUE_WIRE_ARCHIVE="$TMP_ROOT/keepalive-pre-cue-wire.jsonl"
KEEPALIVE_PRE_CUE_MISSING_WIRE_ARCHIVE="$TMP_ROOT/keepalive-pre-cue-missing-wire.jsonl"
KEEPALIVE_PRE_CUE_NONDECODED_WIRE_ARCHIVE="$TMP_ROOT/keepalive-pre-cue-nondecoded-wire.jsonl"
KEEPALIVE_PRE_CUE_DECODED_MALFORMED_ARCHIVE="$TMP_ROOT/keepalive-pre-cue-decoded-malformed.jsonl"
KEEPALIVE_PRE_CUE_SEQUENCE_ARCHIVE="$TMP_ROOT/keepalive-pre-cue-sequence.jsonl"
KEEPALIVE_CANONICAL_PAIR_SEQUENCE_ARCHIVE="$TMP_ROOT/keepalive-canonical-pair-sequence.jsonl"
KEEPALIVE_CANONICAL_PAIR_ELAPSED_ARCHIVE="$TMP_ROOT/keepalive-canonical-pair-elapsed.jsonl"
KEEPALIVE_IN_WINDOW_EXTRA_ARCHIVE="$TMP_ROOT/keepalive-in-window-extra.jsonl"
KEEPALIVE_POST_WINDOW_TIMING_ARCHIVE="$TMP_ROOT/keepalive-post-window-timing.jsonl"
KEEPALIVE_STAGE_ARCHIVE="$TMP_ROOT/keepalive-stage.jsonl"
KEEPALIVE_ORDER_ARCHIVE="$TMP_ROOT/keepalive-order.jsonl"
KEEPALIVE_BOUNDARY_ARCHIVE="$TMP_ROOT/keepalive-boundary.jsonl"
KEEPALIVE_THREE_BOUNDARY_ARCHIVE="$TMP_ROOT/keepalive-three-boundary.jsonl"
KEEPALIVE_MISSING_RELEASE_ARCHIVE="$TMP_ROOT/keepalive-missing-release.jsonl"
KEEPALIVE_ATTESTATION_ARCHIVE="$TMP_ROOT/keepalive-attestation.jsonl"
KEEPALIVE_TIMING_ARCHIVE="$TMP_ROOT/keepalive-timing.jsonl"
KEEPALIVE_MISSING_ACTUAL_ARCHIVE="$TMP_ROOT/keepalive-missing-actual.jsonl"
KEEPALIVE_LATE_ARCHIVE="$TMP_ROOT/keepalive-late.jsonl"
KEEPALIVE_EARLY_ARCHIVE="$TMP_ROOT/keepalive-early.jsonl"
KEEPALIVE_FAILED_PREFLIGHT_ARCHIVE="$TMP_ROOT/keepalive-failed-preflight.jsonl"
KEEPALIVE_UNHEALTHY_ARCHIVE="$TMP_ROOT/keepalive-unhealthy.jsonl"
KEEPALIVE_VALID_TAIL_ARCHIVE="$TMP_ROOT/keepalive-valid-tail.jsonl"
KEEPALIVE_VALID_TOLERANCE_ARCHIVE="$TMP_ROOT/keepalive-valid-tolerance.jsonl"
KEEPALIVE_TOO_MANY_ARCHIVE="$TMP_ROOT/keepalive-too-many.jsonl"
KEEPALIVE_TOO_LARGE_ARCHIVE="$TMP_ROOT/keepalive-too-large.jsonl"
KEEPALIVE_K150_VALID_ARCHIVE="$TMP_ROOT/keepalive-k150-valid.jsonl"
KEEPALIVE_K150_TOLERANCE_ARCHIVE="$TMP_ROOT/keepalive-k150-tolerance.jsonl"
KEEPALIVE_K150_PRE_CUE_VALID_ARCHIVE="$TMP_ROOT/keepalive-k150-pre-cue-valid.jsonl"
KEEPALIVE_K150_PRE_CUE_REGRESSION_ARCHIVE="$TMP_ROOT/keepalive-k150-pre-cue-regression.jsonl"
KEEPALIVE_K150_DECIMAL_ARCHIVE="$TMP_ROOT/keepalive-k150-decimal.jsonl"
KEEPALIVE_K150_LATE_ARCHIVE="$TMP_ROOT/keepalive-k150-late.jsonl"
KEEPALIVE_K150_EARLY_ARCHIVE="$TMP_ROOT/keepalive-k150-early.jsonl"
KEEPALIVE_K150_REORDERED_ARCHIVE="$TMP_ROOT/keepalive-k150-reordered.jsonl"
KEEPALIVE_K150_MISSING_ARCHIVE="$TMP_ROOT/keepalive-k150-missing.jsonl"
KEEPALIVE_K150_TYPED_ARCHIVE="$TMP_ROOT/keepalive-k150-typed.jsonl"
KEEPALIVE_K150_PARTIAL_ARCHIVE="$TMP_ROOT/keepalive-k150-partial.jsonl"
KEEPALIVE_K150_MIXED_ARCHIVE="$TMP_ROOT/keepalive-k150-mixed.jsonl"
KEEPALIVE_K150_UNKNOWN_ARCHIVE="$TMP_ROOT/keepalive-k150-unknown.jsonl"
write_valid_archive "$VALID_ARCHIVE"
write_valid_keepalive_archive "$KEEPALIVE_VALID_ARCHIVE"
write_valid_k150_keepalive_archive "$KEEPALIVE_K150_VALID_ARCHIVE"
write_valid_keepalive_archive "$KEEPALIVE_VALID_PRE_CUE_ONE_ARCHIVE" one
write_valid_keepalive_archive "$KEEPALIVE_VALID_PRE_CUE_ALL_ARCHIVE" all
write_valid_keepalive_archive "$KEEPALIVE_VALID_PRE_CUE_MULTIPLE_ARCHIVE" multiple
cp "$VALID_ARCHIVE" "$UNKNOWN_ARCHIVE"
print -r -- '{"event":"input","mode":"brightness-zero","stage":"captured-input","status":"pass","sequence":8,"phase":"baseline","decoded":true,"malformed":false,"marker":"button","action":"pressed","classification":"expected","boundary":8,"wire_index":0,"unknown_field":"reject"}' >> "$UNKNOWN_ARCHIVE"
cp "$VALID_ARCHIVE" "$RAW_ARCHIVE"
print -r -- '{"event":"input","mode":"brightness-zero","stage":"captured-input","status":"pass","sequence":8,"phase":"baseline","decoded":true,"malformed":false,"marker":"button","action":"pressed","classification":"expected","boundary":8,"wire_index":0,"raw_payload":"reject"}' >> "$RAW_ARCHIVE"
cp "$VALID_ARCHIVE" "$MISSING_WIRE_ARCHIVE"
print -r -- '{"event":"input","mode":"brightness-zero","stage":"captured-input","status":"pass","sequence":8,"phase":"baseline","decoded":true,"malformed":false,"marker":"button","action":"pressed","classification":"expected","boundary":8}' >> "$MISSING_WIRE_ARCHIVE"
VALID_BRIGHTNESS_ARCHIVE_CONTENT="$(<"$VALID_ARCHIVE")"
print -r -- "${VALID_BRIGHTNESS_ARCHIVE_CONTENT/\"brightness_attestation\":\"BRIGHTNESS_100_OBSERVED\"/}" > "$MISSING_BRIGHTNESS_ATTESTATION_ARCHIVE"
print -r -- "${VALID_BRIGHTNESS_ARCHIVE_CONTENT/\"brightness_attestation\":\"BRIGHTNESS_100_OBSERVED\"/\"brightness_attestation\":\"RESTORED\"}" > "$MALFORMED_BRIGHTNESS_ATTESTATION_ARCHIVE"
print -r -- "${VALID_BRIGHTNESS_ARCHIVE_CONTENT/\"brightness_attestation\":\"BRIGHTNESS_100_OBSERVED\"/\"brightness_attestation\":\"BRIGHTNESS_100_OBSERVED extra\"}" > "$TRAILING_BRIGHTNESS_ATTESTATION_ARCHIVE"
print -r -- "${VALID_BRIGHTNESS_ARCHIVE_CONTENT/\"brightness_attestation\":\"BRIGHTNESS_100_OBSERVED\"/\"brightness_attestation\":\"BRIGHTNESS_100_OBSERVED\",\"brightness_attestation\":\"NOT_OBSERVED\"}" > "$DUPLICATE_BRIGHTNESS_ATTESTATION_ARCHIVE"
print -r -- "${VALID_BRIGHTNESS_ARCHIVE_CONTENT/\"stage\":\"brightness-zero-matrix\"/\"stage\":\"brightness-zero-matrix\",\"brightness_attestation\":\"BRIGHTNESS_100_OBSERVED\"}" > "$WRONG_STAGE_BRIGHTNESS_ATTESTATION_ARCHIVE"
print -r -- "${VALID_BRIGHTNESS_ARCHIVE_CONTENT//BRIGHTNESS_100_OBSERVED/NOT_OBSERVED}" > "$NOT_OBSERVED_BRIGHTNESS_ATTESTATION_ARCHIVE"
print -r -- "${VALID_BRIGHTNESS_ARCHIVE_CONTENT//BRIGHTNESS_100_OBSERVED/UNCERTAIN}" > "$UNCERTAIN_BRIGHTNESS_ATTESTATION_ARCHIVE"
print -r -- "${VALID_BRIGHTNESS_ARCHIVE_CONTENT/\"stage\":\"normal-startup\"/\"stage\":\"normal-startup\",\"brightness_attestation\":null}" > "$NULL_DIAGNOSTIC_BRIGHTNESS_ATTESTATION_ARCHIVE"
print -r -- "${VALID_BRIGHTNESS_ARCHIVE_CONTENT/\"stage\":\"captured-input\"/\"stage\":\"captured-input\",\"brightness_attestation\":null}" > "$NULL_INPUT_BRIGHTNESS_ATTESTATION_ARCHIVE"
TRAILING_INPUT_BRIGHTNESS_CONTENT="${VALID_BRIGHTNESS_ARCHIVE_CONTENT/\"phase\":\"baseline\"/\"phase\":\"trailing\"}"
TRAILING_INPUT_BRIGHTNESS_CONTENT="${TRAILING_INPUT_BRIGHTNESS_CONTENT/\"classification\":\"expected\"/\"classification\":\"trailing\"}"
print -r -- "$TRAILING_INPUT_BRIGHTNESS_CONTENT" > "$TRAILING_INPUT_BRIGHTNESS_ARCHIVE"
NONPASS_INPUT_BRIGHTNESS_CONTENT="${VALID_BRIGHTNESS_ARCHIVE_CONTENT/\"stage\":\"captured-input\",\"status\":\"pass\"/\"stage\":\"captured-input\",\"status\":\"class-failure\"}"
print -r -- "$NONPASS_INPUT_BRIGHTNESS_CONTENT" > "$NONPASS_INPUT_BRIGHTNESS_ARCHIVE"

KEEPALIVE_VALID_CONTENT="$(<"$KEEPALIVE_VALID_ARCHIVE")"
KEEPALIVE_PRE_CUE_ONE_CONTENT="$(<"$KEEPALIVE_VALID_PRE_CUE_ONE_ARCHIVE")"
KEEPALIVE_PRE_CUE_ALL_CONTENT="$(<"$KEEPALIVE_VALID_PRE_CUE_ALL_ARCHIVE")"
KEEPALIVE_K150_VALID_CONTENT="$(<"$KEEPALIVE_K150_VALID_ARCHIVE")"
KEEPALIVE_K150_PRE_CUE_LINES=("${(@f)KEEPALIVE_K150_VALID_CONTENT}")
KEEPALIVE_K150_PRE_CUE_FIRST="$(write_pre_cue_record decoded-known 1 200000000000)"
KEEPALIVE_K150_PRE_CUE_SECOND="$(write_pre_cue_record decoded-known 2 200000000000)"
KEEPALIVE_K150_PRE_CUE_LINES=("${(@)KEEPALIVE_K150_PRE_CUE_LINES[1,10]}" "$KEEPALIVE_K150_PRE_CUE_FIRST" "$KEEPALIVE_K150_PRE_CUE_SECOND" "${(@)KEEPALIVE_K150_PRE_CUE_LINES[11,-1]}")
print -l -r -- "${KEEPALIVE_K150_PRE_CUE_LINES[@]}" > "$KEEPALIVE_K150_PRE_CUE_VALID_ARCHIVE"
KEEPALIVE_K150_PRE_CUE_REGRESSION_LINES=("${KEEPALIVE_K150_PRE_CUE_LINES[@]}")
KEEPALIVE_K150_PRE_CUE_REGRESSION_LINES[12]="${KEEPALIVE_K150_PRE_CUE_REGRESSION_LINES[12]/200000000000/199000000000}"
print -l -r -- "${KEEPALIVE_K150_PRE_CUE_REGRESSION_LINES[@]}" > "$KEEPALIVE_K150_PRE_CUE_REGRESSION_ARCHIVE"
print -r -- "${KEEPALIVE_K150_VALID_CONTENT/\"planned_boundary_elapsed_ns\":50000000000/\"planned_boundary_elapsed_ns\":50000000000.0}" > "$KEEPALIVE_K150_DECIMAL_ARCHIVE"
KEEPALIVE_K150_TOLERANCE_CONTENT="${KEEPALIVE_K150_VALID_CONTENT/\"planned_boundary_elapsed_ns\":200000000000,\"actual_timer_wake_elapsed_ns\":200000000000,\"write_start_elapsed_ns\":200000000000,\"write_completion_elapsed_ns\":200000000000/\"planned_boundary_elapsed_ns\":200000000000,\"actual_timer_wake_elapsed_ns\":200250000000,\"write_start_elapsed_ns\":200250000000,\"write_completion_elapsed_ns\":200250000000}"
print -r -- "$KEEPALIVE_K150_TOLERANCE_CONTENT" > "$KEEPALIVE_K150_TOLERANCE_ARCHIVE"
print -r -- "${KEEPALIVE_K150_VALID_CONTENT/\"write_completion_elapsed_ns\":200000000000/\"write_completion_elapsed_ns\":200250000001}" > "$KEEPALIVE_K150_LATE_ARCHIVE"
print -r -- "${KEEPALIVE_K150_VALID_CONTENT/\"actual_timer_wake_elapsed_ns\":50000000000/\"actual_timer_wake_elapsed_ns\":49999999999}" > "$KEEPALIVE_K150_EARLY_ARCHIVE"
print -r -- "${KEEPALIVE_K150_VALID_CONTENT/\"planned_boundary_elapsed_ns\":100000000000,\"actual_timer_wake_elapsed_ns\":100000000000,\"write_start_elapsed_ns\":100000000000/\"planned_boundary_elapsed_ns\":100000000000,\"actual_timer_wake_elapsed_ns\":100000000000,\"write_start_elapsed_ns\":99999999999}" > "$KEEPALIVE_K150_REORDERED_ARCHIVE"
print -r -- "${KEEPALIVE_K150_VALID_CONTENT/\"write_completion_elapsed_ns\":200000000000/}" > "$KEEPALIVE_K150_MISSING_ARCHIVE"
print -r -- "${KEEPALIVE_K150_VALID_CONTENT/\"timing_contract\":\"k1-50-v1\"/\"timing_contract\":1}" > "$KEEPALIVE_K150_TYPED_ARCHIVE"
print -r -- "${KEEPALIVE_K150_VALID_CONTENT/\"timing_contract\":\"k1-50-v1\"/}" > "$KEEPALIVE_K150_PARTIAL_ARCHIVE"
print -r -- "${KEEPALIVE_K150_VALID_CONTENT/\"timing_contract\":\"k1-50-v1\"/\"timing_contract\":\"unknown\"}" > "$KEEPALIVE_K150_MIXED_ARCHIVE"
print -r -- "${KEEPALIVE_K150_VALID_CONTENT//k1-50-v1/unknown}" > "$KEEPALIVE_K150_UNKNOWN_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/\{\"event\":\"diagnostic\"/\{\"unknown_field\":\"reject\",\"event\":\"diagnostic\"}" > "$KEEPALIVE_UNKNOWN_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/\{\"event\":\"input\"/\{\"raw_payload\":\"deadbeef\",\"event\":\"input\"}" > "$KEEPALIVE_RAW_ARCHIVE"
print -r -- "${KEEPALIVE_PRE_CUE_ONE_CONTENT/\"classification\":\"pre-cue\"/\"classification\":\"observed\"}" > "$KEEPALIVE_OBSERVED_GAP_ARCHIVE"
print -r -- "${KEEPALIVE_PRE_CUE_ONE_CONTENT/\"input_elapsed_ns\":127100000000/\"input_elapsed_ns\":128000000000}" > "$KEEPALIVE_PRE_CUE_TIMING_ARCHIVE"
print -r -- "${KEEPALIVE_PRE_CUE_ALL_CONTENT/\"classification\":\"pre-cue\"/\"unexpected\":\"reject\",\"classification\":\"pre-cue\"}" > "$KEEPALIVE_PRE_CUE_KEYS_ARCHIVE"
print -r -- "${KEEPALIVE_PRE_CUE_ONE_CONTENT/\"wire_index\":7/\"wire_index\":256}" > "$KEEPALIVE_PRE_CUE_WIRE_ARCHIVE"
print -r -- "${KEEPALIVE_PRE_CUE_ONE_CONTENT/,\"wire_index\":7/}" > "$KEEPALIVE_PRE_CUE_MISSING_WIRE_ARCHIVE"
print -r -- "${KEEPALIVE_PRE_CUE_ALL_CONTENT/\"decoded\":false/\"wire_index\":1,\"decoded\":false}" > "$KEEPALIVE_PRE_CUE_NONDECODED_WIRE_ARCHIVE"
print -r -- "${KEEPALIVE_PRE_CUE_ONE_CONTENT/\"malformed\":false/\"malformed\":true}" > "$KEEPALIVE_PRE_CUE_DECODED_MALFORMED_ARCHIVE"
print -r -- "${KEEPALIVE_PRE_CUE_ONE_CONTENT/\"sequence\":11/\"sequence\":12}" > "$KEEPALIVE_PRE_CUE_SEQUENCE_ARCHIVE"
KEEPALIVE_CANONICAL_PAIR_SEQUENCE_CONTENT="${KEEPALIVE_VALID_CONTENT/\"sequence\":12/\"sequence\":13}"
print -r -- "${KEEPALIVE_CANONICAL_PAIR_SEQUENCE_CONTENT/\"boundary\":12/\"boundary\":13}" > "$KEEPALIVE_CANONICAL_PAIR_SEQUENCE_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/\"input_elapsed_ns\":131000000000/\"input_elapsed_ns\":129500000000}" > "$KEEPALIVE_CANONICAL_PAIR_ELAPSED_ARCHIVE"
KEEPALIVE_PRE_CUE_ORDER_LINES=("${(@f)KEEPALIVE_PRE_CUE_ALL_CONTENT}")
KEEPALIVE_PRE_CUE_ORDER_RECORD="${KEEPALIVE_PRE_CUE_ORDER_LINES[11]}"
KEEPALIVE_PRE_CUE_ORDER_LINES[11]="${KEEPALIVE_PRE_CUE_ORDER_LINES[12]}"
KEEPALIVE_PRE_CUE_ORDER_LINES[12]="$KEEPALIVE_PRE_CUE_ORDER_RECORD"
print -l -r -- "${KEEPALIVE_PRE_CUE_ORDER_LINES[@]}" > "$KEEPALIVE_PRE_CUE_ORDER_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/keepalive-prevention-schedule/keepalive-prevention-result}" > "$KEEPALIVE_STAGE_ARCHIVE"
KEEPALIVE_ORDER_LINES=("${(@f)KEEPALIVE_VALID_CONTENT}")
KEEPALIVE_ORDER_RECORD="${KEEPALIVE_ORDER_LINES[3]}"
KEEPALIVE_ORDER_LINES[3]="${KEEPALIVE_ORDER_LINES[4]}"
KEEPALIVE_ORDER_LINES[4]="$KEEPALIVE_ORDER_RECORD"
print -l -r -- "${KEEPALIVE_ORDER_LINES[@]}" > "$KEEPALIVE_ORDER_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/\"boundary\":2/\"boundary\":3}" > "$KEEPALIVE_BOUNDARY_ARCHIVE"
while IFS= read -r record; do
    if [[ "$record" == *'"stage":"keepalive-prevention-boundary"'* && "$record" == *'"boundary":4'* ]]; then
        continue
    fi
    print -r -- "${record//\"boundary\":4/\"boundary\":3}"
done < "$KEEPALIVE_VALID_ARCHIVE" > "$KEEPALIVE_THREE_BOUNDARY_ARCHIVE"
while IFS= read -r record; do
    if [[ "$record" != *'"action":"released"'* ]]; then
        print -r -- "$record"
    fi
done < "$KEEPALIVE_VALID_ARCHIVE" > "$KEEPALIVE_MISSING_RELEASE_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/ACTIVE_AT_CUE/SCREENSAVER_AT_CUE}" > "$KEEPALIVE_ATTESTATION_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/\"planned_close_elapsed_ns\":134000000000/\"planned_close_elapsed_ns\":135000000000}" > "$KEEPALIVE_TIMING_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/,\"actual_capture_stop_elapsed_ns\":134000000000/}" > "$KEEPALIVE_MISSING_ACTUAL_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/\"actual_timer_wake_elapsed_ns\":134000000000/\"actual_timer_wake_elapsed_ns\":134250000001}" > "$KEEPALIVE_LATE_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/\"actual_capture_stop_elapsed_ns\":134000000000/\"actual_capture_stop_elapsed_ns\":133999999999}" > "$KEEPALIVE_EARLY_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/\"stage\":\"keepalive-prevention-same-process-preflight\",\"status\":\"pass\"/\"stage\":\"keepalive-prevention-same-process-preflight\",\"status\":\"invalidated\"}" > "$KEEPALIVE_FAILED_PREFLIGHT_ARCHIVE"
print -r -- "${KEEPALIVE_VALID_CONTENT/\"classification\":\"healthy\"/\"classification\":\"terminal-error\"}" > "$KEEPALIVE_UNHEALTHY_ARCHIVE"
KEEPALIVE_VALID_TOLERANCE_CONTENT="${KEEPALIVE_VALID_CONTENT/\"actual_timer_wake_elapsed_ns\":134000000000/\"actual_timer_wake_elapsed_ns\":134250000000}"
print -r -- "${KEEPALIVE_VALID_TOLERANCE_CONTENT/\"actual_capture_stop_elapsed_ns\":134000000000/\"actual_capture_stop_elapsed_ns\":134250000000}" > "$KEEPALIVE_VALID_TOLERANCE_ARCHIVE"
while IFS= read -r record; do
    if [[ "$record" == *'"stage":"keepalive-prevention-final-verification"'* ]]; then
        print -r -- '{"event":"input","mode":"keepalive-prevention","stage":"keepalive-prevention-input","status":"pass","marker":"unknown","action":"unknown","detail":"post-window observation retained outside endpoint classification","sequence":13,"decoded":false,"malformed":true,"classification":"post-window","boundary":13,"input_elapsed_ns":134100000000}'
        record="${record/\"actual_capture_stop_elapsed_ns\":134000000000/\"actual_capture_stop_elapsed_ns\":134100000000}"
    fi
    print -r -- "$record"
done < "$KEEPALIVE_VALID_ARCHIVE" > "$KEEPALIVE_VALID_TAIL_ARCHIVE"
KEEPALIVE_VALID_TAIL_CONTENT="$(<"$KEEPALIVE_VALID_TAIL_ARCHIVE")"
print -r -- "${KEEPALIVE_VALID_TAIL_CONTENT/\"input_elapsed_ns\":134100000000/\"input_elapsed_ns\":134000000000}" > "$KEEPALIVE_POST_WINDOW_TIMING_ARCHIVE"
KEEPALIVE_IN_WINDOW_LINES=("${(@f)KEEPALIVE_VALID_CONTENT}")
KEEPALIVE_IN_WINDOW_LINES=("${KEEPALIVE_IN_WINDOW_LINES[1,12]}" '{"event":"input","mode":"keepalive-prevention","stage":"keepalive-prevention-input","status":"pass","input_class":"square","wire_index":0,"marker":"button","action":"pressed","detail":"bounded input observation retained","sequence":13,"decoded":true,"malformed":false,"classification":"observed","boundary":13,"input_elapsed_ns":133000000000}' "${KEEPALIVE_IN_WINDOW_LINES[13,-1]}")
print -l -r -- "${KEEPALIVE_IN_WINDOW_LINES[@]}" > "$KEEPALIVE_IN_WINDOW_EXTRA_ARCHIVE"
cp "$KEEPALIVE_VALID_ARCHIVE" "$KEEPALIVE_TOO_MANY_ARCHIVE"
for excess_record in {1..54}; do
    print -r -- '{}' >> "$KEEPALIVE_TOO_MANY_ARCHIVE"
done
printf '%262145s\n' 'x' > "$KEEPALIVE_TOO_LARGE_ARCHIVE"

run_backend() {
    local backend_name="$1"
    local backend_dir="$2"
    local PATH="$backend_dir"

    if ! diagnostic_validate_observation_archive "$VALID_ARCHIVE"; then
        print -u2 -- "$backend_name backend rejected a valid archive"
        return 1
    fi
    if diagnostic_validate_observation_archive "$UNKNOWN_ARCHIVE"; then
        print -u2 -- "$backend_name backend accepted an unknown-field archive"
        return 1
    fi
    if diagnostic_validate_observation_archive "$RAW_ARCHIVE"; then
        print -u2 -- "$backend_name backend accepted a raw-field archive"
        return 1
    fi
    if diagnostic_validate_observation_archive "$MISSING_WIRE_ARCHIVE"; then
        print -u2 -- "$backend_name backend accepted a decoded archive without wire_index"
        return 1
    fi
    for invalid_brightness_archive in \
        "$MISSING_BRIGHTNESS_ATTESTATION_ARCHIVE" \
        "$MALFORMED_BRIGHTNESS_ATTESTATION_ARCHIVE" \
        "$TRAILING_BRIGHTNESS_ATTESTATION_ARCHIVE" \
        "$DUPLICATE_BRIGHTNESS_ATTESTATION_ARCHIVE" \
        "$WRONG_STAGE_BRIGHTNESS_ATTESTATION_ARCHIVE" \
        "$NOT_OBSERVED_BRIGHTNESS_ATTESTATION_ARCHIVE" \
        "$UNCERTAIN_BRIGHTNESS_ATTESTATION_ARCHIVE" \
        "$NULL_DIAGNOSTIC_BRIGHTNESS_ATTESTATION_ARCHIVE" \
        "$NULL_INPUT_BRIGHTNESS_ATTESTATION_ARCHIVE" \
        "$TRAILING_INPUT_BRIGHTNESS_ARCHIVE" \
        "$NONPASS_INPUT_BRIGHTNESS_ARCHIVE"; do
        if diagnostic_validate_observation_archive "$invalid_brightness_archive"; then
            print -u2 -- "$backend_name backend accepted invalid brightness attestation archive: $invalid_brightness_archive"
            return 1
        fi
    done
    if ! diagnostic_validate_keepalive_observation_archive "$KEEPALIVE_VALID_ARCHIVE"; then
        print -u2 -- "$backend_name backend rejected a valid keepalive archive"
        return 1
    fi
    for valid_pre_cue in \
        "$KEEPALIVE_VALID_PRE_CUE_ONE_ARCHIVE" \
        "$KEEPALIVE_VALID_PRE_CUE_ALL_ARCHIVE" \
        "$KEEPALIVE_VALID_PRE_CUE_MULTIPLE_ARCHIVE"; do
        if ! diagnostic_validate_keepalive_observation_archive "$valid_pre_cue"; then
            print -u2 -- "$backend_name backend rejected a valid pre-cue archive: $valid_pre_cue"
            return 1
        fi
    done
    if ! diagnostic_validate_keepalive_observation_archive "$KEEPALIVE_VALID_TAIL_ARCHIVE"; then
        print -u2 -- "$backend_name backend rejected a valid post-window-tail archive"
        return 1
    fi
    if ! diagnostic_validate_keepalive_observation_archive "$KEEPALIVE_VALID_TOLERANCE_ARCHIVE"; then
        print -u2 -- "$backend_name backend rejected exact endpoint timing tolerance"
        return 1
    fi
    if ! diagnostic_validate_keepalive_observation_archive "$KEEPALIVE_K150_VALID_ARCHIVE"; then
        print -u2 -- "$backend_name backend rejected a valid prospective k1-50-v1 archive"
        return 1
    fi
    if ! diagnostic_validate_keepalive_observation_archive "$KEEPALIVE_K150_TOLERANCE_ARCHIVE"; then
        print -u2 -- "$backend_name backend rejected the inclusive 250ms prospective boundary tolerance"
        return 1
    fi
    if ! diagnostic_validate_keepalive_observation_archive "$KEEPALIVE_K150_PRE_CUE_VALID_ARCHIVE"; then
        print -u2 -- "$backend_name backend rejected valid nondecreasing prospective pre-cue elapsed ordering"
        return 1
    fi
    local invalid_keepalive
    for invalid_keepalive in \
        "$KEEPALIVE_UNKNOWN_ARCHIVE" \
        "$KEEPALIVE_RAW_ARCHIVE" \
        "$KEEPALIVE_OBSERVED_GAP_ARCHIVE" \
        "$KEEPALIVE_PRE_CUE_TIMING_ARCHIVE" \
        "$KEEPALIVE_PRE_CUE_ORDER_ARCHIVE" \
        "$KEEPALIVE_PRE_CUE_KEYS_ARCHIVE" \
        "$KEEPALIVE_PRE_CUE_WIRE_ARCHIVE" \
        "$KEEPALIVE_PRE_CUE_MISSING_WIRE_ARCHIVE" \
        "$KEEPALIVE_PRE_CUE_NONDECODED_WIRE_ARCHIVE" \
        "$KEEPALIVE_PRE_CUE_DECODED_MALFORMED_ARCHIVE" \
        "$KEEPALIVE_PRE_CUE_SEQUENCE_ARCHIVE" \
        "$KEEPALIVE_CANONICAL_PAIR_SEQUENCE_ARCHIVE" \
        "$KEEPALIVE_CANONICAL_PAIR_ELAPSED_ARCHIVE" \
        "$KEEPALIVE_IN_WINDOW_EXTRA_ARCHIVE" \
        "$KEEPALIVE_POST_WINDOW_TIMING_ARCHIVE" \
        "$KEEPALIVE_STAGE_ARCHIVE" \
        "$KEEPALIVE_ORDER_ARCHIVE" \
        "$KEEPALIVE_BOUNDARY_ARCHIVE" \
        "$KEEPALIVE_THREE_BOUNDARY_ARCHIVE" \
        "$KEEPALIVE_MISSING_RELEASE_ARCHIVE" \
        "$KEEPALIVE_ATTESTATION_ARCHIVE" \
        "$KEEPALIVE_TIMING_ARCHIVE" \
        "$KEEPALIVE_MISSING_ACTUAL_ARCHIVE" \
        "$KEEPALIVE_LATE_ARCHIVE" \
        "$KEEPALIVE_EARLY_ARCHIVE" \
        "$KEEPALIVE_FAILED_PREFLIGHT_ARCHIVE" \
        "$KEEPALIVE_UNHEALTHY_ARCHIVE" \
        "$KEEPALIVE_TOO_MANY_ARCHIVE" \
        "$KEEPALIVE_TOO_LARGE_ARCHIVE" \
        "$KEEPALIVE_K150_LATE_ARCHIVE" \
        "$KEEPALIVE_K150_EARLY_ARCHIVE" \
        "$KEEPALIVE_K150_PRE_CUE_REGRESSION_ARCHIVE" \
        "$KEEPALIVE_K150_DECIMAL_ARCHIVE" \
        "$KEEPALIVE_K150_REORDERED_ARCHIVE" \
        "$KEEPALIVE_K150_MISSING_ARCHIVE" \
        "$KEEPALIVE_K150_TYPED_ARCHIVE" \
        "$KEEPALIVE_K150_PARTIAL_ARCHIVE" \
        "$KEEPALIVE_K150_MIXED_ARCHIVE" \
        "$KEEPALIVE_K150_UNKNOWN_ARCHIVE"; do
        if diagnostic_validate_keepalive_observation_archive "$invalid_keepalive"; then
            print -u2 -- "$backend_name backend accepted invalid keepalive archive: $invalid_keepalive"
            return 1
        fi
    done
    return 0
}

source "$SCRIPT_DIR/common.zsh"

for duration_value in 1ns .5s 1m30s 10m 2h; do
    if ! diagnostic_validate_keepalive_text "$duration_value"; then
        print -u2 -- "keepalive text validator rejected $duration_value"
        exit 1
    fi
done
for duration_value in '' $'1s\nmode=forged' $'1s\rmode=forged'; do
    if diagnostic_validate_keepalive_text "$duration_value"; then
        print -u2 -- "keepalive text validator accepted unsafe value: $duration_value"
        exit 1
    fi
done

if ! diagnostic_validate_keepalive_schedule_cli '.5s' '2s' >/dev/null 2>&1; then
    print -u2 -- 'shared CLI validator rejected an exact valid Go duration'
    exit 1
fi
if diagnostic_validate_keepalive_schedule_cli '1s' '5s' >/dev/null 2>&1; then
    print -u2 -- 'shared CLI validator accepted a K1 ratio mismatch'
    exit 1
fi
if diagnostic_validate_keepalive_schedule_cli '15m' '60m0.000000001s' >/dev/null 2>&1; then
    print -u2 -- 'shared CLI validator accepted a duration above 60 minutes'
    exit 1
fi

(
    diagnostic_start_archive() { return 99 }
    if diagnostic_run_keepalive_prevention '1s; forged' 4s >/dev/null 2>&1; then
        print -u2 -- 'keepalive wrapper accepted unsafe interval syntax'
        exit 1
    elif (( $? != 64 )); then
        print -u2 -- 'keepalive wrapper reached archive setup before argument refusal'
        exit 1
    fi
)

for invalid_schedule in '1s 5s' '15m 60m0.000000001s'; do
    (
        diagnostic_start_archive() { return 99 }
        interval="${invalid_schedule%% *}"
        duration="${invalid_schedule#* }"
        if diagnostic_run_keepalive_prevention "$interval" "$duration" >/dev/null 2>&1; then
            print -u2 -- "keepalive wrapper accepted invalid closed schedule: $invalid_schedule"
            exit 1
        elif (( $? != 64 )); then
            print -u2 -- "keepalive wrapper reached archive setup for invalid schedule: $invalid_schedule"
            exit 1
        fi
    )
done

(
    diagnostic_start_archive() { return 0 }
    diagnostic_check_preconditions() { return 0 }
    diagnostic_finish() { return "$1" }
    diagnostic_run_endpoint_cue_preflight() {
        DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT='accepted'
        DIAGNOSTIC_ENDPOINT_OWNER_HEARD='accepted'
        return 0
    }
    diagnostic_confirm() {
        [[ "$1" == 'RUN ONE D200X KEEPALIVE-PREVENTION DIAGNOSTIC' ]] || return 99
        return 2
    }
    if diagnostic_run_keepalive_prevention 1s 4s; then
        print -u2 -- 'keepalive confirmation regression unexpectedly ran a command'
        exit 1
    elif (( $? != 2 )); then
        print -u2 -- 'keepalive wrapper did not require its exact confirmation phrase'
        exit 1
    fi
)

(
    diagnostic_start_archive() { return 0 }
    diagnostic_check_preconditions() { return 0 }
    diagnostic_finish() { return "$1" }
    diagnostic_run_endpoint_cue_preflight() { return 99 }
    diagnostic_confirm() { return 2 }
    diagnostic_run_command() { return 99 }
    if diagnostic_run_keepalive_prevention 1s 4s >/dev/null 2>&1; then
        print -u2 -- 'keepalive wrapper unexpectedly invoked the removed duplicate cue path'
        exit 1
    elif (( $? != 2 )); then
        print -u2 -- 'keepalive wrapper did not proceed directly to physical confirmation'
        exit 1
    fi
)

(
    HIDHOG_REPO_ROOT="$TMP_ROOT/preflight-repo"
    HIDHOG_CONFIG_PATH="$HIDHOG_REPO_ROOT/deploy/hidhogg.toml"
    HIDHOG_RUNTIME_SOCKET="$HIDHOG_REPO_ROOT/deploy/runtime.sock"
    HIDHOG_ARCHIVE_ROOT="$TMP_ROOT/preflight-archive-root"
    mkdir -p "${HIDHOG_CONFIG_PATH:h}"
    : > "$HIDHOG_CONFIG_PATH"
    diagnostic_validate_keepalive_schedule_cli() { return 0 }
    diagnostic_confirm() { return 0 }
    diagnostic_run_command() {
        DIAGNOSTIC_COMMAND_INVOKED='yes'
        print -r -- '{"event":"diagnostic","mode":"keepalive-prevention","stage":"keepalive-prevention-same-process-preflight","status":"invalidated","detail":"fixed endpoint cue and exact owner-heard token checked before runner construction"}' > "$DIAGNOSTIC_STDOUT_FILE"
        diagnostic_finalize_command_result 2
    }
    if diagnostic_run_keepalive_prevention 1s 4s >/dev/null 2>&1; then
        print -u2 -- 'failed same-process preflight archive regression unexpectedly passed'
        exit 1
    elif (( $? != 2 )); then
        exit 1
    fi
    if [[ ! -f "$DIAGNOSTIC_METADATA_FILE" || ! -f "$DIAGNOSTIC_MANIFEST_FILE" ]]; then
        print -u2 -- 'failed endpoint preflight archive was not retained'
        exit 1
    fi
    FAILED_PREFLIGHT_METADATA="$(command cat -- "$DIAGNOSTIC_METADATA_FILE")"
    if [[ "$FAILED_PREFLIGHT_METADATA" != *$'endpoint_cue_preflight=failed\n'* ||
        "$FAILED_PREFLIGHT_METADATA" != *$'endpoint_owner_heard=failed\n'* ||
        "$FAILED_PREFLIGHT_METADATA" != *$'command_invoked=yes\n'* ||
        "$FAILED_PREFLIGHT_METADATA" != *$'result_status=fail\n'* ||
        "$FAILED_PREFLIGHT_METADATA" != *$'exit_status=2\n'* ]]; then
        print -u2 -- 'failed endpoint preflight metadata is incomplete'
        exit 1
    fi
)

run_backend 'jq' "$TMP_ROOT/jq-bin" || exit 1
run_backend 'python' "$TMP_ROOT/python-bin" || exit 1
if [[ -n "$RUBY_PATH" ]]; then
    run_backend 'ruby' "$TMP_ROOT/ruby-bin" || exit 1
fi

(
    PATH="$TMP_ROOT/jq-bin"
    DIAGNOSTIC_MODE='keepalive-prevention'
    DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT='not-run'
    DIAGNOSTIC_ENDPOINT_OWNER_HEARD='not-run'
    DIAGNOSTIC_STDOUT_FILE="$KEEPALIVE_VALID_ARCHIVE"
    DIAGNOSTIC_STDERR_FILE="$TMP_ROOT/keepalive-finalize-missing-preflight.stderr"
    : > "$DIAGNOSTIC_STDERR_FILE"
    diagnostic_finalize_command_result 0 || exit 1
    [[ "$DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT" == 'accepted' && "$DIAGNOSTIC_ENDPOINT_OWNER_HEARD" == 'accepted' ]] || exit 1
)

(
    PATH="$TMP_ROOT/jq-bin"
    DIAGNOSTIC_MODE='keepalive-prevention'
    DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT='accepted'
    DIAGNOSTIC_ENDPOINT_OWNER_HEARD='accepted'
    DIAGNOSTIC_STDOUT_FILE="$KEEPALIVE_VALID_ARCHIVE"
    DIAGNOSTIC_STDERR_FILE="$TMP_ROOT/keepalive-finalize-valid.stderr"
    : > "$DIAGNOSTIC_STDERR_FILE"
    diagnostic_finalize_command_result 0 || exit 1
    [[ "$DIAGNOSTIC_RESULT_STATUS" == 'pass' && "$DIAGNOSTIC_EXIT_STATUS" == '0' ]] || exit 1
)
(
    PATH="$TMP_ROOT/jq-bin"
    DIAGNOSTIC_MODE='keepalive-prevention'
    DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT='accepted'
    DIAGNOSTIC_ENDPOINT_OWNER_HEARD='accepted'
    DIAGNOSTIC_STDOUT_FILE="$KEEPALIVE_STAGE_ARCHIVE"
    DIAGNOSTIC_STDERR_FILE="$TMP_ROOT/keepalive-finalize-invalid.stderr"
    : > "$DIAGNOSTIC_STDERR_FILE"
    if diagnostic_finalize_command_result 0; then
        print -u2 -- 'invalid keepalive archive was recorded as pass'
        exit 1
    elif (( $? != 65 )) || [[ "$DIAGNOSTIC_RESULT_STATUS" != 'fail' || "$DIAGNOSTIC_EXIT_STATUS" != '65' ]]; then
        print -u2 -- 'invalid keepalive archive did not produce exit 65/fail'
        exit 1
    fi
)

PATH=/usr/bin:/bin
HIDHOG_ARCHIVE_ROOT="$TMP_ROOT/archive-root"
HIDHOG_REPO_ROOT="$TMP_ROOT/repo"
HIDHOG_CONFIG_PATH="$HIDHOG_REPO_ROOT/deploy/hidhogg.toml"
HIDHOG_RUNTIME_SOCKET="$HIDHOG_REPO_ROOT/deploy/runtime.sock"
DIAGNOSTIC_KEEPALIVE_INTERVAL='1s'
DIAGNOSTIC_KEEPALIVE_DURATION='4s'
DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT='accepted'
DIAGNOSTIC_ENDPOINT_OWNER_HEARD='accepted'
diagnostic_start_archive 'keepalive-prevention' '' 'keepalive-prevention' '' || exit 1
if [[ "${DIAGNOSTIC_ARCHIVE_DIR:t}" != *-keepalive-prevention ]]; then
    print -u2 -- "keepalive archive identity is invalid: $DIAGNOSTIC_ARCHIVE_DIR"
    exit 1
fi
diagnostic_finish 2 'not-run' || [[ $? == 2 ]] || exit 1
KEEPALIVE_EXPECTED_COMMAND="command=go run ./cmd/hidhoggdiag --mode keepalive-prevention --keepalive-interval 1s --duration 4s --config-path $HIDHOG_CONFIG_PATH --confirm"
KEEPALIVE_METADATA_LINES=("${(@f)$(command cat -- "$DIAGNOSTIC_METADATA_FILE")}")
if (( ${KEEPALIVE_METADATA_LINES[(Ie)mode=keepalive-prevention]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)keepalive_interval=1s]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)keepalive_duration=4s]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)endpoint_protocol_version=1]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)endpoint_cue=fixed-local-speech-v1]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)endpoint_cue_timeout_ns=12000000000]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)endpoint_capture_tail_ns=5000000000]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)endpoint_close_tolerance_ns=250000000]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)endpoint_cue_preflight_scope=same-process]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)endpoint_cue_preflight=accepted]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)endpoint_owner_heard=accepted]} == 0 ||
    ${KEEPALIVE_METADATA_LINES[(Ie)$KEEPALIVE_EXPECTED_COMMAND]} == 0 )); then
    print -u2 -- 'keepalive metadata identity is incomplete'
    exit 1
fi
KEEPALIVE_ARCHIVE_TEXT="$(command cat -- "$DIAGNOSTIC_METADATA_FILE")$(command cat -- "$DIAGNOSTIC_STDERR_FILE")"
if [[ "$KEEPALIVE_ARCHIVE_TEXT" == *hidraw* || "$KEEPALIVE_ARCHIVE_TEXT" == *serial* || "$KEEPALIVE_ARCHIVE_TEXT" == *payload* ]]; then
    print -u2 -- 'keepalive archive leaked raw HID identity or payload markers'
    exit 1
fi

FORGED_REPORT="$HIDHOG_ARCHIVE_ROOT/20260828T000000Z-brightness-zero"
mkdir -p "$FORGED_REPORT"
print -r -- 'format_version=999' > "$FORGED_REPORT/metadata.txt"
print -r -- 'manifest_version=999' > "$FORGED_REPORT/manifest.sha256"
if diagnostic_check_brightness_report "$FORGED_REPORT"; then
    print -u2 -- 'brightness-report check accepted forged metadata'
    exit 1
fi

print -r -- 'archive validation regression passed'
