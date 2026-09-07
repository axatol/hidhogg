# Owner-run D200X diagnostics

The separate `ulanzi-lldb/` subtree contains static preflight and temporary evidence helpers for the not-yet-authorized Ulanzi Studio LLDB interoperability phase. Those utilities do not launch or attach to the application; follow `docs/ulanzi-studio-lldb-runbook.md` and its explicit authorization gate.

These wrappers run the bounded `hidhoggdiag` modes from the repository root. They do not inspect the TOML configuration; they pass its absolute path to the Go diagnostic after checking that the file exists.

The expected owner-run configuration path is:

```text
<repository>/deploy/hidhogg.toml
```

The wrappers refuse to invoke the diagnostic when `<repository>/deploy/runtime.sock` exists. This is a path-only safety check; the scripts do not inspect processes or environment variables. Stop the owner-run runtime before starting a diagnostic.

## Brightness-zero baseline

From any working directory, run:

```text
<repository>/scripts/diagnostics/brightness-zero.sh
```

Type exactly:

```text
RUN ONE D200X BRIGHTNESS-ZERO DIAGNOSTIC
```

The wrapper invokes `go run ./cmd/hidhoggdiag --mode brightness-zero --config-path <absolute-config> --confirm` once. It does not retry. Follow the prompts printed by `hidhoggdiag`, and record the resulting archive path. A wake candidate is permitted only when that archive's `metadata.txt` reports `mode=brightness-zero`, `result_status=pass`, and `exit_status=0`.

Each run is archived under:

```text
<repository>/deploy/diagnostics/<UTC timestamp>-brightness-zero/
```

`stdout.jsonl` contains the diagnostic JSONL observations. `stderr.log` contains the live stderr transcript. `metadata.txt` records the command, confirmation, preflight result, and exit status without recording raw HID identity. The deployment tree is expected to be ignored by the repository's deployment setup.

## One bounded keepalive-prevention trial

First measure one no-write visible-screensaver onset `T0` in a fresh device
generation. The approved diagnostic values are `I = T0 / 2` and `D = 2 * T0`,
so `D = 4I` and the scheduler sends exactly four experimental frames. The
predeclared C0 ceiling is 30 minutes; the Go core and wrapper enforce a maximum
K1 duration of 60 minutes. Changing the ratio or ceiling requires reviewed
evidence and a code-and-decision revision. Pass both values explicitly as Go
duration strings:

```text
<repository>/scripts/diagnostics/keepalive-prevention.sh <interval> <duration>
```

For example, if the observed onset was 20 minutes:

```text
<repository>/scripts/diagnostics/keepalive-prevention.sh 10m 40m
```

Type exactly:

```text
RUN ONE D200X KEEPALIVE-PREVENTION DIAGNOSTIC
```

The wrapper performs one preflight, asks for one confirmation, and invokes
`hidhoggdiag --mode keepalive-prevention --keepalive-interval <interval>
--duration <duration> --config-path <absolute-config> --confirm` at most once.
Before creating an archive or asking for confirmation, it calls the shared
no-HID Go schedule validator; a ratio mismatch or duration above 60 minutes is
refused.
The diagnostic retains one HID session. After normal startup, the experimental
scheduler sends only `enable-input-stream` at the scheduled boundaries. It does
not catch up or retry after cancellation,
late boundaries, short writes, failed writes, or uncertain writes. Completion
also requires one canonical `0_0` square press/release verification. A
keepalive archive is evidence for this diagnostic run only; it does not select
a production interval or idle policy.

Each run is archived under:

```text
<repository>/deploy/diagnostics/<UTC timestamp>-keepalive-prevention/
```

`metadata.txt` records the explicit interval and duration, invocation status,
result status, and checksums without recording raw HID identity. A nonzero exit
status, including `invalidated`, `indeterminate`, or `not-run`, is not a
successful prevention result.

## One fresh firmware-wake candidate

After a passing brightness-zero baseline, put the device through one new firmware-screensaver generation. Pass the exact baseline archive path to exactly one candidate wrapper:

```text
<repository>/scripts/diagnostics/wake-brightness.sh <brightness-zero-archive>
<repository>/scripts/diagnostics/wake-input-enable.sh <brightness-zero-archive>
<repository>/scripts/diagnostics/wake-unlock.sh <brightness-zero-archive>
<repository>/scripts/diagnostics/wake-complete-page-upload.sh <brightness-zero-archive>
```

The archive argument may be absolute or repository-relative, but it must name a `*-brightness-zero` archive produced by the wrapper. The wrapper reads only that archive's metadata and refuses any report that is not a recorded pass. It checks the configuration and runtime socket again, then requires this exact confirmation:

```text
RUN ONE FRESH D200X WAKE CANDIDATE
```

The selected wrapper invokes one allowlisted command with `--mode firmware-wake --wake-candidate <candidate> --confirm`, then stops. Do not rerun the same candidate for the same firmware-screensaver generation; use a fresh generation and a separately recorded invocation. Candidate archives use `<UTC timestamp>-firmware-wake-<candidate>`.

An exit status of zero means the Go diagnostic reported pass. Any other status, including a refusal, is recorded as not-run or fail in `metadata.txt`; it is not a successful wake result.

For later result reporting, report the archive path, `mode`, `candidate` (when present), `result_status`, and `exit_status` from `metadata.txt`, then report each observation's `stage` and `status` from `stdout.jsonl`. Treat `not-run`, `partial`, `invalidated`, and `indeterminate` as distinct outcomes; do not infer a pass from an archive directory existing.

## Safe dry run

Without a safe `deploy/hidhogg.toml` fixture, a wrapper stops after the existence check and writes a not-run archive. Declining or mistyping the confirmation also stops before `go run`, so these cases never enumerate or access HID hardware. Do not create a fake configuration merely to claim a physical result.
