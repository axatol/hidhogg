#!/bin/zsh

set -u
unsetopt bgnice
umask 077

DIAGNOSTICS_SCRIPT_PATH="${0:A}"
DIAGNOSTICS_SCRIPT_DIR="${DIAGNOSTICS_SCRIPT_PATH:h}"
HIDHOG_REPO_ROOT="${DIAGNOSTICS_SCRIPT_DIR:h:h}"
HIDHOG_DEPLOY_DIR="${HIDHOG_REPO_ROOT}/deploy"
HIDHOG_CONFIG_PATH="${HIDHOG_DEPLOY_DIR}/hidhogg.toml"
HIDHOG_RUNTIME_SOCKET="${HIDHOG_DEPLOY_DIR}/runtime.sock"
HIDHOG_ARCHIVE_ROOT="${HIDHOG_DEPLOY_DIR}/diagnostics"

DIAGNOSTIC_ARCHIVE_DIR=""
DIAGNOSTIC_ARCHIVE_MODE=""
DIAGNOSTIC_MODE=""
DIAGNOSTIC_CANDIDATE=""
DIAGNOSTIC_KEEPALIVE_INTERVAL=""
DIAGNOSTIC_KEEPALIVE_DURATION=""
DIAGNOSTIC_CONFIG_PATH=""
DIAGNOSTIC_REPORT_PATH=""
DIAGNOSTIC_STDOUT_FILE=""
DIAGNOSTIC_STDERR_FILE=""
DIAGNOSTIC_METADATA_FILE=""
DIAGNOSTIC_MANIFEST_FILE=""
DIAGNOSTIC_STDERR_PIPE=""
DIAGNOSTIC_STARTED_AT=""
DIAGNOSTIC_COMMAND=""
DIAGNOSTIC_COMMAND_INVOKED="no"
DIAGNOSTIC_CONFIRMATION="not-requested"
DIAGNOSTIC_PREFLIGHT_STATUS="not-run"
DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT="not-run"
DIAGNOSTIC_ENDPOINT_OWNER_HEARD="not-run"
DIAGNOSTIC_STDERR_CAPTURE_STATUS="not-run"
DIAGNOSTIC_RESULT_STATUS="not-run"
DIAGNOSTIC_EXIT_STATUS="not-run"

diagnostic_message() {
    local message="$1"
    printf '%s\n' "$message" >&2
    if [[ -n "$DIAGNOSTIC_STDERR_FILE" ]]; then
        printf '%s\n' "$message" >> "$DIAGNOSTIC_STDERR_FILE"
    fi
}

diagnostic_start_archive() {
    DIAGNOSTIC_MODE="$1"
    DIAGNOSTIC_CANDIDATE="$2"
    DIAGNOSTIC_ARCHIVE_MODE="$3"
    DIAGNOSTIC_CONFIG_PATH="$HIDHOG_CONFIG_PATH"
    DIAGNOSTIC_REPORT_PATH="$4"
    diagnostic_command_for_mode
    DIAGNOSTIC_STARTED_AT="$(date -u '+%Y%m%dT%H%M%SZ')"
    if [[ -z "$DIAGNOSTIC_STARTED_AT" ]]; then
        printf '%s\n' 'unable to obtain a UTC timestamp; diagnostic was not invoked' >&2
        return 70
    fi

    if ! mkdir -p "$HIDHOG_ARCHIVE_ROOT"; then
        printf '%s\n' "unable to create diagnostic archive root: $HIDHOG_ARCHIVE_ROOT" >&2
        return 70
    fi

    DIAGNOSTIC_ARCHIVE_DIR="${HIDHOG_ARCHIVE_ROOT}/${DIAGNOSTIC_STARTED_AT}-${DIAGNOSTIC_ARCHIVE_MODE}"
    if ! mkdir "$DIAGNOSTIC_ARCHIVE_DIR" 2>/dev/null; then
        DIAGNOSTIC_ARCHIVE_DIR="${HIDHOG_ARCHIVE_ROOT}/${DIAGNOSTIC_STARTED_AT}-$$-${DIAGNOSTIC_ARCHIVE_MODE}"
        if ! mkdir "$DIAGNOSTIC_ARCHIVE_DIR"; then
            printf '%s\n' "unable to create diagnostic archive: $DIAGNOSTIC_ARCHIVE_DIR" >&2
            return 70
        fi
    fi

    DIAGNOSTIC_STDOUT_FILE="${DIAGNOSTIC_ARCHIVE_DIR}/stdout.jsonl"
    DIAGNOSTIC_STDERR_FILE="${DIAGNOSTIC_ARCHIVE_DIR}/stderr.log"
    DIAGNOSTIC_METADATA_FILE="${DIAGNOSTIC_ARCHIVE_DIR}/metadata.txt"
    DIAGNOSTIC_MANIFEST_FILE="${DIAGNOSTIC_ARCHIVE_DIR}/manifest.sha256"
    : > "$DIAGNOSTIC_STDOUT_FILE" || return 70
    : > "$DIAGNOSTIC_STDERR_FILE" || return 70

    diagnostic_message "diagnostic archive: $DIAGNOSTIC_ARCHIVE_DIR"
    diagnostic_message "configuration path: $DIAGNOSTIC_CONFIG_PATH (existence only; contents are not inspected)"
    return 0
}

diagnostic_check_preconditions() {
    local result_code=0

    if [[ ! -f "$DIAGNOSTIC_CONFIG_PATH" ]]; then
        diagnostic_message "refusing diagnostic: configuration file is missing: $DIAGNOSTIC_CONFIG_PATH"
        result_code=78
    fi

    if [[ -e "$HIDHOG_RUNTIME_SOCKET" || -L "$HIDHOG_RUNTIME_SOCKET" ]]; then
        diagnostic_message "refusing diagnostic: $HIDHOG_RUNTIME_SOCKET exists; stop the owner-run runtime first"
        result_code=73
    fi

    if (( result_code == 0 )); then
        DIAGNOSTIC_PREFLIGHT_STATUS='pass'
        return 0
    fi

    DIAGNOSTIC_PREFLIGHT_STATUS='fail'
    return "$result_code"
}

diagnostic_resolve_report_path() {
    local requested="$1"
    local resolved

    if [[ "$requested" = /* ]]; then
        resolved="$requested"
    else
        resolved="${HIDHOG_REPO_ROOT}/${requested}"
    fi
    DIAGNOSTIC_REPORT_PATH="${resolved:A}"
}

diagnostic_sha256_file() {
    local file_path="$1"
    local output
    local digest

    if command -v shasum >/dev/null 2>&1; then
        output="$(command shasum --algorithm 256 -- "$file_path")" || return 1
    elif command -v sha256sum >/dev/null 2>&1; then
        output="$(command sha256sum -- "$file_path")" || return 1
    else
        return 1
    fi

    digest="${output%% *}"
    if [[ ! "$digest" =~ '^[[:xdigit:]]{64}$' ]]; then
        return 1
    fi
    printf '%s\n' "${digest:l}"
}

diagnostic_validate_observation_archive() {
    local archive_file="$1"
    local -i bytes
    local -i lines
    local jq_filter

    if [[ ! -s "$archive_file" ]]; then
        return 1
    fi
    bytes="$(wc -c < "$archive_file")" || return 1
    lines="$(wc -l < "$archive_file")" || return 1
    if (( bytes <= 0 || bytes > 262144 || lines <= 0 || lines > 64 )); then
        return 1
    fi

    jq_filter='
        [
            "normal-startup",
            "brightness-zero-baseline",
            "brightness-zero-write",
            "brightness-zero-attestation",
            "brightness-restore",
            "brightness-zero-matrix",
            "brightness-zero-recovery"
        ] as $required
        | . as $records
        | ($records | map(select(.event == "diagnostic"))) as $stages
        | ($records | map(select(.event == "input"))) as $inputs
        | ($records | all(.[];
            type == "object"
            and ((.event == "diagnostic"
                and .mode == "brightness-zero"
                and (.candidate == null or .candidate == "")
                and .status == "pass"
                and (.stage | type == "string"))
                and (if .stage == "brightness-zero-attestation"
                     then ((.brightness_attestation | type) == "string"
                           and .brightness_attestation == "BRIGHTNESS_100_OBSERVED")
                     else (has("brightness_attestation") | not)
                     end)
              or (.event == "input"
                and .mode == "brightness-zero"
                and (.candidate == null or .candidate == "")
                and (.stage | type == "string")
                and .status == "pass"
                and (.phase | type == "string")
                and ((.phase as $phase | ["pre-ready", "baseline", "zero-write-overlap", "zero-state", "restore-overlap", "recovery", "trailing"] | index($phase)) != null)
                and .phase != "trailing"
                and (.sequence | type == "number" and floor == . and . > 0)
                and (.boundary | type == "number" and floor == . and . > 0)
                and (.decoded | type == "boolean")
                and (.malformed | type == "boolean")
                and (if .decoded
                     then (.wire_index | type == "number" and floor == . and . >= 0 and . <= 255)
                     else (.wire_index == null)
                     end)
                and (.marker | type == "string")
                and ((.marker as $marker | ["button", "encoder", "unknown"] | index($marker)) != null)
                and (.action | type == "string")
                and ((.action as $action | ["released", "pressed", "rotated-left", "rotated-right", "unknown"] | index($action)) != null)
                and (.classification | type == "string")
                and ((.classification as $classification | ["expected", "stale", "duplicate", "malformed", "wrong-input", "write-overlap", "non-input", "trailing"] | index($classification)) != null)
                and .classification != "trailing"
                and (has("brightness_attestation") | not)))
            and ((keys - ["event", "mode", "candidate", "stage", "status", "input_class", "wire_index", "marker", "action", "command", "display", "detail", "sequence", "phase", "decoded", "malformed", "classification", "boundary", "brightness_attestation"]) | length == 0)
        ))
        and ($stages | length == ($required | length))
        and ($stages | map(.stage) == $required)
        and ($stages[0].boundary == null or $stages[0].boundary == 0)
        and ($stages[1].boundary | type == "number")
        and ($stages[1].boundary > 0)
        and ($stages[2].boundary | type == "number")
        and ($stages[2].boundary > $stages[1].boundary)
        and ($stages[3].boundary | type == "number")
        and ($stages[3].boundary > $stages[2].boundary)
        and ($stages[4].boundary | type == "number")
        and ($stages[4].boundary > $stages[3].boundary)
        and ($stages[5].boundary | type == "number")
        and ($stages[5].boundary > $stages[4].boundary)
        and ($stages[6].boundary | type == "number")
        and ($stages[6].boundary > $stages[5].boundary)
        and ($inputs
            | reduce .[] as $input ({ok: true, last: 0};
                if .ok and ($input.sequence > .last) and ($input.boundary == $input.sequence)
                then {ok: true, last: $input.sequence}
                else {ok: false, last: .last}
                end)
            | .ok)
    '

    if command -v jq >/dev/null 2>&1; then
        local unique_keys_filter='[([.] + [inputs])[] | select(length == 2 and (.[0] | length > 0)) | (.[0] | tojson)] | group_by(.) | all(length == 1)'
        local observation_line
        while IFS= read -r observation_line; do
            if ! print -r -- "$observation_line" | command jq --stream --exit-status "$unique_keys_filter" >/dev/null 2>&1; then
                return 1
            fi
        done < "$archive_file"
        command jq --slurp --exit-status "$jq_filter" "$archive_file" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        command python3 - "$archive_file" <<'PY'
import json
import sys

required = [
    "normal-startup",
    "brightness-zero-baseline",
    "brightness-zero-write",
    "brightness-zero-attestation",
    "brightness-restore",
    "brightness-zero-matrix",
    "brightness-zero-recovery",
]
allowed_keys = {
    "event",
    "mode",
    "candidate",
    "stage",
    "status",
    "input_class",
    "wire_index",
    "marker",
    "action",
    "command",
    "display",
    "detail",
    "sequence",
    "phase",
    "decoded",
    "malformed",
    "classification",
    "boundary",
    "brightness_attestation",
}
input_phases = {
    "pre-ready",
    "baseline",
    "zero-write-overlap",
    "zero-state",
    "restore-overlap",
    "recovery",
    "trailing",
}
input_markers = {"button", "encoder", "unknown"}
input_actions = {"released", "pressed", "rotated-left", "rotated-right", "unknown"}
input_classifications = {
    "expected",
    "stale",
    "duplicate",
    "malformed",
    "wrong-input",
    "write-overlap",
    "non-input",
    "trailing",
}

def unique_object_pairs(pairs):
    observation = {}
    for key, value in pairs:
        if key in observation:
            raise ValueError
        observation[key] = value
    return observation

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        observations = [json.loads(line, object_pairs_hook=unique_object_pairs) for line in stream]
    if not observations or len(observations) > 64:
        raise ValueError
    stages = [observation for observation in observations if isinstance(observation, dict) and observation.get("event") == "diagnostic"]
    if len(stages) != len(required):
        raise ValueError
    inputs = []
    for observation in observations:
        if not isinstance(observation, dict):
            raise ValueError
        if set(observation) - allowed_keys:
            raise ValueError
        if observation.get("event") == "diagnostic":
            if observation.get("mode") != "brightness-zero":
                raise ValueError
            if observation.get("candidate") not in (None, ""):
                raise ValueError
            if observation.get("status") != "pass":
                raise ValueError
            if not isinstance(observation.get("stage"), str):
                raise ValueError
            if observation["stage"] == "brightness-zero-attestation":
                if observation.get("brightness_attestation") != "BRIGHTNESS_100_OBSERVED":
                    raise ValueError
            elif "brightness_attestation" in observation:
                raise ValueError
            continue
        if observation.get("event") != "input":
            raise ValueError
        if observation.get("mode") != "brightness-zero":
            raise ValueError
        if observation.get("candidate") not in (None, ""):
            raise ValueError
        if not isinstance(observation.get("stage"), str):
            raise ValueError
        if observation.get("phase") not in input_phases:
            raise ValueError
        if observation.get("status") != "pass" or observation.get("phase") == "trailing":
            raise ValueError
        if not isinstance(observation.get("sequence"), int) or isinstance(observation.get("sequence"), bool) or observation["sequence"] <= 0:
            raise ValueError
        if not isinstance(observation.get("boundary"), int) or isinstance(observation.get("boundary"), bool) or observation["boundary"] <= 0:
            raise ValueError
        if observation["boundary"] != observation["sequence"]:
            raise ValueError
        if not isinstance(observation.get("decoded"), bool) or not isinstance(observation.get("malformed"), bool):
            raise ValueError
        if observation.get("marker") not in input_markers or observation.get("action") not in input_actions:
            raise ValueError
        if observation.get("classification") not in input_classifications:
            raise ValueError
        if observation.get("classification") == "trailing":
            raise ValueError
        if "brightness_attestation" in observation:
            raise ValueError
        if observation["decoded"] and (not isinstance(observation.get("wire_index"), int) or isinstance(observation.get("wire_index"), bool) or not 0 <= observation["wire_index"] <= 255):
            raise ValueError
        if not observation["decoded"] and observation.get("wire_index") is not None:
            raise ValueError
        inputs.append(observation)
    if [observation["stage"] for observation in stages] != required:
        raise ValueError
    boundaries = [observation.get("boundary", 0) for observation in stages]
    if boundaries[0] != 0 or any(
        not isinstance(boundary, int) or boundary <= 0
        for boundary in boundaries[1:]
    ):
        raise ValueError
    if any(left >= right for left, right in zip(boundaries[1:], boundaries[2:])):
        raise ValueError
    sequences = [observation["sequence"] for observation in inputs]
    if any(left >= right for left, right in zip(sequences, sequences[1:])):
        raise ValueError
except (OSError, ValueError, TypeError, json.JSONDecodeError, KeyError, IndexError):
    raise SystemExit(1)
raise SystemExit(0)
PY
        return $?
    fi
    if command -v ruby >/dev/null 2>&1; then
        command ruby -rjson - "$archive_file" <<'RUBY'
required = [
  "normal-startup",
  "brightness-zero-baseline",
  "brightness-zero-write",
  "brightness-zero-attestation",
  "brightness-restore",
  "brightness-zero-matrix",
  "brightness-zero-recovery"
]
allowed_keys = %w[event mode candidate stage status input_class wire_index marker action command display detail sequence phase decoded malformed classification boundary brightness_attestation]
input_phases = %w[pre-ready baseline zero-write-overlap zero-state restore-overlap recovery trailing]
input_markers = %w[button encoder unknown]
input_actions = %w[released pressed rotated-left rotated-right unknown]
input_classifications = %w[expected stale duplicate malformed wrong-input write-overlap non-input trailing]
class UniqueHash < Hash
  def []=(key, value)
    raise "duplicate key" if key?(key)
    super
  end
end
begin
  observations = File.readlines(ARGV.fetch(0), chomp: true).map { |line| JSON.parse(line, object_class: UniqueHash) }
  raise unless observations.any? && observations.length <= 64
  stages = observations.select { |observation| observation.is_a?(Hash) && observation["event"] == "diagnostic" }
  raise unless stages.length == required.length
  inputs = []
  observations.each do |observation|
    raise unless observation.is_a?(Hash)
    raise unless (observation.keys - allowed_keys).empty?
    if observation["event"] == "diagnostic"
      raise unless observation["mode"] == "brightness-zero"
      raise unless [nil, ""].include?(observation["candidate"])
      raise unless observation["status"] == "pass"
      raise unless observation["stage"].is_a?(String)
      if observation["stage"] == "brightness-zero-attestation"
        raise unless observation["brightness_attestation"] == "BRIGHTNESS_100_OBSERVED"
      else
        raise unless !observation.key?("brightness_attestation")
      end
      next
    end
    raise unless observation["event"] == "input"
    raise unless observation["mode"] == "brightness-zero"
    raise unless [nil, ""].include?(observation["candidate"])
    raise unless observation["stage"].is_a?(String)
    raise unless input_phases.include?(observation["phase"])
    raise unless observation["status"] == "pass" && observation["phase"] != "trailing"
    raise unless observation["sequence"].is_a?(Integer) && observation["sequence"] > 0
    raise unless observation["boundary"].is_a?(Integer) && observation["boundary"] > 0
    raise unless observation["boundary"] == observation["sequence"]
    raise unless [true, false].include?(observation["decoded"])
    raise unless [true, false].include?(observation["malformed"])
    raise unless input_markers.include?(observation["marker"])
    raise unless input_actions.include?(observation["action"])
    raise unless input_classifications.include?(observation["classification"])
    raise unless observation["classification"] != "trailing"
    raise unless !observation.key?("brightness_attestation")
    if observation["decoded"]
      raise unless observation["wire_index"].is_a?(Integer) && observation["wire_index"].between?(0, 255)
    elsif !observation["wire_index"].nil?
      raise
    end
    inputs << observation
  end
  raise unless stages.map { |observation| observation["stage"] } == required
  boundaries = stages.map { |observation| observation.fetch("boundary", 0) }
  raise unless boundaries[0] == 0
  raise unless boundaries[1..].all? { |boundary| boundary.is_a?(Integer) && boundary.positive? }
  raise unless boundaries.each_cons(2).all? { |left, right| left < right }
  sequences = inputs.map { |observation| observation["sequence"] }
  raise unless sequences.each_cons(2).all? { |left, right| left < right }
rescue StandardError
  exit 1
end
exit 0
RUBY
        return $?
    fi
    return 1
}

diagnostic_keepalive_timing_contract() {
    local archive_file="$1"
    local contract

    if [[ ! -s "$archive_file" ]]; then
        return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        contract="$(command jq --slurp --raw-output '
            [ .[] | select(type == "object" and has("timing_contract")) | .timing_contract ] as $contracts
            | if ($contracts | length) == 0 then "absent"
              elif ($contracts | length) == 4 and all($contracts[]; . == "k1-50-v1") then "k1-50-v1"
              else "invalid"
              end
        ' "$archive_file")" || return 1
    elif command -v python3 >/dev/null 2>&1; then
        contract="$(command python3 - "$archive_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        records = [json.loads(line) for line in stream]
    contracts = [record["timing_contract"] for record in records if isinstance(record, dict) and "timing_contract" in record]
    if not contracts:
        print("absent")
    elif len(contracts) == 4 and all(value == "k1-50-v1" for value in contracts):
        print("k1-50-v1")
    else:
        print("invalid")
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
    raise SystemExit(1)
PY
        )" || return 1
    elif command -v ruby >/dev/null 2>&1; then
        contract="$(command ruby -rjson - "$archive_file" <<'RUBY'
begin
  records = File.readlines(ARGV.fetch(0), chomp: true).map { |line| JSON.parse(line) }
  contracts = records.select { |record| record.is_a?(Hash) && record.key?("timing_contract") }.map { |record| record["timing_contract"] }
  if contracts.empty?
    puts "absent"
  elsif contracts.length == 4 && contracts.all? { |value| value == "k1-50-v1" }
    puts "k1-50-v1"
  else
    puts "invalid"
  end
rescue StandardError
  exit 1
end
RUBY
        )" || return 1
    else
        return 1
    fi

    case "$contract" in
        absent|k1-50-v1) print -r -- "$contract" ;;
        *) return 1 ;;
    esac
}

diagnostic_validate_keepalive_observation_archive() {
    local archive_file="$1"
    local contract

    contract="$(diagnostic_keepalive_timing_contract "$archive_file")" || return 1
    case "$contract" in
        absent) diagnostic_validate_keepalive_observation_archive_legacy "$archive_file" ;;
        k1-50-v1) diagnostic_validate_keepalive_observation_archive_k150 "$archive_file" ;;
        *) return 1 ;;
    esac
}

diagnostic_validate_keepalive_json_number_spellings() {
    local archive_file="$1"
    local jq_filter='
        def without_json_strings:
            reduce (explode[]) as $code
                ({inside: false, escaped: false, output: ""};
                 ($code | [.] | implode) as $char
                 | if .inside then
                     if .escaped then .escaped = false
                     elif $char == "\\" then .escaped = true
                     elif $char == "\"" then .inside = false
                     else .
                     end
                   elif $char == "\"" then .inside = true
                   else .output += $char
                   end)
                | .output;
        [split("\n")[]
            | select(length > 0)
            | without_json_strings
            | test("(^|[^0-9])-?(0|[1-9][0-9]*)(\\\\.[0-9]+|[eE][+-]?[0-9]+)([^0-9]|$)")]
        | any
        | not
    '
    command jq --raw-input --slurp --exit-status "$jq_filter" "$archive_file" >/dev/null 2>&1
}

diagnostic_validate_keepalive_observation_archive_legacy() {
    local archive_file="$1"
    local -i bytes
    local -i lines
    local jq_filter

    if [[ ! -s "$archive_file" ]]; then
        return 1
    fi
    bytes="$(wc -c < "$archive_file")" || return 1
    lines="$(wc -l < "$archive_file")" || return 1
    if (( bytes <= 0 || bytes > 262144 || lines < 14 || lines > 64 )); then
        return 1
    fi

    jq_filter='
        def exact_keys($expected): ((keys_unsorted | sort) == ($expected | sort));
        def json_integer: type == "number" and (tostring | test("^-?(0|[1-9][0-9]*)$"));
        def positive_integer: json_integer and . > 0;
        def nonnegative_integer: json_integer and . >= 0;
        def input_keys: ["event", "mode", "stage", "status", "input_class", "wire_index", "marker", "action", "detail", "sequence", "decoded", "malformed", "classification", "boundary", "input_elapsed_ns"];
        def decoded_input_keys: ["event", "mode", "stage", "status", "wire_index", "marker", "action", "detail", "sequence", "decoded", "malformed", "classification", "boundary", "input_elapsed_ns"];
        def nondecoded_input_keys: ["event", "mode", "stage", "status", "marker", "action", "detail", "sequence", "decoded", "malformed", "classification", "boundary", "input_elapsed_ns"];
        def valid_input_shape:
            type == "object"
            and .event == "input"
            and .mode == "keepalive-prevention"
            and .stage == "keepalive-prevention-input"
            and .status == "pass"
            and (.detail | type == "string")
            and (.sequence | positive_integer)
            and (.boundary == .sequence)
            and (.decoded | type == "boolean")
            and (.malformed | type == "boolean")
            and (if .decoded then .malformed == false else true end)
            and ((.marker as $marker | ["button", "encoder", "unknown"] | index($marker)) != null)
            and ((.action as $action | ["released", "pressed", "rotated-left", "rotated-right", "unknown"] | index($action)) != null)
            and (.input_elapsed_ns | positive_integer)
            and (if .decoded
                then ((exact_keys(input_keys) and (.input_class as $class | ["square", "wide", "physical-button", "encoder"] | index($class)) != null)
                    or exact_keys(decoded_input_keys))
                    and (.wire_index | json_integer and . >= 0 and . <= 255)
                else exact_keys(nondecoded_input_keys)
                    and .marker == "unknown"
                    and .action == "unknown"
                end);
        def diagnostic_base($stage):
            exact_keys(["event", "mode", "stage", "status", "detail"])
            and .event == "diagnostic"
            and .mode == "keepalive-prevention"
            and .stage == $stage
            and .status == "pass"
            and (.detail | type == "string");
        def terminal_stage($stage; $boundary):
            exact_keys(["event", "mode", "stage", "status", "detail", "boundary"])
            and .event == "diagnostic"
            and .mode == "keepalive-prevention"
            and .stage == $stage
            and .status == "pass"
            and (.detail | type == "string")
            and .boundary == $boundary;
        def final_input($action; $cue_start; $window_close):
            valid_input_shape
            and exact_keys(input_keys)
            and .input_class == "square"
            and .wire_index == 0
            and .marker == "button"
            and .action == $action
            and .decoded == true
            and .malformed == false
            and .classification == "observed"
            and .input_elapsed_ns >= $cue_start
            and .input_elapsed_ns <= $window_close;
        def pre_cue_input($cue_start):
            valid_input_shape
            and .classification == "pre-cue"
            and .input_elapsed_ns < $cue_start;
        def post_window_input($planned_close; $actual_stop):
            valid_input_shape
            and .classification == "post-window"
            and .input_elapsed_ns > $planned_close
            and .input_elapsed_ns <= $actual_stop;
        def ordered_sequences:
            . as $items
            | [range(1; ($items | length)) | ($items[. - 1].sequence < $items[.].sequence)]
            | all;
        def ordered_input_elapsed:
            . as $items
            | [range(1; ($items | length)) | ($items[. - 1].input_elapsed_ns <= $items[.].input_elapsed_ns)]
            | all;
        def valid_middle($records; $endpoint_index; $cue_start; $window_close; $actual_stop):
            ($records[10:$endpoint_index]) as $middle
            | [range(0; (($middle | length) - 1)) as $split
                | (($middle[:$split] | map(pre_cue_input($cue_start)) | all)
                    and ($middle[$split] | final_input("pressed"; $cue_start; $window_close))
                    and ($middle[$split + 1] | final_input("released"; $cue_start; $window_close))
                    and ($middle[$split + 1].sequence == ($middle[$split].sequence + 1))
                    and ($middle[$split + 1].input_elapsed_ns >= $middle[$split].input_elapsed_ns)
                    and ($middle[($split + 2):] | map(post_window_input($window_close; $actual_stop)) | all)
                    and ($middle | ordered_sequences)
                    and ($middle | ordered_input_elapsed))] | any;
        . as $records
        | 4 as $boundary_count
        | (($records | length) - 2) as $endpoint_index
        | $records[9] as $cue
        | $records[$endpoint_index] as $endpoint
        | (($records | length) >= 14 and ($records | length) <= 64)
        and ($records[0] | diagnostic_base("keepalive-prevention-same-process-preflight"))
        and ($records[1] | diagnostic_base("normal-startup"))
        and ($records[2] | diagnostic_base("keepalive-prevention-start"))
        and ([range(0; $boundary_count) as $index
            | $records[3 + $index]
            | exact_keys(["event", "mode", "stage", "status", "command", "detail", "boundary"])
              and .event == "diagnostic"
              and .mode == "keepalive-prevention"
              and .stage == "keepalive-prevention-boundary"
              and .status == "pass"
              and .command == "enable-input-stream"
              and (.detail | type == "string")
              and .boundary == ($index + 1)] | all)
        and ($records[3 + $boundary_count] | terminal_stage("keepalive-prevention-schedule"; $boundary_count))
        and ($records[8] | exact_keys(["event", "mode", "stage", "status", "detail", "classification", "boundary"]))
        and $records[8].event == "diagnostic"
        and $records[8].mode == "keepalive-prevention"
        and $records[8].stage == "keepalive-prevention-capture-health"
        and $records[8].status == "pass"
        and ($records[8].detail | type == "string")
        and $records[8].classification == "healthy"
        and $records[8].boundary == 4
        and ($cue | exact_keys(["event", "mode", "stage", "status", "detail", "boundary", "cue_start_elapsed_ns", "cue_completion_elapsed_ns", "cue_duration_ns"]))
        and $cue.event == "diagnostic"
        and $cue.mode == "keepalive-prevention"
        and $cue.stage == "keepalive-prevention-endpoint-cue"
        and $cue.status == "pass"
        and ($cue.detail | type == "string")
        and $cue.boundary == 4
        and ($cue.cue_start_elapsed_ns | positive_integer)
        and ($cue.cue_completion_elapsed_ns | positive_integer)
        and ($cue.cue_duration_ns | nonnegative_integer)
        and $cue.cue_completion_elapsed_ns == ($cue.cue_start_elapsed_ns + $cue.cue_duration_ns)
        and $cue.cue_duration_ns <= 12000000000
        and ($endpoint | exact_keys(["event", "mode", "stage", "status", "detail", "boundary", "attestation", "cue_completion_elapsed_ns", "window_start_elapsed_ns", "planned_close_elapsed_ns", "actual_timer_wake_elapsed_ns", "actual_capture_stop_elapsed_ns", "window_duration_ns"]))
        and $endpoint.event == "diagnostic"
        and $endpoint.mode == "keepalive-prevention"
        and $endpoint.stage == "keepalive-prevention-final-verification"
        and $endpoint.status == "pass"
        and ($endpoint.detail | type == "string")
        and $endpoint.boundary == 4
        and $endpoint.attestation == "ACTIVE_AT_CUE"
        and ($endpoint.cue_completion_elapsed_ns | positive_integer)
        and ($endpoint.window_start_elapsed_ns | positive_integer)
        and ($endpoint.planned_close_elapsed_ns | positive_integer)
        and ($endpoint.actual_timer_wake_elapsed_ns | positive_integer)
        and ($endpoint.actual_capture_stop_elapsed_ns | positive_integer)
        and ($endpoint.window_duration_ns | positive_integer)
        and $endpoint.cue_completion_elapsed_ns == $cue.cue_completion_elapsed_ns
        and $endpoint.window_start_elapsed_ns == $cue.cue_start_elapsed_ns
        and $endpoint.planned_close_elapsed_ns == ($cue.cue_completion_elapsed_ns + 5000000000)
        and $endpoint.window_duration_ns == ($endpoint.planned_close_elapsed_ns - $endpoint.window_start_elapsed_ns)
        and $endpoint.actual_timer_wake_elapsed_ns >= $endpoint.planned_close_elapsed_ns
        and $endpoint.actual_timer_wake_elapsed_ns <= ($endpoint.planned_close_elapsed_ns + 250000000)
        and $endpoint.actual_capture_stop_elapsed_ns >= $endpoint.actual_timer_wake_elapsed_ns
        and $endpoint.actual_capture_stop_elapsed_ns <= ($endpoint.planned_close_elapsed_ns + 250000000)
        and valid_middle($records; $endpoint_index; $endpoint.window_start_elapsed_ns; $endpoint.planned_close_elapsed_ns; $endpoint.actual_capture_stop_elapsed_ns)
        and ($records[$endpoint_index + 1] | terminal_stage("keepalive-prevention-result"; $boundary_count))
    '

    if command -v jq >/dev/null 2>&1; then
        diagnostic_validate_keepalive_json_number_spellings "$archive_file" || return 1
        command jq --slurp --exit-status "$jq_filter" "$archive_file" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        command python3 - "$archive_file" <<'PY'
import json
import sys

diagnostic_base_keys = {"event", "mode", "stage", "status", "detail"}
boundary_keys = diagnostic_base_keys | {"command", "boundary"}
terminal_keys = diagnostic_base_keys | {"boundary"}
health_keys = diagnostic_base_keys | {"classification", "boundary"}
cue_keys = diagnostic_base_keys | {"boundary", "cue_start_elapsed_ns", "cue_completion_elapsed_ns", "cue_duration_ns"}
endpoint_keys = diagnostic_base_keys | {"boundary", "attestation", "cue_completion_elapsed_ns", "window_start_elapsed_ns", "planned_close_elapsed_ns", "actual_timer_wake_elapsed_ns", "actual_capture_stop_elapsed_ns", "window_duration_ns"}
input_keys = {
    "event",
    "mode",
    "stage",
    "status",
    "input_class",
    "wire_index",
    "marker",
    "action",
    "detail",
    "sequence",
    "decoded",
    "malformed",
    "classification",
    "boundary",
    "input_elapsed_ns",
}

def positive_integer(value):
    return type(value) is int and value > 0

def valid_input_shape(record):
    if not isinstance(record, dict):
        return False
    if (
        record.get("event") != "input"
        or record.get("mode") != "keepalive-prevention"
        or record.get("stage") != "keepalive-prevention-input"
        or record.get("status") != "pass"
        or not isinstance(record.get("detail"), str)
        or not positive_integer(record.get("sequence"))
        or record.get("boundary") != record.get("sequence")
        or type(record.get("decoded")) is not bool
        or type(record.get("malformed")) is not bool
        or record.get("marker") not in {"button", "encoder", "unknown"}
        or record.get("action") not in {"released", "pressed", "rotated-left", "rotated-right", "unknown"}
        or not positive_integer(record.get("input_elapsed_ns"))
    ):
        return False
    if record["decoded"]:
        if record["malformed"]:
            return False
        decoded_keys = input_keys - {"input_class"}
        return (
            set(record) == decoded_keys
            or (set(record) == input_keys and record.get("input_class") in {"square", "wide", "physical-button", "encoder"})
        ) and type(record.get("wire_index")) is int and 0 <= record["wire_index"] <= 255
    nondecoded_keys = input_keys - {"input_class", "wire_index"}
    return set(record) == nondecoded_keys and record["marker"] == "unknown" and record["action"] == "unknown"

def diagnostic_base(record, stage):
    return (
        isinstance(record, dict)
        and set(record) == diagnostic_base_keys
        and record["event"] == "diagnostic"
        and record["mode"] == "keepalive-prevention"
        and record["stage"] == stage
        and record["status"] == "pass"
        and isinstance(record["detail"], str)
    )

def terminal_stage(record, stage, boundary):
    return (
        isinstance(record, dict)
        and set(record) == terminal_keys
        and record["event"] == "diagnostic"
        and record["mode"] == "keepalive-prevention"
        and record["stage"] == stage
        and record["status"] == "pass"
        and isinstance(record["detail"], str)
        and record["boundary"] == boundary
    )

def final_input(record, action, cue_start, window_close):
    return (
        valid_input_shape(record)
        and set(record) == input_keys
        and record["input_class"] == "square"
        and record["wire_index"] == 0
        and record["marker"] == "button"
        and record["action"] == action
        and record["decoded"] is True
        and record["malformed"] is False
        and record["classification"] == "observed"
        and cue_start <= record["input_elapsed_ns"] <= window_close
    )

def pre_cue_input(record, cue_start):
    return valid_input_shape(record) and record["classification"] == "pre-cue" and record["input_elapsed_ns"] < cue_start

def post_window_input(record, planned_close, actual_stop):
    return valid_input_shape(record) and record["classification"] == "post-window" and planned_close < record["input_elapsed_ns"] <= actual_stop

def ordered_sequences(records):
    return all(left["sequence"] < right["sequence"] for left, right in zip(records, records[1:]))

def ordered_input_elapsed(records):
    return all(left["input_elapsed_ns"] <= right["input_elapsed_ns"] for left, right in zip(records, records[1:]))

def valid_middle(records, endpoint_index, cue_start, window_close, actual_stop):
    middle = records[10:endpoint_index]
    for split in range(len(middle) - 1):
        pre_cue = middle[:split]
        pressed = middle[split]
        released = middle[split + 1]
        post_window = middle[split + 2:]
        if (
            all(pre_cue_input(record, cue_start) for record in pre_cue)
            and final_input(pressed, "pressed", cue_start, window_close)
            and final_input(released, "released", cue_start, window_close)
            and released["sequence"] == pressed["sequence"] + 1
            and released["input_elapsed_ns"] >= pressed["input_elapsed_ns"]
            and all(post_window_input(record, window_close, actual_stop) for record in post_window)
            and ordered_sequences(middle)
            and ordered_input_elapsed(middle)
        ):
            return True
    return False

try:
    records = []
    with open(sys.argv[1], encoding="utf-8") as stream:
        for line in stream:
            record = json.loads(line)
            records.append(record)
    boundary_count = 4
    if not 14 <= len(records) <= 64:
        raise ValueError
    if not diagnostic_base(records[0], "keepalive-prevention-same-process-preflight"):
        raise ValueError
    if not diagnostic_base(records[1], "normal-startup"):
        raise ValueError
    if not diagnostic_base(records[2], "keepalive-prevention-start"):
        raise ValueError
    for index in range(boundary_count):
        record = records[3 + index]
        if not (
            isinstance(record, dict)
            and set(record) == boundary_keys
            and record["event"] == "diagnostic"
            and record["mode"] == "keepalive-prevention"
            and record["stage"] == "keepalive-prevention-boundary"
            and record["status"] == "pass"
            and record["command"] == "enable-input-stream"
            and isinstance(record["detail"], str)
            and record["boundary"] == index + 1
        ):
            raise ValueError
    if not terminal_stage(records[3 + boundary_count], "keepalive-prevention-schedule", boundary_count):
        raise ValueError
    health = records[8]
    if not (
        isinstance(health, dict)
        and set(health) == health_keys
        and health["event"] == "diagnostic"
        and health["mode"] == "keepalive-prevention"
        and health["stage"] == "keepalive-prevention-capture-health"
        and health["status"] == "pass"
        and isinstance(health["detail"], str)
        and health["classification"] == "healthy"
        and health["boundary"] == 4
    ):
        raise ValueError
    cue = records[9]
    if not (
        isinstance(cue, dict)
        and set(cue) == cue_keys
        and cue["event"] == "diagnostic"
        and cue["mode"] == "keepalive-prevention"
        and cue["stage"] == "keepalive-prevention-endpoint-cue"
        and cue["status"] == "pass"
        and isinstance(cue["detail"], str)
        and cue["boundary"] == 4
        and positive_integer(cue["cue_start_elapsed_ns"])
        and positive_integer(cue["cue_completion_elapsed_ns"])
        and type(cue["cue_duration_ns"]) is int and cue["cue_duration_ns"] >= 0
        and cue["cue_completion_elapsed_ns"] == cue["cue_start_elapsed_ns"] + cue["cue_duration_ns"]
        and cue["cue_duration_ns"] <= 12000000000
    ):
        raise ValueError
    endpoint_index = len(records) - 2
    endpoint = records[endpoint_index]
    if not (
        isinstance(endpoint, dict)
        and set(endpoint) == endpoint_keys
        and endpoint["event"] == "diagnostic"
        and endpoint["mode"] == "keepalive-prevention"
        and endpoint["stage"] == "keepalive-prevention-final-verification"
        and endpoint["status"] == "pass"
        and isinstance(endpoint["detail"], str)
        and endpoint["boundary"] == 4
        and endpoint["attestation"] == "ACTIVE_AT_CUE"
        and positive_integer(endpoint["cue_completion_elapsed_ns"])
        and positive_integer(endpoint["window_start_elapsed_ns"])
        and positive_integer(endpoint["planned_close_elapsed_ns"])
        and positive_integer(endpoint["actual_timer_wake_elapsed_ns"])
        and positive_integer(endpoint["actual_capture_stop_elapsed_ns"])
        and positive_integer(endpoint["window_duration_ns"])
        and endpoint["cue_completion_elapsed_ns"] == cue["cue_completion_elapsed_ns"]
        and endpoint["window_start_elapsed_ns"] == cue["cue_start_elapsed_ns"]
        and endpoint["planned_close_elapsed_ns"] == cue["cue_completion_elapsed_ns"] + 5000000000
        and endpoint["window_duration_ns"] == endpoint["planned_close_elapsed_ns"] - endpoint["window_start_elapsed_ns"]
        and endpoint["planned_close_elapsed_ns"] <= endpoint["actual_timer_wake_elapsed_ns"] <= endpoint["planned_close_elapsed_ns"] + 250000000
        and endpoint["actual_timer_wake_elapsed_ns"] <= endpoint["actual_capture_stop_elapsed_ns"] <= endpoint["planned_close_elapsed_ns"] + 250000000
    ):
        raise ValueError
    if not valid_middle(records, endpoint_index, endpoint["window_start_elapsed_ns"], endpoint["planned_close_elapsed_ns"], endpoint["actual_capture_stop_elapsed_ns"]):
        raise ValueError
    if not terminal_stage(records[endpoint_index + 1], "keepalive-prevention-result", boundary_count):
        raise ValueError
except (OSError, ValueError, TypeError, json.JSONDecodeError, KeyError, IndexError):
    raise SystemExit(1)
raise SystemExit(0)
PY
        return $?
    fi
    if command -v ruby >/dev/null 2>&1; then
        command ruby -rjson - "$archive_file" <<'RUBY'
diagnostic_base_keys = %w[event mode stage status detail].sort
boundary_keys = (diagnostic_base_keys + %w[command boundary]).sort
terminal_keys = (diagnostic_base_keys + %w[boundary]).sort
health_keys = (diagnostic_base_keys + %w[classification boundary]).sort
cue_keys = (diagnostic_base_keys + %w[boundary cue_start_elapsed_ns cue_completion_elapsed_ns cue_duration_ns]).sort
endpoint_keys = (diagnostic_base_keys + %w[boundary attestation cue_completion_elapsed_ns window_start_elapsed_ns planned_close_elapsed_ns actual_timer_wake_elapsed_ns actual_capture_stop_elapsed_ns window_duration_ns]).sort
input_keys = %w[event mode stage status input_class wire_index marker action detail sequence decoded malformed classification boundary input_elapsed_ns].sort

diagnostic_base = lambda do |record, stage|
  record.is_a?(Hash) &&
    record.keys.sort == diagnostic_base_keys &&
    record["event"] == "diagnostic" &&
    record["mode"] == "keepalive-prevention" &&
    record["stage"] == stage &&
    record["status"] == "pass" &&
    record["detail"].is_a?(String)
end

terminal_stage = lambda do |record, stage, boundary|
  record.is_a?(Hash) &&
    record.keys.sort == terminal_keys &&
    record["event"] == "diagnostic" &&
    record["mode"] == "keepalive-prevention" &&
    record["stage"] == stage &&
    record["status"] == "pass" &&
    record["detail"].is_a?(String) &&
    record["boundary"] == boundary
end

positive_integer = ->(value) { value.is_a?(Integer) && value.positive? }

valid_input_shape = lambda do |record|
  next false unless record.is_a?(Hash) && record["event"] == "input" && record["mode"] == "keepalive-prevention" &&
    record["stage"] == "keepalive-prevention-input" && record["status"] == "pass" && record["detail"].is_a?(String) &&
    positive_integer.call(record["sequence"]) && record["boundary"] == record["sequence"] &&
    [true, false].include?(record["decoded"]) && [true, false].include?(record["malformed"]) &&
    %w[button encoder unknown].include?(record["marker"]) && %w[released pressed rotated-left rotated-right unknown].include?(record["action"]) &&
    positive_integer.call(record["input_elapsed_ns"])
  if record["decoded"]
    next false if record["malformed"]
    decoded_keys = input_keys - %w[input_class]
    keys_valid = record.keys.sort == decoded_keys.sort ||
      (record.keys.sort == input_keys && %w[square wide physical-button encoder].include?(record["input_class"]))
    keys_valid && record["wire_index"].is_a?(Integer) && record["wire_index"].between?(0, 255)
  else
    nondecoded_keys = input_keys - %w[input_class wire_index]
    record.keys.sort == nondecoded_keys.sort && record["marker"] == "unknown" && record["action"] == "unknown"
  end
end

final_input = lambda do |record, action, cue_start, window_close|
  valid_input_shape.call(record) &&
    record.keys.sort == input_keys &&
    record["input_class"] == "square" &&
    record["wire_index"] == 0 &&
    record["marker"] == "button" &&
    record["action"] == action &&
    record["decoded"] == true &&
    record["malformed"] == false &&
    record["classification"] == "observed" &&
    record["input_elapsed_ns"] >= cue_start &&
    record["input_elapsed_ns"] <= window_close
end

pre_cue_input = lambda do |record, cue_start|
  valid_input_shape.call(record) && record["classification"] == "pre-cue" && record["input_elapsed_ns"] < cue_start
end

post_window_input = lambda do |record, planned_close, actual_stop|
  valid_input_shape.call(record) && record["classification"] == "post-window" && record["input_elapsed_ns"] > planned_close && record["input_elapsed_ns"] <= actual_stop
end

ordered_sequences = lambda do |records|
  records.each_cons(2).all? { |left, right| left["sequence"] < right["sequence"] }
end

ordered_input_elapsed = lambda do |records|
  records.each_cons(2).all? { |left, right| left["input_elapsed_ns"] <= right["input_elapsed_ns"] }
end

valid_middle = lambda do |records, endpoint_index, cue_start, window_close, actual_stop|
  middle = records[10...endpoint_index]
  (0..(middle.length - 2)).any? do |split|
    pre_cue = middle[0...split]
    pressed = middle[split]
    released = middle[split + 1]
    post_window = middle[(split + 2)..]
    pre_cue.all? { |record| pre_cue_input.call(record, cue_start) } &&
      final_input.call(pressed, "pressed", cue_start, window_close) &&
      final_input.call(released, "released", cue_start, window_close) &&
      released["sequence"] == pressed["sequence"] + 1 &&
      released["input_elapsed_ns"] >= pressed["input_elapsed_ns"] &&
      post_window.all? { |record| post_window_input.call(record, window_close, actual_stop) } &&
      ordered_sequences.call(middle) &&
      ordered_input_elapsed.call(middle)
  end
end

begin
  records = File.readlines(ARGV.fetch(0), chomp: true).map { |line| JSON.parse(line) }
  boundary_count = 4
  raise unless records.length.between?(14, 64)
  raise unless diagnostic_base.call(records[0], "keepalive-prevention-same-process-preflight")
  raise unless diagnostic_base.call(records[1], "normal-startup")
  raise unless diagnostic_base.call(records[2], "keepalive-prevention-start")
  boundary_count.times do |index|
    record = records[3 + index]
    raise unless record.is_a?(Hash) &&
      record.keys.sort == boundary_keys &&
      record["event"] == "diagnostic" &&
      record["mode"] == "keepalive-prevention" &&
      record["stage"] == "keepalive-prevention-boundary" &&
      record["status"] == "pass" &&
      record["command"] == "enable-input-stream" &&
      record["detail"].is_a?(String) &&
      record["boundary"] == index + 1
  end
  raise unless terminal_stage.call(records[3 + boundary_count], "keepalive-prevention-schedule", boundary_count)
  health = records[8]
  raise unless health.is_a?(Hash) && health.keys.sort == health_keys && health["event"] == "diagnostic" &&
    health["mode"] == "keepalive-prevention" && health["stage"] == "keepalive-prevention-capture-health" &&
    health["status"] == "pass" && health["detail"].is_a?(String) && health["classification"] == "healthy" && health["boundary"] == 4
  cue = records[9]
  raise unless cue.is_a?(Hash) && cue.keys.sort == cue_keys && cue["event"] == "diagnostic" &&
    cue["mode"] == "keepalive-prevention" && cue["stage"] == "keepalive-prevention-endpoint-cue" &&
    cue["status"] == "pass" && cue["detail"].is_a?(String) && cue["boundary"] == 4 &&
    positive_integer.call(cue["cue_start_elapsed_ns"]) && positive_integer.call(cue["cue_completion_elapsed_ns"]) &&
    cue["cue_duration_ns"].is_a?(Integer) && cue["cue_duration_ns"] >= 0 && cue["cue_completion_elapsed_ns"] == cue["cue_start_elapsed_ns"] + cue["cue_duration_ns"] &&
    cue["cue_duration_ns"] <= 12000000000
  endpoint_index = records.length - 2
  endpoint = records[endpoint_index]
  raise unless endpoint.is_a?(Hash) && endpoint.keys.sort == endpoint_keys && endpoint["event"] == "diagnostic" &&
    endpoint["mode"] == "keepalive-prevention" && endpoint["stage"] == "keepalive-prevention-final-verification" &&
    endpoint["status"] == "pass" && endpoint["detail"].is_a?(String) && endpoint["boundary"] == 4 &&
    endpoint["attestation"] == "ACTIVE_AT_CUE" && positive_integer.call(endpoint["cue_completion_elapsed_ns"]) &&
    positive_integer.call(endpoint["window_start_elapsed_ns"]) && positive_integer.call(endpoint["planned_close_elapsed_ns"]) &&
    positive_integer.call(endpoint["actual_timer_wake_elapsed_ns"]) && positive_integer.call(endpoint["actual_capture_stop_elapsed_ns"]) &&
    positive_integer.call(endpoint["window_duration_ns"]) && endpoint["cue_completion_elapsed_ns"] == cue["cue_completion_elapsed_ns"] &&
    endpoint["window_start_elapsed_ns"] == cue["cue_start_elapsed_ns"] &&
    endpoint["planned_close_elapsed_ns"] == cue["cue_completion_elapsed_ns"] + 5000000000 &&
    endpoint["window_duration_ns"] == endpoint["planned_close_elapsed_ns"] - endpoint["window_start_elapsed_ns"] &&
    endpoint["actual_timer_wake_elapsed_ns"].between?(endpoint["planned_close_elapsed_ns"], endpoint["planned_close_elapsed_ns"] + 250000000) &&
    endpoint["actual_capture_stop_elapsed_ns"].between?(endpoint["actual_timer_wake_elapsed_ns"], endpoint["planned_close_elapsed_ns"] + 250000000)
  raise unless valid_middle.call(records, endpoint_index, endpoint["window_start_elapsed_ns"], endpoint["planned_close_elapsed_ns"], endpoint["actual_capture_stop_elapsed_ns"])
  raise unless terminal_stage.call(records[endpoint_index + 1], "keepalive-prevention-result", boundary_count)
rescue StandardError
  exit 1
end
exit 0
RUBY
        return $?
    fi
    return 1
}

diagnostic_validate_keepalive_observation_archive_k150() {
    local archive_file="$1"
    local -i bytes
    local -i lines
    local jq_filter

    if [[ ! -s "$archive_file" ]]; then
        return 1
    fi
    bytes="$(wc -c < "$archive_file")" || return 1
    lines="$(wc -l < "$archive_file")" || return 1
    if (( bytes <= 0 || bytes > 262144 || lines < 14 || lines > 64 )); then
        return 1
    fi

    jq_filter='
        def exact_keys($expected): ((keys_unsorted | sort) == ($expected | sort));
        def json_integer: type == "number" and (tostring | test("^-?(0|[1-9][0-9]*)$"));
        def positive_integer: json_integer and . > 0;
        def nonnegative_integer: json_integer and . >= 0;
        def input_keys: ["event", "mode", "stage", "status", "input_class", "wire_index", "marker", "action", "detail", "sequence", "decoded", "malformed", "classification", "boundary", "input_elapsed_ns"];
        def decoded_input_keys: ["event", "mode", "stage", "status", "wire_index", "marker", "action", "detail", "sequence", "decoded", "malformed", "classification", "boundary", "input_elapsed_ns"];
        def nondecoded_input_keys: ["event", "mode", "stage", "status", "marker", "action", "detail", "sequence", "decoded", "malformed", "classification", "boundary", "input_elapsed_ns"];
        def valid_input_shape:
            type == "object"
            and .event == "input"
            and .mode == "keepalive-prevention"
            and .stage == "keepalive-prevention-input"
            and .status == "pass"
            and (.detail | type == "string")
            and (.sequence | positive_integer)
            and (.boundary == .sequence)
            and (.decoded | type == "boolean")
            and (.malformed | type == "boolean")
            and (if .decoded then .malformed == false else true end)
            and ((.marker as $marker | ["button", "encoder", "unknown"] | index($marker)) != null)
            and ((.action as $action | ["released", "pressed", "rotated-left", "rotated-right", "unknown"] | index($action)) != null)
            and (.input_elapsed_ns | positive_integer)
            and (if .decoded
                then ((exact_keys(input_keys) and (.input_class as $class | ["square", "wide", "physical-button", "encoder"] | index($class)) != null)
                    or exact_keys(decoded_input_keys))
                    and (.wire_index | json_integer and . >= 0 and . <= 255)
                else exact_keys(nondecoded_input_keys)
                    and .marker == "unknown"
                    and .action == "unknown"
                end);
        def diagnostic_base($stage):
            exact_keys(["event", "mode", "stage", "status", "detail"])
            and .event == "diagnostic"
            and .mode == "keepalive-prevention"
            and .stage == $stage
            and .status == "pass"
            and (.detail | type == "string");
        def terminal_stage($stage; $boundary):
            exact_keys(["event", "mode", "stage", "status", "detail", "boundary"])
            and .event == "diagnostic"
            and .mode == "keepalive-prevention"
            and .stage == $stage
            and .status == "pass"
            and (.detail | type == "string")
            and .boundary == $boundary;
        def final_input($action; $cue_start; $window_close):
            valid_input_shape
            and exact_keys(input_keys)
            and .input_class == "square"
            and .wire_index == 0
            and .marker == "button"
            and .action == $action
            and .decoded == true
            and .malformed == false
            and .classification == "observed"
            and .input_elapsed_ns >= $cue_start
            and .input_elapsed_ns <= $window_close;
        def pre_cue_input($cue_start):
            valid_input_shape
            and .classification == "pre-cue"
            and .input_elapsed_ns < $cue_start;
        def post_window_input($planned_close; $actual_stop):
            valid_input_shape
            and .classification == "post-window"
            and .input_elapsed_ns > $planned_close
            and .input_elapsed_ns <= $actual_stop;
        def ordered_sequences:
            . as $items
            | [range(1; ($items | length)) | ($items[. - 1].sequence < $items[.].sequence)]
            | all;
        def ordered_input_elapsed:
            . as $items
            | [range(1; ($items | length)) | ($items[. - 1].input_elapsed_ns <= $items[.].input_elapsed_ns)]
            | all;
        def valid_middle($records; $endpoint_index; $cue_start; $window_close; $actual_stop):
            ($records[10:$endpoint_index]) as $middle
            | [range(0; (($middle | length) - 1)) as $split
                | (($middle[:$split] | map(pre_cue_input($cue_start)) | all)
                    and ($middle[$split] | final_input("pressed"; $cue_start; $window_close))
                    and ($middle[$split + 1] | final_input("released"; $cue_start; $window_close))
                    and ($middle[$split + 1].sequence == ($middle[$split].sequence + 1))
                    and ($middle[$split + 1].input_elapsed_ns >= $middle[$split].input_elapsed_ns)
                    and ($middle[($split + 2):] | map(post_window_input($window_close; $actual_stop)) | all)
                    and ($middle | ordered_sequences)
                    and ($middle | ordered_input_elapsed))] | any;
        . as $records
        | 4 as $boundary_count
        | (($records | length) - 2) as $endpoint_index
        | $records[9] as $cue
        | $records[$endpoint_index] as $endpoint
        | (($records | length) >= 14 and ($records | length) <= 64)
        and ($records[0] | diagnostic_base("keepalive-prevention-same-process-preflight"))
        and ($records[1] | diagnostic_base("normal-startup"))
        and ($records[2] | diagnostic_base("keepalive-prevention-start"))
        and ([range(0; $boundary_count) as $index
            | $records[3 + $index]
            | exact_keys(["event", "mode", "stage", "status", "command", "detail", "boundary", "timing_contract", "planned_boundary_elapsed_ns", "actual_timer_wake_elapsed_ns", "write_start_elapsed_ns", "write_completion_elapsed_ns"])
              and .event == "diagnostic"
              and .mode == "keepalive-prevention"
              and .stage == "keepalive-prevention-boundary"
              and .status == "pass"
              and .command == "enable-input-stream"
              and (.detail | type == "string")
              and .boundary == ($index + 1)
              and .timing_contract == "k1-50-v1"
              and (.planned_boundary_elapsed_ns | positive_integer)
              and .planned_boundary_elapsed_ns == (($index + 1) * 50000000000)
              and (.actual_timer_wake_elapsed_ns | positive_integer)
              and (.write_start_elapsed_ns | positive_integer)
              and (.write_completion_elapsed_ns | positive_integer)
              and .planned_boundary_elapsed_ns <= .actual_timer_wake_elapsed_ns
              and .actual_timer_wake_elapsed_ns <= .write_start_elapsed_ns
              and .write_start_elapsed_ns <= .write_completion_elapsed_ns
              and .write_completion_elapsed_ns <= (.planned_boundary_elapsed_ns + 250000000)] | all)
        and ([ $records[3:7][] | .planned_boundary_elapsed_ns, .actual_timer_wake_elapsed_ns, .write_start_elapsed_ns, .write_completion_elapsed_ns ]
            | reduce .[] as $timing ({ok: true, last: 0};
                if .ok and ($timing | positive_integer) and ($timing >= .last)
                then {ok: true, last: $timing}
                else {ok: false, last: .last}
                end)
            | .ok)
        and ($records[3 + $boundary_count] | terminal_stage("keepalive-prevention-schedule"; $boundary_count))
        and ($records[8] | exact_keys(["event", "mode", "stage", "status", "detail", "classification", "boundary"]))
        and $records[8].event == "diagnostic"
        and $records[8].mode == "keepalive-prevention"
        and $records[8].stage == "keepalive-prevention-capture-health"
        and $records[8].status == "pass"
        and ($records[8].detail | type == "string")
        and $records[8].classification == "healthy"
        and $records[8].boundary == 4
        and ($cue | exact_keys(["event", "mode", "stage", "status", "detail", "boundary", "cue_start_elapsed_ns", "cue_completion_elapsed_ns", "cue_duration_ns"]))
        and $cue.event == "diagnostic"
        and $cue.mode == "keepalive-prevention"
        and $cue.stage == "keepalive-prevention-endpoint-cue"
        and $cue.status == "pass"
        and ($cue.detail | type == "string")
        and $cue.boundary == 4
        and ($cue.cue_start_elapsed_ns | positive_integer)
        and ($cue.cue_completion_elapsed_ns | positive_integer)
        and ($cue.cue_duration_ns | nonnegative_integer)
        and $cue.cue_completion_elapsed_ns == ($cue.cue_start_elapsed_ns + $cue.cue_duration_ns)
        and $cue.cue_duration_ns <= 12000000000
        and $records[6].write_completion_elapsed_ns <= $cue.cue_start_elapsed_ns
        and ($endpoint | exact_keys(["event", "mode", "stage", "status", "detail", "boundary", "attestation", "cue_completion_elapsed_ns", "window_start_elapsed_ns", "planned_close_elapsed_ns", "actual_timer_wake_elapsed_ns", "actual_capture_stop_elapsed_ns", "window_duration_ns"]))
        and $endpoint.event == "diagnostic"
        and $endpoint.mode == "keepalive-prevention"
        and $endpoint.stage == "keepalive-prevention-final-verification"
        and $endpoint.status == "pass"
        and ($endpoint.detail | type == "string")
        and $endpoint.boundary == 4
        and $endpoint.attestation == "ACTIVE_AT_CUE"
        and ($endpoint.cue_completion_elapsed_ns | positive_integer)
        and ($endpoint.window_start_elapsed_ns | positive_integer)
        and ($endpoint.planned_close_elapsed_ns | positive_integer)
        and ($endpoint.actual_timer_wake_elapsed_ns | positive_integer)
        and ($endpoint.actual_capture_stop_elapsed_ns | positive_integer)
        and ($endpoint.window_duration_ns | positive_integer)
        and $endpoint.cue_completion_elapsed_ns == $cue.cue_completion_elapsed_ns
        and $endpoint.window_start_elapsed_ns == $cue.cue_start_elapsed_ns
        and $endpoint.planned_close_elapsed_ns == ($cue.cue_completion_elapsed_ns + 5000000000)
        and $endpoint.window_duration_ns == ($endpoint.planned_close_elapsed_ns - $endpoint.window_start_elapsed_ns)
        and $endpoint.actual_timer_wake_elapsed_ns >= $endpoint.planned_close_elapsed_ns
        and $endpoint.actual_timer_wake_elapsed_ns <= ($endpoint.planned_close_elapsed_ns + 250000000)
        and $endpoint.actual_capture_stop_elapsed_ns >= $endpoint.actual_timer_wake_elapsed_ns
        and $endpoint.actual_capture_stop_elapsed_ns <= ($endpoint.planned_close_elapsed_ns + 250000000)
        and valid_middle($records; $endpoint_index; $endpoint.window_start_elapsed_ns; $endpoint.planned_close_elapsed_ns; $endpoint.actual_capture_stop_elapsed_ns)
        and ($records[$endpoint_index + 1] | terminal_stage("keepalive-prevention-result"; $boundary_count))
    '

    if command -v jq >/dev/null 2>&1; then
        diagnostic_validate_keepalive_json_number_spellings "$archive_file" || return 1
        command jq --slurp --exit-status "$jq_filter" "$archive_file" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        command python3 - "$archive_file" <<'PY'
import json
import sys

diagnostic_base_keys = {"event", "mode", "stage", "status", "detail"}
boundary_keys = diagnostic_base_keys | {
    "command",
    "boundary",
    "timing_contract",
    "planned_boundary_elapsed_ns",
    "actual_timer_wake_elapsed_ns",
    "write_start_elapsed_ns",
    "write_completion_elapsed_ns",
}
terminal_keys = diagnostic_base_keys | {"boundary"}
health_keys = diagnostic_base_keys | {"classification", "boundary"}
cue_keys = diagnostic_base_keys | {"boundary", "cue_start_elapsed_ns", "cue_completion_elapsed_ns", "cue_duration_ns"}
endpoint_keys = diagnostic_base_keys | {"boundary", "attestation", "cue_completion_elapsed_ns", "window_start_elapsed_ns", "planned_close_elapsed_ns", "actual_timer_wake_elapsed_ns", "actual_capture_stop_elapsed_ns", "window_duration_ns"}
input_keys = {
    "event",
    "mode",
    "stage",
    "status",
    "input_class",
    "wire_index",
    "marker",
    "action",
    "detail",
    "sequence",
    "decoded",
    "malformed",
    "classification",
    "boundary",
    "input_elapsed_ns",
}

def positive_integer(value):
    return type(value) is int and value > 0

def valid_input_shape(record):
    if not isinstance(record, dict):
        return False
    if (
        record.get("event") != "input"
        or record.get("mode") != "keepalive-prevention"
        or record.get("stage") != "keepalive-prevention-input"
        or record.get("status") != "pass"
        or not isinstance(record.get("detail"), str)
        or not positive_integer(record.get("sequence"))
        or record.get("boundary") != record.get("sequence")
        or type(record.get("decoded")) is not bool
        or type(record.get("malformed")) is not bool
        or record.get("marker") not in {"button", "encoder", "unknown"}
        or record.get("action") not in {"released", "pressed", "rotated-left", "rotated-right", "unknown"}
        or not positive_integer(record.get("input_elapsed_ns"))
    ):
        return False
    if record["decoded"]:
        if record["malformed"]:
            return False
        decoded_keys = input_keys - {"input_class"}
        return (
            set(record) == decoded_keys
            or (set(record) == input_keys and record.get("input_class") in {"square", "wide", "physical-button", "encoder"})
        ) and type(record.get("wire_index")) is int and 0 <= record["wire_index"] <= 255
    nondecoded_keys = input_keys - {"input_class", "wire_index"}
    return set(record) == nondecoded_keys and record["marker"] == "unknown" and record["action"] == "unknown"

def diagnostic_base(record, stage):
    return (
        isinstance(record, dict)
        and set(record) == diagnostic_base_keys
        and record["event"] == "diagnostic"
        and record["mode"] == "keepalive-prevention"
        and record["stage"] == stage
        and record["status"] == "pass"
        and isinstance(record["detail"], str)
    )

def terminal_stage(record, stage, boundary):
    return (
        isinstance(record, dict)
        and set(record) == terminal_keys
        and record["event"] == "diagnostic"
        and record["mode"] == "keepalive-prevention"
        and record["stage"] == stage
        and record["status"] == "pass"
        and isinstance(record["detail"], str)
        and record["boundary"] == boundary
    )

def final_input(record, action, cue_start, window_close):
    return (
        valid_input_shape(record)
        and set(record) == input_keys
        and record["input_class"] == "square"
        and record["wire_index"] == 0
        and record["marker"] == "button"
        and record["action"] == action
        and record["decoded"] is True
        and record["malformed"] is False
        and record["classification"] == "observed"
        and cue_start <= record["input_elapsed_ns"] <= window_close
    )

def pre_cue_input(record, cue_start):
    return valid_input_shape(record) and record["classification"] == "pre-cue" and record["input_elapsed_ns"] < cue_start

def post_window_input(record, planned_close, actual_stop):
    return valid_input_shape(record) and record["classification"] == "post-window" and planned_close < record["input_elapsed_ns"] <= actual_stop

def ordered_sequences(records):
    return all(left["sequence"] < right["sequence"] for left, right in zip(records, records[1:]))

def ordered_input_elapsed(records):
    return all(left["input_elapsed_ns"] <= right["input_elapsed_ns"] for left, right in zip(records, records[1:]))

def valid_middle(records, endpoint_index, cue_start, window_close, actual_stop):
    middle = records[10:endpoint_index]
    for split in range(len(middle) - 1):
        pre_cue = middle[:split]
        pressed = middle[split]
        released = middle[split + 1]
        post_window = middle[split + 2:]
        if (
            all(pre_cue_input(record, cue_start) for record in pre_cue)
            and final_input(pressed, "pressed", cue_start, window_close)
            and final_input(released, "released", cue_start, window_close)
            and released["sequence"] == pressed["sequence"] + 1
            and released["input_elapsed_ns"] >= pressed["input_elapsed_ns"]
            and all(post_window_input(record, window_close, actual_stop) for record in post_window)
            and ordered_sequences(middle)
            and ordered_input_elapsed(middle)
        ):
            return True
    return False

try:
    records = []
    with open(sys.argv[1], encoding="utf-8") as stream:
        for line in stream:
            record = json.loads(line)
            records.append(record)
    boundary_count = 4
    if not 14 <= len(records) <= 64:
        raise ValueError
    if not diagnostic_base(records[0], "keepalive-prevention-same-process-preflight"):
        raise ValueError
    if not diagnostic_base(records[1], "normal-startup"):
        raise ValueError
    if not diagnostic_base(records[2], "keepalive-prevention-start"):
        raise ValueError
    boundaries = records[3:7]
    for index in range(boundary_count):
        record = boundaries[index]
        if not (
            isinstance(record, dict)
            and set(record) == boundary_keys
            and record["event"] == "diagnostic"
            and record["mode"] == "keepalive-prevention"
            and record["stage"] == "keepalive-prevention-boundary"
            and record["status"] == "pass"
            and record["command"] == "enable-input-stream"
            and isinstance(record["detail"], str)
            and record["boundary"] == index + 1
            and record["timing_contract"] == "k1-50-v1"
            and positive_integer(record["planned_boundary_elapsed_ns"])
            and record["planned_boundary_elapsed_ns"] == (index + 1) * 50000000000
            and positive_integer(record["actual_timer_wake_elapsed_ns"])
            and positive_integer(record["write_start_elapsed_ns"])
            and positive_integer(record["write_completion_elapsed_ns"])
            and record["planned_boundary_elapsed_ns"] <= record["actual_timer_wake_elapsed_ns"] <= record["write_start_elapsed_ns"] <= record["write_completion_elapsed_ns"] <= record["planned_boundary_elapsed_ns"] + 250000000
        ):
            raise ValueError
    timings = [
        timing
        for record in boundaries
        for timing in (
            record["planned_boundary_elapsed_ns"],
            record["actual_timer_wake_elapsed_ns"],
            record["write_start_elapsed_ns"],
            record["write_completion_elapsed_ns"],
        )
    ]
    if any(previous > current for previous, current in zip(timings, timings[1:])):
        raise ValueError
    if not terminal_stage(records[3 + boundary_count], "keepalive-prevention-schedule", boundary_count):
        raise ValueError
    health = records[8]
    if not (
        isinstance(health, dict)
        and set(health) == health_keys
        and health["event"] == "diagnostic"
        and health["mode"] == "keepalive-prevention"
        and health["stage"] == "keepalive-prevention-capture-health"
        and health["status"] == "pass"
        and isinstance(health["detail"], str)
        and health["classification"] == "healthy"
        and health["boundary"] == 4
    ):
        raise ValueError
    cue = records[9]
    if not (
        isinstance(cue, dict)
        and set(cue) == cue_keys
        and cue["event"] == "diagnostic"
        and cue["mode"] == "keepalive-prevention"
        and cue["stage"] == "keepalive-prevention-endpoint-cue"
        and cue["status"] == "pass"
        and isinstance(cue["detail"], str)
        and cue["boundary"] == 4
        and positive_integer(cue["cue_start_elapsed_ns"])
        and positive_integer(cue["cue_completion_elapsed_ns"])
        and type(cue["cue_duration_ns"]) is int and cue["cue_duration_ns"] >= 0
        and cue["cue_completion_elapsed_ns"] == cue["cue_start_elapsed_ns"] + cue["cue_duration_ns"]
        and cue["cue_duration_ns"] <= 12000000000
    ):
        raise ValueError
    if boundaries[3]["write_completion_elapsed_ns"] > cue["cue_start_elapsed_ns"]:
        raise ValueError
    endpoint_index = len(records) - 2
    endpoint = records[endpoint_index]
    if not (
        isinstance(endpoint, dict)
        and set(endpoint) == endpoint_keys
        and endpoint["event"] == "diagnostic"
        and endpoint["mode"] == "keepalive-prevention"
        and endpoint["stage"] == "keepalive-prevention-final-verification"
        and endpoint["status"] == "pass"
        and isinstance(endpoint["detail"], str)
        and endpoint["boundary"] == 4
        and endpoint["attestation"] == "ACTIVE_AT_CUE"
        and positive_integer(endpoint["cue_completion_elapsed_ns"])
        and positive_integer(endpoint["window_start_elapsed_ns"])
        and positive_integer(endpoint["planned_close_elapsed_ns"])
        and positive_integer(endpoint["actual_timer_wake_elapsed_ns"])
        and positive_integer(endpoint["actual_capture_stop_elapsed_ns"])
        and positive_integer(endpoint["window_duration_ns"])
        and endpoint["cue_completion_elapsed_ns"] == cue["cue_completion_elapsed_ns"]
        and endpoint["window_start_elapsed_ns"] == cue["cue_start_elapsed_ns"]
        and endpoint["planned_close_elapsed_ns"] == cue["cue_completion_elapsed_ns"] + 5000000000
        and endpoint["window_duration_ns"] == endpoint["planned_close_elapsed_ns"] - endpoint["window_start_elapsed_ns"]
        and endpoint["planned_close_elapsed_ns"] <= endpoint["actual_timer_wake_elapsed_ns"] <= endpoint["planned_close_elapsed_ns"] + 250000000
        and endpoint["actual_timer_wake_elapsed_ns"] <= endpoint["actual_capture_stop_elapsed_ns"] <= endpoint["planned_close_elapsed_ns"] + 250000000
    ):
        raise ValueError
    if not valid_middle(records, endpoint_index, endpoint["window_start_elapsed_ns"], endpoint["planned_close_elapsed_ns"], endpoint["actual_capture_stop_elapsed_ns"]):
        raise ValueError
    if not terminal_stage(records[endpoint_index + 1], "keepalive-prevention-result", boundary_count):
        raise ValueError
except (OSError, ValueError, TypeError, json.JSONDecodeError, KeyError, IndexError):
    raise SystemExit(1)
raise SystemExit(0)
PY
        return $?
    fi
    if command -v ruby >/dev/null 2>&1; then
        command ruby -rjson - "$archive_file" <<'RUBY'
diagnostic_base_keys = %w[event mode stage status detail].sort
boundary_keys = (diagnostic_base_keys + %w[command boundary timing_contract planned_boundary_elapsed_ns actual_timer_wake_elapsed_ns write_start_elapsed_ns write_completion_elapsed_ns]).sort
terminal_keys = (diagnostic_base_keys + %w[boundary]).sort
health_keys = (diagnostic_base_keys + %w[classification boundary]).sort
cue_keys = (diagnostic_base_keys + %w[boundary cue_start_elapsed_ns cue_completion_elapsed_ns cue_duration_ns]).sort
endpoint_keys = (diagnostic_base_keys + %w[boundary attestation cue_completion_elapsed_ns window_start_elapsed_ns planned_close_elapsed_ns actual_timer_wake_elapsed_ns actual_capture_stop_elapsed_ns window_duration_ns]).sort
input_keys = %w[event mode stage status input_class wire_index marker action detail sequence decoded malformed classification boundary input_elapsed_ns].sort

diagnostic_base = lambda do |record, stage|
  record.is_a?(Hash) &&
    record.keys.sort == diagnostic_base_keys &&
    record["event"] == "diagnostic" &&
    record["mode"] == "keepalive-prevention" &&
    record["stage"] == stage &&
    record["status"] == "pass" &&
    record["detail"].is_a?(String)
end

terminal_stage = lambda do |record, stage, boundary|
  record.is_a?(Hash) &&
    record.keys.sort == terminal_keys &&
    record["event"] == "diagnostic" &&
    record["mode"] == "keepalive-prevention" &&
    record["stage"] == stage &&
    record["status"] == "pass" &&
    record["detail"].is_a?(String) &&
    record["boundary"] == boundary
end

positive_integer = ->(value) { value.is_a?(Integer) && value.positive? }

valid_input_shape = lambda do |record|
  next false unless record.is_a?(Hash) && record["event"] == "input" && record["mode"] == "keepalive-prevention" &&
    record["stage"] == "keepalive-prevention-input" && record["status"] == "pass" && record["detail"].is_a?(String) &&
    positive_integer.call(record["sequence"]) && record["boundary"] == record["sequence"] &&
    [true, false].include?(record["decoded"]) && [true, false].include?(record["malformed"]) &&
    %w[button encoder unknown].include?(record["marker"]) && %w[released pressed rotated-left rotated-right unknown].include?(record["action"]) &&
    positive_integer.call(record["input_elapsed_ns"])
  if record["decoded"]
    next false if record["malformed"]
    decoded_keys = input_keys - %w[input_class]
    keys_valid = record.keys.sort == decoded_keys.sort ||
      (record.keys.sort == input_keys && %w[square wide physical-button encoder].include?(record["input_class"]))
    keys_valid && record["wire_index"].is_a?(Integer) && record["wire_index"].between?(0, 255)
  else
    nondecoded_keys = input_keys - %w[input_class wire_index]
    record.keys.sort == nondecoded_keys.sort && record["marker"] == "unknown" && record["action"] == "unknown"
  end
end

final_input = lambda do |record, action, cue_start, window_close|
  valid_input_shape.call(record) &&
    record.keys.sort == input_keys &&
    record["input_class"] == "square" &&
    record["wire_index"] == 0 &&
    record["marker"] == "button" &&
    record["action"] == action &&
    record["decoded"] == true &&
    record["malformed"] == false &&
    record["classification"] == "observed" &&
    record["input_elapsed_ns"] >= cue_start &&
    record["input_elapsed_ns"] <= window_close
end

pre_cue_input = lambda do |record, cue_start|
  valid_input_shape.call(record) && record["classification"] == "pre-cue" && record["input_elapsed_ns"] < cue_start
end

post_window_input = lambda do |record, planned_close, actual_stop|
  valid_input_shape.call(record) && record["classification"] == "post-window" && record["input_elapsed_ns"] > planned_close && record["input_elapsed_ns"] <= actual_stop
end

ordered_sequences = lambda do |records|
  records.each_cons(2).all? { |left, right| left["sequence"] < right["sequence"] }
end

ordered_input_elapsed = lambda do |records|
  records.each_cons(2).all? { |left, right| left["input_elapsed_ns"] <= right["input_elapsed_ns"] }
end

valid_middle = lambda do |records, endpoint_index, cue_start, window_close, actual_stop|
  middle = records[10...endpoint_index]
  (0..(middle.length - 2)).any? do |split|
    pre_cue = middle[0...split]
    pressed = middle[split]
    released = middle[split + 1]
    post_window = middle[(split + 2)..]
    pre_cue.all? { |record| pre_cue_input.call(record, cue_start) } &&
      final_input.call(pressed, "pressed", cue_start, window_close) &&
      final_input.call(released, "released", cue_start, window_close) &&
      released["sequence"] == pressed["sequence"] + 1 &&
      released["input_elapsed_ns"] >= pressed["input_elapsed_ns"] &&
      post_window.all? { |record| post_window_input.call(record, window_close, actual_stop) } &&
      ordered_sequences.call(middle) &&
      ordered_input_elapsed.call(middle)
  end
end

begin
  records = File.readlines(ARGV.fetch(0), chomp: true).map { |line| JSON.parse(line) }
  boundary_count = 4
  raise unless records.length.between?(14, 64)
  raise unless diagnostic_base.call(records[0], "keepalive-prevention-same-process-preflight")
  raise unless diagnostic_base.call(records[1], "normal-startup")
  raise unless diagnostic_base.call(records[2], "keepalive-prevention-start")
  boundaries = records[3, boundary_count]
  boundary_count.times do |index|
    record = boundaries[index]
    raise unless record.is_a?(Hash) &&
      record.keys.sort == boundary_keys &&
      record["event"] == "diagnostic" &&
      record["mode"] == "keepalive-prevention" &&
      record["stage"] == "keepalive-prevention-boundary" &&
      record["status"] == "pass" &&
      record["command"] == "enable-input-stream" &&
      record["detail"].is_a?(String) &&
      record["boundary"] == index + 1 &&
      record["timing_contract"] == "k1-50-v1" &&
      positive_integer.call(record["planned_boundary_elapsed_ns"]) &&
      record["planned_boundary_elapsed_ns"] == (index + 1) * 50000000000 &&
      positive_integer.call(record["actual_timer_wake_elapsed_ns"]) &&
      positive_integer.call(record["write_start_elapsed_ns"]) &&
      positive_integer.call(record["write_completion_elapsed_ns"]) &&
      record["planned_boundary_elapsed_ns"] <= record["actual_timer_wake_elapsed_ns"] &&
      record["actual_timer_wake_elapsed_ns"] <= record["write_start_elapsed_ns"] &&
      record["write_start_elapsed_ns"] <= record["write_completion_elapsed_ns"] &&
      record["write_completion_elapsed_ns"] <= record["planned_boundary_elapsed_ns"] + 250000000
  end
  timings = boundaries.flat_map do |record|
    %w[planned_boundary_elapsed_ns actual_timer_wake_elapsed_ns write_start_elapsed_ns write_completion_elapsed_ns].map { |key| record[key] }
  end
  raise unless timings.each_cons(2).all? { |left, right| left <= right }
  raise unless terminal_stage.call(records[3 + boundary_count], "keepalive-prevention-schedule", boundary_count)
  health = records[8]
  raise unless health.is_a?(Hash) && health.keys.sort == health_keys && health["event"] == "diagnostic" &&
    health["mode"] == "keepalive-prevention" && health["stage"] == "keepalive-prevention-capture-health" &&
    health["status"] == "pass" && health["detail"].is_a?(String) && health["classification"] == "healthy" && health["boundary"] == 4
  cue = records[9]
  raise unless cue.is_a?(Hash) && cue.keys.sort == cue_keys && cue["event"] == "diagnostic" &&
    cue["mode"] == "keepalive-prevention" && cue["stage"] == "keepalive-prevention-endpoint-cue" &&
    cue["status"] == "pass" && cue["detail"].is_a?(String) && cue["boundary"] == 4 &&
    positive_integer.call(cue["cue_start_elapsed_ns"]) && positive_integer.call(cue["cue_completion_elapsed_ns"]) &&
    cue["cue_duration_ns"].is_a?(Integer) && cue["cue_duration_ns"] >= 0 && cue["cue_completion_elapsed_ns"] == cue["cue_start_elapsed_ns"] + cue["cue_duration_ns"] &&
    cue["cue_duration_ns"] <= 12000000000
  raise unless boundaries[3]["write_completion_elapsed_ns"] <= cue["cue_start_elapsed_ns"]
  endpoint_index = records.length - 2
  endpoint = records[endpoint_index]
  raise unless endpoint.is_a?(Hash) && endpoint.keys.sort == endpoint_keys && endpoint["event"] == "diagnostic" &&
    endpoint["mode"] == "keepalive-prevention" && endpoint["stage"] == "keepalive-prevention-final-verification" &&
    endpoint["status"] == "pass" && endpoint["detail"].is_a?(String) && endpoint["boundary"] == 4 &&
    endpoint["attestation"] == "ACTIVE_AT_CUE" && positive_integer.call(endpoint["cue_completion_elapsed_ns"]) &&
    positive_integer.call(endpoint["window_start_elapsed_ns"]) && positive_integer.call(endpoint["planned_close_elapsed_ns"]) &&
    positive_integer.call(endpoint["actual_timer_wake_elapsed_ns"]) && positive_integer.call(endpoint["actual_capture_stop_elapsed_ns"]) &&
    positive_integer.call(endpoint["window_duration_ns"]) && endpoint["cue_completion_elapsed_ns"] == cue["cue_completion_elapsed_ns"] &&
    endpoint["window_start_elapsed_ns"] == cue["cue_start_elapsed_ns"] &&
    endpoint["planned_close_elapsed_ns"] == cue["cue_completion_elapsed_ns"] + 5000000000 &&
    endpoint["window_duration_ns"] == endpoint["planned_close_elapsed_ns"] - endpoint["window_start_elapsed_ns"] &&
    endpoint["actual_timer_wake_elapsed_ns"].between?(endpoint["planned_close_elapsed_ns"], endpoint["planned_close_elapsed_ns"] + 250000000) &&
    endpoint["actual_capture_stop_elapsed_ns"].between?(endpoint["actual_timer_wake_elapsed_ns"], endpoint["planned_close_elapsed_ns"] + 250000000)
  raise unless valid_middle.call(records, endpoint_index, endpoint["window_start_elapsed_ns"], endpoint["planned_close_elapsed_ns"], endpoint["actual_capture_stop_elapsed_ns"])
  raise unless terminal_stage.call(records[endpoint_index + 1], "keepalive-prevention-result", boundary_count)
rescue StandardError
  exit 1
end
exit 0
RUBY
        return $?
    fi
    return 1
}


diagnostic_check_brightness_report() {
    local metadata_file
    local manifest_file
    local stdout_file
    local stderr_file
    local key
    local value
    local -a metadata_keys
    local -a manifest_keys
    local -i metadata_lines=0
    local -i manifest_lines=0
    local -A metadata
    local -A manifest
    local report_root
    local expected_command
    local digest
    local actual_digest

    diagnostic_resolve_report_path "$1"
    report_root="${HIDHOG_ARCHIVE_ROOT:A}"
    case "$DIAGNOSTIC_REPORT_PATH" in
        "$report_root"/*) ;;
        *)
            diagnostic_message "refusing wake candidate: brightness-zero report must be under $HIDHOG_ARCHIVE_ROOT"
            return 78
            ;;
    esac

    if [[ ! -d "$DIAGNOSTIC_REPORT_PATH" || "${DIAGNOSTIC_REPORT_PATH:t}" != *-brightness-zero ]]; then
        diagnostic_message "refusing wake candidate: report is not a brightness-zero archive: $DIAGNOSTIC_REPORT_PATH"
        return 78
    fi

    metadata_file="${DIAGNOSTIC_REPORT_PATH}/metadata.txt"
    manifest_file="${DIAGNOSTIC_REPORT_PATH}/manifest.sha256"
    stdout_file="${DIAGNOSTIC_REPORT_PATH}/stdout.jsonl"
    stderr_file="${DIAGNOSTIC_REPORT_PATH}/stderr.log"
    if [[ ! -f "$metadata_file" ]]; then
        diagnostic_message "refusing wake candidate: brightness-zero metadata is missing: $metadata_file"
        return 78
    fi
    if [[ ! -f "$manifest_file" ]]; then
        diagnostic_message "refusing wake candidate: brightness-zero manifest is missing: $manifest_file"
        return 78
    fi

    metadata_keys=(
        format_version
        started_at_utc
        finished_at_utc
        mode
        candidate
        result_status
        exit_status
        command_invoked
        confirmation
        preflight_status
        stderr_capture_status
        repo_root
        config_path
        runtime_socket
        brightness_zero_report
        command
        stdout_sha256
        stderr_sha256
    )
    while IFS='=' read -r key value; do
        (( metadata_lines += 1 ))
        if [[ -z "$key" || ! "$key" =~ '^[a-z0-9_]+$' ]] || (( ${+metadata[$key]} )); then
            diagnostic_message "refusing wake candidate: brightness-zero metadata is malformed: $metadata_file"
            return 78
        fi
        metadata[$key]="$value"
    done < "$metadata_file"

    if (( metadata_lines != ${#metadata_keys[@]} )); then
        diagnostic_message "refusing wake candidate: brightness-zero metadata is incomplete: $metadata_file"
        return 78
    fi
    for key in "${metadata_keys[@]}"; do
        if (( ! ${+metadata[$key]} )); then
            diagnostic_message "refusing wake candidate: brightness-zero metadata is incomplete: $metadata_file"
            return 78
        fi
    done

    if [[ "${metadata[format_version]}" != '1' ||
        "${metadata[mode]}" != 'brightness-zero' ||
        -n "${metadata[candidate]}" ||
        "${metadata[result_status]}" != 'pass' ||
        "${metadata[exit_status]}" != '0' ||
        "${metadata[command_invoked]}" != 'yes' ||
        "${metadata[confirmation]}" != 'accepted' ||
        "${metadata[preflight_status]}" != 'pass' ||
        "${metadata[stderr_capture_status]}" != '0' ||
        "${metadata[repo_root]}" != "$HIDHOG_REPO_ROOT" ||
        "${metadata[config_path]}" != "$HIDHOG_CONFIG_PATH" ||
        "${metadata[runtime_socket]}" != "$HIDHOG_RUNTIME_SOCKET" ||
        -n "${metadata[brightness_zero_report]}" ]]; then
        diagnostic_message 'refusing wake candidate: brightness-zero metadata does not describe a trusted pass'
        return 78
    fi

    if [[ ! "${metadata[started_at_utc]}" =~ '^[0-9]{8}T[0-9]{6}Z$' ||
        ! "${metadata[finished_at_utc]}" =~ '^[0-9]{8}T[0-9]{6}Z$' ||
        "$DIAGNOSTIC_REPORT_PATH:t" != "${metadata[started_at_utc]}-brightness-zero" &&
        "$DIAGNOSTIC_REPORT_PATH:t" != "${metadata[started_at_utc]}-"<->"-brightness-zero" ]]; then
        diagnostic_message "refusing wake candidate: brightness-zero metadata timestamps or archive identity are invalid: $metadata_file"
        return 78
    fi

    expected_command="go run ./cmd/hidhoggdiag --mode brightness-zero --config-path $HIDHOG_CONFIG_PATH --confirm"
    if [[ "${metadata[command]}" != "$expected_command" ]]; then
        diagnostic_message "refusing wake candidate: brightness-zero command identity is invalid: $metadata_file"
        return 78
    fi

    manifest_keys=(manifest_version metadata_sha256 stdout_sha256 stderr_sha256)
    while IFS='=' read -r key value; do
        (( manifest_lines += 1 ))
        if [[ -z "$key" || ! "$key" =~ '^[a-z0-9_]+$' ]] || (( ${+manifest[$key]} )); then
            diagnostic_message "refusing wake candidate: brightness-zero manifest is malformed: $manifest_file"
            return 78
        fi
        manifest[$key]="$value"
    done < "$manifest_file"
    if (( manifest_lines != ${#manifest_keys[@]} )); then
        diagnostic_message "refusing wake candidate: brightness-zero manifest is incomplete: $manifest_file"
        return 78
    fi
    for key in "${manifest_keys[@]}"; do
        if (( ! ${+manifest[$key]} )); then
            diagnostic_message "refusing wake candidate: brightness-zero manifest is incomplete: $manifest_file"
            return 78
        fi
    done
    if [[ "${manifest[manifest_version]}" != '1' ]]; then
        diagnostic_message "refusing wake candidate: brightness-zero manifest version is unsupported: $manifest_file"
        return 78
    fi
    if [[ ! -s "$stdout_file" || ! -s "$stderr_file" ]]; then
        diagnostic_message 'refusing wake candidate: brightness-zero observation or stderr archive is empty'
        return 78
    fi

    for digest in "${metadata[stdout_sha256]}" "${metadata[stderr_sha256]}" "${manifest[metadata_sha256]}" "${manifest[stdout_sha256]}" "${manifest[stderr_sha256]}"; do
        if [[ ! "$digest" =~ '^[[:xdigit:]]{64}$' ]]; then
            diagnostic_message "refusing wake candidate: brightness-zero archive checksum is invalid: $manifest_file"
            return 78
        fi
    done
    if [[ "${manifest[stdout_sha256]:l}" != "${metadata[stdout_sha256]:l}" ||
        "${manifest[stderr_sha256]:l}" != "${metadata[stderr_sha256]:l}" ]]; then
        diagnostic_message "refusing wake candidate: brightness-zero metadata and manifest checksums disagree: $manifest_file"
        return 78
    fi

    actual_digest="$(diagnostic_sha256_file "$stdout_file")" || {
        diagnostic_message "refusing wake candidate: unable to checksum brightness-zero observations: $stdout_file"
        return 78
    }
    if [[ "$actual_digest" != "${metadata[stdout_sha256]:l}" ]]; then
        diagnostic_message "refusing wake candidate: brightness-zero observations do not match metadata: $stdout_file"
        return 78
    fi
    actual_digest="$(diagnostic_sha256_file "$stderr_file")" || {
        diagnostic_message "refusing wake candidate: unable to checksum brightness-zero stderr: $stderr_file"
        return 78
    }
    if [[ "$actual_digest" != "${metadata[stderr_sha256]:l}" ]]; then
        diagnostic_message "refusing wake candidate: brightness-zero stderr does not match metadata: $stderr_file"
        return 78
    fi
    actual_digest="$(diagnostic_sha256_file "$metadata_file")" || {
        diagnostic_message "refusing wake candidate: unable to checksum brightness-zero metadata: $metadata_file"
        return 78
    }
    if [[ "$actual_digest" != "${manifest[metadata_sha256]:l}" ]]; then
        diagnostic_message "refusing wake candidate: brightness-zero metadata does not match manifest: $metadata_file"
        return 78
    fi

    if ! diagnostic_validate_observation_archive "$stdout_file"; then
        diagnostic_message "refusing wake candidate: brightness-zero observations are not a parseable supporting pass: $stdout_file"
        return 78
    fi

    diagnostic_message "brightness-zero report accepted: $DIAGNOSTIC_REPORT_PATH"
    return 0
}

diagnostic_confirm() {
    local phrase="$1"
    local confirmation=''

    DIAGNOSTIC_CONFIRMATION='declined'
    printf 'Type exactly "%s" to continue: ' "$phrase" >&2
    printf 'Type exactly "%s" to continue: ' "$phrase" >> "$DIAGNOSTIC_STDERR_FILE"
    if ! IFS= read -r confirmation; then
        printf '\n' >&2
        printf '\n' >> "$DIAGNOSTIC_STDERR_FILE"
        diagnostic_message 'confirmation was not received; hidhoggdiag was not invoked'
        return 2
    fi
    printf '\n' >&2
    printf '\n' >> "$DIAGNOSTIC_STDERR_FILE"
    if [[ "$confirmation" != "$phrase" ]]; then
        diagnostic_message 'confirmation did not match; hidhoggdiag was not invoked'
        return 2
    fi

    DIAGNOSTIC_CONFIRMATION='accepted'
    diagnostic_message 'typed confirmation accepted; one diagnostic invocation is permitted'
    return 0
}

diagnostic_validate_keepalive_text() {
    local value="$1"

    if [[ -z "$value" || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        return 1
    fi
    return 0
}

diagnostic_validate_keepalive_schedule_cli() {
    local interval="$1"
    local duration="$2"

    (
        if ! builtin cd "$HIDHOG_REPO_ROOT"; then
            exit 70
        fi
        command go run ./cmd/hidhoggdiag \
            --mode keepalive-prevention \
            --keepalive-interval "$interval" \
            --duration "$duration" \
            --validate-keepalive-schedule
    )
}

diagnostic_run_endpoint_cue_preflight() {
    diagnostic_message 'running the fixed local endpoint cue before physical confirmation'
    if command go run ./cmd/hidhoggdiag --mode keepalive-prevention --preflight-endpoint-cue; then
        DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT='accepted'
        DIAGNOSTIC_ENDPOINT_OWNER_HEARD='accepted'
        diagnostic_message 'fixed endpoint cue and owner-heard token accepted'
        return 0
    fi
    DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT='failed'
    DIAGNOSTIC_ENDPOINT_OWNER_HEARD='failed'
    diagnostic_message 'fixed endpoint cue preflight failed; hidhoggdiag will not access HID'
    return 65
}

diagnostic_command_for_mode() {
    if [[ -n "$DIAGNOSTIC_CANDIDATE" ]]; then
        DIAGNOSTIC_COMMAND="go run ./cmd/hidhoggdiag --mode $DIAGNOSTIC_MODE --wake-candidate $DIAGNOSTIC_CANDIDATE --config-path $DIAGNOSTIC_CONFIG_PATH --confirm"
    elif [[ "$DIAGNOSTIC_MODE" == 'keepalive-prevention' ]]; then
        DIAGNOSTIC_COMMAND="go run ./cmd/hidhoggdiag --mode $DIAGNOSTIC_MODE --keepalive-interval $DIAGNOSTIC_KEEPALIVE_INTERVAL --duration $DIAGNOSTIC_KEEPALIVE_DURATION --config-path $DIAGNOSTIC_CONFIG_PATH --confirm"
    else
        DIAGNOSTIC_COMMAND="go run ./cmd/hidhoggdiag --mode $DIAGNOSTIC_MODE --config-path $DIAGNOSTIC_CONFIG_PATH --confirm"
    fi
}

diagnostic_keepalive_same_process_preflight_observed() {
    local archive_file="$1"

    if [[ ! -s "$archive_file" ]]; then
        return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        command jq --slurp --exit-status '.[0] | (keys_unsorted | sort) == ["detail", "event", "mode", "stage", "status"] and .event == "diagnostic" and .mode == "keepalive-prevention" and .stage == "keepalive-prevention-same-process-preflight" and .status == "pass"' "$archive_file" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        command python3 - "$archive_file" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        record = json.loads(stream.readline())
    valid = set(record) == {"detail", "event", "mode", "stage", "status"} and record["event"] == "diagnostic" and record["mode"] == "keepalive-prevention" and record["stage"] == "keepalive-prevention-same-process-preflight" and record["status"] == "pass"
except (OSError, ValueError, TypeError, KeyError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
        return $?
    fi
    if command -v ruby >/dev/null 2>&1; then
        command ruby -rjson - "$archive_file" <<'RUBY'
begin
  record = JSON.parse(File.open(ARGV.fetch(0), &:readline))
  valid = record.keys.sort == %w[detail event mode stage status] && record["event"] == "diagnostic" && record["mode"] == "keepalive-prevention" && record["stage"] == "keepalive-prevention-same-process-preflight" && record["status"] == "pass"
rescue StandardError
  valid = false
end
exit(valid ? 0 : 1)
RUBY
        return $?
    fi
    return 1
}

diagnostic_finalize_command_result() {
    local command_status="$1"

    if (( command_status == 0 )) && [[ "$DIAGNOSTIC_MODE" == 'keepalive-prevention' ]] &&
        ! diagnostic_validate_keepalive_observation_archive "$DIAGNOSTIC_STDOUT_FILE"; then
        diagnostic_message 'keepalive observation archive failed strict validation; diagnostic result is fail'
        command_status=65
    fi
    if [[ "$DIAGNOSTIC_MODE" == 'keepalive-prevention' ]]; then
        if diagnostic_keepalive_same_process_preflight_observed "$DIAGNOSTIC_STDOUT_FILE"; then
            DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT='accepted'
            DIAGNOSTIC_ENDPOINT_OWNER_HEARD='accepted'
        else
            DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT='failed'
            DIAGNOSTIC_ENDPOINT_OWNER_HEARD='failed'
        fi
    fi
    if (( command_status == 0 )); then
        DIAGNOSTIC_RESULT_STATUS='pass'
    else
        DIAGNOSTIC_RESULT_STATUS='fail'
    fi
    DIAGNOSTIC_EXIT_STATUS="$command_status"
    return "$command_status"
}

diagnostic_run_command() {
    diagnostic_command_for_mode

    if [[ ! -f "$DIAGNOSTIC_CONFIG_PATH" ]]; then
        diagnostic_message "refusing diagnostic: configuration file disappeared: $DIAGNOSTIC_CONFIG_PATH"
        DIAGNOSTIC_PREFLIGHT_STATUS='fail'
        return 78
    fi
    if [[ -e "$HIDHOG_RUNTIME_SOCKET" || -L "$HIDHOG_RUNTIME_SOCKET" ]]; then
        diagnostic_message "refusing diagnostic: $HIDHOG_RUNTIME_SOCKET appeared before invocation"
        DIAGNOSTIC_PREFLIGHT_STATUS='fail'
        return 73
    fi

    DIAGNOSTIC_STDERR_PIPE="${DIAGNOSTIC_ARCHIVE_DIR}/stderr.pipe"
    if ! mkfifo "$DIAGNOSTIC_STDERR_PIPE"; then
        diagnostic_message "unable to create diagnostic stderr pipe: $DIAGNOSTIC_STDERR_PIPE"
        return 70
    fi

    tee -a "$DIAGNOSTIC_STDERR_FILE" < "$DIAGNOSTIC_STDERR_PIPE" >&2 &
    local tee_pid=$!
    local command_status
    local tee_status

    DIAGNOSTIC_COMMAND_INVOKED='yes'
    if [[ -n "$DIAGNOSTIC_CANDIDATE" ]]; then
        command go run ./cmd/hidhoggdiag --mode "$DIAGNOSTIC_MODE" --wake-candidate "$DIAGNOSTIC_CANDIDATE" --config-path "$DIAGNOSTIC_CONFIG_PATH" --confirm > "$DIAGNOSTIC_STDOUT_FILE" 2> "$DIAGNOSTIC_STDERR_PIPE"
        command_status=$?
    elif [[ "$DIAGNOSTIC_MODE" == 'keepalive-prevention' ]]; then
        command go run ./cmd/hidhoggdiag --mode "$DIAGNOSTIC_MODE" --keepalive-interval "$DIAGNOSTIC_KEEPALIVE_INTERVAL" --duration "$DIAGNOSTIC_KEEPALIVE_DURATION" --config-path "$DIAGNOSTIC_CONFIG_PATH" --confirm > "$DIAGNOSTIC_STDOUT_FILE" 2> "$DIAGNOSTIC_STDERR_PIPE"
        command_status=$?
    else
        command go run ./cmd/hidhoggdiag --mode "$DIAGNOSTIC_MODE" --config-path "$DIAGNOSTIC_CONFIG_PATH" --confirm > "$DIAGNOSTIC_STDOUT_FILE" 2> "$DIAGNOSTIC_STDERR_PIPE"
        command_status=$?
    fi

    wait "$tee_pid"
    tee_status=$?
    rm -f "$DIAGNOSTIC_STDERR_PIPE"
    DIAGNOSTIC_STDERR_PIPE=''
    DIAGNOSTIC_STDERR_CAPTURE_STATUS="$tee_status"

    if (( command_status == 0 && tee_status != 0 )); then
        command_status=70
    fi
    diagnostic_finalize_command_result "$command_status"
}

diagnostic_write_metadata() {
    local exit_status="$1"
    local result_status="$2"
    local finished_at
    local stdout_sha256=''
    local stderr_sha256=''
    finished_at="$(date -u '+%Y%m%dT%H%M%SZ')"
    if ! stdout_sha256="$(diagnostic_sha256_file "$DIAGNOSTIC_STDOUT_FILE")"; then
        stdout_sha256=''
    fi
    if ! stderr_sha256="$(diagnostic_sha256_file "$DIAGNOSTIC_STDERR_FILE")"; then
        stderr_sha256=''
    fi

    {
        printf 'format_version=1\n'
        printf 'started_at_utc=%s\n' "$DIAGNOSTIC_STARTED_AT"
        printf 'finished_at_utc=%s\n' "$finished_at"
        printf 'mode=%s\n' "$DIAGNOSTIC_MODE"
        printf 'candidate=%s\n' "$DIAGNOSTIC_CANDIDATE"
        if [[ "$DIAGNOSTIC_MODE" == 'keepalive-prevention' ]]; then
            printf 'keepalive_interval=%s\n' "$DIAGNOSTIC_KEEPALIVE_INTERVAL"
            printf 'keepalive_duration=%s\n' "$DIAGNOSTIC_KEEPALIVE_DURATION"
            printf 'endpoint_protocol_version=1\n'
            printf 'endpoint_cue=fixed-local-speech-v1\n'
            printf 'endpoint_cue_timeout_ns=12000000000\n'
            printf 'endpoint_capture_tail_ns=5000000000\n'
            printf 'endpoint_close_tolerance_ns=250000000\n'
            printf 'endpoint_cue_preflight_scope=same-process\n'
            printf 'endpoint_cue_preflight=%s\n' "$DIAGNOSTIC_ENDPOINT_CUE_PREFLIGHT"
            printf 'endpoint_owner_heard=%s\n' "$DIAGNOSTIC_ENDPOINT_OWNER_HEARD"
        fi
        printf 'result_status=%s\n' "$result_status"
        printf 'exit_status=%s\n' "$exit_status"
        printf 'command_invoked=%s\n' "$DIAGNOSTIC_COMMAND_INVOKED"
        printf 'confirmation=%s\n' "$DIAGNOSTIC_CONFIRMATION"
        printf 'preflight_status=%s\n' "$DIAGNOSTIC_PREFLIGHT_STATUS"
        printf 'stderr_capture_status=%s\n' "$DIAGNOSTIC_STDERR_CAPTURE_STATUS"
        printf 'repo_root=%s\n' "$HIDHOG_REPO_ROOT"
        printf 'config_path=%s\n' "$DIAGNOSTIC_CONFIG_PATH"
        printf 'runtime_socket=%s\n' "$HIDHOG_RUNTIME_SOCKET"
        printf 'brightness_zero_report=%s\n' "$DIAGNOSTIC_REPORT_PATH"
        printf 'command=%s\n' "$DIAGNOSTIC_COMMAND"
        printf 'stdout_sha256=%s\n' "$stdout_sha256"
        printf 'stderr_sha256=%s\n' "$stderr_sha256"
    } > "$DIAGNOSTIC_METADATA_FILE"
}

diagnostic_write_manifest() {
    local metadata_sha256=''
    local stdout_sha256=''
    local stderr_sha256=''

    if ! metadata_sha256="$(diagnostic_sha256_file "$DIAGNOSTIC_METADATA_FILE")"; then
        metadata_sha256=''
    fi
    if ! stdout_sha256="$(diagnostic_sha256_file "$DIAGNOSTIC_STDOUT_FILE")"; then
        stdout_sha256=''
    fi
    if ! stderr_sha256="$(diagnostic_sha256_file "$DIAGNOSTIC_STDERR_FILE")"; then
        stderr_sha256=''
    fi
    {
        printf 'manifest_version=1\n'
        printf 'metadata_sha256=%s\n' "$metadata_sha256"
        printf 'stdout_sha256=%s\n' "$stdout_sha256"
        printf 'stderr_sha256=%s\n' "$stderr_sha256"
    } > "$DIAGNOSTIC_MANIFEST_FILE"
}

diagnostic_finish() {
    local exit_status="$1"
    local result_status="$2"
    if (( exit_status == 0 )); then
        diagnostic_message "diagnostic completed with result_status=$result_status; stdout JSONL: $DIAGNOSTIC_STDOUT_FILE"
    else
        diagnostic_message "diagnostic stopped with result_status=$result_status exit_status=$exit_status; stdout JSONL: $DIAGNOSTIC_STDOUT_FILE"
    fi
    if ! diagnostic_write_metadata "$exit_status" "$result_status"; then
        return 70
    fi
    if ! diagnostic_write_manifest; then
        return 70
    fi
    return "$exit_status"
}

diagnostic_run_brightness_zero() {
    local result_code

    if (( $# != 0 )); then
        printf '%s\n' 'usage: brightness-zero.sh' >&2
        return 64
    fi

    diagnostic_start_archive 'brightness-zero' '' 'brightness-zero' '' || return $?
    if ! builtin cd "$HIDHOG_REPO_ROOT"; then
        diagnostic_message "unable to enter repository root: $HIDHOG_REPO_ROOT"
        diagnostic_finish 70 'not-run'
        return 70
    fi
    diagnostic_check_preconditions
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" 'not-run'
        return "$result_code"
    fi
    diagnostic_confirm 'RUN ONE D200X BRIGHTNESS-ZERO DIAGNOSTIC'
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" 'not-run'
        return "$result_code"
    fi
    diagnostic_run_command
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" "$DIAGNOSTIC_RESULT_STATUS"
        return "$result_code"
    fi
    diagnostic_finish 0 'pass'
}

diagnostic_run_firmware_wake() {
    local candidate="$1"
    local report_argument
    local result_code

    if (( $# != 2 )); then
        printf '%s\n' "usage: ${DIAGNOSTICS_SCRIPT_PATH:t} <brightness-zero-archive>" >&2
        return 64
    fi
    report_argument="$2"

    diagnostic_start_archive 'firmware-wake' "$candidate" "firmware-wake-${candidate}" "$report_argument" || return $?
    if ! builtin cd "$HIDHOG_REPO_ROOT"; then
        diagnostic_message "unable to enter repository root: $HIDHOG_REPO_ROOT"
        diagnostic_finish 70 'not-run'
        return 70
    fi
    diagnostic_check_brightness_report "$report_argument"
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" 'not-run'
        return "$result_code"
    fi
    diagnostic_check_preconditions
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" 'not-run'
        return "$result_code"
    fi
    diagnostic_message "candidate=$candidate requires one fresh firmware-screensaver generation; this wrapper will make one invocation and never retry"
    diagnostic_confirm 'RUN ONE FRESH D200X WAKE CANDIDATE'
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" 'not-run'
        return "$result_code"
    fi
    diagnostic_run_command
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" "$DIAGNOSTIC_RESULT_STATUS"
        return "$result_code"
    fi
    diagnostic_finish 0 'pass'
}

diagnostic_run_keepalive_prevention() {
    local interval=''
    local duration=''
    local result_code

    if (( $# != 2 )); then
        printf '%s\n' "usage: ${DIAGNOSTICS_SCRIPT_PATH:t} <keepalive-interval> <duration>" >&2
        return 64
    fi
    interval="$1"
    duration="$2"

    if ! diagnostic_validate_keepalive_text "$interval"; then
        printf '%s\n' 'keepalive interval must be a single nonempty argument without line breaks' >&2
        return 64
    fi
    if ! diagnostic_validate_keepalive_text "$duration"; then
        printf '%s\n' 'duration must be a single nonempty argument without line breaks' >&2
        return 64
    fi
    if ! diagnostic_validate_keepalive_schedule_cli "$interval" "$duration"; then
        printf '%s\n' 'keepalive interval and duration do not satisfy the closed K1 contract' >&2
        return 64
    fi

    DIAGNOSTIC_KEEPALIVE_INTERVAL="$interval"
    DIAGNOSTIC_KEEPALIVE_DURATION="$duration"
    diagnostic_start_archive 'keepalive-prevention' '' 'keepalive-prevention' '' || return $?
    if ! builtin cd "$HIDHOG_REPO_ROOT"; then
        diagnostic_message "unable to enter repository root: $HIDHOG_REPO_ROOT"
        diagnostic_finish 70 'not-run'
        return 70
    fi
    diagnostic_check_preconditions
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" 'not-run'
        return "$result_code"
    fi
    diagnostic_message "keepalive interval=$interval duration=$duration; the wrapper permits one invocation and never retries"
    diagnostic_confirm 'RUN ONE D200X KEEPALIVE-PREVENTION DIAGNOSTIC'
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" 'not-run'
        return "$result_code"
    fi
    diagnostic_run_command
    result_code=$?
    if (( result_code != 0 )); then
        diagnostic_finish "$result_code" "$DIAGNOSTIC_RESULT_STATUS"
        return "$result_code"
    fi
    diagnostic_finish 0 'pass'
}
