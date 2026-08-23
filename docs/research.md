# Feasibility evidence

Updated: 2026-08-23

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

The first open attempt from the Codex process failed before any write:

```text
open matching D200X HID: permission denied: IOHIDDeviceOpen failed: 0xe00002e2
```

The user then ran the documented commands from an authorized terminal. The resulting local log records 20 successful open/close iterations, all square and wide touch inputs, both physical buttons, and left/press/release/right events for all three encoders. The user visually confirmed that brightness control works.

The first diagnostic display run did not change the display despite reporting successful upload and unlock. Inspection found that the generated `manifest.json` omitted the closing bracket for every `ViewParam` array and was therefore invalid JSON. The repair adds the missing bracket and an independent semantic JSON test covering all 14 display mappings. Plain tests, race tests, vet, ZIP extraction, geometry checks, framing checks, and independent review pass. On physical rerun, the display showed colored numbered tiles. The numbers were not highly legible; this is a diagnostic-artwork limitation rather than a protocol failure.

The appended reconnect log records one disconnect followed by reconnection and active-session replacement. On 2026-08-23, the owner accepted one cycle as sufficient for this feasibility spike and removed the two remaining cycles from the gate. This does not establish repeated-cycle reliability.

### Physical matrix

- 20 open/close iterations: pass.
- Representative square, wide, physical-button, and encoder input: pass.
- Brightness `0`, `80`, and `100`: pass by user visual confirmation.
- Numbered complete-display upload followed by unlock: pass after manifest repair; colored numbered tiles were visible, with low number legibility.
- One unplug/replug cycle without duplicate sessions or uncertain-write retries: pass. Repeated-cycle reliability remains unmeasured.

All owner-approved feasibility gates pass. This supports, but does not compel, selection of the Go service architecture; `D-01` remains an explicit owner decision.

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

TOML was the evidence-based recommendation, conditional on accepting an exact unstable dependency pin behind a Hidhogg-owned adapter and regression corpus. The owner selected TOML under `D-01` on 2026-08-24. No public configuration schema has been declared.

## Sources

- [go-ctap/hid](https://pkg.go.dev/github.com/go-ctap/hid)
- [go-toml](https://github.com/pelletier/go-toml)
- [HuJSON](https://github.com/tailscale/hujson)
- [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)
