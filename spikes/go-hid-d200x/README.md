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

The CLI has no default action. Every outbound command requires both an explicit
action and `--confirm`. Brightness is accepted only in the range `0` through
`100`; the library constructor also clamps programmatic callers. The
`diagnostic-display` builds a deterministic numbered archive containing the
13 square icons and wide tile from the D200X layout, sends it as a complete
`0x0001` upload, then sends `0x0010` unlock. It does not send `0x000f` and the
spike never sends arbitrary commands.

## Automatic validation

Run from this directory:

```sh
go test ./...
CGO_ENABLED=0 go test ./...
CGO_ENABLED=0 go build ./cmd/d200x
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
