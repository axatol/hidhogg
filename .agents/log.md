# Hidhogg decision log

## 2026-09-19 — M-07 defaults approved and configuration slice started

- M-07 owner physical acceptance passed. The owner confirmed all runbook checks. While dimmed, emitting `WAKE` did not wake or brighten the display; manual wake retained the overlay; the next selection restored only that tile to `status`. This is evidence for the owned D200X/current firmware, not a cross-firmware guarantee. M-07 is complete; no commit has been requested.

- M-07 implementation P01/C01/R01/I01/A01 and automatic V01 gates are complete; owner physical V01 remains pending. Independent whole-tree uncached tests/race/vet/build and final architect review pass. Main fresh full tests/vet, Darwin arm64/amd64 command builds, deterministic schema regeneration and whitespace checks pass. Independent normal suite repeated the separately recorded lock-helper race once and passed its single rerun; full race suite passed. The ready owner runbook is `docs/m07-notification-runbook.md`. No hardware/apps/native input, M-07 commit or completion notification occurred; no verification command remains active.
- Review fixes preserve four critical boundaries: redraw gating spans state publication; cancellation is caller-linked and idempotent before write; strict IPC/CLI validation tracks field/flag presence rather than nonzero values; selection rechecks TTL after prebuild under the gate. Successful authorized writes publish despite later cancellation/expiry, and subsequent reload does not retroactively cancel that static-action authorization. Cooperative budgets are not hard OS/HID bounds; dimmed firmware behaviour is explicitly unverified until owner acceptance.

- I01 executor tests/race/vet/full uncached suite passed. Strict notification codec/client/server/discovery-aware CLI and protocol documentation are implemented; review found and executor fixed foreign-response DTO contamination, empty-first duplicate flags and explicit empty inappropriate profile flags. Independent I01 verification remains pending. A01 tile-local physical dismissal is now delegated with runtime-only ownership; no hardware interaction is authorized or underway.

- R01 executor gates passed focused notification race tests, ten-repeat cancellation/shutdown stress and focused vet. A04 resolved the shutdown test contract: an admitted caller may receive success or `ErrClosed`, but a successful write must publish before `Close` returns, with queued mutations rejected and timers stopped. The first full suite repeated the separately recorded discovery helper race; the immediate rerun passed. Independent R01 review remains pending; I01 is delegated to the same executor with IPC/CLI/adapter-only ownership. No hardware test or M-07 commit has occurred.

- Independent C01 review passed focused tests/race/vet, source-boundary/schema/catalog/reload regressions, formatting and whitespace checks with no blockers. This closes C01; it does not establish notification runtime behaviour or physical acceptance.

- Sequential reuse of available executor/reviewer threads succeeded after the new-thread limit; no main-agent implementation takeover was necessary. C01 automatic gates passed and independent review is pending; R01 delegated to the same executor with a new bounded ownership capsule. The asynchronous workflow-choice question is superseded by successful reuse.

- Architect codec cross-check corrected a main-agent planning error before any IPC changes: the flat Go Request DTO is explicitly encoded into the existing nested `params` wire envelope. M-07 preserves that envelope; the notification plan was corrected against EncodeRequest/DecodeRequest.

- Owner approved the notification defaults. Final architect consultation froze exact source grammar, a 16-filter per-position bound, canonical generation-local notification IDs, bounded emit/clear replies, five-second cooperative runtime budgets, and notification-specific seven-second default client read allowances. Timeout/disconnect remains outcome-unknown; no automatic retry or new idempotency/list API.
- M-07-C01 delegated to the configuration executor, including immutable profile propagation, schema validation, and a narrow reload catalog-equality integration check. Filters do not change rendered baseline pages or action bindings.
- Runtime/IPC delegation was refused by the agent-thread limit; attempting reuse also failed. Main did not silently assume implementation ownership. Owner was asked whether to resume in a fresh session or approve direct implementation. Until resolved, runtime/IPC work remains planned.
- Existing opt-in D200X diagnostics expose bounded report prefixes/digests rather than full packets. Notification documentation qualifies content-confidentiality claims instead of assuming those fragments are harmless.

## 2026-09-18 — Completed Go commit and M-07 planning

- Owner-approved completed label, gesture, native-input, permission/status/doctor work committed as `78732e5`. Protected untracked files and ignored deploy configuration were not included.
- M-07 notification draft recorded in `docs/m07-notification-plan.md`; no notification implementation was performed. Architect consultation supports extending existing profile/reload coordination rather than introducing another device writer. Owner-visible defaults and remaining timeout/ID recovery contract details await approval.
- Fresh full-suite rerun, ten isolated lock-test repetitions, vet and standalone native-spike tests passed. The initial lock-test failure is explained by a readiness-marker/immediate-helper-exit race and recorded as a test-hardening follow-up, not a demonstrated production defect.

## 2026-08-22 — Planning baseline

- Status: provisional; owner decision pending `D-01`.
- Product: personal-use macOS 26+ HID utility, initially one D200X and one page.
- Runtime preference: cgo-free Go if physical D200X feasibility passes; otherwise native Swift.
- Configuration preference: TOML if required GUI edits are lossless; otherwise JSONC.
- Security boundary: inbound notifications are display-only and cannot supply executable commands. Physical controls may invoke statically configured executable paths with argument arrays.
- Persistence: immediate GUI writes, content-hash conflict refusal, atomic replacement, and last-known-good runtime behavior for invalid external edits.
- Reference policy: `UlanziDeckControl` supplies evidence only, not a product or code foundation.
- Uncertainty: pure-Go macOS HID and lossless TOML editing remain unverified in this repository.

## 2026-08-22 — S-01 automatic evidence and permission blocker

- `go-ctap/hid v0.11.0` builds and tests with cgo disabled.
- One physical D200X exposes both a consumer-control and keyboard top-level collection on interface 0 through this backend. Exact usage filtering is required in addition to VID, PID, and interface number.
- Read-only enumeration selects one `0x000c:0x0001` collection after rejecting `0x0001:0x0006`.
- The first open returned `0xe00002e2`; no physical write occurred. Go architecture selection remains blocked pending an authorized hardware run.
- The required Discord blocker notification failed inside the sandbox because DNS resolution was unavailable. The escalated retry was rejected because the external destination and payload lacked explicit approval. No workaround was attempted.

## 2026-08-22 — S-02 measured result

- Pinned go-toml's exact edit-capable pseudo-version passed 34/34 required cases and 8/8 exact same-line minimal-edit checks.
- HuJSON passed 2 malformed-input cases but failed all 32 mutation preservation comparisons by changing untouched trailing commas.
- TOML is recommended provisionally. The unstable dependency pin and filesystem TOCTOU limitation remain explicit risks; the owner has not declared a stable format.

## 2026-08-23 — S-01 physical evidence and display repair

- An authorized terminal completed 20 open/close iterations and captured the required touch, physical-button, and encoder inputs.
- Brightness changes were visually confirmed on the physical D200X.
- The first diagnostic display attempt failed. The generated manifest omitted each `ViewParam` closing bracket and was invalid JSON; automated tests had only compared it to itself and therefore missed the defect.
- The manifest repair now has independent JSON and coordinate-mapping validation. Plain, race, vet, archive, framing, and independent review checks pass, but physical display behavior remains unverified.
- One reconnect/session-replacement cycle was recorded against the then-current three-cycle gate; the later owner decision below supersedes that threshold.

## 2026-08-23 — S-01 completed under revised reconnect gate

- The repaired archive physically displayed colored numbered tiles. Low number legibility is confined to diagnostic artwork and does not invalidate the protocol result.
- The owner reduced the reconnect feasibility gate from three cycles to one. One disconnect, reconnect, and active-session replacement passed; repeated-cycle reliability remains unmeasured.
- `S-01` is complete. Both feasibility spikes now support owner decision `D-01`; neither the runtime architecture nor configuration format has yet been selected.

## 2026-08-24 — D-01 production direction selected

- The owner selected a Go core with a SwiftUI client and TOML configuration.
- `D-01` is complete. `M-01` is ready for planning, but its production scaffold boundary has not been defined or approved.
- The owner accepts reconnect reliability as an implementation assumption. This is a risk decision, not additional physical evidence: only one reconnect/session-replacement cycle has been measured, and repeated-cycle reliability remains unverified.
- The TOML editing dependency must remain behind a Hidhogg-owned adapter with regression coverage because the tested edit-capable version is an unstable pin.

## 2026-08-24 — M-01 boundary approved for planning

- The owner approved the `M-01` scaffold boundary and a SwiftUI-supervised Go process model.
- `M-01` establishes testable shells and internal contracts only. Product behavior, physical HID integration, public configuration schema, packaging, signing, login items, and `launchd` remain out of scope.
- The Go module uses Go 1.26 as its minimum language baseline. Go 1.27 was not installed or tested during `M-01`.
- The local scaffold protocol is versioned, JSON-encoded, bounded, owner-only, and restricted to health/status. It cannot carry executable commands.
- Implementation remains pending owner approval of the detailed roadmap tasks.

## 2026-08-24 — M-01 authorized and independently revised

- The owner authorized the main agent to complete `M-01`, research consequential decisions, seek architect consensus, and maintain a separate review register while continuing.
- Independent architecture review returned `revise before implementation`; the selected Go/Swift architecture was accepted, while IPC, endpoint, and process-supervision contracts required tightening.
- Architect consensus selected one LF-framed request and response per connection, strict shared v1 JSON fixtures, 16 KiB frames, one-second phase deadlines, eight concurrent connections, unique per-generation endpoints, UUID instance attribution, bounded output, fixed shutdown escalation, and one automatic restart.
- `M-01` was narrowed to exercised runtime and IPC boundaries. Action, notification, D200X, HID, and TOML implementation packages are deferred.
- Installed tools are Go 1.26.4, Swift 6.3.3, and Xcode 26.6. The installed macOS SDK exposes a 104-byte `sun_path` and Swift imports `getpeereid`; Go's `x/sys/unix` exposes `GetsockoptXucred` with `SOL_LOCAL` and `LOCAL_PEERCRED`.

## 2026-08-24 — M-01-P01 contract frozen

- `api/protocol/v1` is the normative internal scaffold contract and shared Go/Swift fixture corpus.
- Independent architect review required two correction rounds covering deterministic post-LF behavior, crash cleanup, generated-case oracles, validation precedence, missing-LF timeout behavior, and field/type error precedence.
- The architect approved the corrected contract with no remaining implementation-blocking semantic ambiguity.
- `M-01-P01` is complete. `M-01-G01`, `M-01-I01`, and `M-01-S01` may proceed within the frozen contract.

## 2026-08-24 — M-01 endpoint root revised after execution evidence

- Escalated XCTest execution showed that Foundation's per-user temporary-directory path exceeded Darwin's 104-byte Unix-socket path field, so the production Swift supervisor could not launch.
- Architect consensus replaced the environment-derived root with literal `/private/tmp`, verified at startup as a real UID-0-owned `01777` directory. Each generation is an atomic effective-UID-owned `0700` child named `hidhogg-<euid>-<UUID>`.
- The target host read-only check reported `/private/tmp` as UID 0, mode `041777`, directory. Future sandboxed packaging must revisit the location.

## 2026-08-24 — M-01 cleanup threat boundary corrected

- Independent verification found that Swift overwrote the first recorded socket identity and that both languages ultimately rely on a pathname identity check followed by unlink.
- Architect consensus found no macOS compare-and-unlink primitive available to the cgo-free Go and Swift scaffold. `M-01` therefore trusts same-effective-UID processes and records the final check/unlink race instead of claiming atomic conditional cleanup.
- Observable identity, type, owner, or mode mismatches must remain untouched. Swift must retain the first identity and treat drift as a security failure.
- Generated manifest families are milestone-blocking test requirements; exhaustive fuzzing, sustained load, adversarial same-UID stress, packaging isolation, and repeated physical reconnects remain future work.

## 2026-08-24 — M-01 production scaffold completed

- The Go runtime and CLI, strict bounded Unix-socket health/status IPC, SwiftUI menu-bar shell, process supervisor, shared fixtures, and live Go/Swift integration are implemented.
- Architect consensus added pre-health, post-health, and ready-state endpoint identity checks. The first socket identity is retained; observable drift is terminal and guarded cleanup preserves replacements.
- Independent verification found and reproduced one Go cleanup defect: mode-mutated sockets were identity-checked but not required to remain `0600`. Both unlink guards now enforce type, owner, mode, and identity; the regression test and a fresh live `0644` mutation probe pass.
- Final gates pass: cgo-free Go build, unit tests, race tests, vet, `git diff --check`, and 15/15 Xcode tests including live runtime integration.
- `M-01` is complete. Residual risks are the accepted same-effective-UID pathname race, untested Go 1.27, no dedicated Swift post-ready substitution test, deferred packaging isolation, and unmeasured repeated reconnect reliability.

## 2026-08-24 — M-01-F01 bundled-runtime correction completed

- Xcode launches initially failed because the app bundle contained no Go runtime and the app fell back to absent `/usr/local/bin/hidhogg`. Two empty generation directories confirmed cleanup failures were being discarded.
- The Go runtime is now an always-run, cache-backed Xcode build output atomically installed as `Contents/MacOS/hidhogg-runtime`. The initial case-only `hidhogg` name was rejected after it overwrote the Swift `Hidhogg` executable on case-insensitive APFS.
- `NSApplicationDelegateAdaptor` now starts the shared model eagerly and uses an AppKit terminate-later handshake so normal application termination awaits supervisor cleanup. Launch failure cleanup is observable, and two failed attempts leave no generation directories.
- Hosted XCTest originally orphaned the eagerly started runtime because test-host teardown bypasses normal termination. A dedicated `Test` configuration defines `HIDHOGG_TEST_HOST` only for the app target and compiles out only automatic app-owned startup; explicit live integration remains enabled.
- Final independent verification passes 17/17 tests with identical pre/post process and generation inventories. Two Debug direct-launch probes reached matching health/status readiness and normal quit removed each child, socket, and generation.
- Signing and notarization of the nested runtime remain deferred and unverified.

## 2026-08-24 — M-01-F02 Xcode GUI build correction completed

- GUI-launched Xcode could not resolve Go because the installed executable is under Apple Silicon Homebrew and the build phase inherited no interactive shell path.
- The runtime phase now checks standard Apple Silicon Homebrew, official Go installer, and Intel Homebrew locations before its supplied `PATH`, and emits actionable remediation if none contains Go.
- All best-effort cleanup calls explicitly discard their returned result, removing the unused-result Swift diagnostics without changing cleanup semantics.
- Independent verification passed a fresh restricted-`PATH` universal build, warning audit, bundle inspection, direct bundled-runtime health/cleanup probe, and the existing 17/17 Test-configuration suite.

## 2026-08-26 — M-02 Go-only vertical slice authorized

- The owner authorized the next milestone as a thin functional slice in which one explicit TOML file drives one complete D200X page and decoded physical input through the production Go runtime.
- Independent architect review recommended strict validation before HID activity, all 14 display positions, deterministic label/colour rendering, an injected diagnostic event sink, and no actions, notifications, reload, rich assets, new IPC, or general device registry.
- The owner deferred all Swift-related work until the Go application is fully functional.
- Opt-in verbose diagnostics must log decoded input events and outbound packets. Raw HID paths, serials, and unrelated device identities remain prohibited from logs.
- The milestone-private schema uses `schema_version = 1`, rejects unknown fields, and will be generated deterministically from the same canonical Go model used for TOML decoding. Future root/device composition remains a deliberate migration.

## 2026-08-26 — M-02 automatic implementation verified

- Strict configuration, deterministic Draft-4 JSON Schema generation, the production D200X adapter, and direct Go runtime integration are implemented.
- Stable production dependencies are `go-toml/v2 v2.4.3` and `google/jsonschema-go v0.4.3`, both MIT licensed. The D200X adapter pins pre-v1 `go-ctap/hid v0.11.0`, Apache-2.0, as established by the feasibility spike.
- Two malformed transitive checksums introduced during parallel dependency integration were corrected by comparison with the retained spike and Go's authenticated module download; `go mod verify` now passes.
- Independent architecture review required exact integrated startup-order coverage, config/adapter position-map parity, and an explicit stdout-failure shutdown test. All corrections pass.
- Full cgo-free Go tests and race tests pass outside the socket-restricted sandbox; build, vet, schema regeneration, module tidy diff, module verification, and diff checks pass. Automated tests use fake transports and do not access HID hardware.
- Taplo is not installed, so direct Taplo consumption remains not run. The physical D200X gate remains not run.
- Deferring Swift creates an intentional temporary incompatibility: the current supervisor omits the newly required `--config-path`, so the bundled Swift application cannot launch the M-02 runtime until the later Swift milestone.

## 2026-08-26 — M-02 physical slice completed

- The official Taplo CLI linted `examples/d200x.toml` against the generated local Draft-4 schema without diagnostics.
- The direct Go runtime opened one owner-confirmed D200X and sent eight complete-display-upload reports followed by brightness `80`, unlock, and input-enable reports.
- The owner confirmed all 14 configured positions were visible and brightness 80 was applied.
- Two intentional interactions with configured tile `music` at position `4_0` each emitted exactly one ordered `pressed` then `released` event pair with no raw device identity.
- Controlled interruption closed the runtime and removed its Unix socket.
- `M-02` is complete. This evidence does not establish repeated reconnect reliability or Swift application compatibility.

## 2026-08-27 — Deploy-directory verification and immediate follow-up

- The owner verified a direct launch using `deploy/hidhogg.toml` and `deploy/runtime.sock` after setting `deploy` to owner-only mode `0700`.
- The live runtime repeated the expected upload, brightness, unlock, and input-enable sequence. `hidhoggctl health` returned protocol version 1, `ready`, and the exact launched instance ID.
- While running, the socket was an owner-owned Unix socket with mode `0600`; after controlled shutdown, `runtime.sock` was absent while the configuration remained.
- A deploy-path negative run using the checked-in unknown-field fixture exited with configuration failure, emitted no outbound packet diagnostic, and created no socket, confirming rejection before HID and IPC activity.
- macOS `uuidgen` emits uppercase hexadecimal, which the current canonical-lowercase parser rejects. Manual lowercasing works, but this is an avoidable CLI defect rather than a security requirement.
- `M-03` is the immediate next improvement: accept one runtime directory, generate and atomically publish the instance ID internally, normalize explicit UUID overrides case-insensitively, let the CLI discover runtime metadata, and validate IPC state before changing the physical device.

## 2026-08-27 — Extended deploy input verification exposed idle-state loss

- `hidhoggctl status` returned `ready`, protocol version 1, and the exact live instance ID.
- Every configured display input at wire indexes `0` through `13` emitted one correctly mapped pressed/released pair with the expected stable ID and position.
- Unconfigured physical inputs remained bounded and were not assigned invented tile identities: wire indexes `15` and `16` emitted button pairs; encoder indexes `17` and `18` emitted rotation and press/release events; index `19` emitted at least a left-rotation event before interruption.
- Before the owner completed the extended action matrix, the device entered its firmware screensaver state and the live runtime received no further input events. Runtime shutdown still removed `deploy/runtime.sock`.
- The temporal association is verified, but the cause is not: it may be firmware input suppression, a missing keep-awake/session command, or another protocol state transition. Extended idle-duration input reliability is therefore not established.

## 2026-08-27 — Controlled screensaver isolation reproduced the defect

- A fresh direct-Go run initialized the D200X and received a baseline `clock` press/release pair at wire index `0`.
- After the owner observed the firmware screensaver, `hidhoggctl status` still returned protocol version 1, `ready`, and the exact live instance ID.
- The owner then pressed the same display input twice. Neither interaction woke or changed the display, and the runtime received no input event.
- Controlled shutdown removed `deploy/runtime.sock`.
- The failure is isolated from process and IPC liveness: current `ready` does not prove that the configured D200X remains operational after its firmware idle transition.
- Cause remains unknown. Investigation must distinguish missing keep-awake/wake protocol behavior, firmware input suppression, and device-session state loss before selecting a correction.

## 2026-08-27 — M-02-F01 diagnostic boundary authorized

- The owner selected an application-owned screensaver plus keepalive direction, subject to physical evidence.
- Brightness zero is already visually confirmed to disable the screens, but input availability at brightness zero is unmeasured.
- `M-02-F01` will first measure square, physical-button, and encoder input at brightness zero, then test whether allowlisted known-safe packets recover input from a fresh firmware-screensaver state.
- The initial wake allowlist is brightness, unlock, input-enable, and complete configured-page upload. Arbitrary commands and uncertain-write retries remain prohibited.
- If brightness zero preserves input, the first wake interaction will be consumed before any future configured action. Final keepalive and idle behavior remain undecided until the matrix is complete.

## 2026-08-27 — First M-02-F01 physical run rejected the probe sequencing

- Automatic diagnostic gates and an independent review passed after adding exact closed-set wake-candidate, brightness-restore, no-retry, and multi-report cancellation coverage.
- In the first brightness-zero physical run, the square probe accepted the press event at wire index 0, but its release remained queued. The following wide-tile probe consumed that stale square release and failed before brightness zero was sent.
- The run was stopped immediately. This is a diagnostic-harness sequencing defect, not evidence of a D200X input failure.
- The confirmed repair boundary is to validate complete press/release pairs for tiles, physical buttons, and encoder presses; rotations remain single-event probes. Hardware testing must restart from a fresh generation after regression and independent verification pass.

## 2026-08-28 — Full baseline matrix exceeds the firmware idle window

- After the paired-event repair passed automatic and independent verification, a fresh physical run decoded the square pair at wire index 0 and the wide pair at wire index 13 exactly.
- Before the first physical-button probe completed, the owner observed the firmware screensaver. The run was stopped as indeterminate; brightness zero was never sent.
- Human-paced per-probe prompting therefore cannot reliably complete the full pre-zero baseline before firmware sleep. This does not establish a physical-button or encoder failure.
- The protocol requires revision to capture the baseline faster without an outbound keepalive contaminating the measurement.

## 2026-08-28 — Continuous-capture diagnostic and owner-run wrappers verified

- Architecture review rejected an outbound keepalive during the brightness-zero baseline because it would contaminate the measured firmware state.
- The brightness-zero diagnostic now proves one square pair, sends brightness zero immediately, continuously captures the compact full input matrix, restores configured brightness, and proves a recovery square pair. Monotonic write and operator-ready boundaries prevent stale or transition-overlapping events from being attributed to a phase.
- Closed-set firmware-wake diagnostics remain one candidate per fresh process. Failed, short, or canceled writes are not retried.
- Owner-run wrappers under `scripts/diagnostics` archive bounded JSONL observations, stderr, metadata, and SHA-256 manifests. Wake wrappers require a verified passing brightness-zero archive.
- Focused tests, race tests, vet, build, shell syntax, forged-report rejection, and declined-confirmation paths passed independent review. No hardware was accessed during this verification.

## 2026-08-28 — First owner-run continuous baseline was not attributable

- Archive `20260827T153157Z-brightness-zero` passed startup but rejected the baseline as `class-failure`; brightness zero, the zero-state matrix, and recovery were not run.
- The archive did not retain individual captured inputs, so the extra or mismatched event source could not be distinguished from stale, duplicate, malformed, or wrong input. It is not brightness-zero device evidence.
- The diagnostic now emits bounded per-event observations with monotonic sequence, phase, wire index, known marker/action, decode state, and classification. Raw HID reports, payloads, and device identity remain structurally absent.
- Independent review verified the Go observation path and strict jq/Python archive-validation parity, including rejection of raw, unknown, forged, and decoded-without-wire-index records.

## 2026-08-28 — Non-input frames isolated from decoded input validation

- Archive `20260827T161240Z-brightness-zero` captured three ordinary undecoded non-input frames followed by the exact square wire-index 0 pressed/released pair.
- The baseline failure was caused by the diagnostic counting those non-input frames in the exact decoded-input trace; brightness zero was not sent.
- Non-input frames remain bounded observations but are now excluded from baseline, zero-state, recovery, and write-overlap input validation. Malformed frames and wrong, duplicate, or transition-overlapping decoded input remain failures.
- Independent tests verified the correction across Go validation and both isolated archive-validator backends.

## 2026-08-28 — Encoder rotation overrides explicit brightness zero

- The owner confirmed the device was explicitly at brightness zero immediately before testing.
- Turning any encoder caused the device to restore brightness to 100 without an application brightness command.
- Using the spike CLI, the owner confirmed that display tiles and physical buttons did not restore brightness; the override occurred only with encoder knobs.
- Brightness zero is therefore not a stable passive application-owned screensaver state for encoder rotation, but the observed override is not a general input-wake behavior.
- A future idle design cannot assume that consuming the first decoded encoder interaction is sufficient: firmware may visibly illuminate the device at 100 before the application can respond.
- The owner also confirmed that sending brightness packets with the spike CLI did not dismiss the firmware screensaver. This is direct negative evidence for brightness alone as a visible firmware-screensaver wake candidate; input recovery from that packet remains unmeasured.

## 2026-08-28 — Spike-only known-command probe implemented

- The owner explicitly authorized a no-confirm experimental CLI for all 12 known D200X command IDs so behavior can be measured. Supplying an exact symbolic `--action` is the authorization boundary.
- `spikes/go-hid-d200x/cmd/d200xprobe` sends exactly one logical frame once, or passively listens with zero outbound frames. It permits only canonical brightness and the deterministic diagnostic upload parameters; numeric IDs and arbitrary payload injection remain unavailable.
- The experimental allowlist is confined to the nested spike module. The spike's normal `Session.SendFrame` and production `internal/d200x` safe-outbound refusals remain unchanged.
- Independent test, race, vet, build, stress, redaction, passive-listen, no-retry, exact-upload, and production-boundary verification passed. Physical behavior for the newly exposed commands remains unmeasured.
- Passive observation was subsequently revised to `--listen` for indefinite zero-write capture, with optional `--duration <positive duration>`. SIGINT/SIGTERM stops cleanly at a frame boundary and reports a partial assembled frame as failure; independent synthetic cancellation and stress verification passed.
- The owner cautioned that legacy packet-ordering and behavior assumptions may be wrong. Imported legacy material is therefore evidence only for captured bytes and observed temporal sequences; it is not a causal ordering contract, stable firmware guarantee, or proof that a completed write was accepted.
- The spike probe now accepts strict typed JSON for captured `0x0006` modes `0`, `1`, `2`, and `200...203`, reproducing legacy golden payload bytes exactly while making no behavior claim. Mode `100` remains rejected because its associated `0x0011` artwork initialization is unresolved. Independent golden, parser, redaction, one-write, stress, and production-boundary verification passed.

## 2026-08-29 — Individual firmware-screensaver wake observations

- The owner confirmed that input remains receivable at brightness zero while the native firmware screensaver is inactive. Brightness zero alone therefore does not account for the previously observed input suppression; the exact input classes tested were not recorded exhaustively.
- The owner confirmed that `enable-input-stream` (`0x0002`), `small-window-refresh` (`0x0006`), and `unlock-screen` (`0x0010`) were tested individually while the tested D200X was in its native firmware screensaver state.
- Each command dismissed the screensaver and restored input reception. The exact `small-window-refresh` parameter fixture was not recorded.
- This establishes three observed wake candidates on one device. It does not establish required packet ordering, keepalive timing, necessity, sufficiency across firmware versions, or long-duration reliability.

## 2026-08-29 — Small-window refresh owner wrapper

- `scripts/diagnostics/small-window-refresh.sh` accepts exactly one captured mode from `0`, `1`, `2`, `200`, `201`, `202`, or `203` and invokes one fresh `d200xprobe` process with strict typed JSON.
- Mode `2` sends only `{"mode":2}`. Other modes use one local date/time snapshot, zero-valued bounded metrics, and only the fields required by that captured mode.
- Missing, extra, unsupported, padded, and raw-payload arguments refuse before Go execution. The wrapper does not inspect configuration, retry, loop, or batch modes.
- Synthetic wrapper checks, spike Go tests, independent adversarial verification, syntax checks, and diff checks pass without HID access. Physical behavior remains owner-run evidence.

## 2026-08-29 — Small-window presets integrated into d200xprobe

- The temporary small-window shell wrapper was superseded and removed. `d200xprobe --action small-window-refresh --parameters <preset>` now accepts `metrics`, `dial-time`, `background`, `date-time-weekday`, `time-weekday`, `date-time`, and `time`, mapping respectively to captured modes `0`, `1`, `2`, `200`, `201`, `202`, and `203`.
- Generated presets use one local clock snapshot, zero CPU/RAM/GPU values, `24H`, and only mode-required fields. `background` does not read the clock and emits exactly `2|`. Strict JSON fixtures remain unchanged.
- Focused exact-payload and pre-enumeration refusal tests, full cgo-free tests, race tests, vet, both CLI builds, independent verification, and diff checks pass without HID access. Physical behavior remains owner-run evidence.

## 2026-08-29 — Synthetic metric probe and mode-2 observation

- The owner observed that the mode-`2` `background` preset displayed a metrics view when selected after other modes, including `date-time`. The earlier mode-`0` `metrics` preset used zero values and did not visibly report metrics.
- This supports investigation of a two-packet model in which mode `0` updates metric values and mode `2` selects their view, but does not prove ordering, necessity, or causality.
- The `metrics` preset now generates independent synthetic CPU/RAM/GPU integers from `1` through `99`, includes them in one mode-`0` frame, and reports them only after a successful write. Exact JSON fixtures remain deterministic.
- Random-source errors or invalid values refuse before HID access and are never retried. Tests cover failure at each of the three draws, exact payload and output, failed-write suppression, one frame, full cgo-free tests, race, vet, build, and independent verification without HID access.
- The owner subsequently confirmed that a physical mode-`0` `metrics` run displayed the generated nonzero synthetic values. This validates mode-0 metric value injection on the tested D200X; mode `2` and the proposed mode-0/mode-2 sequencing relationship remain unconfirmed.

## 2026-08-29 — M-02-F01 handoff checkpoint

- M-02-F01 remains in progress. Manual physical probes provide useful evidence, but no trusted passing archive exists for the current continuous-capture brightness-zero diagnostic, so the roadmap acceptance matrix is not complete.
- Independent handoff audit found no documentation/source contradiction in the probe implementation. It identified stale document dates and broad handoff wording, which were corrected.
- The next physical question is an isolated mode-`2` run from a recorded non-metrics view. The next process decision is whether to retain the archived diagnostic matrix as a completion gate or explicitly revise that gate based on owner acceptance.
- Before another archived run, review the 48-record diagnostic cap against 20 required decoded events plus possible non-input frames. This is a source-level boundedness risk, not a reproduced physical failure.
- The worktree remains uncommitted. An untracked compiled `spikes/go-hid-d200x/d200xprobe` artifact may be stale; protected unrelated `.envrc`, `.codex`, and Xcode workspace metadata were not inspected or modified.

## 2026-08-30 — Ulanzi Studio bounded static interoperability analysis

- The owner authorized static interoperability analysis of `/Volumes/Data/Applications/Ulanzi Studio.app`. The installed application remained untouched and unlaunched; application data, preferences, logs, accounts, telemetry, unrelated assets, and protection bypass were excluded.
- The arm64 Qt executable `UlanziDeck` is 57,231,952 bytes with SHA-256 `b64e598411c0d67fc44b08b09820e0b5fea12ce26052c44098e96bbd9b2c3022`. A static-only copy excluding unreadable `.DS_Store` files has identical executable bytes but an invalid bundle seal and must never be launched.
- Static disassembly independently verified the complete native path from `UlanziDeck` through `SendDataQueue`, `HIDDevice`, bundled hidapi, and `IOHIDDeviceSetReport`. The application uses `7c 7c`, little-endian payload length, 1,024-byte protocol chunks, a leading HID report ID byte, and a 100 ms read timeout.
- `0x0003` is a zero-payload command emitted on device/connect/settings paths. `0x000b` carries font-style JSON on connection; the later full-payload capture established that its serialization is indented rather than compact. `0x000d` and mode-100 `0x0011` carry raw bytes of conventional ZIP archives containing `manifest.json` plus `Images/`.
- Inbound `0x010b` routes to the font-style update path; inbound `0x0303` is treated as NUL-terminated UTF-8 JSON for device-profile migration/initialization. A cross-check corrected an initial misclassification: four-byte key/position/type/status input belongs to `0x0101`, not `0x010b`.
- Xcode command-line disassembly is sufficient for framing, command identity, call paths, and broad payload shape. Exact archive manifest nesting remains unresolved and would benefit from a dedicated decompiler. Dynamic tracing remains a separate authorization gate and must not bypass hardened-runtime or signing controls.

## 2026-08-30 — LLDB phase prepared but not authorized for execution

- `docs/ulanzi-studio-lldb-runbook.md` defines an isolated, symbol-based procedure for bounded outbound, inbound, and optional hidapi captures.
- The first execution gate is ordinary LLDB launch from a new local standard account with no prior Ulanzi Studio state and networking disconnected. A debugger/signing denial is a stop result; protection bypass, patching, resigning, injection, and security-control changes remain prohibited.
- The trial matrix starts with two repeat connection captures and stops for review before font, ZIP, input, or screensaver experiments. Every later trial changes one variable per fresh process.
- Raw captures remain outside the repository. Only hashes, bounded derived protocol fields, evidence classification, and synthetic clean-room fixtures may be retained.
- Preparing the runbook did not launch, attach to, or modify Ulanzi Studio and does not constitute authorization to execute the dynamic phase.
- Static-only utilities now live under `scripts/diagnostics/ulanzi-lldb`. They verify the reviewed executable hash, architecture, and breakpoint resolution; create owner-only T01/T02 workspaces under `/private/tmp`; hash safe-named binary captures; and compare digest, size, and filename manifests.
- The preflight passed against both the non-runnable static specimen and the signed installed bundle, resolving the reviewed application entry addresses plus bundled `hid_write` and `hid_read_timeout`. Synthetic evidence validation exercised identical and different manifest outcomes plus refusal of empty, unsafe-named, and unprepared captures. No Ulanzi Studio process or HID access was attempted.

## 2026-08-30 — LLDB T01 blocked before target launch

- The owner explicitly authorized launching the installed Ulanzi Studio against the sole connected, owned D200X. The owner selected use of the existing macOS account and prior local application state, and restricted collection to command IDs, lengths, and bounded call stacks; payload bytes remained excluded.
- Physical network disconnection was unavailable. A per-process sandbox profile denying `network*` was validated by a local socket attempt failing with `EPERM`, then used to launch LLDB.
- LLDB loaded the reviewed arm64 executable, resolved `HIDDevice::sendDataToDeck`, `UlanziDeck::OnDeckFrameReceived`, `hid_write`, and `hid_read_timeout`, and installed both application breakpoints.
- `process launch` failed before target execution with status -1: task attachment was not allowed. No command identifiers, lengths, stacks, or payloads were collected; T02 was not attempted.
- Strict verification of the installed application reports `invalid signature (code or signature have been modified)`. Independently, `DevToolsSecurity -status` cannot resolve `system.privilege.taskport.debug`. The available evidence does not establish which condition caused the attachment denial.
- Per the approved stop rule, no patching, resigning, injection, permission mutation, security-control weakening, or Console-log inspection occurred. Trial evidence is outside the repository at `/private/tmp/ulanzi-lldb.5M53ad/T01-connect-baseline` and may disappear after reboot.

## 2026-08-30 — Temporary ad-hoc-copy exception authorized

- The owner corrected the historical context: the earlier `UlanziDeckControl` project records successful bounded LLDB observations against an authorized temporary ad-hoc-signed Ulanzi Studio 3.1.9 copy. Its `docs/research.md` and `.agents/log.md` establish the method and observations, although they do not retain the exact signing command; that temporary copy was removed.
- The owner explicitly authorized reproducing that approach for M-02-F03. The exception permits creating and ad-hoc signing one new owner-only temporary copy. The initial whole-file-identity condition was corrected before signing: embedded-signature replacement necessarily changes the executable file, so the enforceable integrity gate is whole-executable identity before signing and identical `__TEXT,__text` machine-code bytes afterward.
- The installed application and both existing static specimens remain protected from modification. Payload contents remain excluded; networking remains denied for the traced process; T01/T02 remain the stop gate.
- The exception does not authorize changing SIP, AMFI, debugger authorization, entitlements, or other system security controls. Failure after temporary-copy signing remains a stop result.

## 2026-08-30 — Ad-hoc T01 invalidated by network-deny enclosure

- A fresh owner-only copy at `/private/tmp/ulanzi-lldb-runnable.87Jf7l` was byte-identical to the reviewed main executable before signing. Ad-hoc signing produced a valid bundle; the expected whole-file hash changed, while the `__TEXT,__text` hash remained `5a07a3228e601d32c5996c758ca3558c39180f06b80438e6dc40ad2970a58e90`, identical to the installed specimen.
- LLDB successfully launched the ad-hoc target and resolved both D200X breakpoints. The target then reported `sandbox initialization failed: Operation not permitted` twice under the enclosing per-process network-deny sandbox.
- After initialization, outbound and inbound breakpoint hit counts both remained zero. The process was manually stopped without UI interaction. No command IDs, lengths, stacks, or payload bytes were captured, so the run is invalid as T01 and T02 remains unstarted.
- Retrying without the network-deny enclosure changes the approved data-exposure boundary and requires explicit confirmation. The disposable copy remains pending the research decision and must be removed after the approved trials or abandonment.

## 2026-08-30 — Normal-network T01/T02 retry authorized

- The owner authorized retrying the disposable-copy trials with Ulanzi Studio's normal network access after the enclosing network-deny sandbox invalidated application initialization.
- This is an operational exception, not evidence that network access is causally required. LLDB will discard target stdout/stderr and capture only D200X command identifiers, lengths, and bounded stacks; payload contents, network traffic, application data, and account state remain excluded.
- The no-login condition, owned D200X boundary, installed/static-copy immutability, T01/T02 stop gate, and post-research deletion of the disposable copy remain in force.

## 2026-08-30 — Connection observation gate completed

- Two preliminary harness runs were rejected: the first retained only `continue` from repeated one-line LLDB breakpoint commands, and the second was the already recorded network-deny sandbox failure. Neither contributes protocol evidence.
- Valid T01 and T02 used multiline breakpoint command lists verified before launch. Outbound capture read command words and payload lengths; inbound capture read only the eight-byte frame header; each hit retained at most eight stack frames. Payload contents and target stdout/stderr were not captured.
- Both trials repeated the same initialization prefix: outbound `0x0003/0`, `0x0001/5633`, `0x000b/144`; inbound `0x0303/1014`; outbound `0x000a/2`, `0x0003/0`; inbound `0x0303/1014`; outbound `0x000a/2`.
- Both trials then emitted periodic outbound `0x0006` from `SendSmallWinInfoToDeck::$_1`. T01 observed five 26-byte occurrences; T02 observed six 25-byte occurrences. The count reflects unequal observation duration. Payload exclusion leaves the verified one-byte length difference unexplained.
- T01's owner-only 17,664-byte transcript has SHA-256 `701074ad46011e6e6baf0fc6fa99b9626731dad912a8863f68f5c96f43812005`; T02's 17,682-byte transcript has SHA-256 `afcc34ae8079b195c03014614bd9df356d9ac1aae6101711b78ef2d2f3dc85f5`. Both remain outside the repository under `/private/tmp/ulanzi-lldb.m4xHv3/` for owner review and may disappear after reboot.
- The repeated prefix is observed application chronology, not a causal device ordering guarantee. The normal-network success does not establish that network access was required. Later font, ZIP, input, and screensaver trials remain behind the owner review gate.
- The exact owner-only disposable directory `/private/tmp/ulanzi-lldb-runnable.87Jf7l` was removed after both targets had been terminated. The installed bundle, static specimen, and retained evidence workspace were not removed.

## 2026-08-30 — Complete D200X payload inspection authorized

- The owner clarified that maximizing protocol learning is the governing objective and that the existing Studio and device data contain nothing secret. Complete D200X logical packets and their derived JSON, ZIP, image, profile, and device-metadata contents may be captured and inspected.
- The earlier metadata-only connection boundary was unnecessarily restrictive relative to the milestone goal. It remains documented as the scope of T01/T02 rather than being recharacterized after the fact.
- The expansion applies to repeat connection trials `T01P` and `T02P`. It does not authorize inspection of unrelated application memory or network traffic. Raw captures remain owner-only outside Git, and a newly created ad-hoc-signed disposable copy must be removed after the review gate.

## 2026-08-30 — Full-payload connection gate completed

- T01P and T02P captured every non-empty D200X logical payload in two fresh connection-only launches. The inspected executable matched the installed specimen before ad-hoc signing, and `__TEXT,__text` remained byte-identical afterward. Target stdout/stderr were discarded; unrelated memory and network traffic were not inspected.
- Stable captured bytes: `0x000b` is 144-byte indented six-field font JSON with SHA-256 `1b1d9b3dcaf219585488071ece82f3a98b9cbb32c890149867dda51be30cbebc`; `0x000a` is ASCII `44` with SHA-256 `71ee45a3c0db9a9865f7313dd3372cf60dca6479d46261f3542eb9346e4a04d6`; all four 1,014-byte `0x0303` captures share SHA-256 `9fc85325ef5f80e87a6a042e8cf4bf196a95360a905872ec33ef7ddc62e19a4e`.
- `0x0303` consists of 149 bytes of UTF-8 JSON followed by 865 NUL bytes. Its keys are `SerialNumber`, `Dversion`, `error`, `DeviceType`, and `HardwareVersion`; the identifier value was not copied into Git.
- T01P/T02P `0x0001` ZIPs were 5,634 and 5,632 bytes. Generated UUID filenames, entry order, timestamps, and raw compression differ; their normalized sorted manifests share SHA-256 `f35628660a902c3af7b455cfd64c1376f0ef4cb15e78134b8cc4ae276d39e260`, and their four-PNG content multisets are equal.
- Periodic `0x0006` is ASCII `100|CPU|RAM|HH:mm:ss|GPU|12H|` with unpadded decimal values. This data-dependent grammar explains the earlier 25/26-byte variation, although the discarded earlier values cannot be recovered.
- The prior static-only claim that `0x000b` was compact JSON was wrong and has been corrected. Captured bytes establish indented JSON.
- Manual binary dumping perturbed asynchronous order. T01P/T02P are payload evidence; the earlier auto-continue T01/T02 remain the chronology evidence.
- Owner-only captures and transcripts remain temporarily under `/private/tmp/ulanzi-lldb-payload.zSRQIR/`. T01P and T02P transcript SHA-256 values are `bb33adc27792dbde7450794087f3b9c3d51d5c80e532f8e835465e5cc1370c60` and `437a27ad8bfc928b7f1cbc0fd79bcf0ac1ab39436e7ca2947de5a8b3130bfea9`.
- After both LLDB targets had ended and evidence hashes were recorded, the exact disposable root `/private/tmp/ulanzi-lldb-runnable.VWfCYn` was permanently removed. The installed Ulanzi Studio bundle and `/private/tmp/ulanzi-lldb-payload.zSRQIR/` evidence remain.

## 2026-08-30 — Automated Ulanzi Studio gap analysis completed

- A final static pass established that connection upload `0x0001`, targeted key upload `0x000d`, and mode-100 encoder upload `0x0011` all use `ItemBeanProfileManager::createZip` and the same `fillEncoderJson` callback. Their distinction is profile selection and command ID, not archive schema.
- `0x000d` selects one current-page key profile. Mode-100 `0x0011` selects the current page's `Encoder` profiles and falls back to ordinary `0x0006` refresh outside mode 100. The common manifest builder emits ordinary `ViewParam`/`State` or an `Encoder` object and conditionally includes `SmallViewMode` for the small-window component or key `3_2`.
- Inbound `0x010b` ignores its payload, reads the current Studio font model, and invokes the outbound `0x000b` path. It is therefore a font retransmission request in Studio's implementation, not a correlated acknowledgement payload.
- Studio's `0x0303` parser consumes `SerialNumber`, `Dversion`, and optional `HardwareVersion`; it lowercases and validates the expected 17-character serial before device/profile lookup. No read of captured `DeviceType` or `error` was found in that path.
- `sendBackgroundBrightness` reads persisted per-device brightness, converts it to decimal ASCII, and asynchronously sends `0x000a`. This proves the source of captured `44`, but not why connection chronology invokes the path twice.
- Architect review and direct evidence agree that further unattended launches have low information value. Remaining gaps require owner-controlled one-variable trials: `0x000d`, `0x0011`, font changes, physical input, and native-screensaver behavior, in that order. Cross-firmware `0x0303` variability requires another specimen or controlled emulation.
- The previous removal of the disposable run copy happened at the earlier review gate. For any resumed interactive dynamic phase, create a fresh verified disposable copy and retain it until that overall phase ends; remove it only after the owner ends or abandons the temporary research phase.

## 2026-08-30 — Interactive targeted-key T05-T07 gate completed

- A fresh owner-only copy at `/private/tmp/ulanzi-lldb-runnable.zII2q5` matched the reviewed executable before signing, passed strict verification after ad-hoc signing, and retained `__TEXT,__text` SHA-256 `5a07a3228e601d32c5996c758ca3558c39180f06b80438e6dc40ad2970a58e90`. It remains retained for the active interactive phase.
- The first LLDB harness used the terminal UI plus a high-frequency register condition and made Studio unresponsive. Its main thread was observed in Qt backing-store rendering. That harness was terminated and rejected. A plain FIFO-driven LLDB console with producer breakpoints at `SendKeyZip` and `SendKeyZipFromCurrentPage` restored responsiveness.
- Studio requires an action before a tile can display text and has no save/submit boundary; display-affecting edits transmit immediately. Architect consensus selected the built-in System -> Text action as the least-confounded action-backed baseline. The fixed precomposed action string produced no `0x000d` producer hit; the tile was never physically pressed.
- Eight owner-only `0x000d` archives under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T05-one-key-upload` cover initial assignment, title T05, title T06, accidental deletion, repeated assignment, repeated title T05, and both move packets. Repeated normalized empty-title and T05 manifests are identical. All bundled Text-action PNG bytes share SHA-256 `9137b7981ab83b9e2034a892dda78ee2fa00684b7f85f1e6685f351bf5d0ef88`.
- Equal-length `HIDHOGG-T05` to `HIDHOGG-T06` changed only `ViewParam[0].Text`. Raw ZIP length varied independently because generated UUID filenames and archive metadata affect compression.
- Delete emits a 299-byte ZIP whose manifest explicitly clears the position with `State: 0` and `ViewParam: [{"Font":"","Text":""}]`. Moving `0_0` to `1_0` emitted new-position content first and the same old-position tombstone second in this observed run. Manual debugger stops preclude treating that order as a firmware requirement.
- The tile editor also exposes title visibility, size, color, and three alignment controls. These are verified future one-variable inputs; their packet deltas and ranges remain untested.

## 2026-08-30 — Interactive mode-100 T08 gate completed

- Static caller analysis corrected the initial intervention plan. Encoder assignment and removal did not hit `UlanziDeck::SendSmallWindowData_Knob`. `SystemSmallWindowsEditor::selectSmallWindowMode` emits `SignShowSmallWindows`; the connected `UlanziDeck::OnShowSmallWindows` invokes `SendSmallWindowData_Knob`, whose decimal-mode-100 branch sends `0x0011`.
- The owner reduced the profile to one Multimedia action on knob 1 and empty knobs 2 and 3. With capture disabled, Studio was switched to `Time` and allowed to settle. Selecting the Studio `Knob` radio produced exactly one outbound `0x0011`; the same controlled transition was repeated once and again produced exactly one.
- Both payloads were 1,866-byte ZIPs. Raw SHA-256 values were `a6fec39aa40a0af7e09199eb0776aaac88a99b86ebfe30ab7def6bb3c8dd7c5b` and `51b775bef3829715093ee2cc64785c38dc99a472fde292a1deddb48b04238bef`. Generated image UUIDs and ZIP timestamps differed, while normalized manifest SHA-256 `857ae8ca6cb399c424c70e2c2d3f811888e024b39cbaa82e9cb1804aabddccf5` and PNG SHA-256 `12eef5f47405971014f91b2696a8960b64a28274f4c1f8f661a93bc585bcfcee` matched.
- The manifest maps physical knobs 1-3 to positions `2_3`, `3_3`, and `4_3`. Knob 1 contains the `Encoder` layout; the two empty knobs are explicit `State: 0`/empty `ViewParam` tombstones. This corrects the earlier unverified assumption that archive coordinate `2_3` meant the physical third knob.
- Raw T08 captures remain owner-only under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T08-mode100-encoder/`. The active disposable copy remains retained for later interactive trials. Device-side necessity, minimal schema, visible firmware effect, and `0x0006`/`0x0011` ordering remain unresolved.

## 2026-08-30 — Interactive alignment T03 and wide-background T12 completed

- T03 changed the retained tile at `1_0` from `Font.Align: bottom` to `center`. Two captures each emitted exactly one 1,680-byte `0x000d`; their normalized manifests share SHA-256 `b7fd0901a4009dc6c85c52818b61a0376cf56b6825f1a48a165cb061b6c982e0`, their PNG bytes retain SHA-256 `9137b7981ab83b9e2034a892dda78ee2fa00684b7f85f1e6685f351bf5d0ef88`, and only `Font.Align` differs from the retained bottom baseline.
- The owner requested that future discovery trials not be routinely repeated. One controlled observation is sufficient unless output is ambiguous or contradicts prior evidence.
- T12 proved at the UI handler that the wide-tile Background radio supplies numeric mode `2`. The wide tile was blank without configured artwork. An exact filter observed no immediate outbound `0x0006` with payload `2|` during the bounded post-transition interval; other timer paths remain possible.
- Background file selection opens an `Edit Icon` crop/preview dialog with an explicit Save boundary. Saving a project-owned 458-by-196 RGB diagnostic PNG emitted exactly one 1,608-byte `0x000d`, raw SHA-256 `46459ca4ef76e40a12d99aaaec1a3e94b778e109885f5b842228c9e54e296041`. Its normalized manifest at `3_2` includes `SmallViewMode: 2` and has SHA-256 `702b3c098adf364f3e9d2a27e8deea04cdbf081f466427f65d5516f962179418`.
- Studio preserved the 458-by-196 dimensions, converted the source from RGB to RGBA, and applied transparent rounded corners. Source SHA-256 is `4d728692a942d2f12c91e7d488f5315c4e6dc67d98c4fb6a93d2b7c43d395094`; transformed PNG SHA-256 is `fa6a18eda0dc3d06231c44293d21cc0b8a30d9fe83f42a9cea4d0f25be05591d`. The owner confirmed correct full-width orientation without unexpected cropping or stretching. Extra colour bands were present in the interpolated source.
- Raw evidence remains owner-only under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T03-font-alignment/` and `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T12-background-wide/`. The disposable copy remains active with protocol breakpoints disabled.

## 2026-08-30 — Interactive title-size T04 completed

- From the restored bottom-aligned size-10 baseline, one stepper increment to size 11 emitted exactly one 1,678-byte `0x000d`, raw SHA-256 `528e44723128470cb6d5a8136601058df7171cb0fbdd2455f9d7f957a3f30e34`.
- The UUID-normalized manifest has SHA-256 `324b1d52239ea13a30570fc0aa2f310b5d8cd9f1ce65d0e20049cad387d3429b`. Deleting only `Font.Size` makes it equal the retained size-10 baseline. The PNG remains byte-identical with SHA-256 `9137b7981ab83b9e2034a892dda78ee2fa00684b7f85f1e6685f351bf5d0ef88`.
- No routine repeat was performed, following the owner's discovery-testing preference. Raw evidence remains owner-only under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T04-font-size/`; the breakpoint was disabled after its hit count was verified as one.

## 2026-08-30 — Interactive inbound-input T09-T11 completed

- A conditional breakpoint at `UlanziDeck::OnDeckFrameReceived` captured six inbound `0x0101` payloads from one unassigned square at `0_0` and the unassigned physical middle encoder. No configured Studio action executed.
- Every payload was 1,014 bytes with only the first four bytes nonzero. Square press/release were `01 00 01 01` and `01 00 01 00`; middle-encoder left/right/press/release were `01 12 02 02`, `01 12 02 03`, `01 12 02 01`, and `01 12 02 00`.
- This independently confirms the direct-probe mapping for the observed controls: byte 1 wire index, byte 2 button/encoder marker, and byte 3 release/press/left/right action. It does not establish an exhaustive firmware event namespace.
- Raw payload SHA-256 values and the evidence location `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T09-T11-input/` are recorded in `docs/ulanzi-studio-analysis.md`. The inbound breakpoint was disabled and Studio resumed; the disposable copy remains retained for screensaver trials.

## 2026-08-31 — S0 no-write screensaver control completed

- Architect review rejected Ulanzi Studio as the primary causal harness because its asynchronous and periodic traffic cannot attribute a wake to one frame. The agreed harness is `d200xprobe`, one candidate frame per fresh native-screensaver generation.
- The completed T09-T11 Studio target and LLDB process were terminated; the verified disposable bundle and raw evidence remain retained. No process from that session holds the D200X.
- With the native screensaver already visible, passive `d200xprobe --listen` opened the device and explicitly sent zero frames. Opening did not dismiss the screensaver. One owner-controlled `0_0` press/release did not dismiss it and emitted no frame.
- One `unlock-screen` frame was then used only to reset the specimen for a fresh generation. A passive listener captured exactly one `0_0` pressed/released pair with the same SHA-256 values as T09, proving working input before the new idle wait. The owner proceeded under an instruction to press only if the screensaver was gone, but did not separately state the visual result.
- The passive listener was stopped. The device is now waiting without an open Hidhogg/Studio process or outbound writes for the next native screensaver state. S1 will send exactly one `enable-input-stream` frame, then test one `0_0` press/release.

## 2026-08-31 — S1 single-frame input-enable wake passed

- From the fresh screensaver generation created after S0, `d200xprobe` sent exactly one `enable-input-stream` (`0x0002`) frame. No brightness, unlock, upload, small-window refresh, or retry was sent in S1.
- Before touching the D200X, the owner explicitly reported that the visible screensaver had disappeared.
- A passive zero-write listener then captured exactly one `0_0` press and release. The 1,014-byte payload SHA-256 values were `8d8d8158584390de642c28ea609110a4758e1a9d5e0e761ba0b0c675ca6dca74` and `663f5c56995bb094776d27cacbcc6ebf232bbec69cb841ba7d425cd493f17379`, matching the pre-idle and Studio T09 baselines.
- S0 versus S1 is controlled one-device causal evidence that a single `0x0002` frame is sufficient to dismiss this native screensaver state and restore input. It does not prove that periodic `0x0002` prevents the state, determine an interval, or generalize across firmware.
- The passive listener was stopped after the result. No Hidhogg, probe, Studio, or LLDB process remains intentionally attached to the D200X.

## 2026-08-31 — Diagnostic keepalive experiment authorized

- Architect review found no existing tool capable of a bounded periodic intervention: `d200xprobe` is intentionally one-shot, `hidhoggdiag` has only brightness-zero and one-shot wake modes, and production sends input-enable only in its startup page sequence.
- The owner approved a diagnostic-only `keepalive-prevention` mode. Its experiment derives interval `I = T0 / 2` and duration `D = 2 * T0` from one newly measured no-write onset, uses a monotonic one-session scheduler, sends only input-enable, and forbids catch-up and retry.
- Production runtime behavior, configuration, and Swift/UI remain protected until the physical K1 and archived brightness-zero gates are reviewed. Consequential decisions are recorded separately in `docs/m02-f01-decision-review.md`.

## 2026-08-31 — Closed K1 diagnostic implemented and verified

- Architect review resolved the approved prevention experiment as a closed protocol: `D = 4I`, `D <= 60m`, and exactly four experimental `enable-input-stream` boundaries. Documentation-only or wrapper-only limits were rejected because the direct CLI would remain capable of producing out-of-contract evidence.
- Core validation, a shared no-HID CLI validation path, and the owner wrapper enforce the same Go-duration contract before HID activity; the wrapper rejects invalid schedules before archive creation and confirmation. There is no runtime override. The 48-boundary guard remains unreachable defense-in-depth.
- A successful run serializes exactly 11 ordered redacted observations: normal startup, scheduler start, four boundary writes, schedule completion, canonical wire-0 square press/release, final verification, and result. jq, Python, and Ruby archive validators require that shape.
- Automatic verification passed the full uncached cgo-free Go suite, focused race tests, vet, shell syntax, all archive-validator backends, formatting, and diff checks. Independent tester `M-02-F01-K01-V02` passed with no high or medium defect. The tests did not access HID hardware.
- Accepted sub-interval wake jitter can extend actual wall-clock completion while remaining before the next boundary. Physical K1 evidence must retain actual timing rather than infer it solely from requested duration.

## 2026-08-31 — C0 attempt reached ceiling without visual report

- A single `enable-input-stream` reset completed at `2026-08-30T15:41:46Z`, followed by a passive zero-write `d200xprobe` listener.
- The listener received no frames through the 30-minute ceiling and was stopped by signal. No listener-originated frame was sent.
- No contemporaneous owner visual-state report was received. The attempt is incomplete: zero inbound frames do not reveal visible screensaver onset, so no `T0` is derived and K1 remains blocked on an owner-observed C0.

## 2026-08-31 — Owner-observed C0 established conservative onset

- A setup-only input-enable reset completed at `2026-08-30T23:04:34Z`; the owner immediately confirmed the configured display was visible, and a passive zero-write listener remained open.
- The owner reported native screensaver onset at `2026-08-30T23:05:38Z`, 64 seconds later. Human observation latency is included, so this is a conservative observed `T0`, not a firmware-precise boundary.
- One `0_0` press/release after onset left the screensaver visible and emitted no listener output. This satisfies the C0 visible-onset and suppressed-input checks on the owned specimen.
- The reviewed formula derives `I = 32s` and `D = 128s` for K1. No K1 result has been recorded yet.

## 2026-08-31 — First K1 archive classified final-verification failure

- K1 ran with `I = 32s`, `D = 128s`. The archive records normal startup, exactly four passing scheduled input-enable writes, and passing duration completion without retry or catch-up.
- The owner did not perform the immediate post-schedule visual/input check. The screensaver was reported approximately one C0 interval after the nominal fourth write, and a later `0_0` press/release neither woke it nor emitted input.
- The diagnostic correctly recorded no input observations, `class-failure` for final verification and result, and exit 1. Manifest hashes match metadata, stdout, and stderr. This is schedule-execution and post-write-recurrence evidence, not a prevention pass or an at-`D` result.
- A second invocation is not assumed authorized by the first-run protocol; architect review was requested before proceeding.

## 2026-08-31 — One replacement K1 endpoint measurement authorized

- Architect review classified the first K1 as scheduler-valid but endpoint-inconclusive because the at-`D` primary endpoint was not observed. A second run is allowed only as a clearly labeled replacement with unchanged parameters; the first archive remains retained and is not a negative replicate.
- The replacement predeclares continuous observation, a local at-`D` cue, a five-second visual-classification window, and—only when active—a subsequent five-second window for one canonical `0_0` press/release.
- Any early screensaver, uncertainty, distraction, unrelated interaction, missed window, late/failed write, or missing pair prevents a pass. A third K1 requires a revised protocol decision.

## 2026-08-31 — Replacement K1 failed the endpoint-timing gate

- The authorized replacement retained `I = 32s`, `D = 128s`, a fresh owner-confirmed active baseline, continuous observation, and exactly four passing scheduled boundaries.
- The owner reported active display at the spoken cue, then screensaver onset before there was enough time to press. No input pair was captured. The agent-mediated cue cannot be proven within five seconds of the diagnostic endpoint.
- The checksum-valid archive correctly records `class-failure` and exit 1, but the causal endpoint remains inconclusive. It must not be presented as prevention pass or failure.
- Both permitted K1 invocations have now been consumed. K02 is blocked on an explicitly revised protocol with a diagnostic-coupled cue; no third run is authorized under the existing decision.

## 2026-08-31 — Revised endpoint timing and classification contract

- Main-agent review rejected the first scheduler-coupled implementation because it archived the planned five-second deadline as though it were the actual capture close and assigned `class-failure` to uncertain or malformed owner attestations.
- Architect decision `M-02-F01-K02-R01-A02` distinguishes the logical close from actual timer wake and capture stop. The nominal tail remains exactly five seconds after cue completion; actual closure must be no earlier and no more than 250 milliseconds late. All planned and actual monotonic timings must be archived. The allowance is experimental policy, not a platform guarantee.
- Only `ACTIVE_AT_CUE` plus exactly one canonical `0_0` press/release within the logical window can pass. Screensaver evidence is `class-failure`; uncertainty, missing/malformed attestation, and capture/decoder failure are `indeterminate`; cue or timing failure is `invalidated`, taking precedence.
- Exactly one further physical K1 run with `I = 32s` and `D = 128s` remains authorized only after corrected automatic gates, independent verification, final architect review, and owner-heard same-cue preflight pass.

## 2026-08-31 — First R01 independent verification failed

- The corrected planned-close, actual-wake, actual-stop, post-window, classification, and archive-schema gates passed focused automatic checks, including all jq, Python, and Ruby validators.
- Independent tester `M-02-F01-K02-R01-V01` failed the revision because a terminal input-capture error detected before a scheduled boundary does not stop later keepalive writes or the endpoint cue. The existing check occurs only after the endpoint capture window.
- A separate read-only integration audit also identified unresolved direct-CLI preflight authority, attestation after already-invalid endpoint timing, injected-cue timeout enforcement, protocol-error classification, cancellation, and bounded-observation behavior. Architect decision `M-02-F01-K02-R01-A03` is required before the next narrow correction.
- No physical cue or HID run is permitted while R01 verification is failing.

## 2026-08-31 — Architect A03 set the final R01 fail-closed boundary

- Capture health must be checked before and after each of the four writes and immediately before cue. Terminal failure or capacity exhaustion stops further frames and the cue, records redacted health, and makes the result indeterminate.
- Direct CLI execution is part of the physical authority boundary: the fixed cue and exact `CUE_HEARD` token must occur in the same process before runner construction or HID activity. Wrapper-only preflight is insufficient.
- Invalid endpoint timing skips owner attestation. Injected cues cannot report success after their derived timeout. Only proven inbound-byte malformation is class evidence; ambiguous protocol, transport, session, and read-count failures are terminal capture failures.
- Cancellation before terminal observation commit prevents pass. Continuous pre-schedule capture is retained, but logical endpoint eligibility starts at cue invocation. Zero fake-clock cue duration is allowed. Required observations may not be silently discarded; archive checks are defense-in-depth.
- The sole remaining physical authorization is unchanged and remains gated on corrected automatic tests, independent PASS, final architect PASS, and same-invocation owner-heard preflight.

## 2026-08-31 — Stale task caches removed

- At the owner's request, stale Hidhogg Go build, test, race, and vet caches under `/private/tmp` were removed after active agents confirmed they no longer needed them. Available space increased from 636 MiB to 24 GiB.
- The two approximately 1.3 GiB Ulanzi static-analysis trees were retained because their future research value has not yet been resolved. Project files and durable diagnostic archives were not removed.

## 2026-08-31 — R01 boundary re-review found one remaining defect

- Independent verifier `M-02-F01-K02-R01-V02B` passed focused Go, repeated, race, vet, shell-syntax, and jq/Python/Ruby archive-validation gates. Its broad `go test ./...` failure was confined to sandbox-denied Unix-socket IPC fixtures and is not endpoint evidence.
- Static review found that the endpoint classifier reused `idleEnd` as `cueStart`. Frames arriving during capture-health and observation work after the completed idle interval could therefore be misclassified as cue-window evidence.
- Architect ruling `M-02-F01-K02-R01-A04` requires a fresh boundary immediately before cue invocation. Frames between `idleEnd` and that fresh boundary remain archived but are excluded from both idle invalidation and endpoint classification. The narrow caller-boundary-to-cue-call race is accepted as invocation-boundary semantics.
- Mid-window capture failure with valid timing still permits one visual attestation, but endpoint and result must remain `indeterminate`. Invalid endpoint timing continues to suppress attestation and takes precedence.
- Physical K1 remains blocked pending the boundary correction, renewed independent verification, and final architect approval.

## 2026-08-31 — R01 V03 found jq archive-parity defect

- The fresh cue boundary, pre-cue classification, focused Go, race, vet, shell-syntax, and jq/Python/Ruby regression suites passed after corrections R06 and R07.
- Independent verifier `M-02-F01-K02-R01-V03` demonstrated that jq accepted a canonical pair with nonadjacent sequences `11 → 13`, while Python and Ruby rejected it. The jq partition checked only increasing sequence order and omitted the pair-adjacency and nondecreasing elapsed-time predicates already enforced by the other backends.
- This is a strict archive-validator parity defect, not a production endpoint finding. Physical K1 remains blocked pending a narrow jq correction, regression coverage, renewed independent PASS, and final architect approval.

## 2026-08-31 — R01 automatic and architect gates passed

- Correction `R08` added the missing jq canonical-pair adjacency and nondecreasing-time predicates plus separate sequence-gap and reversed-time fixtures. jq, Python, and Ruby reject both fixtures and retain all valid zero/pre-cue/post-window cases.
- Main verification passed focused Go, race, vet, shell syntax, archive regressions, diff checks, and an unrestricted full `go test ./...`, including Unix-socket IPC tests. Independent verifier `M-02-F01-K02-R01-V04` passed with no production defect or material coverage gap.
- Final architect review `M-02-F01-K02-R01-A06` marks the automatic implementation PASS and authorizes exactly one owner-present physical K1 at `I = 32s`, `D = 128s`, conditional on audible same-process preflight and exact `CUE_HEARD` before runner construction or HID activity.
- Any outcome after HID scheduling consumes the authorization. No retry, replacement, production policy, or cross-device generalization is authorized.

## 2026-08-31 — Final K1 diagnostic passed but K02 timing evidence failed

- The owner completed the one authorized scheduler-coupled K1. Archive `deploy/diagnostics/20260831T064118Z-keepalive-prevention` is checksum-valid, passes strict validation, and records internal diagnostic `pass` with `I = 32s`, `D = 128s`, four ordered boundary writes, healthy capture, `ACTIVE_AT_CUE`, and one adjacent canonical wire-0 press/release pair in-window.
- Cue duration was 2.565405084 seconds. Timer wake and capture stop were 1.073666 and 1.160541 milliseconds after planned close, both within the 250-millisecond tolerance. Manifest hashes match recomputed metadata, stdout, and stderr hashes.
- The boundary observations omit actual monotonic wake/write timestamps. Since accepted scheduler jitter extends until the next interval boundary, the archive cannot satisfy K02's retained actual-timing evidence requirement or prove exact 32-second delivery.
- Architect `M-02-F01-K02-A07` classifies K02 contract acceptance as `fail`; independent tester `M-02-F01-K02-V01` classifies the physical inference as inconclusive despite the valid diagnostic pass. The authorization is consumed and no further K1 is permitted without a new explicit protocol decision.

## 2026-09-01 — Owner waived K02 timestamp retention after outcome

- After reviewing the favourable endpoint outcome, the owner explicitly waived the retained requirement for serialized actual monotonic wake/write timestamps. Architect `M-02-F01-K02-A08` classifies K02 as bounded pass by retrospective waiver, not an unqualified or prospectively compliant pass.
- The accepted claim is limited to one owned-specimen 128-second run with four ordered `0x0002` writes admitted within 32-second categorical scheduler windows, visible activity at the coupled cue, and one valid canonical input pair.
- The owner proposed reducing the scheduler window to reduce risk. A 16-second cadence is the conservative analytical candidate because worst admitted categorical spacing approaches 32 seconds, retaining the intended `T0 / 2` margin against observed `T0 = 64s`. It remains physically unverified and is not yet a production policy.
- B01 and explicit production-policy confirmation remain required before changing runtime code or configuration. The five-second endpoint window is unchanged. No further K1 is authorized.

## 2026-09-01 — Owner approved prospective K1-50 planning

- The owner clarified that the desired risk buffer is a cadence near observed `T0`, then explicitly confirmed a new prospective `I = 50s`, `D = 200s`, four-write experiment with a 250-millisecond lateness gate and the unchanged five-second endpoint window.
- K1-50 is a new experiment, not a retry or reclassification of K02. It requires serialized planned, actual-wake, and write-completion timing for every boundary before any physical run.
- No device action or production-policy change is authorized during implementation. Automatic, independent, and final architect gates must pass before one owner-present physical invocation is prepared.

## 2026-09-01 — Architect fixed K1-50 timing contract

- Architect `M-02-F01-K03-A01` requires `planned <= actual wake <= write start <= successful completion <= planned + 250ms` for each of four boundaries. All values are monotonic nanoseconds from one scheduler origin and must be serialized under `timing_contract = k1-50-v1`.
- The 250-millisecond bound is inclusive; 250 milliseconds plus 1 nanosecond, early/reordered/missing timing, or clock regression invalidates without retry, catch-up, later write, or cue. Failed or uncertain writes are indeterminate and must omit completion rather than synthesize it.
- The fourth completion must precede the fresh cue boundary. Retained legacy archives keep their historical schema and cannot satisfy K03. One physical K1-50 remains gated on automatic, independent, and final architect PASS.

## 2026-09-01 — K1-50 automatic readiness gates passed

- `K03-R01` implemented prospective boundary timing and strict legacy/prospective validator dispatch. Independent `K03-V01` found two medium validator defects: accepted pre-cue elapsed-time regression and jq acceptance of floating-point nanosecond representations.
- `K03-R02` made pre-cue elapsed time nondecreasing and aligned jq, Python, and Ruby on strict integer nanosecond representations. Independent tester `K03-V02` passed the full K1-50 matrix, including all twelve timing fields, legacy compatibility, inclusive 250-millisecond tolerance, failure termination, output-bound failure, and fourth-completion-to-cue ordering.
- Final architect `K03-A02` passed the architecture and scientific-readiness gate. The unrelated full-suite limitation is sandbox-denied Unix-socket creation in `internal/ipc`; it does not exercise K03.
- Exactly one owner-present `I = 50s`, `D = 200s` physical invocation may now be prepared. Same-process cue preflight and exact `CUE_HEARD` remain mandatory. Once HID scheduling begins, every outcome consumes the authorization and no retry is permitted.

## 2026-09-01 — K1-50 physical scheduler passed; endpoint indeterminate

- The one authorized K03 invocation is archived at `deploy/diagnostics/20260901T063506Z-keepalive-prevention`. Same-process preflight passed, one HID session started, all four writes passed `k1-50-v1`, capture health passed, and checksums computed from `stdout.jsonl` and `stderr.log` match the values recorded in metadata.
- Boundary completion lateness was 1.711458 ms, 1.576791 ms, 1.988541 ms, and 1.326333 ms. Boundary four completed at 200.001326333 s and the endpoint cue began at 200.002471333 s, preserving the required ordering.
- The interaction supplied `CUE_HEARD` at the later closed visual-attestation prompt. That token is not `ACTIVE_AT_CUE`, `SCREENSAVER_AT_CUE`, or `UNCERTAIN`, so the diagnostic correctly retained an indeterminate final verification and result. No canonical endpoint input pair was captured.
- K03 therefore provides prospective scheduler-conformance evidence but no prevention pass or failure. Its physical authorization is consumed; do not retry without a new reviewed decision.

## 2026-09-01 — Owner-run K1-50 pass designated authoritative

- The owner completed the interaction directly and produced `deploy/diagnostics/20260901T065715Z-keepalive-prevention`. Strict archive validation passed, and computed SHA-256 values match metadata for `stdout.jsonl` and `stderr.log`.
- All four `k1-50-v1` boundaries passed with completion lateness from 1.694333 ms to 2.852750 ms. Capture health passed, boundary four completed before cue start, `ACTIVE_AT_CUE` was recorded, and exactly one canonical wire-0 square press/release pair occurred inside the endpoint window. Final verification and result are `pass`.
- The owner explicitly designated this independently operated archive as the authoritative and sufficient K03 source of truth. Earlier agent-mediated archives remain historical procedural failures caused by prompt/interaction timing and do not control the K03 result.
- K03 is complete. The ruling does not complete B01 or choose a production idle policy.

## 2026-09-01 — Studio screensaver uploader and encoder wake discovery

- The owner confirmed that encoder rotation at brightness zero restores firmware brightness to 100 under both direct-Go operation and Ulanzi Studio. The current B01 single-zero-write trace therefore cannot classify every later encoder action as occurring at brightness zero and requires redesign before another trusted matrix run.
- Studio Device preferences expose a screensaver-artwork editor for `1220 × 708` images. `Stored Image` opens the macOS file picker; `Set Image` is the explicit commit control. This is artwork configuration, not a discovered timeout setting.
- Architect `M-02-F03-T13-A02` approved a bounded synthetic `SS-U0` through `SS-U3` click/cancel and A/B/A upload protocol. Production encoder-brightness behavior remains deferred until T13 and revised B01 evidence are reviewed.

## 2026-09-02 — T13 non-launching capture gate passed

- Initial independent verifier `T13-V02` found evidence-integrity defects in timestamp ordering, specimen authorization, payload-log/file reconciliation, boolean chronology timestamps, and zero-length callback handling. No dynamic process or hardware was accessed.
- Correction `T13-R02` binds authorization to the selected specimen record, validates nondecreasing strict-integer timestamps, reconciles every payload row and owner-only file by name/size/hash/specimen, rejects orphan evidence, and checks declared length before process-memory access.
- Independent `T13-V03` passed 59 fresh-workspace checks plus the 12-test Python and shell suites. Deterministic `1220 × 708` A/B fixtures, LLDB ABI fakes, closed marker flows, bounds, modes, and static no-launch/attach/HID/network behavior pass. Real Studio/LLDB trials remain intentionally unrun.

## 2026-09-02 — T13 dynamic screensaver-artwork evidence

- Authorized dynamic trials used the disposable Studio copy and controlled metadata-free `1220 × 708` fixtures. SS-U0 open/cancel showed only periodic `0x0006` traffic and the owner observed no display change.
- SS-U1 committed fixture A, captured an authorized `0x0009` payload of 40,982 bytes, and the owner confirmed A visible. SS-U2 committed fixture B from the A baseline, captured an authorized `0x0009` payload of 130,798 bytes, and the owner confirmed B visible.
- The initial stopped-payload boundary also stopped on periodic `0x0006`, starving Studio's UI. A debugger-side packet-length condition excluding payloads of at most 1,024 bytes allowed the `0x0009` upload to reach the stopped capture boundary; the payload breakpoint was then disabled before the observation window.
- SS-U2 reached the 256-event chronology cap before commit because of interactive delay. Its authorized payload and owner-observed B outcome are valid, but it is not complete chronology evidence. SS-U3 was opened through file-picker visibility and then cancelled at the owner's direction; it is intentionally excluded from protocol conclusions.
- The owner waived the A-restoration repeat. T13 supports implementing `0x0009` screensaver-artwork upload, but does not establish payload structure, deterministic re-encoding, or A/B/A normalized restoration.

## 2026-09-03 — T14 payload contract and B01 automatic gate

- Offline T14 analysis reconciled both controlled `0x0009` artifacts with their authorization logs. Each is one method-8 Deflate ZIP entry containing a Studio-reencoded `1220 × 708`, 8-bit RGB PNG with `pHYs`. This supports a semantic clean-room encoder boundary but does not establish firmware-required ZIP/PNG details, alpha behavior, deterministic re-encoding, repeated-upload safety, or malformed-upload behavior.
- Architect review closes T14 as qualified research and defers production `0x0009` support until after M-02-F01-P01, deterministic encoder/parser tests, and a separately authorized physical acceptance test.
- B01 R01-R05 narrowed the evidence claim to exact wide-13, physical-button-15/16, and square-0 pairs while brightness persists at zero; the first encoder-17/18/19 left/right rotation ends that state and is not zero-state encoder evidence. A dedicated exact `brightness_attestation` is required; only `BRIGHTNESS_100_OBSERVED` supports a pass.
- Independent review initially rejected free-text attestation, an unclassified pre-recovery gap, nullable schema keys, and a contradictory trailing-input/pass archive. Corrections made all pre-shutdown decoded or malformed input part of the terminal verdict and aligned jq, Python, and Ruby validators on exact keys and pass-only input records.
- Final independent R05 verification and architect review passed focused/full diagnostic, race, vet, command, shell, archive, and diff gates without HID access. Exactly one owner-present, no-retry B01 physical run is authorized.

## 2026-09-03 — Authorized B01 physical run class-failed

- Archive `deploy/diagnostics/20260902T235304Z-brightness-zero` has matching metadata, stdout, and stderr hashes. Its result is `fail`, exit status 1, and strict observation validation returns non-pass as required.
- Baseline, brightness-zero write, structured `BRIGHTNESS_100_OBSERVED`, configured-brightness restore, and recovery passed. Zero-state evidence contains exact wide-13 and physical-button-15/16 pairs, followed by encoder-17 left as the restoration transition. The required zero-state square-0 pair is absent, so the matrix correctly records `class-failure`.
- The one-run authorization is consumed. This archive is valid failure evidence but cannot complete B01 or support P01. No replacement is authorized without a new reviewed decision.

## 2026-09-03 — Owner retrospectively accepts B01 replacement

- The owner independently initiated `deploy/diagnostics/20260903T032301Z-brightness-zero` after the one-shot authorization was consumed. All three hashes match, strict archive validation passes, result is `pass`, and exit status is 0.
- The archive contains the exact baseline; zero-state wide-13, button-15, button-16, and square-0 pairs; encoder-17-left transition; structured `BRIGHTNESS_100_OBSERVED`; one configured-brightness restore; and exact recovery pair. There is no contrary or trailing input.
- Architect review classified the run as technically valid passing evidence with a procedural authorization deviation. On 2026-09-03 the owner explicitly accepted it retrospectively as authoritative and sufficient for the bounded one-device B01 decision.
- Preserve both archives. The first remains a valid prospectively authorized class-failure; the second closes B01 but does not establish repeatability or cross-firmware behavior. No third B01 run is justified. P01 may proceed to explicit owner policy selection.

## 2026-09-03 — P01 policy selected and automatic gate passed

- The owner selected optional integer `idle_timeout_seconds`, omitted default 300, range 0 through 86,400, with zero disabling application dimming but not the fixed absolute 50-second `0x0002` keepalive. Idle sends brightness zero once. The first known physical gesture restores configured brightness and is consumed completely; unknown decoded values do not wake or reset idle.
- The runtime owns one injectable idle coordinator above the serialized D200X session. Input at or before the idle deadline wins; simultaneous keepalive precedes dim; keepalive does not reset idle; successful restore begins the next idle interval. Any uncertain keepalive, dim, or restore write fail-stops without retry. IPC, supervisor restart behavior, Swift, actions, reconnect, and `0x0009` remain unchanged.
- Independent V01 found that encoder-marker press/release was omitted from the known-gesture classifier. R02 corrected it and keyed suppression by marker plus wire. Independent re-verification passed all known gestures, config/schema parity, deterministic scheduler cases, lifecycle, full and race suites, vet, build, schema staleness, formatting, and diff checks without HID access.
- Final architect review passed the implementation boundary and authorized one bounded physical acceptance using a temporary five-second idle timeout. Exact scheduling remains automatic evidence; the physical gate checks visible blanking, one scheduled keepalive while blank, consumed first wake pair, dispatched second pair, and clean shutdown.

## 2026-09-03 — P01 owner-present physical acceptance passed

- A setup attempt using `/private/tmp` for IPC failed before acceptance because the directory was not owner-private. The later acceptance used an owner-private socket under `deploy`; an intermediate run was deliberately stopped for the owner's requested `/private/tmp` cleanup and is excluded from acceptance evidence.
- In the bounded acceptance run, startup completed, one brightness-zero write followed the configured five-second idle interval, and the owner confirmed the display was blank. The first scheduled post-startup `0x0002` was logged while the device was untouched; the owner confirmed the display remained blank.
- One square `0_0` press/release restored configured brightness. Both wire frames were logged, but no input JSON was emitted. After the next idle blank, two quick square pairs produced one consumed wake pair followed by exactly one ordered pressed/released JSON pair for the second gesture. A later single brightness-zero write confirmed re-idle.
- SIGINT stopped the runtime and the acceptance socket was absent afterward. This closes the physical P01 gate for the owned specimen. Human-observed timing is not scheduler-precision evidence; deterministic fake-clock tests remain authoritative for deadlines and ordering.
- Independent milestone-close verifier `M-02-F01-P01-V03` passed full tests, race, vet, build, schema determinism, formatting, diff checks, and the supplied physical-gate mapping without HID access. Repeated race stress exposed two low-severity test synchronization weaknesses involving fixed waits; no runtime defect was observed, and this does not block P01 closure.

## 2026-09-03 — M-03 locked discovery contract selected

- The owner accepted a persistent advisory `runtime.lock` instead of PID authority or manual-only stale cleanup. One cooperating runtime owns one owner-only runtime directory; the lock file persists across clean shutdown and is never unlinked.
- Architect reviews M-03-A01/A02 passed. Discovery startup validates and locks the directory, guardedly recovers only strictly valid stale generation entries, binds IPC, initializes HID, starts serving, and atomically publishes `runtime.json` as the readiness marker. All detectable directory, lock, stale-entry, path, and bind failures precede HID mutation.
- Generated instance IDs are lowercase UUIDv4; explicit canonical UUIDs accept ASCII hex case and normalize to lowercase. Discovery and legacy explicit CLI modes are mutually exclusive; legacy mode remains for Swift/tests during M-03.
- Advisory locks coordinate compliant processes, not malicious or non-cooperating same-UID actors. Malformed or substituted entries are preserved and rejected. The existing guarded check/unlink race is not claimed solved.

## 2026-09-03 — M-03-D01 discovery lifecycle passed

- New `internal/discovery` owns secure directory/lock handling, UUID generation and normalization, strict 1-KiB `runtime.json` metadata using `socket_name`, atomic no-replace publication, valid-only stale recovery, guarded cleanup, and client resolution/revalidation.
- Main review corrected metadata naming/bounds and required descriptor-relative lock opening through a retained runtime-directory descriptor. Independent verifier D01-V01 passed package/full tests, race, vet, build, repeated lock/recovery/publication cases, formatting, and diff checks without HID access.
- Tests additionally cover uppercase/generated IDs through `Open` and directory/lock substitution through `Resolved.Revalidate`. D01 is complete; R01 may integrate the reviewed API.

## 2026-09-03 — M-03-R01 automatic gate passed

- `cmd/hidhogg` now supports mutually exclusive discovery and legacy modes; `cmd/hidhoggctl` resolves and revalidates discovery state before emitting its response. Explicit UUIDs normalize ASCII hex case. Swift retains legacy arguments and remains outside M-03.
- Runtime startup binds IPC before HID enumeration/open/write, withholds `runtime.json` until device initialization and serving readiness, withdraws metadata before terminal closure, joins partial-start cleanup failures, removes matching generation entries, and retains `runtime.lock`.
- Independent V01 requested missing public `Start`, serving-wait, and post-start terminal-path coverage. R02 added deterministic short-path tests and corrected terminal withdrawal ordering. Independent V02 passed full/race/vet/build, repeated lifecycle matrices, idle regressions, formatting, diff, and no-skip gates without HID access.
- Three low-severity compound integration gaps remain documented in the roadmap; helper/direct behavior is covered and no production defect was demonstrated. R01 is complete; M-03-V01 awaits the direct functional gate.

## 2026-09-04 — M-03 completed

- Final architect A03 found a reachable `Generation.Close` deadlock when metadata remained published: close set `closed`, then entered the public withdrawal branch waiting for its own `closeDone`. R04 uses the internal locked withdrawal operation, joins failures, and always continues socket cleanup, lock release, descriptor closure, and completion signaling.
- Independent V03 passed 50-repeat discovery/runtime lifecycle cases, focused race repetitions, the full/race suites, vet, build, formatting, and diff checks. Direct close, substituted metadata preservation, error return, socket cleanup, lock reuse, and concurrent withdrawal/close all complete without deadlock. Architect A04 closed the blocker.
- Direct acceptance verified strict `0600` lock/metadata/socket entries, discovery health/status without an instance argument, ready/protocol-version responses, valid stale-state recovery after an execution-host termination, and same-directory contention before any second D200X packet. The owner observed that the already-off display remained unchanged during the rejected contender.
- Clean SIGINT returned zero, removed the matching metadata/socket, and retained `runtime.lock` as a `0600` regular file. M-03 and V01 are complete. No identifiers were retained in the durable acceptance record.

## 2026-09-05 — M-04 responsibility boundary selected

- The owner rejected putting foreground-app bundle mappings in the Go runtime. Go will own profile definitions, validation, default/current selection, transactional activation, profile listing, and activation requests. A later Swift milestone will observe `NSWorkspace` activation, own bundle-ID-to-profile mappings, retrieve valid profiles from Go, and request activation.
- Built-in `activate_profile` actions assigned to buttons will use the same Go profile service as IPC. M-04 supports only a complete ordinary press gesture; long/double press remain undefined and rejected rather than prematurely specified.
- Executable actions are deferred beyond profile switching. Supervised asynchronous actions and execution logs are a later milestone.

## 2026-09-05 — M-04-P01 contract confirmed

- The owner confirmed strict schema version 2 with `default_profile_id` and `profiles`; no dual v1 decoding or automatic rewrite. Each profile owns a complete 14-position D200X layout and optional typed `activate_profile` actions accepting only a complete ordinary press.
- The architect-proposed 64-profile bound was rejected because worst-case 256-byte labels would exceed the existing 16-KiB IPC response limit. A subsequent exact calculation proved that 32 worst-case profiles produce a 16,387-byte framed response, three bytes over the limit. The owner accepted a corrected maximum of 31, whose calculated worst-case frame is 15,880 bytes, leaving 504 bytes of headroom. Encoder-level bounds remain mandatory.
- One coordinator serializes IPC and button activation. Current-profile activation is idempotent with zero writes. A successful full page write precedes logical profile/binding commit; an uncertain write withdraws readiness and terminates without retry or rollback.
- Internal IPC version 1 gains `profiles.list` and `profiles.activate` while preserving exact health/status behavior. Swift owns bundle-ID mappings and sends only profile IDs.

## 2026-09-06 — M-04-C01 profile configuration passed

- Strict configuration schema version 2 replaces `pages` with one case-sensitive `default_profile_id` and 1..31 ordered profiles. Each profile contains all 14 D200X positions and may bind only the exact `activate_profile`/`press` action shape to a position.
- Configuration decoding rejects version 1, unknown fields, unresolved or ambiguous profile references, invalid identifiers, incomplete layouts, and labels outside the confirmed visible-text, 1..64-rune, and 256-byte bounds. Unicode control and format characters and invisible-only labels are rejected semantically; portable JSON Schema cannot express the full Unicode-category rule, so Go validation remains authoritative.
- `internal/profile` provides an ordered immutable catalog with defensive copies and case-sensitive action-target resolution.
- Independent V01 found invisible Unicode format characters were accepted and identified missing boundary and mutation tests. R01 corrected the validator and coverage. Independent V02 passed focused race tests, vet, deterministic schema regeneration, scoped diff checks, all 31/32 and 64/65 boundaries, invalid action cases, and mutation isolation. No material C01 residual risk remains.
- Runtime and diagnostic callers still use the removed `Config.Pages` field; their expected compile failures define the next M-04-R01 migration boundary.

## 2026-09-06 — M-04-R01 runtime profile service passed

- Runtime and diagnostics now consume the schema-v2 catalog. Startup renders the configured default profile even when it is not first; a bounded eight-slot coordinator serializes activation, commits the current profile and bindings only after a complete successful page write, and treats current-profile activation as a zero-write success.
- Unknown profiles cause no writes. An uncertain page write withdraws readiness, cancels serving, rejects queued and future work, invokes terminal paths exactly once, and fail-stops without retry or rollback. Idle/wake suppression remains ahead of action routing and active input resolves against the current committed bindings.
- Independent V01 found missing integrated failure/capacity/default-selection gates, a flaky diagnostic deadline, and cancellation-time blocked-read leakage. R01 added deterministic coverage and close/join behavior. V02 then proved arbitrary non-closable readers could not satisfy cancellation; architect A02 selected an owned `io.ReadCloser` contract and preservation of one buffered CLI reader. R02 implemented that contract and tests.
- Independent V03 found early `Run` exits did not close the owned reader. R03 registered cleanup at entry and covered canceled, refused, invalid-config, enumeration, selection, open-failure, success, cancellation, and deadline exits. Independent V04 passed 50-repeat race stress, scoped race/vet, whole-tree compilation, and diff gates with no material residual risk.

## 2026-09-06 — M-04-I01 profile IPC passed

- Internal protocol version 1 now accepts exact `profiles.list` and `profiles.activate` requests while preserving existing health/status behavior. Listing returns only ordered `{id,label,is_default,is_current}` summaries with the canonical instance ID; activation preserves profile-ID case and returns exact `{profile_id,changed}` state.
- Stable application errors distinguish profile-not-found, activation failure, uncertain device write, shutdown, and coordinator saturation. Strict duplicate, unknown-key, type, method, identifier, and response validation remain enforced.
- `hidhoggctl` exposes discovery-aware and legacy-explicit profile listing and activation. Foreground bundle mappings and profile layouts/actions are not exposed.
- The natural maximum-width 31-profile response frames at exactly 15,880 bytes. The equivalent 32-profile proof frames at exactly 16,387 bytes and is rejected by the retained 16,384-byte encoder limit.
- Independent V01 passed 50-repeat race tests, Darwin/Linux vet and builds, protocol/adapter/CLI gates, and an unsandboxed Unix-socket race suite covering IPC, discovery, runtime, and CLI. No production defect was reproduced; physical switching remains for A01/V01.

## 2026-09-06 — M-04-A01 built-in profile action passed

- Active emitted D200X input now feeds a deterministic one-press/one-release action state machine keyed by wire index, marker, and the committed profile/binding snapshot. Exactly one matching completed ordinary press invokes the same bounded profile service used by IPC.
- Wake-consumed input, failed event emission, release-only, duplicate or mismatched gestures, encoder rotation, unknown input, unsupported gestures, and a profile transition during the gesture do not activate. Conditional enqueue prevents a stale button gesture from racing an IPC profile transition; busy, shutdown, and uncertain states are not retried.
- Independent V01 passed 100-repeat shuffled race stress, runtime and whole-tree race/test gates, vet, compilation, formatting, and diff checks. No production defect was found. Long/double press remain deliberately undefined.

## 2026-09-06 — M-04-V01 automatic gate passed

- The initial milestone audit passed uncached whole-tree race, vet, build, formatting, diff, module, schema, frame-boundary, and 50-repeat critical stress gates, but rejected conclusive acceptance because profile IPC/CLI lacked real-socket end-to-end tests, the action path lacked an integrated `Runtime.Run` fake-transport test, and the protocol README retained M-01-only wording.
- Remediation added real Unix-socket client/server and discovery/legacy CLI profile tests, corrected the protocol scope, and added a complete fake-device `Runtime.Run` flow from session input through idle/action routing to redraw, dynamic bindings, wake suppression, and cleanup.
- Unsandboxed 50-repeat shuffled race runs passed for the new IPC, CLI, and runtime integration tests. Final independent review passed the automatic M-04 gate with no material defect or documentation drift. No real HID or network access occurred.
- M-04-V01 remains open only for owner-visible physical acceptance on the owned D200X.

## 2026-09-07 — M-04 physical live-redraw assumption disproved

- Fresh startup with the synthetic two-profile fixture physically rendered the default profile at brightness 80. `profiles.list` reported the correct ordered default/current flags.
- IPC activation of `alternate` returned `changed:true`, emitted the complete `0x0001` page-start sequence, and committed the logical current profile. Repeating activation returned `changed:false`, and listing reported `alternate` current. The owner confirmed the D200X still showed the original default labels.
- This disproves the M-04 assumption that the physically verified startup `0x0001` operation is also a live redraw primitive. Transport success did not establish visible state, so physical acceptance failed and no button-switch claim was attempted.
- Static Studio evidence identifies targeted `0x000d` one-position archives as the strongest live-update candidate. Independent investigation and architect A03 agree to preserve startup `0x0001`, add a distinct live-update operation only after a one-position physical `0x000d` gate, prebuild all target archives before writes, serialize a full batch, commit only after success, and fail-stop on any uncertain partial update. Physical atomicity cannot be claimed for sequential tile writes.
- The divergent runtime was stopped cleanly; its metadata and socket were removed and its persistent lock retained. No speculative recovery or extra redraw command was sent.

## 2026-09-07 — Targeted live `0x000d` square update passed

- A spike-only typed probe built one conventional two-member Deflate ZIP containing `manifest.json` and one content-addressed 196×196 RGBA PNG. The manifest contained only coordinate `0_0`, `State: 0`, and one Studio-shaped `Font`/`Icon`/`Text` view for the high-contrast `LIVE-000D` tile.
- After a fresh verified default startup and clean shutdown, the probe sent exactly one `0x000d` logical frame with no brightness, unlock, input-enable, retry, or recovery command. The first invocation was observation-inconclusive because the owner was not watching.
- A separately owner-cued replacement trial repeated the fresh default baseline and one bounded `0x000d` write. The owner confirmed only the top-left `Clock` tile changed to `LIVE-000D`; other tiles remained unchanged. This establishes targeted live square replacement for the owned specimen and current firmware.
- Repeated-update filename caching and targeted wide-tile geometry remain unverified. Production runtime code remains unchanged pending those protocol trials.

## 2026-09-07 — Reused live icon path produced partial replacement

- After restoring the default page, targeted `square-a` sent `0x000d` for `0_0` using fixed icon path `Images/live-square.png`; the owner confirmed the tile became cyan-bordered `LIVE-A`.
- A subsequent `square-b` targeted the same coordinate and reused the exact icon path with different PNG bytes and text. The owner observed the label change to `LIVE-B`, but the image/background disappeared rather than showing the expected magenta border.
- This establishes that the manifest update was processed but a reused icon path did not reliably replace its image bytes. The specific firmware mechanism may be caching or resource replacement behavior; that cause remains uncertain. Production live updates must not reuse fixed paths without a successful content-derived-path control.

## 2026-09-07 — Content-derived live icon path control passed

- A third targeted `0x000d` sent the exact same `LIVE-B` coordinate, label, dimensions, colours, and PNG bytes as the failed fixed-path update, changing only the manifest icon path to `Images/<sha256>.png` derived from the PNG content.
- The owner confirmed the expected magenta border/background appeared. This isolates the path as the causal variable for the observed image replacement: repeated fixed paths are unreliable, while the content-derived path applied the same bytes successfully on the owned specimen.
- Production live-update builders must use deterministic content-derived icon paths. This conclusion is specimen/firmware-specific; the internal firmware cache mechanism is not directly observed.

## 2026-09-07 — Targeted live `0x000d` wide update passed

- After restoring the verified default baseline, one typed spike archive targeted only wide coordinate `3_2`, used a content-derived 458×196 RGBA image path, and included the Studio-observed `SmallViewMode: 2` manifest field.
- Exactly one `0x000d` frame was sent with no auxiliary or recovery command. The owner confirmed only the bottom-right wide tile changed to the yellow-bordered `LIVE-WIDE` image with correct full-width geometry and no visible crop or stretch.
- Square isolation, repeated content-addressed replacement, and wide geometry are now physically established sufficiently for a typed production encoder and serialized 14-position live-update batch. Cross-firmware behavior remains unverified.

## 2026-09-07 — M-04-D02 typed live-update encoder passed

- Production `internal/d200x` now has a typed targeted live-position builder and batch session API. Each update is a validated two-member `0x000d` ZIP with one coordinate, Studio-shaped manifest fields, exact square/wide RGBA geometry, wide-only `SmallViewMode: 2`, and a deterministic SHA-256 content-derived icon path.
- A batch prebuilds and validates all updates before writes, rejects empty, duplicate, and greater-than-14 batches without invalidating the session, uses canonical wire order and one write serialization boundary, and stops/invalidates on the first uncertain transport failure. Generic raw `SendFrame` still rejects `0x000d`; startup `SendPage` remains unchanged.
- Independent V01 passed all-coordinate archive inspection, 100-repeat shuffled race and startup stress, full package race, vet, compilation, formatting, and diff gates. R01 added direct empty/15-item rejection and subsequent-session-usability coverage. No production defect remains within D02.

## 2026-09-07 — M-04-R02 live profile redraw correction passed

- Startup retains the physically verified `SendPage` `0x0001` sequence. Non-current activation now validates and canonicalizes the full target, prebuilds all 14 typed live updates, then sends one serialized canonical 14×`0x000d` batch with no brightness, unlock, or input-enable frames.
- The runtime commits the target profile and bindings only after the complete batch succeeds. Transition start clears press candidates; inputs observed across the mixed-display interval are suppressed through commit or failure. Current/unknown profiles remain zero-write, and post-commit input uses new bindings.
- Logical/update or packet failure stops later writes, retains the prior logical profile, marks physical state uncertain, withdraws readiness/cancels once, rejects queued/future activation, and performs no retry or rollback. Logs contain bounded phase metadata without payload contents. Sequential device updates are not represented as physically atomic.
- Independent R02 V02 passed 100-repeat shuffled transition/failure/action race stress, full runtime race, whole-tree and nested-module compilation/vet, formatting, and diff gates. The later milestone audit found two socket-dependent integration tests still asserted the superseded live `0x0001` sequence and could be skip-masked. Their assertions now require one startup `0x0001` plus 14 live `0x000d` updates per transition, and critical runtime/IPC/CLI socket tests use validated workspace-local owner-private directories with bind failures fatal. An unsandboxed verbose 50-repeat shuffled race gate passed every critical test with zero skips; final independent V02 automatic review passed. No production defect was reproduced.

## 2026-09-07 — Live bulk-redraw conclusion reopened

- The earlier live full-page `0x0001` trial reused fixed icon paths. Later controlled `0x000d` trials established that reusing a path can update manifest text while failing to replace the corresponding image, whereas changing only that path to a content-derived name applies the expected image.
- Therefore the earlier statement that the failed trial disproved live `0x0001` redraw was too strong. The verified observation is only that the particular fixed-path archive did not visibly replace the existing page; live bulk redraw support remains uncertain.
- M-04-P02 will send one complete 14-position `0x0001` archive with content-derived paths from a verified baseline and no auxiliary commands. Production remains on the verified sequential `0x000d` implementation until that physical gate is resolved.

## 2026-09-08 — Content-addressed live bulk `0x0001` passed

- The spike built one deterministic complete archive containing a valid 14-position manifest, 13 distinct 196×196 PNGs, one distinct 458×196 PNG, and `Images/<sha256>.png` paths derived from the exact image bytes. Independent automatic review verified that the CLI sends exactly one `0x0001` and no brightness, unlock, input-enable, retry, or recovery command.
- The first physical invocation completed at the transport layer but was observation-inconclusive because the owner was not watching. It is not used as behavioral evidence.
- For the owner-observed repeat, the production runtime first restored the verified default page and was stopped with its socket and generation metadata removed. The spike then sent exactly one content-addressed full-page `0x0001`. The owner reported that all 14 tiles changed together.
- This establishes live bulk redraw on the owned D200X and firmware as of 2026-09-08. It does not prove device-side atomicity or cross-firmware behavior. M-04-R03 should replace the sequential 14×`0x000d` production transition with one typed bulk `0x0001` operation after owner confirmation and automatic gates.

## 2026-09-08 — M-04-R03 content-addressed bulk runtime passed automatic gates

- Production now prebuilds one immutable content-addressed full-page update and sends one `0x0001` for a non-current profile activation. The archive contains all 14 canonical positions, exact square/wide geometry, and manifest paths bound to SHA-256 of the exact PNG bytes. Logical profile and bindings commit only after every report succeeds; current activation remains zero-write and an uncertain write retains prior logical state and fail-stops without retry or rollback.
- Architecture review found that generic `Session.SendFrame` still allowed raw `0x0001`. Remediation closed generic `0x0001` and `0x000d`, retained typed startup/live/targeted paths, removed unused profile-service brightness state, and retained transition-generation suppression because one logical command spans multiple reports and device-side atomicity is unproven.
- Closing raw `0x0001` initially regressed diagnostic startup and complete-page wake tests. The whole-tree gate detected this. Diagnostics now use a narrow `SendPageUpload(Page)` operation that validates/builds a configured page and emits exactly one complete upload without startup auxiliaries; arbitrary raw archive bytes remain unavailable.
- Independent post-remediation verification passed scoped race tests for D200X, diagnostics, runtime, IPC, and CLI; uncached whole-tree tests; vet; build; and diff checks with no skips. Neutral extraction of manifest schema helpers from the targeted-live module remains a maintainability improvement, not a behavioral blocker. M-04-V03 physical verification remains.

## 2026-09-08 — M-04-V03 physical acceptance and milestone completion

- The corrected runtime rendered the default profile with its established startup sequence. Discovery-based IPC activation of `alternate` returned `changed:true`; the runtime emitted one logical content-addressed `0x0001` transition and the owner confirmed that all 14 alternate tiles appeared together and correctly.
- Repeating IPC activation of the already-current `alternate` profile returned `changed:false` and emitted no profile transition.
- One completed `calendar` press/release at `1_0` invoked the alternate binding. The trace contains exactly one transition from `alternate` to `default`, one logical `0x0001`, and no targeted `0x000d`; the owner confirmed that all 14 default tiles returned together.
- Clean shutdown removed `runtime.sock` and `runtime.json` and retained `runtime.lock`. M-04 is complete. “Together” is the owner's visible observation and is not a claim of device-side atomicity; cross-firmware behavior remains unverified.

## 2026-09-08 — M-05-P01 executable-action contract confirmed

- The owner selected a thin synchronous executable-action slice. “Synchronous” means one isolated worker starts and waits for one child; HID input, idle/keepalive, profiles, and IPC do not wait for it. One child may run globally and there is no queue; another completed executable gesture records `rejected_busy` and launches nothing.
- Configuration uses an additive strict schema-version-2 `execute`/`press` variant with an absolute executable, literal bounded argument vector, and optional 1..60-second timeout defaulting to 10. The child uses `/` and a fixed minimal `PATH`; M-05 has no shell, inherited environment, configured environment, or configured working directory.
- Timeout and runtime shutdown use process-group TERM, a two-second grace period, KILL if necessary, and direct-child reap. Process failure is recorded but is not a D200X runtime failure. History is generation-local RAM, retains 32 entries, keeps separate 4,096-byte stdout/stderr tails with totals/truncation, and never records command material.
- Read-only `executions.list` and `executions.get` expose bounded summaries/details; output is base64. IPC cannot start, retry, cancel, or provide commands. Async execution, long/double press, persistence, config reload, Swift, and visible failure feedback remain deferred.
- The owner suggested future env-file lists for Hidhogg and child commands. This is a separate future contract: runtime loading and child exposure are distinct, and child exposure should require explicit variable-name allowlists rather than forwarding the entire runtime environment. No `.env` content was read.

## 2026-09-08 — M-05-C01 executable-action configuration passed

- Strict schema version 2 now accepts an additive `execute`/`press` action with absolute NUL-free executable, optional literal argument array defaulting empty, and optional timeout defaulting to 10 seconds. It preserves the existing `activate_profile` variant and rejects cross-variant, shell, working-directory, environment, and unknown fields.
- Semantic validation enforces at most 32 arguments, 1,024 UTF-8 bytes per argument, 8,192 aggregate bytes, valid UTF-8/no NUL, and timeout 1..60. The immutable profile catalog defensively copies argument slices.
- JSON Schema rejects NUL and represents structural/count/character bounds. Its description explicitly states that Go semantic validation is authoritative for encoded-byte and aggregate bounds because JSON Schema `maxLength` counts characters and cannot express aggregate UTF-8 bytes.
- Independent verification passed deterministic regeneration, scoped race tests, vet, and diff checks. Schema-v1 rejection and required migration remain the already accepted compatibility policy.

## 2026-09-08 — M-05-E01 execution worker passed

- `internal/execution` owns one active child with no queue. Submit returns without waiting for execution; busy attempts launch nothing and enter history. Children receive literal arguments, `/` as working directory, exactly the fixed minimal `PATH`, no inherited environment, and a new process group.
- Timeout and Close perform bounded group TERM/grace/KILL/reap supervision. Signal errors are retained; unconfirmed reap remains truthfully running with `supervision_error`, keeps the worker occupied, returns stable errors, and publishes one nonblocking generation fault rather than claiming completion.
- History retains the active record under busy pressure, evicts the oldest terminal entry, bounds output to separate 4,096-byte tails with totals, exposes output-free limited summaries, and defensively copies results. UUIDv7-style IDs increment only the 74 non-reserved bits and carry into the timestamp.
- Architecture A02 defects covering active eviction, unbounded reap, ignored signal failures, list sizing, and UUID reserved-bit carry were remediated. Independent full race and 50-repeat lifecycle/carry gates passed. A combined Submit/List/Get/Close test then passed 20 race-detected repetitions. Remaining OS risk is a child that cannot be killed or reaped; the fail-closed worker and fault channel make that state observable to runtime integration.

## 2026-09-08 — M-05-R01 runtime and history integration passed automatic gates

- Completed execute press actions submit an immutable request containing the committed originating profile/value IDs, absolute executable, cloned literal arguments, and bounded timeout. Submission does not wait for the child; existing wake, transition, matched press/release, and activate-profile behavior remains intact. Busy is retained history and is never retried.
- Runtime owns one execution generation, exposes only read-only history to IPC, closes execution admission before other service teardown, and monitors the one-shot supervision-fault channel. Ordinary child results are nonterminal; unconfirmed reap produces a sanitized terminal runtime failure and readiness withdrawal.
- Internal protocol v1 now includes strict read-only `executions.list` and `executions.get`. No IPC method supplies, starts, retries, or cancels commands. List summaries exclude output and command material; get returns separate canonical-base64 output tails with totals/truncation. Discovery and legacy CLI modes support both queries.
- Architecture review accepted the integrated boundary. Exact maximum-width fixtures produce a 16,007-byte list frame and 11,743-byte get frame including LF, below the 16,384-byte limit. Main full race, test, generation, vet, build, diff, and unsandboxed socket E2E gates passed. Independent focused race, socket, and 50-repeat worker gates found no defect; its monolithic full-race attempt was interrupted, so the main full-race run is the source for that aggregate gate.

## 2026-09-08 — M-05-V01 physical executable-action acceptance passed

- A temporary owner-visible schema-v2 profile bound square `0_0` to absolute `/usr/bin/printf` with literal arguments `literal:%s\n` and `a;$(not-executed)|*.txt`. The owner pressed and released that tile once.
- Verbose input recorded the expected wire-index-0 pressed/released pair. `executions.list` returned one terminal `exited` record with exit code 0, no signal, and no supervision error. `executions.get` returned 32 stdout bytes, zero stderr bytes, and no truncation; canonical base64 decoded exactly to `literal:a;$(not-executed)|*.txt\n`.
- The literal output establishes that shell metacharacters were passed as argv data rather than evaluated. Controlled SIGINT shutdown removed the generation socket and metadata; the owner-only discovery directory retained only its persistent `runtime.lock`.
- Independent milestone-close review passed the configuration, worker, runtime-routing, IPC/CLI, physical evidence, privacy, and lifecycle mapping with no blocker. The final unrestricted whole-tree generation, race, vet, build, and diff gate also passed.
- This closes the direct-Go M-05 vertical slice on the owned D200X. It does not broaden the contract to environment files, configurable child environment/current directory, asynchronous or concurrent execution, configuration reload, long/double press, or persistent history.

## 2026-09-11 — M-06-P01 transactional reload contract confirmed

- The owner confirmed automatic external-edit detection as part of M-06. The runtime will use `fsnotify` on the explicit configuration's parent directory, filter the configured basename, treat events only as dirty hints, and use one internal 200-millisecond trailing debounce. Atomic rename-based editor saves are an acceptance case.
- All triggers feed one reload coordinator. A complete immutable candidate is read, decoded, validated, rendered, and semantically diffed before authoritative mutation. One reload may be active with no queue; a concurrent manual trigger reports busy, while watcher events during an attempt set one dirty bit for at most one subsequent attempt.
- Invalid, unreadable, or unpreparable candidates retain last-known-good state with zero HID writes and a bounded status failure while health remains ready. Any failed/uncertain write after live application begins publishes no candidate and fail-stops because device rollback cannot be trusted.
- Reload preserves the current profile when present and otherwise falls back to the candidate default. Only effective page changes redraw. Brightness changes write once while awake but only change the future restore target while dimmed. Idle timeout changes remain owned by the existing policy loop and derive from latest activity.
- Partial gestures reset at transition. Existing child executions continue with copied request data; reload does not cancel, mutate, retry, or relabel them. Post-commit gestures use new bindings.
- Strict protocol-v1 `config.reload` and `config.status` will expose bounded revision/outcome/effect metadata without paths, TOML, action material, environment, raw OS errors, or timestamps. The owner proposed `config.get` and then explicitly deferred it.
- Architect A01 recommends one serialized effective-snapshot boundary and warned that transactionality cannot promise device rollback. Automatic watching remains required by the existing product overview; the transaction coordinator is implemented first and the watcher attaches afterward.

## 2026-09-11 — M-06-C01 immutable candidate and semantic diff passed

- Two runtime-local pure boundaries now build a validated immutable reload candidate from the explicit absolute configuration and compare it with the current effective candidate. They retain no source path or TOML bytes and perform no HID access, goroutine startup, or live mutation.
- Candidate construction resolves the existing current profile when present and otherwise falls back to the candidate default. It prebuilds the typed live page and retains copied catalog, profile, page, rendered bytes, brightness, and idle timeout for later serialized application.
- Diff classification covers unchanged, action-only, display, brightness, idle, default, and catalog changes. Display comparison uses deterministic rendered live-page archive bytes; inactive-profile changes remain catalog-only until activated.
- Independent V01 found no production defect but identified missing direct coverage for an empty current-profile ID. R02 added that boundary; independent V02 passed 20 race-detected repetitions, vet, and diff checks. The main focused runtime race/vet/diff gate also passes.

## 2026-09-11 — M-06-R01 serialized reload application passed

- Reload and profile activation now share one coordinator. Successful reloads publish catalog, current/default profile, bindings, settings, rendered page, and revision through one atomic effective-snapshot pointer; startup begins at revision 1.
- Invalid and pre-write-cancelled candidates retain the last-known-good snapshot with zero writes. Display changes issue one typed live-page update before commit; a failed attempted write retains the snapshot and enters the existing terminal uncertain state. Action-only and catalog-only changes commit without HID writes.
- Brightness and idle-timeout changes deliberately remain uncommitted with zero writes and a stable pending result until M-06-I01 routes them through the existing idle-policy owner.
- Main runtime race and vet gates passed. A transient full-suite brightness diagnostic timing failure passed five focused repetitions and the subsequent full suite. Independent V01B passed the runtime race suite in 21.594 seconds, vet, and diff checks with no production defect.
- Residual test risk: there is no adversarial concurrent-reader assertion for same-revision multi-field observations; the implementation uses a single atomic snapshot pointer and passes race detection.

## 2026-09-11 — M-06-I01 mutable idle settings passed after race remediation

- Reloaded brightness and idle timeout now pass through an unbuffered bridge consumed by the existing idle-policy loop, retaining one owner for dim state, suppression, activity time, timers, and keepalive scheduling. Awake brightness changes write once; dimmed changes alter only the future restore target; timeout deadlines derive from the last recorded activity.
- Independent V01 exposed two real lifecycle races: a due keepalive could cross the check-to-transition boundary, and a delivered settings request could block if the policy consumer stopped before responding. Due writes now revalidate and hold the transition read gate through the write. Settings requests now have atomic claim/abort state so shutdown aborts unclaimed requests while claimed requests return their authoritative result.
- Deterministic tests cover unchanged keepalive scheduling during zero-timeout restore, due keepalive/dim deferral across transition begin, bridge shutdown after delivery, and end-to-end Runtime.Reload recovery with last-known-good revision retained. The end-to-end shutdown case passed 20 race-detected repetitions.
- Worker and main runtime race/vet/diff gates pass. Independent V02 passed the first two gaps and missed the existing end-to-end reload test during inspection; the main repeated gate supplies the missing evidence. No confirmed I01 defect remains.

## 2026-09-11 — M-06-I02 bounded reload IPC and CLI passed

- Protocol v1 now exposes exact no-option `config.reload` and read-only `config.status` requests. Results contain only instance ID, revision, bounded state/outcome/reason/effect enums, and explicit effect booleans; they exclude configuration content/path, profile/action/command/environment material, timestamps, and raw errors. `config.get` remains deferred.
- Discovery and explicit legacy CLI modes accept dotted methods and `config reload|status` subcommands, reject irrelevant flags and extra arguments, and revalidate the discovered generation after the call. Maximum response framing remains below 16,384 bytes.
- Independent V01 found that real HID-write failures were misclassified as `reload_rejected` because the uncertain state did not survive as an error identity. R04 wraps attempted-write failures with `ErrProfileStateUncertain`; the adapter now returns static `device_write_failed`, while pre-write failures retain their nonterminal classifications.
- Independent V02 passed the real page/settings failure regressions and static server mapping for 10 race-detected repetitions, plus runtime/IPC race, vet, and diff gates. Main affected-package race/vet, full-suite, and diff gates pass. No confirmed I02 defect remains.

## 2026-09-11 — M-06-W01 external-edit watcher passed

- The runtime watches the explicit configuration's parent directory and filters the exact basename, allowing direct writes and atomic rename-based replacement to remain observable. Create, write, rename, and remove events are dirty hints; chmod and unrelated paths are ignored.
- A fixed 200-millisecond trailing debounce coalesces bursts. A capacity-one automatic signal and one admission dirty bit ensure an event consumed during an active reload produces at most one subsequent attempt; manual concurrent reload remains busy.
- Watcher setup/runtime failures disable automatic watching with static verbose diagnostics while readiness and manual reload remain available. Watcher and automatic-reload goroutines start only in Run and are joined on every teardown branch.
- Independent V01 passed 10 race-detected watcher-suite repetitions in 51.735 seconds, the full runtime race suite in 29.192 seconds, vet, and diff checks. Coverage includes filtering, direct/atomic/removal saves, debounce, active-attempt coalescing, invalid-content single attempt/recovery, degradation, Run-only ownership, and shutdown. No production defect remains; physical validation is reserved for M-06-V01.

## 2026-09-11 — Descriptive owner-local configuration diagnostics deferred

- The owner attempted to start the M-06 physical gate with `deploy/hidhogg.toml`; startup returned only `configuration could not be loaded`. Inspection showed that the file used obsolete schema v1 fields (`schema_version = 1`, `pages`) while production accepts schema v2 (`schema_version = 2`, `default_profile_id`, `profiles`).
- The owner requires future local errors to identify the explicit source path and problematic key or syntax location. M-06-F01 records this work after the current physical gate.
- The intended boundary distinguishes owner-local diagnostics from IPC privacy: local startup stderr or an explicit local reload may name the configuration path, dotted key, and bounded parse/validation category, but must not echo values or source content. IPC and discovery responses remain sanitized and bounded.

## 2026-09-11 — Startup initial-profile reassertion queued for physical investigation

- The owner requires each successful runtime boot to send the configured initial/default profile once; otherwise the D200X may continue showing the last page applied by an earlier process.
- The current startup path already constructs the configured default page and invokes one complete-page send before readiness. Therefore this is recorded as M-06-F02, an unconfirmed physical-path defect or regression, rather than a known absent feature.
- Verification must begin with a visibly different retained page and distinguish skipped/ineffective/stale-content startup from an unnecessary duplicate-send workaround. No retry or second startup redraw is authorized without that evidence.

## 2026-09-11 — M-06-F01 contract confirmed and F02 physically reproduced

- The owner confirmed that local configuration diagnostics may include the absolute source path, dotted key, and TOML line/column when available. They must not echo configuration values or source excerpts; IPC remains the bounded sanitized `reload_rejected` surface.
- F01 must cover startup and runtime-local reload diagnostics for syntax, schema version, obsolete/unknown fields, missing fields, type mismatches, semantic validation, and unreadable paths.
- The owner reproduced F02 under schema v2: changed initial-profile content was not visible after startup and appeared only after the same configuration was saved again, triggering automatic reload. This confirms a startup-versus-live application defect even though the current startup path invokes one complete-page send before readiness.
- Direct code, explorer, and architect review found two startup-versus-reload differences: startup uses legacy fixed icon paths and immediately follows `0x0001` with auxiliary commands, while reload uses content-addressed icons and sends only `0x0001`. The physical report does not distinguish firmware caching from command-processing interference.
- The owner confirmed a diagnostic-first trial using `d200xprobe`: one fresh session will send unlock, content-addressed live-bulk `0x0001`, configured brightness, and input-enable in that order, exactly once each with no delay or retry. Production remains unchanged until the owner reports the device result.
- The bounded `startup-sequence` probe is implemented in the spike module. Parser, exact order/count, live-bulk archive identity, safe output, invalid pre-enumeration rejection, and ordinary/short failure at every logical boundary pass focused and full spike race, vet, and build gates.
- Independent D01-V01 repeated the probe package 10 times under race detection and passed the full spike suite. The owner then ran the verified sequence and confirmed all three observable results: the content-addressed live-bulk page appeared, brightness became 10, and the display remained active.
- This physical pass validates the combined candidate order but does not isolate fixed-path caching from auxiliary-command timing as the sole cause. It is sufficient to select the tested order for a production implementation; the production cold-start gate remains required.
- On 2026-09-12 the owner confirmed the production plan: add one typed startup transaction using the already-built content-addressed initial candidate and send unlock, page, brightness, then input-enable under one session lock. Legacy `SendPage` must share the content-addressed builder; no duplicate page, delay, retry, rollback, or post-readiness redraw is authorized.

## 2026-09-11 — M-06-F01 descriptive local diagnostics completed

- `internal/config` now owns typed safe diagnostics. Local output contains the absolute configured path, a closed category, a canonical dotted or indexed key, and go-toml's typed 1-based line/column when available. Details are fixed and bounded; raw causes, TOML context, source excerpts, and configuration values are never rendered. `errors.Is` and `errors.As` identities remain available internally.
- Startup emits one local diagnostic. Manual and automatic candidate rejection converge on one runtime-local emission per admitted attempt, independent of verbose mode. Busy, cancellation, shutdown, and device-write failures are excluded. IPC retains the static `reload_rejected` boundary.
- Independent V01 identified that separate component locks did not serialize multiple producers sharing raw stderr. The runtime now wraps stderr once with a shared serialized writer used by D200X session, profile, reload, and watcher diagnostics; stdout remains unchanged.
- Independent V02 passed the unsafe byte-writer concurrency stress 20 times under race detection, the broader affected-package race suite, vet, and diff checks. Path/key/location, schema/pages guidance, read/decode/semantic categories, bounded UTF-8/control filtering, secret suppression, exactly-once logging, excluded failures, and static IPC all pass. No confirmed F01 defect remains.

## 2026-09-11 — M-06-F01 reopened for bounded rejected-status metadata

- The owner confirmed that consumers need the latest rejected configuration's safe line or key detail. `config.status` will carry an optional diagnostic containing category, key, line, column, and static detail only when the latest completed attempt is candidate-rejected.
- The status projection must omit the absolute source path, values, TOML excerpts, action/command/environment material, and raw causes. The `config.reload` error response remains the static `reload_rejected` contract.
- A later completed attempt whose outcome is not candidate-rejected clears the diagnostic. Busy observation does not manufacture or replace completed-attempt metadata.

## 2026-09-11 — M-06-F01 rejected-status projection completed

- `config.status` now always includes a `diagnostic` field. It is null unless the latest completed attempt is `rejected` for `candidate-rejected`; otherwise it is an exact path-free object containing category, nullable key, nullable paired line/column, and fixed detail.
- Runtime admission stores outcome, reason, and a defensively copied safe projection under one mutex. Manual and automatic candidate rejection publish it; subsequent successful, canceled, unsupported, closed-attempt, or device-failed completion clears it. Busy/active observation preserves the latest completed-attempt record. Runtime lifecycle closure itself does not erase that record.
- Strict IPC decoding rejects missing/extra/wrong-type/control-containing/out-of-range diagnostics and incompatible outcome/reason combinations. `config.reload` remains static `reload_rejected`; status excludes path, values, excerpts, raw causes, actions, commands, and environment material.
- Independent V04 passed runtime cancellation/device clearing, discovery and legacy CLI rendering/non-disclosure, strict codec compatibility, frame bounds, and diff checks for 10 race-detected repetitions. No confirmed defect remains.
- The owner subsequently confirmed the descriptive rejection behavior works in the live workflow. This is the authoritative owner-visible acceptance for M-06-F01.

## 2026-09-11 — M-06 transactional configuration reload completed

- Architecture close review passed the single-snapshot transaction, activation serialization, idle-loop ownership, last-known-good/fail-stop boundary, gesture/child isolation, strict IPC privacy, watcher semantics, and lifecycle/degradation design. No production correctness defect remained.
- Comprehensive automatic verification passed `go generate ./...`, whole-tree race tests, vet, build, formatting, diff checks, and targeted M-06 race stress with no generated drift.
- The owner reported that all steps in the manual M-06 runbook passed. This is the authoritative owner-visible evidence for valid automatic external-edit application, invalid-edit retention of the last-known-good runtime, subsequent valid recovery, and clean shutdown.
- M-06 is complete. Device-side atomicity, rollback, and cross-firmware behavior remain intentionally unclaimed. M-06-F01 descriptive local configuration errors and M-06-F02 startup reassertion investigation remain planned follow-ups rather than milestone blockers.

## 2026-09-12 — M-06-F02 production correction passed automatic gates

- Production startup now consumes the already-built content-addressed initial `LivePageUpdate` and sends exactly unlock, complete-page upload, configured brightness, then input-enable under one session write lock before readiness. `SendPage` builds the same update and delegates; diagnostic-only fixed-path `SendPageUpload` remains unchanged.
- All update and brightness validation precedes HID writes. Ordinary or short write failure stops later frames, invalidates the session through the existing transport boundary, performs no retry or rollback, and prevents successful runtime startup/readiness.
- Independent V01 passed archive/payload identity, exact sequence, all logical failure boundaries, startup readiness unwinding, legacy entrypoint and diagnostic compatibility, profile/reload regression checks, focused race/vet, whole-tree tests/build, and diff checks. The remaining gate is an owner-visible cold start from a visibly different retained page, followed by a clean-shutdown repeat without saving the configuration.

## 2026-09-12 — M-06-F02 physical acceptance completed

- The owner ran the production runtime twice from a deliberately different retained device page without saving or reloading the configuration. Both cold starts visibly replaced the retained page with the configured initial page as expected.
- Together with the automatic and independent gates, this establishes that the typed unlock, content-addressed page, configured-brightness, and input-enable startup transaction corrects the reproduced startup reassertion defect on the owned D200X and current firmware. Cross-firmware behavior remains unverified. M-06-F02 is complete.

## 2026-09-15 — M-04-F04 firmware label rendering passed automatic gates

- The owner observed that `*` and `+` appeared as raster fallback `?` glyphs while their separate firmware-rendered labels were correct. Prior controlled Studio evidence already established that `Font.Align` and `Font.Size` change manifest fields without changing PNG bytes, correcting the assumption that Hidhogg should rasterize label text into tile artwork.
- Position configuration now has optional `label_alignment` and `label_size` with backward-compatible effective defaults `bottom` and `10`; the strict accepted domains are `bottom|center` and `8..32`. Labels remain required visible text. The ignored deployment numpad profile sets all 14 positions to `center` and `24` and retains its literal no-shell `/usr/bin/osascript` press actions.
- Configured, targeted, and bulk archives now encode text/style in the manifest while PNG members contain only background and border. Equal artwork therefore retains identical PNG bytes/content-addressed paths across label/style changes. Independent V01 passed configuration/schema parity, propagation, manifest/PNG invariants, reload classification, determinism, race, generation, vet, full tests/build, formatting, and diff checks. Physical size-24 rendering and AppleScript input remain unverified.

## 2026-09-16 — M-04-F04 wide-label protocol limitation and fallback

- Owner-visible trials found no `3_2` label with center/24 or Studio-matching bottom/10 while `SmallViewMode: 2` background rendering remained active. Earlier Studio T12 evidence had an empty `Text` field, so it never established wide firmware-title support; square firmware labels remain verified.
- The implementation now renders only the wide label into its deterministic 458x196 PNG with bundled Go Regular, retains `SmallViewMode: 2`, and sets the wide manifest `ShowTitle` false to avoid a possible duplicate. Square labels remain firmware-rendered and their PNG content addresses stay independent of text/style.
- Independent P02-V01 passed explicit `Enter`, digits, `.`, `*`, and `+` glyph checks plus configured, targeted, bulk, determinism, content-addressing, square deduplication, race, generation, vet, full test/build, formatting, and diff gates. Owner-visible wide-label acceptance remains pending.
- The first fallback made `Status` and `Enter` visible, proving that wide PNG text works, but the owner reported the 72-DPI result was very small and bottom-aligned. The bottom placement was the retained diagnostic configuration; `label_size = 24` is a point value, not a requested 24-pixel cap.
- P03 restores the numpad wide position to center/24 and rasterizes point sizes at 144 DPI, so 24 points produces approximately 48 device pixels. Independent V01 passed metric comparison against a 72-DPI control, focused race, deterministic archives, full generation/vet/test/build, formatting, and diff gates. Final physical size/alignment acceptance remains pending.
- Position `id` is currently used for semantic execution-history identity, duplicate validation, reload comparison, and logs. It is not required for D200X addressing because the coordinate is already unique within a profile. A future breaking schema may key positions as `[profiles.positions."2_2"]` and derive history identity from profile plus coordinate; `[profiles.2_2]` is rejected as a design because it mixes positions with profile metadata. No schema change is authorized in M-04-F04.

## 2026-09-17 — M-04-F04 display acceptance

- The owner accepted the corrected 144-DPI wide label as slightly smaller than square firmware labels but adequate. Combined with prior automatic and independent verification, this closes the label-display task; exact font parity and cross-firmware support are not claimed.
- Numpad typing-action acceptance is separate and remains unconfirmed. No additional font tuning or commit is authorized by this acceptance report.

## 2026-09-17 — M-05-F01 action timing contract approved

- The owner approved scalar `gesture = "press"` for initial-down execution and `gesture = "release"` for execution on an up event only after matching down. Omitted gesture defaults to release; duplicate downs do not retrigger; press bindings ignore release; idle-wake gestures remain fully consumed.
- Because schema v2 `press` meant a completed pair, the owner explicitly rejected backwards compatibility and approved strict schema v3 plus migration of maintained configurations. Numpad bindings move to press; existing profile-switch bindings retain their timing as release. Position-table restructuring is deferred.
- Separate `gesture` and `trigger` fields were discarded as redundant for the current scope. A string-sequence gesture language was deferred because delay/order/cancellation semantics are unspecified and unnecessary for this vertical slice.

## 2026-09-17 — M-05-F01 automatic implementation verified

- Schema v3 is the sole accepted version; older configurations receive descriptive version-key diagnostics. Omitted gestures become effective release in TOML decoding and immutable catalog construction; explicit empty TOML gestures are rejected. The generated linting artifact is `schema/hidhogg-d200x-v3.json`.
- Press execution occurs once on initial down; release execution requires a matching down with a still-valid binding. Per-key held state survives profile/reload cancellation while pending release candidates are cleared; suppressed idle/transition events reconcile physical latches without action submission. Multiple configured keys can retain independent release candidates.
- Independent V01 passed focused and whole-tree race tests, strict/default/schema parity, both action variants, duplicate/orphan/mismatched events, held profile-switch behavior, reload/transition/idle boundaries, bounded-map audit, generation, vet/build, formatting, and diff checks. Maintained examples/fixtures and ignored deployment configuration are migrated to v3; numpad uses press and profile actions use release.
- No HID or configured real action was executed during implementation. Owner-visible press timing and numpad typing acceptance remain pending; changes are uncommitted.

## 2026-09-17 — First-post-transition input attribution defect

- The owner reported that the first press after switching profiles is ignored. Inspection found that `readInputObservations` snapshots the transition generation before blocking `ReadInput` and rejects an event when the generation changes during that wait, even if the event returns after the transition completes. This software condition matches the symptom; physical causality still requires the corrected owner-run check.
- The owner authorized M-05-F01-F01: attribute events at reception, preserve active-transition and stale queued-event suppression, and add deterministic input-reader tests. Existing controller-level gesture tests did not cover a blocked read spanning a completed switch.
- The reader now snapshots transition state once immediately after successful input read return. Independent F01-V01 passed deterministic blocked-read and combined fake-executor tests: first post-completion down submits once immediately; duplicate down/release do not submit; next fresh down submits again. Active-transition observations and stale queued observations remain suppressed with physical latch reconciliation.
- Focused race repetition (20), full runtime race, whole-tree tests, vet/build, formatting, and diff gates passed. Some earlier whole-tree attempts hit intermittent discovery process-exit and runtime test failures that passed isolated/rerun; no related production defect was reproduced. The corrected hardware behavior remains unconfirmed. Runtime observation is not a hardware arrival timestamp.

## 2026-09-17 — Numpad typing latency investigation

- The owner confirmed the first-post-switch correction works, but reported press-to-visible-text latency. Read-only generation-local execution summaries contained 19 numpad records: 15 exited and four rejected_busy. Completed process durations ranged from 124.384 to 470.662 ms, with median 139.431 ms. Submission-to-start timestamps imply approximately 2–6 ms (median 3 ms) before start, so most measured time is inside the command path rather than worker admission. These are process timings, not hardware-press-to-visible-character measurements.
- Five authorized no-op `/usr/bin/osascript -e 'return 1'` runs took 30–50 ms each. No typing or application-data access was performed in this benchmark. Apple Events delivery and application rendering were not separately measured. The existing single-slot execution worker intentionally rejects overlapping submissions rather than queues them, matching the four busy records.
- A native cgo-free implementation can dynamically bind system CoreGraphics keyboard/text event APIs using [purego](https://github.com/ebitengine/purego), which supports macOS arm64/amd64. [RobotGo's current Darwin backend](https://github.com/go-vgo/robotgo/blob/master/darwin/cg.go) demonstrates direct framework loading and symbol registration; its [cgo-free backends](https://github.com/go-vgo/robotgo#cgo-free-builds) are explicitly experimental. No local native-input implementation or benchmark exists yet.
- [Apple's Unicode-event API](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:)) supports text payloads but documents that some application frameworks may ignore them. Physical key events and text insertion should therefore be distinct actions; Enter is a key, not a text string. A native approach still needs event-posting permission and must not silently report delivered input merely because posting returned.
- Recommended next decision: approve a small isolated purego/CoreGraphics input spike before production integration, with permission preflight and fake-only automatic tests; no real event injection until separately authorized. No production code changes were made during investigation.

## 2026-09-17 — S-03 native-input spike approved

- The owner authorized building the isolated Go/purego/CoreGraphics spike. The selected boundary is a standalone `spikes/go-native-input` module; production action configuration and the generic execution worker remain unchanged.
- Agents may run non-prompting permission preflight and construct/release benchmarks without posting events. Live text/Enter delivery remains owner-run. The probe must distinguish a text payload from a physical key event, allocate both halves before posting, and preserve native pointer/release ownership.
- `purego v0.10.2` is already an indirect root dependency; the spike pins that version as a direct module dependency instead of adding a new broad desktop-automation framework. A construction benchmark cannot establish end-to-end typing latency or foreground-app delivery.

## 2026-09-17 — S-03 automatic/no-post probe verified

- `spikes/go-native-input` now contains a standalone module, typed text/Enter actions, dynamically loaded system-framework backend, strict CLI, fake tests, and owner runbook. Default prints usage; `--check` never prompts or posts; `--benchmark N` constructs/releases Text("1") pairs; `--text` and `--key enter` are owner-only posting modes with optional focus delay.
- Independent V01 passed SDK ABI audit, cgo-free dependency graph, UTF-16 surrogate/lifetime checks, allocate-both-before-post, partial-failure release, permission-before/after-delay checks, fake-only race tests, vet, formatting/diff, and Darwin arm64/amd64 builds. No root module or production action code changed for the spike.
- Approved outside-sandbox final Text("1") benchmark: 1 unmeasured warm-up plus 1,000 iterations; min 1.083 microseconds, median 1.166, p95 2.459, max 12.833; zero events posted. Permission preflight reported granted in that execution context. Sandbox preflight was denied and construction emitted hiservices XPC warnings, so the warning-free outside-sandbox run is the canonical allocation timing.
- Live posting and visible UI latency remain untested; a stable owner-built binary may need its own permission grant. CoreGraphics posting returns no target-delivery acknowledgement. Next: owner-run harmless-field text and Enter tests, then an explicit decision on production integration and burst handling. Changes remain uncommitted.

## 2026-09-17 — S-03 owner delivery failure and diagnostic extension

- The owner reported granted permission preflight but no text delivery; an Enter test also produced no newline in VS Code, and a subsequent TextEdit test produced no text. These observations do not identify the cause or prove that correctly constructed events reached the target application.
- The owner authorized isolated construction diagnostics and selectable event source/posting locations. Production actions remain unchanged; agent-run posting, permission prompts, clipboard access, and application-data reads remain outside scope.
- [Apple's posting API](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)) posts at a selected event-stream location and returns no delivery result. Source/tap variations are diagnostic hypotheses, not established fixes. Construction readback will run without posting.
- Approved outside-sandbox no-post inspection read back Text("1") with combined/session options as down/up types 10/11, keycode 0, flags `0x20000000`, and Unicode `[0031]` matching both events. Default/null-source Enter read back types 10/11, keycode 36, flags `0x20000000`, and native Unicode `[000D]`; Unicode-payload matching is not applicable to physical Enter. Both commands posted zero events and performed no permission checks. This validates these construction observations, not target delivery or a source/tap fix.
- The isolated extension adds `--inspect` with `--text` or `--key enter`, `--source default|private|combined|hid`, and `--tap hid|session|annotated`. Source states map to null/-1/0/1 and posting locations to 0/1/2. Inspection uses bounded UTF-16 readback and releases both events and any explicit source on success/failure; check/benchmark reject these modifiers. Executor and main race/vet/build/format gates passed; executor also passed both Darwin architectures. Main rebuilt the ignored `deploy/native-input` binary without posting events. Independent extension verification remains pending at this checkpoint.
- Independent V02 subsequently passed automatic ABI/fake/race/vet/format and both Darwin architecture gates, including oversized-readback cleanup. Its overall report was partial because sandbox native private-source allocation failed and HID-source initialization exceeded 30 seconds with HIServices connection errors; main's warning-free default/combined construction evidence does not establish those variants. Explorer A02 found no production integration or unexpected spike artifacts. Delivery remains unresolved; next owner-run trial is one combined-source/session-tap text pair, not an exhaustive matrix or production integration.
- After the timed-out source trial, an approved outside-sandbox exact-name PID check found no process named `native-input`; the spike file inventory contained only its ten expected source/module/documentation files. No agent posted events or launched a target application in this extension.

## 2026-09-18 — Native input owner comparison and integration approved

- The owner reported TextEdit text delivery succeeded for explicit combined source/session tap, failed for combined/HID, and failed for default/null source/session. Earlier null/HID tests also failed. These are one-machine application observations, not a proven explanation for the differences or cross-application support.
- The owner approved built-in `type_text` and `key_press` actions, a bounded native-only FIFO, posting history that does not claim delivery, and runtime-owned permission management. Existing execute behaviour remains unchanged, with no automatic osascript fallback.
- Additional approved IPC/CLI methods are `input.status`, explicit `input.request_permission`, and a read-only `doctor`. Startup/status/doctor remain non-prompting and never inject test input. The request must originate in the Go runtime that posts events; the future Swift app can reuse IPC.
- [Apple exposes `CGRequestPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()), returning a boolean; permission check/request functions were verified against current documentation on 2026-09-18. Permission UI/process identity and post-grant behaviour remain owner-run gates. No promise is made that a request itself grants access.
- M-05-F02 is selected with separated contract/native/integration responsibilities. Architecture review is requested before locking lifecycle/interface details; deploy numpad migration remains behind owner Enter/symbol and production acceptance gates.

## 2026-09-18 — Native input review checkpoint

- Strict text/Enter contracts and generated schema are implemented; main focused config/profile tests pass. Runtime compilation passed before the private backend cancellation API revision. Independent automatic review is in progress; this is not milestone completion.
- Architecture consensus is a combined-session source/session tap with both event flags set to zero. Held physical Cmd/Control behaviour remains an owner-observed gate; no synthetic modifier-release events are added.
- Per-item cancellation must be checked after preparation immediately before down posting. Once down begins, up follows even if canceled. The narrow final-check/down race can still post a complete pair; cancellation is not an absolute no-post-after-shutdown guarantee. Native ownership is retained if bounded Close times out while a native call remains in flight.
- Execution history adds an action-type discriminator. Valid maximum IPC fixtures preserve the 16 KiB frame/32-record bounds using producer-sized 36-byte IDs and mutually exclusive exit code/signal; no silent clipping or frame increase is selected. Existing timestamp encoding already normalizes UTC.
- Detailed owner-review decisions are maintained separately in `docs/native-input-decisions.md`. Deploy configuration remains on osascript; no agent posts or permission prompts occurred.

## 2026-09-18 — M-05-F02 implementation and automatic closure

- Implemented schema-v3 native text/Enter variants, the native-only 16-waiting/one-active FIFO, runtime lifecycle/dispatch/history adapters, strict input permission/status/doctor IPC, CLI mappings, and protocol documentation. Existing execute admission is unchanged. Owner deployment remains unmigrated.
- Independent full uncached test/race suites, vet, schema comparison, module verification, whitespace checks, and Darwin arm64/amd64 builds passed. Main reran final full uncached test/race/vet gates and native race stress: 10/10. Deterministic tests cover cancellation during preparation, assigned-but-unstarted input, permission-request context cancellation, no replay, deferred release, and close timeout/eventual release.
- Final architecture review found no remaining correctness blocker. Native initialization is synchronous before IPC under startup serialization; an indefinitely blocked source-creation/preflight call can delay HID startup and Runtime.Close. Ordinary returned failure isolation is not a universal bounded-shutdown guarantee. NI-13 records that limit.
- Verification ownership lesson: the assigned read-only tester added `internal/nativeinput/worker_test.go` cases and `cmd/hidhoggctl/input_test.go`. Main reviewed/preserved the test-only overlap and reran final gates; no production/doc edits were reported by the tester. Future read-only roles must preserve their explicit write boundary.
- Generated `/Volumes/Data/tmp/nativeinput-darwin-arm64.test` and `/Volumes/Data/tmp/nativeinput-darwin-amd64.test` were removed and verified absent; both are reproducible build artifacts. No unrelated temporary/user files were touched.
- Owner-only commands and harmless-field acceptance are in `docs/native-input-runbook.md`. Text/Enter/symbols, VS Code, rapid ordering, held modifiers, permission UI/post-grant behaviour, and shutdown remain physical gates. No process was launched or input posted by agents, no commit was made, and no milestone-completion notification was sent.

## 2026-09-18 — Owner-approved native numpad configuration

- The owner explicitly confirmed replacing deploy numpad osascript actions with native input before manual acceptance. `deploy/hidhogg.toml` now has 13 `type_text` actions for digits/symbols and one Enter `key_press`; all retain `gesture = "press"`. Layout, labels/styles, brightness, initial profile and other profiles were preserved.
- Strict `config.Load` and assertions for all 14 mappings passed through a temporary verification test alongside config/profile tests. The temporary test was removed. No runtime was launched, input posted, or permission prompt requested. Physical acceptance remains pending; migration alone does not close M-05-F02.

## 2026-09-18 — Native numpad owner acceptance

- Following the deploy migration, the owner reported "all working as expected". This confirms expected behaviour of the deployed native numpad; no new automatic test was required for this report.
- Specific target application, rapid ordering, held modifiers, runtime permission request/status/doctor and shutdown observations were not supplied. Those scenarios are not inferred from the numpad report. M-05-F02 remains pending scenario confirmation or explicit waiver; no milestone notification or commit was performed.

## 2026-09-18 — M-05-F02 owner functional closure

- When explicitly asked whether input.request_permission, input.status and doctor were also verified, the owner replied "yes, all seems ok". Combined with the deployed numpad report, this closes owner functional acceptance and M-05-F02 on the already-passing automatic/final architecture gates.
- Specific cross-app, rapid-ordering, held-modifier, revocation/regrant and shutdown observations are not individually claimed. These remain evidence limits, not invented physical test outcomes. Synchronous native initialization can still delay startup/runtime close; NI-13 remains qualified.
- Closure changes documentation only. No commit, runtime launch, input posting or permission request was performed by agents. Next implementation/commit requires a new owner request.
- The required milestone `notify-discord` command completed successfully (exit 0) after durable closure records were updated.

## 2026-09-18 — Completed Go checkpoint approved for commit

- The owner approved the recommended sequence: commit completed work, then draft M-07's Go-only notification slice. The commit includes the completed label-rendering and schema-v3 gesture prerequisites, native-input spike and production integration, associated tests/examples/schema, protocol and durable records. Protected user files and compiled artifacts are excluded. `deploy/hidhogg.toml` is ignored and is not force-added.
- Fresh root tests initially failed unchanged `TestLockReleasedOnProcessExit`: the parent acquired the directory after reading readiness. Source inspection shows the child prints `locked` and immediately returns, allowing process exit before the parent's contention check. The isolated test then passed 10/10 and the full root suite passed on rerun; root vet and standalone native-spike tests passed. This is recorded as a discovery test synchronization follow-up, not a new production-lock defect or silent fix.
