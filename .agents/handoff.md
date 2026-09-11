# Hidhogg handoff

Updated: 2026-09-11

## Current canonical checkpoint

- M-04 is complete as of 2026-09-08. The final runtime uses one typed content-addressed full-page `0x0001` for live activation; automatic and owner-visible physical acceptance pass.
- M-05 is complete as of 2026-09-08. Strict schema-v2 `execute`/`press` actions run one absolute executable with literal argv through a single nonblocking runtime-owned worker, retain bounded generation-local history, and expose read-only `executions.list/get` IPC and CLI queries.
- M-05 automatic, architecture, and independent focused gates passed. The owner-visible D200X acceptance bound `0_0` to `/usr/bin/printf`; one press exited 0 and captured exactly `literal:a;$(not-executed)|*.txt\n` with no stderr, truncation, signal, or supervision error. Shutdown removed socket/metadata and retained the persistent lock.
- M-06 is complete as of 2026-09-11. The runtime builds immutable candidates, serializes reloads with profile activation, applies brightness and idle-timeout changes through the sole idle-policy owner, exposes strict bounded IPC/CLI methods, and watches the explicit configuration's parent directory with a 200-millisecond trailing debounce. Architecture and comprehensive automatic gates passed; the owner reported the complete manual sequence passed: valid automatic reload, invalid-edit last-known-good retention, valid recovery, and clean shutdown. `config.get` remains deferred.
- M-06-F01 is planned after V01: owner-local startup/reload diagnostics should identify the explicit configuration path and failing dotted key or TOML line/column without echoing values. IPC/discovery errors remain sanitized. This was prompted by an obsolete schema-v1 deploy file producing only the generic load failure.
- M-06-F02 is a planned physical investigation: each successful generation must send the configured initial/default profile exactly once before readiness. The current code already intends to do so, so stale retained device content is not yet a confirmed missing implementation; reproduce from a visibly different page before changing write behavior.
- C01 introduced strict schema version 2 with one default and 1..31 complete profiles, exact optional `activate_profile`/`press` actions, and an immutable profile catalog. Independent V02 passed race, vet, schema determinism, boundary, invalid-input, and defensive-copy gates.
- R01 restored full-tree compilation and added the bounded transactional runtime profile service. Independent V04 passed activation, queue saturation, fail-stop, dynamic binding, idle suppression, diagnostics default selection, owned-reader cancellation, race, vet, compile, and diff gates.
- I01 added strict profile list/activate IPC and discovery-aware `hidhoggctl` commands. Independent V01 passed boundary, protocol, adapter, CLI, race, build, vet, and unsandboxed Unix-socket gates; 31 maximum-width summaries frame at 15,880 bytes and 32 at 16,387 bytes/rejected.
- A01 added one completed ordinary-press action using the same runtime service. Independent V01 passed emission ordering, wake suppression, transition, concurrency, no-retry, 100-repeat race, and whole-tree gates.
- Historical M-04-V01 automatic verification passed; its physical gate exposed the fixed-path redraw confound that led to P02/R03. Final physical acceptance is recorded under V03 below.
- The first M-04 live activation sent a second successful `0x0001` page sequence and committed `alternate`, but the D200X retained the original labels. That trial reused fixed icon paths; later controlled evidence proved path-sensitive image replacement. It therefore does not establish that live bulk `0x0001` is unsupported. M-04-P02 is testing one content-addressed full archive before the production redraw design is treated as final.
- A subsequent bounded spike trial established that one Studio-shaped targeted `0x000d` archive changes only square `0_0` live. The owner observed `Clock` become `LIVE-000D`. Production remains unchanged; repeated-update caching and wide-tile behavior are the remaining protocol gates before implementing the 14-position live batch.
- The repeated-path control then showed `LIVE-A` correctly, but sending `LIVE-B` with the same icon path changed only the label and lost the expected background/image. Fixed image paths are not reliable for repeated `0x000d` updates on this specimen; a content-derived-path control is the next discriminating trial.
- The content-derived-path control reused the exact `LIVE-B` PNG bytes and changed only its manifest icon path; the expected magenta image then appeared. Production live updates must use deterministic content-derived icon names. Targeted wide-tile behavior remains the last protocol gate before implementation.
- The targeted wide `3_2` control then passed: one `0x000d` with content-derived 458×196 artwork and `SmallViewMode: 2` changed only the wide tile with correct geometry. M-04-D02/R02/V02 are now the active correction path.
- M-04-P02 resolved the reopened bulk question. After automatic verification, an owner-observed repeat sent exactly one content-addressed full-page `0x0001` from a verified default baseline; the owner reported that all 14 tiles changed together. This is specimen/firmware evidence, not proof of device-side atomicity. M-04-R03 subsequently adopted that operation in production.
- M-04-D02 is complete. Typed production targeted archives and the canonical batch API pass independent archive, geometry, content-path, serialization, failure, race, vet, and compile gates; raw generic `0x000d` remains disallowed and startup is unchanged.
- Historical M-04-R02 implemented a canonical 14×`0x000d` transition and passed V02; R03 supersedes that runtime path while retaining the targeted protocol API for bounded single-position use.
- M-04-R03 supersedes the R02 runtime transition. Live activation sends one typed content-addressed full-page `0x0001`; generic raw `0x0001` and `0x000d` are rejected. Typed diagnostic page upload preserves startup/wake behavior. Architecture remediation and independent race, whole-tree, vet, build, and diff gates passed without skips.
- M-04-V03 physical acceptance passed: default startup rendered; IPC activation returned `changed:true` and all 14 alternate tiles appeared together; repeated activation returned `changed:false` with no transition; one `calendar` press/release produced one bulk transition and all 14 default tiles returned together; shutdown removed socket/metadata and retained the lock. Physical atomicity and cross-firmware behavior are not claimed.
- M-01, M-02, M-02-F01, and M-03 are complete.
- M-03 provides self-contained direct-Go runtime discovery through a caller-owned absolute `0700` directory containing persistent `0600` `runtime.lock`, generation-scoped `runtime.json`, and `runtime.sock`.
- One cooperating runtime owns one directory through a retained nonblocking exclusive advisory lock. The lock persists and is never automatically removed; no PID is authority.
- Valid stale generation entries are recovered only while holding the lock. Malformed or substituted entries are preserved and rejected before HID access.
- IPC binds before HID enumeration/open/write. Strict metadata is published atomically only after device initialization and serving readiness; it is withdrawn before terminal closure.
- `hidhoggctl --runtime-dir` discovers and revalidates generation identity without an instance argument. Legacy explicit socket/instance mode remains for Swift and tests.
- Independent full, race, vet, build, repeated lifecycle, formatting, and diff gates pass. Architect A03 found a direct-close self-wait deadlock; R04 corrected it, independent V03 passed, and architect A04 closed the blocker.
- Direct acceptance passed owner-only entry modes, discovery health/status, valid stale recovery, same-directory contention before any second D200X packet, unchanged display during rejection, clean zero-exit shutdown, metadata/socket removal, and persistent-lock retention.
- The worktree remains intentionally uncommitted. Preserve unrelated `.envrc`, `.codex`, Xcode workspace metadata, and other user-owned untracked files without reading or changing them.

### Current next action

M-06 is complete. Next, choose whether to address M-06-F01 descriptive owner-local configuration diagnostics and M-06-F02 startup initial-profile physical investigation before beginning the next product milestone. `config.get`, env-file loading/exposure, Swift foreground-application mapping, and asynchronous actions remain deferred; no `.env` content may be inspected.

All older checkpoints below are retained as historical evidence. Their `next action` statements are superseded by this section.

## Active Ulanzi Studio interaction checkpoint

`M-02-F02` has completed its bounded command-path investigation against a static-only copy of the owner's Ulanzi Studio app. The canonical record is `docs/ulanzi-studio-analysis.md`; the installed application was not modified or launched.

Verified results:

- The specimen is an arm64 Qt executable with SHA-256 `b64e598411c0d67fc44b08b09820e0b5fea12ce26052c44098e96bbd9b2c3022` and bundled hidapi 0.14.0.
- The full framing path reaches `IOHIDDeviceSetReport`; framing, report sizing, and read timeout are documented with addresses.
- Outbound `0x0003` is zero-payload; `0x000b` carries indented font-style JSON; `0x0001`, single-key `0x000d`, and mode-100 encoder `0x0011` share one ZIP/manifest builder.
- Inbound `0x010b` ignores its payload and triggers retransmission of Studio's current font style as `0x000b`. `0x0303` is NUL-terminated JSON; Studio consumes `SerialNumber`, `Dversion`, and optional `HardwareVersion`. Four-byte key/position/type/status input is `0x0101`.
- `0x000d` selects one key profile. In mode 100, `0x0011` selects current-page `Encoder` profiles; otherwise Studio uses ordinary `0x0006` refresh. Two controlled T08 transitions captured the exact one-encoder/two-empty-knob archive reproducibly. Minimal firmware-accepted fields and visible replacement/additive effects remain unresolved.

No proprietary source, extracted assets, application data, preferences, logs, account data, or telemetry were stored in the repository.

The dynamic phase is documented in `docs/ulanzi-studio-lldb-runbook.md`. Ordinary LLDB launch was denied. Authorized owner-only, ad-hoc-signed disposable copies passed strict signature verification and retained machine-code identity. A network-denied run failed application sandbox initialization and is rejected evidence. The owner explicitly accepted normal network access and its stated disclosure risk; target stdout/stderr remain discarded.

Both metadata-only connection trials repeated the same eight-event prefix: outbound `0x0003/0`, `0x0001/5633`, `0x000b/144`; inbound `0x0303/1014`; outbound `0x000a/2`, `0x0003/0`; inbound `0x0303/1014`; outbound `0x000a/2`. Both then emitted periodic outbound `0x0006`, with length 26 in T01 and 25 in T02. This remains observed application chronology rather than a causal device contract. Raw owner-only transcripts remain temporarily under `/private/tmp/ulanzi-lldb.m4xHv3/`; that disposable app copy was removed after capture.

The owner subsequently authorized complete D200X packet and content inspection, stating that the existing Studio and device data contain nothing secret. Repeat connection trials `T01P` and `T02P` captured every non-empty logical HID payload. Stable results are: empty `0x0003`; indented six-field `0x000b` font JSON; five-field `0x0303` device JSON plus NUL padding; ASCII `44` for `0x000a`; and `100|CPU|RAM|HH:mm:ss|GPU|12H|` for periodic mode-100 `0x0006`. Static analysis proves that `44` came from persisted per-device Studio brightness but does not explain the duplicate invocation. The `0x0001` ZIP's raw UUID names, ordering, timestamps, and compression varied, while its normalized manifest and PNG-content multiset were stable. Manual dump stops perturbed ordering, so the earlier auto-continue trials remain the chronology evidence. Raw payload evidence remains temporarily under `/private/tmp/ulanzi-lldb-payload.zSRQIR/`; unrelated application memory and network traffic were not inspected.

Interactive T03-T12 are complete. The verified copy remains at `/private/tmp/ulanzi-lldb-runnable.zII2q5/`, but its Studio target and LLDB process were terminated after T09-T11; raw targeted captures remain under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/`. Studio requires an action-backed tile and immediately transmits ordinary display edits. T03 and T04 prove `Font.Align` and `Font.Size` are isolated manifest deltas with unchanged PNG bytes. Repeated empty-title and `HIDHOGG-T05` `0x000d` manifests normalize identically; title T05 to T06 changes only `Text`; delete sends an explicit empty `Font`/`Text` tombstone; moving `0_0` to `1_0` emitted new content then the old-position tombstone in the observed run. T08 corrected the trigger model: selecting the `Knob` small-window radio from `Time`, not assigning an encoder action, emits `0x0011`. T12 proves the wide Background radio is mode `2`; saving a project-owned image emits one `0x000d` at `3_2` with `SmallViewMode: 2`. T09-T11 captured exact square and middle-encoder `0x0101` press, release, left, and right payloads and independently matched the direct-probe mapping. No device-side ordering necessity or exhaustive event namespace is claimed.

## Current objective

Complete `M-02-F01`, the bounded screensaver wake and keepalive diagnosis.

`M-02-F01-K01`, scheduler-coupled revision `M-02-F01-K02-R01`, and K02 are complete. The one authorized physical K1 ran and is consumed. Archive `20260831T064118Z-keepalive-prevention` is checksum-valid and internally passes with `I = 32s`, `D = 128s`, four ordered writes, healthy capture, `ACTIVE_AT_CUE`, and one canonical pair. Actual monotonic boundary timestamps were omitted; after seeing the favourable endpoint outcome, the owner explicitly waived that requirement on 2026-09-01. Architect `A08` classifies K02 as bounded pass by retrospective waiver. Do not claim exact 32-second delivery or run another K1. A 16-second cadence is an analytical production candidate only; B01 and explicit policy confirmation remain required.

Canonical accumulated protocol and idle-state findings are consolidated in `docs/research.md` under `M-02-F01 — D200X idle and protocol research`.

Small-window convenience is integrated into `d200xprobe`: `--action small-window-refresh --parameters <preset>` accepts `metrics`, `dial-time`, `background`, `date-time-weekday`, `time-weekday`, `date-time`, or `time`. Exact JSON fixtures remain supported. The temporary shell wrapper was removed; automatic and independent verification pass without HID access.

The `metrics` preset sends reported random values from `1` through `99`, and the owner physically confirmed that mode `0` displays them. Mode `2` still requires isolated confirmation; its role and any mode-0/mode-2 sequencing relationship remain unresolved.

## Completed state

- `M-02` is complete. One strict TOML file drives one configured 14-position D200X page, brightness, and bounded decoded input events through the direct Go runtime.
- Full cgo-free Go build/test/race/vet, deterministic schema generation, `go mod verify`, Taplo linting, independent tester review, and independent architecture review pass.
- The owner physically confirmed all 14 positions and brightness 80. Two interactions with `music` at `4_0` each emitted exactly one pressed/released pair; controlled shutdown removed the runtime socket.
- A deploy-directory run additionally verified owner-only directory/socket modes, matching-instance health readiness, and socket removal after shutdown.
- A controlled reproduction confirmed the screensaver defect: baseline input worked, IPC remained `ready`, two post-screensaver presses neither woke the display nor emitted events, and shutdown cleanup passed.
- The continuous-capture brightness-zero diagnostic and owner-run archival wrappers are implemented and independently verified. Earlier owner runs were invalidated before brightness zero by harness defects or the wrong baseline wire index; no trusted passing archive exists.
- A spike-only `d200xprobe` now exposes each of the 12 known command IDs by exact symbolic action for one-frame physical research; production unsafe-command refusal is unchanged.
- Manual physical probes established that brightness zero preserves input while the native screensaver is inactive; encoder rotation restores brightness to 100; `enable-input-stream`, one unspecified `small-window-refresh` fixture, and `unlock-screen` each dismissed the screensaver and restored input; mode `0` displayed generated synthetic metrics. These observations do not replace the archived diagnostic matrix.
- `S-01`, `S-02`, `D-01`, and `M-01` are complete.
- The owner selected a Go core, SwiftUI client, and TOML configuration on 2026-08-24.
- `M-01` implements Go runtime/CLI shells, strict bounded health/status IPC, shared v1 fixtures, a SwiftUI `MenuBarExtra`, deterministic process supervision, endpoint security, and live Go/Swift integration.
- `M-01-F01` is complete: every Xcode-built app contains `Contents/MacOS/hidhogg-runtime`, starts it eagerly outside the dedicated hosted-test configuration, and awaits cleanup on normal application termination.
- `M-01-F02` is complete: GUI-launched Xcode discovers Go from standard installation locations without interactive shell initialization, and the Swift build has no unused cleanup-result warnings.
- The normative internal protocol is `api/protocol/v1/README.md`; consequential decisions awaiting owner review are in `docs/m01-decision-review.md`.
- Installed verification toolchains were Go 1.26.4, Swift 6.3.3, and Xcode 26.6. Go 1.27 was unavailable and not run.
- Final verification passed cgo-free Go build/test/race/vet, `git diff --check`, and 15/15 Xcode tests. An independent live probe confirmed a mode-mutated socket is preserved during shutdown.
- The post-milestone bundling correction passes 17/17 Xcode tests. Independent Debug direct-launch probes reached ready and cleaned their exact runtime/socket/generation on quit; the Test configuration created no orphan or generation.

## Residual risks

- `M-01` trusts same-effective-UID processes; pathname replacement between final identity validation and unlink is not atomic and remains accepted.
- Repeated physical reconnect reliability is an owner-accepted implementation assumption supported by only one measured reconnect/session-replacement cycle.
- Swift monitors endpoint identity after readiness, but no dedicated post-ready substitution test exists.
- Packaging, signing, App Sandbox isolation, login items, `launchd`, product behavior, physical HID integration, and a public TOML schema remain deferred.
- Distribution signing/notarization of the embedded Go runtime is unverified; Test-configuration app products intentionally suppress automatic runtime startup.
- The Swift supervisor does not yet pass the now-required `--config-path`; the bundled app is intentionally incompatible until the deferred Swift follow-up.
- Repeated reconnect reliability, configuration watching/last-known-good reload, actions, notifications, and rich assets remain unimplemented.
- Idle/screensaver-duration input reliability is not established; the latest live session stopped receiving events after the firmware screen state appeared.
- Explicit brightness zero is not stable across encoder rotation: the owner observed any encoder turn restore device brightness to 100, while display tiles and physical buttons did not. Spike-CLI brightness packets also did not dismiss the firmware screensaver; their effect on suppressed input remains unmeasured.
- Studio's Background radio is definitively numeric mode `2`, and its saved artwork uses `0x000d` at `3_2`. The legacy `0x0006` payload `2|` was not emitted during the controlled radio transition, so that payload's independent firmware role and any relation to mode `0` remain unresolved.
- The worktree is intentionally uncommitted. Relevant new source includes `cmd/hidhoggdiag`, `internal/diagnostic`, `scripts/diagnostics`, and `spikes/go-hid-d200x/cmd/d200xprobe`. Preserve unrelated untracked `.envrc`, `.codex`, and Xcode workspace metadata without reading or modifying them.
- `spikes/go-hid-d200x/d200xprobe` is an untracked compiled Mach-O artifact that may predate the latest source. Do not treat it as verification evidence or delete it without owner direction.

## Historical next actions — superseded

1. Do not run another K1. Preserve the bounded-pass archive and do not reclassify it as exact 32-second delivery. Complete the retained B01 brightness-zero matrix, then obtain explicit owner confirmation before implementing or configuring the analytical 16-second keepalive candidate.
2. Isolate mode `2`: from a recorded non-metrics view, send only `--action small-window-refresh --parameters background`; record the before/after view and whether input remains available.
3. Decide explicitly whether M-02-F01 still requires the archived `brightness-zero.sh` matrix. If retained, obtain one trusted passing archive before using its wake wrappers; manual probe results are supporting evidence, not a substitute under the current acceptance text.
4. Resolve the keepalive/application-owned idle policy from measured evidence, including interval and whether `enable-input-stream`, `small-window-refresh`, or `unlock-screen` is individually sufficient over the target idle duration.
5. Review the diagnostic 48-record cap against the 20 required decoded events plus possible non-input frames before another archived run.
6. Complete M-02-F01 only after its evidence gate and idle policy are explicit; then resume pending M-03. Keep configuration watching/editing and reconnect hardening separate.

## 2026-08-31 — K01 bounded keepalive diagnostic completed

- Architect consensus made `keepalive-prevention` a closed K1 experiment: `D = 4I`, `D <= 60m`, and exactly four experimental boundaries. The core and wrapper enforce the contract before HID activity; the wrapper rejects invalid schedules before archive creation or confirmation. There is no override.
- One normal startup/session is retained. Only `enable-input-stream` is sent during the experimental schedule. Cancellation, early inbound activity, a wake at or after the next boundary, and failed or uncertain writes invalidate or stop the run without retry or catch-up.
- A pass requires one final canonical wire-0 square press/release pair and exactly 11 ordered redacted JSONL records. jq, Python, and Ruby validators enforce the same archive shape.
- The full uncached cgo-free Go suite passed outside the managed socket sandbox; focused race tests, vet, zsh syntax, archive regressions, formatting, and diff checks passed. Independent tester `M-02-F01-K01-V02` passed with no high or medium defect. No physical HID evidence is claimed by K01.
- The scheduler accepts actual wake times before the next interval boundary. K02 must retain actual timing. The 48-boundary resource guard is unreachable for valid K1 and remains defense-in-depth.

## 2026-09-01 — Prospective K1-50 ready for one physical run

- K03 fixes the prospective schedule at `I = 50s`, `D = 200s`, with exactly four `enable-input-stream` writes. Each successful boundary records planned, wake, write-start, and write-completion monotonic elapsed nanoseconds under `timing_contract = k1-50-v1` and requires `planned <= wake <= start <= completion <= planned + 250ms`.
- Implementation `R01`, validator correction `R02`, independent tester `V02`, and final architect `A02` pass. jq, Python, and Ruby reject early, late, reordered, missing, partial, unknown, floating-point, exponent, and string timing representations; pre-cue elapsed timestamps must be nondecreasing. Legacy archives retain their historical schema.
- No hardware was accessed during these gates. The full Go suite's only reported failure is the managed sandbox's denial of unrelated `internal/ipc` Unix-socket creation.
- Next action: with the owner present, prepare exactly one K1-50 invocation. Require the same-process endpoint-cue preflight and exact `CUE_HEARD` before HID confirmation. Once scheduling begins, retain and classify every outcome; do not retry or launch a replacement without a new reviewed decision.
- A pass can establish only that this owned specimen remained active and accepted the canonical endpoint input during this one 200-second run with four contract-conforming writes. It cannot establish a maximal safe interval, production cadence, long-term reliability, causal necessity, or cross-device/firmware behavior.

## 2026-09-01 — K1-50 authorization consumed with indeterminate endpoint

- Archive: `deploy/diagnostics/20260901T063506Z-keepalive-prevention`. Four `k1-50-v1` boundaries passed with completion lateness between 1.326333 ms and 1.988541 ms; capture remained healthy and boundary four completed before the endpoint cue.
- The later visual-attestation prompt received `CUE_HEARD`, which is outside its closed token set. No canonical input pair was retained. Final verification and result are correctly `indeterminate`.
- Treat the run only as prospective scheduler-conformance evidence. It neither proves nor disproves 50-second screensaver prevention. The single K03 physical authorization is consumed and must not be retried without a new reviewed protocol decision.

## 2026-09-01 — Authoritative owner-run K1-50 result

- Source of truth: `deploy/diagnostics/20260901T065715Z-keepalive-prevention`. The owner explicitly accepts this independently operated archive as sufficient to close K03.
- Strict validation and metadata checksums pass. Four 50-second boundaries satisfy `k1-50-v1`; capture remains healthy; boundary four precedes the cue; `ACTIVE_AT_CUE` and exactly one in-window canonical wire-0 square press/release pair are retained; endpoint and result are `pass`.
- Earlier archives remain historical evidence of agent-mediated prompt timing failures and are not the controlling K03 outcome.
- Next milestone gate remains B01, followed by explicit P01 production-policy selection. K03 alone does not complete either gate.

## 2026-09-01 — T13 screensaver-artwork capture queued

- Studio's `Screensaver` preference is an artwork editor, not a timeout control. It targets `1220 × 708`; `Stored Image` opens the file picker and `Set Image` commits. Prepare non-launching utilities for synthetic SS-U0 click/cancel, SS-U1 image A, SS-U2 image B, and SS-U3 revert A under architect `T13-A02`.
- Encoder rotation restores brightness from zero to firmware value 100 under both Hidhogg and Studio. Do not rerun the existing B01 script as authoritative evidence; revise it to model that state transition before another physical matrix.

## 2026-09-02 — T13 preparation independently ready

- Non-launching screensaver capture utilities under `scripts/diagnostics/ulanzi-lldb/` passed independent `T13-V03`: 59 fresh-workspace checks and all 12 regression cases. The earlier V02 timestamp, authorization, payload reconciliation, and zero-read defects are closed.
- The utilities generate deterministic metadata-free `1220 × 708` fixtures, enforce owner-only marked SS-U0–SS-U3 workspaces and closed markers, separate auto-continue chronology from explicitly authorized stopped payload capture, and contain no Studio launch/attach, HID, or network action.
- Next action is to prepare the private workspace, then obtain explicit dynamic authorization before launching the disposable Studio copy under LLDB for SS-U0 through SS-U3.

## 2026-09-02 — T13 dynamic capture completed with qualified scope

- Temporary evidence remains at `/private/tmp/ulanzi-screensaver.u_g5my35`; the disposable app path is `/private/tmp/ulanzi-lldb-runnable.zII2q5/Ulanzi Studio.app`. No disposable Studio process remains running.
- SS-U0: open/cancel, only periodic `0x0006`, owner outcome unchanged.
- SS-U1: controlled A commit, authorized `0x0009` payload of 40,982 bytes, owner confirmed A visible.
- SS-U2: controlled B commit from A, authorized `0x0009` payload of 130,798 bytes, owner confirmed B visible. Chronology reached its 256-event cap before commit, so do not cite SS-U2 as complete chronology.
- SS-U3 was cancelled after the picker opened and is excluded. The owner explicitly waived restoration testing. Remaining gaps are the `0x0009` payload structure and deterministic A/B/A equality, not the command identity or visible upload effect.
- Next work: analyze only the controlled A/B `0x0009` payloads, consult the architect on the minimum independent implementation boundary, then redesign B01 encoder handling around the verified firmware brightness-to-100 behavior.

## 2026-09-03 — T14 complete; B01 ready for one physical run

- T14 offline analysis is complete as qualified research. Both authorized `0x0009` artifacts reconcile and are one-entry method-8 ZIP payloads containing Studio-reencoded `1220 × 708` RGB PNGs. Production support is deferred behind P01 plus separate encoder/parser and physical-acceptance gates.
- B01 R01-R05 automatic work passed independent verification and final architect review. The matrix proves wide/button/square input while zero persists, then treats one encoder rotation as a separately attested state-ending transition. Only exact `BRIGHTNESS_100_OBSERVED` may pass.
- Runtime and archive validation include every decoded or malformed record captured through shutdown; trailing or non-pass input cannot coexist with a passing result. Configured brightness restoration remains exactly once with no retry. jq, Python, and Ruby agree on the strict archive contract.
- Next action: run exactly one owner-present `scripts/diagnostics/brightness-zero.sh` invocation with no retry. Follow its exact order and token prompt. Then independently validate the checksum archive before any P01 policy selection.

## 2026-09-03 — B01 physical authorization consumed by class-failure

- The authorized archive is `deploy/diagnostics/20260902T235304Z-brightness-zero`. All three hashes match its manifest; result is `fail`, exit 1, and the strict validator rejects it as a passing archive.
- Passing components: baseline square pair, brightness-zero write, wide-13 pair, button-15/16 pairs, encoder-17-left transition with structured `BRIGHTNESS_100_OBSERVED`, configured-brightness restore, and recovery square pair.
- Missing component: the required zero-state square-0 pair before encoder rotation. The matrix is correctly `class-failure`; this is not currently attributable to a harness defect.
- Do not rerun. B01 remains incomplete and P01 remains blocked until the owner and architect explicitly decide whether a replacement is justified or the partial physical evidence is sufficient for a narrower policy claim.

## 2026-09-03 — B01 replacement accepted retrospectively

- The owner independently produced `deploy/diagnostics/20260903T032301Z-brightness-zero` outside the consumed no-retry authorization. It passes all hash and strict archive checks and contains every required event, positive structured brightness attestation, one restore, recovery, and no contrary/trailing input.
- On 2026-09-03 the owner explicitly designated that replacement authoritative and sufficient for the bounded one-device B01 decision after architect review. Record this as a procedural authorization deviation with retry-selection risk, not as invalidation of the first class-failure.
- B01 is complete. Preserve both archives and do not run a third B01 trial. Next action is M-02-F01-P01: present the evidence-supported idle-policy choices and obtain an explicit owner decision before production source changes.

## 2026-09-03 — P01 automatic implementation ready for physical acceptance

- Owner-confirmed contract: optional `idle_timeout_seconds` defaults to 300, accepts 0 through 86,400; zero disables application dimming only. Fixed absolute `0x0002` keepalive remains 50 seconds. Idle writes brightness zero once; the first known physical gesture restores configured brightness and is consumed completely. Failures fail-stop without retry.
- Implementation is in `internal/config` plus generated schema and `internal/runtime/idle.go` integration. Independent R02 verification and final architect review pass all automatic gates. No HID was accessed.
- The owner-present physical gate passed on 2026-09-03. With temporary `idle_timeout_seconds = 5`, the owner confirmed blanking and remaining blank through the first scheduled 50-second `0x0002`; the first square pair restored brightness with no input JSON; after re-idle, a consumed wake pair followed by a second quick pair emitted exactly one ordered pressed/released JSON pair. Clean SIGINT shutdown removed the socket.
- Independent milestone-close verification V03 passed full tests, race, vet, build, schema determinism, formatting, diff checks, and the physical-gate mapping. M-02-F01-P01 and parent M-02-F01 are complete. Human timing is not scheduler-precision evidence; fake-clock tests remain authoritative. Two low-severity fixed-wait synchronization weaknesses appeared only under 1,000-repeat race stress and may be hardened later; no production defect was observed.

## 2026-08-31 — First C0 observation incomplete at ceiling

- One `enable-input-stream` frame established the intended fresh active reset at `2026-08-30T15:41:46Z` (`2026-08-31 01:41:46 AEST`), then a passive `d200xprobe --listen` session reported that it would send zero frames.
- The listener remained frame-free through the predeclared 30-minute ceiling and was stopped by signal just after the ceiling. No post-reset outbound frame was sent by the listener.
- The owner did not provide a contemporaneous visual active-state or screensaver-onset report during the bounded window. Protocol silence cannot identify the display state, so this attempt does not establish `T0`, does not pass or fail C0, and cannot parameterize K1.
- On resumption, first ask the owner for the current visual state without touching the device. A visible screen state after the fact can bound but cannot timestamp onset; exact K1 derivation requires a repeated owner-observed C0 unless the reviewed experiment is revised.

## 2026-08-31 — Repeated owner-observed C0 passed

- One setup-only `enable-input-stream` reset completed at `2026-08-30T23:04:34Z` (`2026-08-31 09:04:34 AEST`), and the owner immediately confirmed the configured display was visible. A passive zero-write listener then remained open.
- The owner reported native screensaver onset at `2026-08-30T23:05:38Z`, 64 seconds after reset. This includes human observation/reporting latency and is a conservative observed interval, not a firmware-precise transition timestamp.
- One requested `0_0` press/release left the screensaver visible and produced no listener output. The listener was stopped by signal after the check.
- C0 passes for this specimen with observed `T0 = 64s`. The approved K1 parameters are `I = 32s` and `D = 128s`; K1 has not yet started.

## 2026-08-31 — First K1 invocation failed final verification after delayed check

- The owner typed the exact wrapper confirmation. The invocation used `I = 32s`, `D = 128s`; archive `deploy/diagnostics/20260830T230813Z-keepalive-prevention` records normal startup, four passing input-enable boundaries, and passing schedule completion.
- The immediate at-`D` visual/input check was not completed. The owner reported the screensaver at `2026-08-30T23:12:27Z`, approximately one C0 interval after the nominal last boundary. One subsequent `0_0` press/release did not wake it and produced no captured input.
- The wrapper correctly exited 1 with `class-failure`. The nine-record stdout SHA-256 is `b8aabda2d5f8c477015f8aa3b8887ee6dd0ff7c7aa694aafe37ddb2c3c284922`; metadata and stderr hashes match their manifest. The run is not a prevention pass and does not establish state at `D`.
- Architect `M-02-F01-K02-A01` is reviewing whether a clearly labeled second K1 invocation is valid. Do not silently retry or overwrite the failed archive.

## 2026-08-31 — Architect authorized one replacement K1 endpoint measurement

- Architect review classifies the first K1 as scheduler-valid but endpoint-inconclusive. It permits exactly one clearly labeled replacement with unchanged `I = 32s`, `D = 128s`; retain the first archive and do not describe it as a negative replicate.
- The owner must continuously observe without interacting. At a local non-chat cue at `D`, classify the display within five seconds. If active, press/release `0_0` once within the next five seconds; if the screensaver is visible, do not press. Then report `active-pressed`, `screensaver`, or `uncertain`.
- Any early screensaver, distraction, unrelated interaction, uncertain state, missed window, late/failed write, or missing captured pair makes the replacement inconclusive. No third K1 is authorized without a revised protocol decision.

## 2026-08-31 — Replacement K1 endpoint remained inconclusive

- A setup-only reset established a fresh owner-confirmed active display at `2026-08-30T23:22:23Z`. The replacement archive is `deploy/diagnostics/20260830T232327Z-keepalive-prevention` with unchanged `I = 32s`, `D = 128s`.
- The archive records four passing boundaries and passing schedule completion. At the spoken cue the owner reported no screensaver, then reported screensaver onset before there was enough time to press `0_0`; no pair was captured.
- The cue was mediated through the agent after the diagnostic prompt and cannot be proven to have occurred within the predeclared five-second endpoint window. The wrapper correctly records `class-failure`, exit 1. Metadata, stdout, and stderr hashes match the manifest; stdout SHA-256 is again `b8aabda2d5f8c477015f8aa3b8887ee6dd0ff7c7aa694aafe37ddb2c3c284922`.
- The replacement is endpoint-inconclusive, not a pass or prevention failure. K02 is blocked; do not run a third K1 without an explicit revised protocol and a cue coupled directly to the diagnostic endpoint.
