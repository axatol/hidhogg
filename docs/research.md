# Feasibility evidence

Updated: 2026-08-22

This record separates automatic evidence, one-device observations, upstream claims, and unresolved hypotheses.

## S-01 — cgo-free Go HID

### Automatic evidence

The isolated module pins `github.com/go-ctap/hid v0.11.0` (Apache-2.0) and builds with `CGO_ENABLED=0`. It uses native IOKit/Core Foundation through `purego`, not HIDAPI or cgo.

Independent commands passed:

```text
CGO_ENABLED=0 go test -count=1 ./...
CGO_ENABLED=0 go build ./cmd/d200x
CGO_ENABLED=0 go vet ./...
CGO_ENABLED=0 go test -race -count=1 ./...
```

The tests cover exact D200X selection, report-ID normalization, framing and continuation boundaries, zero padding, input decoding, bounded/allowlisted writes, one-handle replacement, read cancellation/draining, reconnect session replacement, deterministic display archive creation, and CLI confirmation gates.

### One-device read-only observation

Initial enumeration exposed two interface-0 top-level collections:

| Usage page | Usage | Classification |
|---:|---:|---|
| `0x000c` | `0x0001` | observed D200X consumer-control collection |
| `0x0001` | `0x0006` | generic-desktop keyboard collection; rejected |

Interface number alone is therefore insufficient with this backend. After requiring VID `0x2207`, PID `0x0019`, interface `0`, usage page `0x000c`, and usage `0x0001`, enumeration returned exactly one eligible candidate. Raw paths, instance identifiers, parent identifiers, and serials were not recorded; diagnostic output uses short SHA-256 hashes.

The first open attempt failed before any write:

```text
open matching D200X HID: permission denied: IOHIDDeviceOpen failed: 0xe00002e2
```

No brightness, display, input-enable, or reconnect write was attempted. The physical gate is blocked pending execution from a process with the required macOS HID permission. It is not evidence that the library cannot communicate with the device once authorized.

### Outstanding physical matrix

- 20 open/close iterations.
- Representative square, wide, physical-button, and encoder input.
- Brightness `0`, `80`, and `100`.
- Numbered complete-display upload followed by unlock.
- Three unplug/replug cycles without duplicate sessions or uncertain-write retries.

Go must not be selected for production until every item passes.

## S-02 — lossless configuration editing

### Dependencies

| Module | Pin | License |
|---|---|---|
| `github.com/pelletier/go-toml/v2` | `v2.4.4-0.20260718201843-686c980c4758` | MIT |
| `github.com/tailscale/hujson` | `v0.0.0-20260727124030-b80ff77dac4f` | BSD-3-Clause |

The tagged go-toml `v2.4.3` release did not expose the required `unstable/edit` package, so the spike pins an exact pseudo-version. This is a maintenance risk.

### Measured results

| Check | Result |
|---|---:|
| Required TOML cases | 34/34 pass |
| Exact same-line minimal edits | 8/8 pass |
| JSONC/HuJSON comparison | 2/34 pass |
| Transactional checks | 3/3 pass |
| Deterministic artifact regeneration | pass |

TOML cases cover LF/CRLF, scalar insert/replace/delete, ordering, tables, arrays of tables, arrays, dotted keys, inline tables, multiline strings, comments, unknown fields, device files, malformed input, and semantic revalidation. Whole-document LCS checks constrain changed regions; exact prefix/suffix checks cover array, inline-table, and trailing-comment mutations.

HuJSON rejected malformed inputs as expected but changed untouched trailing commas during the 32 mutation cases. This is a measured incompatibility with Hidhogg's strict preservation requirement, not a general claim about JSONC.

Content hashing refuses changes already present before a GUI write. The test also demonstrates the remaining time-of-check/time-of-use race: an external write after the hash check but before rename can be overwritten because ordinary filesystem APIs provide no compare-and-swap. Production design must not claim stronger conflict guarantees.

### Recommendation

TOML is the current evidence-based recommendation, conditional on accepting an exact unstable dependency pin behind a Hidhogg-owned adapter and regression corpus. No public configuration schema has been declared. The final format remains owner decision `D-01`.

## Sources

- [go-ctap/hid](https://pkg.go.dev/github.com/go-ctap/hid)
- [go-toml](https://github.com/pelletier/go-toml)
- [HuJSON](https://github.com/tailscale/hujson)
- [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)
