# Feasibility evidence

Updated: 2026-08-30

Historical v1 research only. The Go commands and probes below document retired feasibility work; they are not current build, test, or operational instructions. The exact v1 roadmap is preserved separately in [v1-roadmap.md](v1-roadmap.md), and current Swift acceptance is in [v2-plan.md](v2-plan.md).

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

## M-02-F01 — D200X idle and protocol research

This section separates encoded byte contracts, one-device observations, observed chronology, and unverified behavior. A write completing at the host does not prove device acceptance. Packet order observed from another client is not assumed causal or required.

### Independently encoded protocol facts

- D200X framing uses magic `7c 7c`, a big-endian 16-bit command, a little-endian 32-bit declared payload length, 1,016 payload bytes in the first 1,024-byte protocol packet, and 1,024-byte continuations. macOS HID writes include report ID `0`.
- The eligible collection remains VID `0x2207`, PID `0x0019`, interface `0`, usage page `0x000c`, usage `0x0001`.
- Production permits only complete upload `0x0001`, input enable `0x0002`, brightness `0x000a`, and unlock `0x0010` outbound. The experimental spike probe does not alter that production boundary.
- Input `0x0101` uses the first four declared payload bytes as device state, wire index, marker, and action. Marker `0x01` is button and `0x02` encoder; actions `0x00` through `0x03` are release, press, left, and right. Unknown values remain lossless diagnostics.
- Controlled Ulanzi Studio T09-T11 captures independently matched that interpretation. Square `0_0` emitted `01 00 01 01` then `01 00 01 00`; the physical middle encoder emitted `01 12 02 02`, `01 12 02 03`, `01 12 02 01`, and `01 12 02 00` for left, right, press, and release. Each payload was 1,014 bytes with zero padding after byte 3. This confirms the observed values, not an exhaustive event namespace.

### One-device observations

- A fresh direct-Go session delivered input before the native firmware screensaver. Once that screensaver appeared, IPC remained `ready`, but two display presses neither changed the display nor produced input. Process and IPC liveness therefore do not prove device health.
- Explicit brightness zero blanks the displays without suppressing input reception while the native firmware screensaver is inactive. Display tiles and physical buttons did not restore brightness, but turning any encoder caused firmware to restore brightness to 100. The observed input classes at zero were not recorded exhaustively.
- On 2026-09-01 the owner reproduced the encoder-triggered restoration to 100 while Studio owned the device, so the transition is not specific to Hidhogg's direct-Go sender. Studio's Device preferences also expose a screensaver-artwork editor for `1220 × 708` images: `Stored Image` opens the macOS picker and `Set Image` is the explicit commit control. The command and payload are not yet captured.
- Brightness packets sent through the spike CLI did not dismiss the native firmware screensaver. Whether they restore suppressed input while the screensaver remains visible is unmeasured.
- The owner subsequently tested `enable-input-stream` (`0x0002`), `small-window-refresh` (`0x0006`), and `unlock-screen` (`0x0010`) individually from the native firmware screensaver state. Each command dismissed the screensaver and restored input reception on the tested D200X. The exact `small-window-refresh` parameter fixture was not recorded, and these observations do not establish required ordering, a keepalive interval, or behavior on other firmware versions.
- A controlled S0 no-write trial on 2026-08-31 opened only passive `d200xprobe --listen` after the native screensaver was already visible. Opening sent zero frames and did not dismiss the screensaver; one `0_0` press/release neither dismissed it nor produced an inbound frame. This isolates passive device open from the subsequent command intervention on this specimen.
- To create a fresh screensaver generation, one setup-only `unlock-screen` frame was sent after S0. A new passive listener then captured exactly one `0_0` pressed/released pair with payload hashes `8d8d8158584390de642c28ea609110a4758e1a9d5e0e761ba0b0c675ca6dca74` and `663f5c56995bb094776d27cacbcc6ebf232bbec69cb841ba7d425cd493f17379`. Visible dismissal was implied by the owner's conditional response but was not separately stated. The listener was closed before the fresh idle wait.
- In the resulting fresh S1 screensaver generation, the probe sent exactly one `enable-input-stream` (`0x0002`) frame. The owner observed that the screensaver disappeared before touching the device. A subsequent passive listener captured exactly one canonical `0_0` pressed/released pair with the same hashes. Compared with S0, this is controlled one-device evidence that one `0x0002` frame was sufficient to dismiss that visible screensaver state and restore input. It does not establish prevention, interval, ordering with other packets, or cross-firmware behavior.
- In the owner-observed K02 C0 trial, one setup-only `enable-input-stream` reset completed at `2026-08-30T23:04:34Z` and the owner immediately confirmed the configured display was visible. A passive zero-write listener then remained open. The owner reported the native screensaver at `2026-08-30T23:05:38Z`, 64 seconds after reset; this reported interval includes human observation latency and is not a firmware-precise transition timestamp. One subsequent `0_0` press/release left the screensaver visible and produced no listener output. C0 therefore establishes a conservative observed `T0 = 64s` for this specimen and derives the approved K1 parameters `I = 32s`, `D = 128s`.
- The first K1 invocation used `I = 32s`, `D = 128s` and archived four passing scheduled input-enable boundaries with no catch-up or retry. The owner did not answer the immediate post-schedule visual check until reporting the screensaver at `2026-08-30T23:12:27Z`, approximately one C0 interval after the nominal fourth boundary. A subsequent `0_0` press/release did not wake the display and produced no captured input. The archive correctly records `class-failure` because final verification was not captured. This run proves schedule execution and post-write screensaver recurrence; it does not establish the required visible/input state at `D` because the owner check was delayed.
- The single architect-authorized replacement K1 retained `I = 32s`, `D = 128s`, a fresh owner-confirmed active baseline, continuous observation, and four passing scheduled boundaries. The owner reported the display active at the spoken endpoint cue, then reported screensaver onset before there was enough time to press `0_0`; no input was captured. The agent-mediated cue could not be proven to occur within the predeclared five-second endpoint window. The second checksum-matching archive therefore also records `class-failure` and remains endpoint-inconclusive. It supports recurrence soon after scheduled writes stop, but does not establish the required timely at-`D` visible-plus-input endpoint.
- The final scheduler-coupled invocation used `I = 32s`, `D = 128s` and produced checksum-valid archive `20260831T064118Z-keepalive-prevention`. It records accepted same-process audible preflight, four ordered input-enable boundary records, healthy capture, `ACTIVE_AT_CUE`, one adjacent canonical wire-0 press/release pair within the logical window, endpoint close lateness near 1.1 milliseconds, and diagnostic pass. However, boundary records omit actual monotonic wake/write timestamps; because the scheduler accepts jitter before the next 32-second boundary, exact schedule timing cannot be independently reconstructed. This supports one owned-specimen 128-second bounded-jitter prevention observation but fails the retained K02 timing-evidence contract. No further K1 is authorized.
- On 2026-09-01, after reviewing that favourable endpoint result, the owner explicitly waived serialized per-boundary timestamps and accepted the categorical scheduler-window evidence. K02 is therefore a bounded pass by retrospective waiver rather than prospective compliance. A 16-second cadence is the conservative analytical production candidate because its worst accepted categorical spacing approaches 32 seconds, retaining the intended half-`T0` margin; it remains physically unverified and is not a production selection.
- The owner tested the standalone mode-`2` `background` preset after other visible modes, including `date-time`; it retained or displayed a metrics view. A later physical mode-`0` `metrics` run displayed generated nonzero values, confirming that mode `0` carries visible metric data. Subsequent Studio tracing proved that its Background radio is numeric mode `2`, but Studio configures the actual image separately with a `0x000d` archive at `3_2` and did not emit `0x0006`/`2|` during the controlled radio transition. The earlier standalone `2|` result is therefore state-dependent evidence, not a complete background-configuration sequence.
- A prior legacy observation found that `0x0006` background mode plus `0x0010`, sent periodically, kept one D200X active past its earlier idle transition. The individual necessity, ordering, interval, and causal mechanism were not isolated.

### Captured small-window payload bytes

The legacy implementation contains one-device Ulanzi Studio 3.1.9 captures for `0x0006`. Hidhogg independently ports their exact payload-byte fixtures into the spike probe without inheriting behavior claims:

| Mode | Observed feature | Captured payload form |
|---:|---|---|
| `0` | CPU + RAM + GPU | `0|CPU|RAM|HH:mm:ss|GPU|12H-or-24H|` |
| `1` | Dial Time | `1|CPU|RAM|HH:mm:ss|GPU|format|` |
| `2` | Studio wide-tile Background radio; background artwork is separately uploaded at `3_2` | exactly `2|` in the legacy capture; not observed on the controlled Studio radio-transition path |
| `200` | Date + Time + Weekday | base fields plus `YYYY/MM/DD ddd` |
| `201` | Time + Weekday | base fields plus `ddd` |
| `202` | Time + Date | base fields plus `YYYY/MM/DD` |
| `203` | Time | base fields only |

Mode `100` uses `100|CPU|RAM|HH:mm:ss|GPU|12H-or-24H|`; the numbers are unpadded decimal values, so total length varies. A connection-time `0x0001` archive also showed `SmallViewMode: 100` and encoder artwork. Controlled T08 trials established that selecting Studio's `Knob` radio from a settled `Time` mode emits exactly one `0x0011` ZIP containing all three encoder positions. The remaining standalone gap is firmware behavior when project-owned code sends the captured `0x0011` and mode-100 `0x0006` data; typed `d200xprobe` parameters still reject mode `100` pending that clean-room implementation decision.

### Experimental probe boundary

`spikes/go-hid-d200x/cmd/d200xprobe` can send exactly one logical frame for any of the 12 currently known symbolic command IDs. Supplying `--action` is explicit authorization; there is no confirmation flag. Numeric IDs and arbitrary payload injection remain unavailable. Typed parameters exist only for brightness, the deterministic diagnostic complete upload, and captured small-window modes. Small-window refresh accepts exact symbolic presets (`metrics`, `dial-time`, `background`, `date-time-weekday`, `time-weekday`, `date-time`, and `time`) or strict JSON fixtures. The `metrics` preset generates and reports independent synthetic CPU/RAM/GPU values from `1` through `99`; other context presets use zero metrics. Presets use one local clock snapshot and `24H`; strict JSON remains available for reproducible captured bytes. Passive `--listen` sends zero frames and may run indefinitely or for a positive duration.

The following commands or variants retain evidence gaps:

| Command | Current evidence gap |
|---:|---|
| `0x0001` | Complete connection archive captured, including manifest shape and PNGs; minimal required schema and firmware acceptance variants are not isolated |
| `0x0003` | Repeatedly captured with an empty payload during Studio setup; trigger and device-side semantics are not isolated; not yet in Hidhogg's known-ID table |
| `0x0004` | Empty frame observed during macOS lock; causal device behavior unknown |
| `0x0009` | Controlled A/B commits establish a one-entry method-8 ZIP containing a `1220 × 708` RGB PNG and visible screensaver-artwork replacement. Firmware-required ZIP/PNG details, alpha handling, deterministic re-encoding, repeated-upload safety, and malformed-upload behavior remain unproven |
| `0x0006` mode `2` | The legacy capture is exactly `2|`, but a controlled Studio Background-radio transition emitted no matching payload in the bounded interval. Studio instead commits background artwork as a targeted `0x000d` archive with `SmallViewMode: 2`; other timer paths remain possible |
| `0x0006` mode `100` | Exact pipe-delimited live-value grammar captured; the corresponding controlled `0x0011` artwork archive is now known, but standalone firmware behavior and ordering remain untested |
| `0x000a` | Exact connection payload was ASCII `44`; static analysis proves the sender reads per-device persisted Studio brightness and converts it to decimal ASCII, but why the connection path invokes it twice is not isolated |
| `0x000b` | Exact six-field indented JSON captured; required fields, ranges, defaults, and single-field effects are not isolated |
| `0x000d` | Controlled T05-T07 captures establish one action-backed tile schema, text-only deltas, explicit empty-entry deletion, and a move sequence of new-position content then old-position tombstone; firmware-required fields and device-side ordering necessity remain unproven |
| `0x0011` | Two controlled `Time` to `Knob` transitions each emitted one 1,866-byte ZIP. Normalized manifests and PNG bytes matched; positions `2_3`, `3_3`, and `4_3` encode knob 1 plus two empty tombstones. Firmware behavior and minimal required fields remain unvalidated; not yet in Hidhogg's known-ID table |
| `0x010b` | Studio ignores the inbound payload and retransmits its current font style as `0x000b`; the device-side trigger condition remains unknown |
| `0x0303` | Exact five-field JSON captured; Studio consumes `SerialNumber`, `Dversion`, and optional `HardwareVersion` in the traced path. Field optionality, limits, and other-firmware values require another specimen or controlled emulation |

### Diagnostic development findings

- Early brightness-zero runs were invalidated by diagnostic defects rather than device failures: queued release events, human-paced baseline duration, ordinary non-input frames included in input validation, and an ambiguous baseline prompt. Each defect was isolated and corrected with deterministic fake-transport tests and independent review.
- The current continuous-capture design uses one square baseline, immediately writes brightness zero, captures a compact full input sequence, restores configured brightness, and checks recovery. Bounded per-event observations retain phase, sequence, wire index, marker, action, and classification without raw payload or identity.
- The most recent owner-run baseline correctly rejected wire index `2` because the experimental baseline currently requires wire index `0`. Brightness zero was not sent in that run. The prompt should explicitly identify position `0_0` before the next physical run.
- The revised one-shot B01 run at `deploy/diagnostics/20260902T235304Z-brightness-zero` is checksum-consistent but class-failed. While brightness was zero it captured the exact wide-13 and physical-button-15/16 pairs, but not the required square-0 pair; encoder-17 left then ended the zero state. The owner supplied `BRIGHTNESS_100_OBSERVED`, configured-brightness restoration passed, and the recovery square pair passed. This proves the archived subset and transition for that invocation but does not complete the required matrix.
- The owner subsequently initiated `deploy/diagnostics/20260903T032301Z-brightness-zero` outside the consumed no-retry authorization. Its three hashes match, strict validation passes, and it contains the complete exact baseline, zero-state wide-13/button-15/button-16/square-0 sequence, encoder-17-left transition, structured `BRIGHTNESS_100_OBSERVED`, configured restore, and recovery pair without contrary or trailing input. On 2026-09-03 the owner explicitly accepted this archive retrospectively as authoritative and sufficient for the bounded one-device B01 decision. This procedural deviation and potential retry-selection bias are retained; the result does not establish repeatability or cross-firmware behavior.
- P01 implementation on 2026-09-03 uses an injectable runtime-owned coordinator rather than protocol-layer timers. The strict optional `idle_timeout_seconds` setting defaults to 300, accepts 0 through 86,400, and does not control the fixed 50-second keepalive. Fake-clock and integration tests establish absolute keepalive scheduling, keepalive-before-dim ordering, input-at-deadline precedence, one idle zero write, full wake-gesture consumption for button and encoder markers, marker-plus-wire suppression, unknown-input exclusion, fail-stop/no-retry writes, and cancellation-safe shutdown. In the owner-present physical gate with a five-second idle setting, the display blanked, remained blank across the first scheduled 50-second `0x0002`, restored configured brightness while consuming the first square pair, dispatched exactly one ordered JSON pair for the next square gesture, dimmed again, and removed its socket on clean shutdown. This is bounded evidence from one owned D200X; exact scheduling and failure paths remain automatic-test evidence.

### Automated research boundary

- Two metadata-only and two full-payload connection trials were completed on 2026-08-30 using authorized disposable ad-hoc-signed copies. The metadata trials establish a repeated initialization chronology. The payload repeats establish exact `0x000b`, `0x000a`, and `0x0303` bytes; the logical `0x0001` ZIP structure; and the mode-`100` `0x0006` grammar. Manual payload dumping perturbed asynchronous ordering, so it does not replace the earlier chronology evidence.
- A deeper static pass established a common `0x0001`/`0x000d`/`0x0011` archive builder, exact single-key and current-page-encoder selection, `0x010b`-triggered font retransmission, the `0x0303` fields consumed by Studio, and persisted-model provenance for `0x000a`.
- Owner-driven T05-T07 on 2026-08-30 captured eight targeted `0x000d` archives. Studio requires an action-backed tile and transmits display edits immediately. Repeated empty-title and `HIDHOGG-T05` states normalized identically; `HIDHOGG-T05` to `HIDHOGG-T06` changed only `Text`; deletion is `State: 0` plus `ViewParam: [{"Font":"","Text":""}]`; moving `0_0` to `1_0` emitted the new content before the old-position tombstone in the observed run. All rendered Text-action PNGs were byte-identical despite regenerated UUID filenames.
- Owner-driven T08 on 2026-08-30 corrected the trigger model: encoder assignment does not invoke `0x0011`; changing the Studio small-window radio mode does. Two controlled `Time` to `Knob` transitions each emitted exactly one 1,866-byte `0x0011` ZIP. Raw ZIP hashes differed because of generated UUIDs and timestamps, while normalized manifest SHA-256 `857ae8ca6cb399c424c70e2c2d3f811888e024b39cbaa82e9cb1804aabddccf5` and PNG SHA-256 `12eef5f47405971014f91b2696a8960b64a28274f4c1f8f661a93bc585bcfcee` matched. The manifest maps knobs 1-3 to `2_3`, `3_3`, and `4_3`; empty knobs are explicit tombstones.
- Owner-driven T03 changed only tile alignment from `bottom` to `center`. Both captured `0x000d` archives normalized identically, and deleting only `Font.Align` made them equal the retained bottom baseline. PNG bytes did not change.
- Owner-driven T04 incremented title size from 10 to 11. One 1,678-byte `0x000d` was emitted; after UUID normalization only `Font.Size` differs from the retained baseline, and the PNG bytes are unchanged.
- Owner-driven T12 proved that Studio's wide-tile Background radio is numeric mode `2`. Without configured artwork the wide tile was blank, and no immediate `0x0006`/`2|` was observed. Selecting a project-owned 458-by-196 PNG opened a crop/preview dialog; Save emitted one 1,608-byte `0x000d` archive at `3_2` with `SmallViewMode: 2`. Studio preserved the dimensions, converted RGB to RGBA, and applied transparent rounded corners. The owner confirmed correct full-width rendering without unexpected cropping or stretching.
- Owner-driven T13 on 2026-09-02 established the screensaver-artwork commit boundary using controlled metadata-free `1220 × 708` fixtures. Opening and cancelling the editor produced no non-periodic command and no visible device change. Committing fixture A emitted `0x0009` with a 40,982-byte payload and made A visible. Committing fixture B from the A baseline emitted `0x0009` with a 130,798-byte payload and made B visible. The SS-U2 chronology exhausted its 256-event cap before commit during the interactive delay, so only its authorized payload and physical outcome are retained as evidence. The owner waived the A-restoration repeat; deterministic encoding and exact firmware-required `0x0009` details remain unresolved.
- Offline T14 analysis on 2026-09-03 reconciled both `0x0009` artifact hashes and lengths against their authorization logs. Each logical payload is one ZIP entry using Deflate method 8. Studio re-encoded the opaque RGBA fixture as a `1220 × 708`, 8-bit RGB PNG with a `pHYs` chunk; A contains a 47,567-byte PNG and B a 138,324-byte PNG. Both archives pass structural validation. This supports a semantic clean-room encoder boundary, not byte-exact Studio emulation: filename, ZIP metadata, timestamps, compression, RGB conversion, alpha policy, and `pHYs` remain implementation choices until physical acceptance isolates firmware requirements.
- Owner-driven T09-T11 captured six `0x0101` payloads from square `0_0` and the physical middle encoder. They independently matched the direct-probe wire-index, marker, and release/press/left/right action mapping; all bytes after offset 3 were zero.
- Further unattended launch-only captures would repeat the saturated connection baseline. The remaining T13 work is offline analysis of controlled `0x0009` artifacts; revised brightness-zero and optional mode-100 causal trials require owner-driven device interaction. The installed application must remain untouched; future causal trials should use project-owned synthetic inputs and change one variable at a time.
- Any proprietary-client observation must be reimplemented independently using project-owned synthetic fixtures. Raw captured assets, device identifiers, personal labels, paths, and proprietary content must not enter the repository.

## Sources

- [go-ctap/hid](https://pkg.go.dev/github.com/go-ctap/hid)
- [go-toml](https://github.com/pelletier/go-toml)
- [HuJSON](https://github.com/tailscale/hujson)
- [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- [Bitfocus D200/D200X surface implementation](https://github.com/bitfocus/companion-surface-ulanzi-stream-controller)
- [ulanzi-linux protocol notes](https://github.com/marcelobrake/ulanzi-linux/blob/main/docs/protocol.md)
