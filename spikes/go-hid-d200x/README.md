# cgo-free Go D200X HID spike

This isolated module tests whether the Ulanzi D200X can be driven through
`github.com/go-ctap/hid` without cgo. It is a feasibility spike, not the
production runtime.

## Safety boundary

Only the D200X control collection with vendor `0x2207`, product `0x0019`,
interface `0`, usage page `0x000c`, and usage `0x0001` is eligible. The
generic-desktop keyboard collection observed on interface `0` (`0x0001:0x0006`)
is rejected. Enumeration and connection events are filtered by the
go-ctap/hid enumeration options or the spike's candidate validator, and the
public watcher exposes only validated candidates. A session refuses to open a
nonmatching candidate, refuses to choose when more than one eligible control
collection exists, and serializes complete multi-packet writes. Enumeration
summaries include usage page/usage and short SHA-256 hashes of opaque instance,
parent, and path identifiers; raw identifiers and serial-number fields are
never printed.

A read-only host observation on 2026-08-22 found two interface-0 collections
belonging to the same D200X: one eligible control collection (`0x000c:0x0001`)
and one rejected keyboard collection (`0x0001:0x0006`). Consequently, filtered
re-enumeration is expected to return exactly one eligible candidate. The spike
does not deduplicate collections or select between opaque hashes.

The original `cmd/d200x` CLI has no default action. Every outbound command requires both an explicit
action and `--confirm`. Brightness is accepted only in the range `0` through
`100`; the library constructor also clamps programmatic callers. The
`diagnostic-display` builds a deterministic numbered archive containing the
13 square icons and wide tile from the D200X layout, sends it as a complete
`0x0001` upload, then sends `0x0010` unlock. It does not send `0x000f` and the
spike never sends arbitrary commands.

## Raw one-frame probe

`cmd/d200xprobe` is an isolated research CLI for the 12 known command IDs. It
has exactly two mutually exclusive modes:

```text
d200xprobe --action <symbolic-name> [--parameters <value>]
d200xprobe --action startup-sequence --parameters <brightness>
d200xprobe --listen [--duration <positive-duration>]
```

There is no `--confirm` flag. The action and its parameters are fully built and
validated before HID enumeration. A regular action then selects exactly one
eligible interface-0 collection, opens it once, writes exactly one logical
frame, and closes it. A complete-display upload does not send an unlock frame.
Writes are never retried: the first transport error or short write stops the
process. Success means only that the write completed; it does not mean the
device accepted the command or exhibited any particular behavior.

| Symbolic action | ID | Observed direction/status | Parameters |
| --- | ---: | --- | --- |
| `complete-display-upload` | `0x0001` | host to device | required preset `diagnostic` or `live-bulk`; deterministic bounded in-memory archive |
| `enable-input-stream` | `0x0002` | host to device | none |
| `observed-host-lock` | `0x0004` | host to device, observed | none |
| `small-window-refresh` | `0x0006` | host to device, observed | optional exact preset or strict JSON mode object; absent means an empty payload |
| `brightness` | `0x000a` | host to device | required canonical decimal `0` through `100` |
| `label-style` | `0x000b` | host to device, observed | none |
| `partial-display-upload` | `0x000d` | host to device, observed | none |
| `lock-screen` | `0x000f` | host to device | none |
| `unlock-screen` | `0x0010` | host to device | none |
| `input-event` | `0x0101` | device to host, observed; outbound probe is experimental | none |
| `acknowledgement` | `0x010b` | device to host, observed; outbound probe is experimental | none |
| `device-information` | `0x0303` | device to host, observed; outbound probe is experimental | none |

### Bounded startup sequence

`d200xprobe --action startup-sequence --parameters <brightness>` is the one
bounded multi-frame action. The parameter must be canonical decimal `0` through
`100`; validation
and construction of all four frames, including the content-addressed
`live-bulk` archive, complete before HID enumeration. The action selects one
eligible interface-0 collection, opens one session, and sends exactly this
order:

```text
unlock-screen (0x0010)
complete-display-upload live-bulk (0x0001)
brightness (0x000a)
enable-input-stream (0x0002)
```

Each completed symbolic command is printed without payload, archive contents,
or device identity. The first transport error or short write stops the
sequence immediately. The sequence has no delay, retry, rollback, recovery, or
listen behavior. A failed step is reported with its symbolic command and a
bounded write-failure message; earlier completed steps remain visible.

Canonical brightness excludes signs, padding, whitespace, and alternate numeric
forms. Every action other than brightness, complete-display-upload, and
small-window-refresh rejects `--parameters`, including an explicitly empty
value.

The `live-bulk` complete-display preset is a physical protocol spike for live
redraw. Run it only from a freshly verified default-display baseline:

```sh
CGO_ENABLED=0 go run ./cmd/d200xprobe --action complete-display-upload --parameters live-bulk
```

It opens one eligible interface, writes exactly one logical `0x0001` archive,
and closes it. The archive contains all 14 canonical positions: thirteen
196x196 square images and the 458x196 `3_2` wide image. Each image has a
distinct numbered/colorized diagnostic design, and its `Images/<sha256>.png`
name is derived from the exact PNG bytes. The probe sends no brightness,
unlock, input-enable, retry, or recovery command. Record whether the owned
D200X redraws all positions in bulk, redraws them progressively, or leaves the
existing page unchanged; a successful host write alone does not establish any
of those device outcomes.

`small-window-refresh` accepts one of the exact presets `metrics`, `dial-time`,
`background`, `date-time-weekday`, `time-weekday`, `date-time`, and `time`, or
a typed JSON object with only the fields `mode`, `cpu`, `ram`, `time`, `gpu`,
`format`, `date`, and `weekday`. Presets capture one local clock snapshot and
use `24H`. The `metrics` preset generates independent cryptographically secure
synthetic CPU/RAM/GPU values in the inclusive range `1` through `99`; the
values are reported only after its one frame write completes. Other context
presets use zero CPU/RAM/GPU values and include only the fields required by
their mode. The `background` preset remains the exact payload `2|`; its role as
a display-selection/background context is observed or hypothesized, and no
causal relationship with mode-0 metric updates is asserted. Preset names are
case-sensitive and must not be padded. The JSON form retains the supported
modes `0`, `1`, `2`, `200`, `201`, `202`, and `203`; mode `2` requires only
`mode`, while other modes require the five common fields (`cpu`, `ram`, `time`,
`gpu`, and `format`) and produce `mode|cpu|ram|HH:mm:ss|gpu|12H-or-24H|suffix`.
Modes `200`, `201`, and `202` respectively require date plus weekday, weekday
only, and date only. Modes `0`, `1`, and `203` forbid both date and weekday.
Metrics, time, date, weekday, and format values are validated strictly, and
unknown or duplicate JSON fields, trailing JSON, unsupported modes, and
noncanonical JSON types are rejected before HID enumeration. For example:

```json
{"mode":200,"cpu":16,"ram":72,"time":"20:50:26","gpu":7,"format":"12H","date":"2026/08/12","weekday":"Wed"}
```

Passive listen opens one eligible collection and sends zero frames. It runs
indefinitely until `SIGINT` or `SIGTERM` unless the optional `--duration` is
supplied; a supplied duration must be positive. `--duration` is valid only
with `--listen`. It logs every complete input and non-input frame as bounded
command, payload length, SHA-256 digest, and decoded input metadata where
valid. It never logs a raw payload, device path, serial number, or other
device identity. A signal or duration expiry at a frame boundary is successful
completion; cancellation after a partial frame is a failure.

Run passive listen first, then use one fresh process per action in increasing
uncertainty:

```text
brightness
enable-input-stream
unlock-screen
complete-display-upload
lock-screen
observed-host-lock
small-window-refresh
label-style
partial-display-upload
device-information
acknowledgement
input-event
```

Keep Ulanzi Studio stopped. The final three commands are direction-unverified
or inbound-observed and must remain last. Stop at the first write error, short
write, disconnect, reset, display corruption, keyboard effect, unexpected
device state, or need to reconnect. Do not automatically retry, recover,
unlock, or continue to the next action after a failure. If a recovery action is
needed, run and record it separately rather than appending it to the tested
command.

## Automatic validation

Run from this directory:

```sh
go test ./...
CGO_ENABLED=0 go test ./...
CGO_ENABLED=0 go build ./cmd/d200x
CGO_ENABLED=0 go build ./cmd/d200xprobe
CGO_ENABLED=0 go vet ./...
```

The tests are synthetic and deterministic. They cover report-ID normalization,
frame endianness, empty/short/exact-1016/1017-byte/multi-packet payloads,
zero-padding, truncation and 16 MiB rejection, unknown command/input
preservation, outbound command gating, the input action matrix, bounded
brightness, control-collection filtering, serialized writes, failed-write
invalidation, close-first connection replacement, read cancellation during
replacement/close, deterministic manifest/PNG/ZIP generation, firmware-safe
archive padding, and archive geometry. Passing these commands does not
establish physical device behavior.

## Explicit physical commands

Run these only with one D200X connected and Ulanzi Studio fully quit. The
commands do not log device serial numbers or open a nonmatching collection.

```sh
CGO_ENABLED=0 go run ./cmd/d200x --action enumerate
CGO_ENABLED=0 go run ./cmd/d200x --action open-close-loop --iterations 20
CGO_ENABLED=0 go run ./cmd/d200x --action listen-input --duration 60s --confirm
CGO_ENABLED=0 go run ./cmd/d200x --action brightness --brightness 0 --confirm
CGO_ENABLED=0 go run ./cmd/d200x --action brightness --brightness 80 --confirm
CGO_ENABLED=0 go run ./cmd/d200x --action brightness --brightness 100 --confirm
CGO_ENABLED=0 go run ./cmd/d200x --action diagnostic-display --confirm
CGO_ENABLED=0 go run ./cmd/d200x --action reconnect-observation --duration 180s
```

`listen-input` enables input with `0x0002` and prints decoded input indexes,
markers, actions, and payload sizes until the bounded duration expires.
`reconnect-observation` watches connection events and replaces the session
after a matching reconnect; it sends no D200X command. Do not auto-retry a
write after cancellation: macOS may complete an in-flight write after the
context returns an error.

## Physical pass criteria

Record each item as `pass`, `fail`, or `not run`; this implementation has not
personally observed any physical result.

1. Enumeration shows exactly one eligible interface-0 control collection
   (`0x000c:0x0001`) and never selects the rejected keyboard collection
   (`0x0001:0x0006`); if more than one eligible collection appears, record
   usage/hash diagnostics and do not deduplicate.
2. The 20-iteration open/close loop completes without a leaked handle or
   keyboard seizure.
3. `listen-input` receives representative square, wide, physical-button, and
   encoder reports without dead reads, duplicate sessions, truncated frames,
   or report-ID misalignment.
4. Brightness `0`, `80`, and `100` visibly produce the expected bounded device
   behavior; record whether zero blanks the displays.
5. `diagnostic-display` visibly shows the numbered layout, accepts the complete
   upload followed by unlock, and can be recovered safely through the tested
   procedure.
6. Three unplug/replug cycles produce ordered disconnect/reconnect observations
   and a live replacement session without writes to a nonmatching interface.

Recommend Go for the runtime only if every required physical criterion passes.
Otherwise report the exact failure and keep the architecture decision gated.

## Dependency

`github.com/go-ctap/hid v0.11.0` is pinned in `go.mod`. The module is
Apache-2.0 licensed and uses native IOKit/Core Foundation through `purego` on
macOS; it does not require cgo or HIDAPI. This release requires Go 1.25 or
newer. The upstream module is pre-v1, so API stability remains a risk.

Protocol constants and framing are based on the repository's D200X protocol
appendix and remain subject to the physical validation above.
