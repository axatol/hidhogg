# Hidhogg handoff

Updated: 2026-10-02

## Active objective and approvals

Review v1, move tracking into TaskView, create v2, replace production Go with a Swift macOS app owning runtime/device plus Swift CLI, and complete button appearance/actions/notification-source editing. Use subagents for implementation/verification and commit each accepted task. Persistent goal remains active; no push/tag/PR is authorized.

Owner approvals on 2026-10-02: commit existing source as v1; Swift app owns runtime plus CLI; native macOS app with simulated D200X satisfies the simulator gate; complete diagnostic field paths/UTF-8 byte origins; improvements need no backwards compatibility. Use conventional straight-alpha RGBA and native CoreText, retaining requested features and strict TOML v4.

Offline boundaries: no selected config, owner app, real HID enumeration/open, native input posts, permission prompts or configured owner actions. Synthetic fixtures/fake adapters and later isolated native-app simulation are authorized. Never inspect environment values, prohibited secret paths, PII or license/author text. Opaque licenses are copied/hashed only. Confirm exact depth of actual synthetic child-process and socket/CLI integration before executing those gates; unit fakes and compile-only adapters are authorized.

## Checklist and Git checkpoints

- [x] Architecture review, fresh v1 baseline and TaskView migration.
- [x] v1 master a1a64ed9d2e910951f38cf7189c2b499fb14fa10, 110 curated paths.
- [x] v2 setup 2eec28b273e8c9236d95485560b13cc687248a6a.
- [x] C01 strict configuration bba1dc616cfaa2734a4659e33788d7f9a5c1b606.
- [x] C02 lossless edits/store 57f93a14451a3cb18b73e0dcb8d0654323649f51.
- [x] D01 codec/archive/renderer fb038c882d18ff67f64efce911bc5d50896dc473.
- [x] D02 native/simulated transport 478e2a79406fcf27f384074f247db85e12ca61a1, current HEAD.
- [ ] R01 profiles/reload/idle/host state: independent 125/125 gate passed; documentation and exact commit pending.
- [ ] R02 actions/input/notifications: disjoint action/input service implementation started.
- [ ] I01 Swift IPC/CLI; U01 app ownership; U02 complete button editor.
- [ ] V01 independent requirements/native-app simulation; X01 production Go removal/final audit.

D02 commit title: feat: add native and simulated Swift D200X sessions. Parent fb038c8, branch v2, exactly 16 intended paths verified against /Volumes/Data/tmp/hidhogg-v2-d02-commit-manifest.paths; live/staged source hashes matched accepted proof. Tracked tree was clean immediately after commit. R01 untracked work was excluded; these main progress ledgers are updated afterward.

Protected unrelated untracked paths: .codex/, .envrc, Xcode project workspace metadata, diagnostics Python cache and spike binary. Never stage broadly.

## TaskView

Personal organization 2, HIDhogg project 5; list 48 legacy/list 49 v2. Listing omits directly proven records: get_task by known ID is authoritative. Use HTML notes and exact readback, verifying goalId/goalListId/parentId/complete; privately parse responses to avoid owner fields.

| Stable task | Task ID | Verified state |
| --- | --- | --- |
| P01 / C01 / C02 | 121 / 122 / 123 | Complete |
| D01 / D02 | 124 / 125 | Complete |
| R01 / R02 | 126 / 128 | In progress |
| I01 | 130 | Pending; HTML static preparation recorded |
| U01 / U02 | 132 / 134 | Pending |
| V01 / X01 | 136 / 138 | Pending |

Archive 120 is complete for import only: exact sanitized 103-code manifest, 86,059 UTF-8 bytes. Fifteen known legacy records retain hierarchy/completion; 30 acyclic v2 edges plus four legacy edges were verified. docs/roadmap.md is a locator. docs/v1-roadmap.md is byte-identical to v1: SHA-256 034e4200aed491671193bc927c40f221d51d86e8fc1939eb6b7ae88369eef129, 123,842 bytes.

Task125 complete and Task128 in-progress HTML were read back exactly after D02 commit. Status-only D02 Discord notification exited 0 with output suppressed. No push/tag/PR.

## Verified Core and evidence

HidhoggCore is standalone SwiftPM, tools 6.0, deployment macOS 26. Production app/runtime/CLI still use Go; app wiring is pending.

C01 uses one strict source-backed TOML 1.1 engine, explicit-field validation, exact-byte normalized identity and deterministic 14-position layout. Safe complete diagnostic paths use UTF-8 origins for syntax/type/unknown keys; semantic/missing/schema locations are 0:0. Vendor swift-toml-edit v3.0.0 commit 603c402868e1fb5c4348d130f16e73b401f531f8. Independent C01 passed 30/30.

C02 typed keep/set/reset position patches and profile label/clone/delete preserve untouched valid source/trivia. Store separates unchanged/committed/uncertain file outcomes from reload, using exact digest, same-directory replacement, file/parent sync and exact committed bytes. Post-rename uncertainty does not roll back. Hash-to-rename is not atomic external-editor compare-and-swap; basic mode bits, not ACL/xattrs, are preserved. Runtime admission spans apply/reload.
Independent C01+C02 passed 59/59; refreshed TOML 1.1 corpus 681/681 (214 valid, 467 invalid, no failures/skips), pinned toml-test v2.2.0 commit ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c. Temporary runner removes only explicit NO_COLOR lookup/defaults colour off. Evidence /Volumes/Data/tmp/hidhogg-v2-c02-verification, eleven hashes matched.

D01 framing: 1024-byte packets, synthetic 1025-byte ID-zero reports, big-endian command/little-endian length, 1016 initial/1024 continuation bytes, 16 MiB cap. Startup unlock → page → brightness → input enable; keepalive is input enable only. Renderer: thirteen 196×196 tiles plus 458×196 wide tile, bundled Go Regular/CoreText, deterministic content-addressed PNG/classic ZIP and firmware-safe padding. Render 16-bit premultiplied working pixels then convert to 8-bit straight RGBA.
First independent gate found low-alpha loss/inverted text, corrected before acceptance. Final full suite 76/76, export-adapter suite 77/77; external zipfile/Pillow checks 18 archives/56 members, CRC/manifests/dedup/determinism, eight exact PNG8 RGBA cases, zero-alpha RGB, fitting/contrast and 14,598 upload bytes reconstructed from 15 reports. Upright L bounds center (216,76)-(244,121), bottom (216,131)-(244,176). Root read/hash checked and viewed images. CoreText fallback identity and Go compression-byte identity are unasserted. Evidence /Volumes/Data/tmp/hidhogg-v2-d01-verification; final source manifest SHA-256 336f54a970206525d1d69c5b73b1ff7b2a49ba34645d0c869f64ce9cad4f3127.

D02 selects simulation before constructing native discovery. Native validation: VID2207/PID0019, actual well-typed usage pair000c/1, USB interface0, output1024; refuse zero/multiple candidates before per-device open, no manager-wide open. Strip synthetic zero; native SetReport ID0/body1024. Complete batches serialize; input is copied independently, native callbacks use dedicated CFRunLoop. Synchronous stop is nonblocking/idempotent; waitUntilStopped returns closed/cleanupUncertain after drain. Existing OS writes cannot be preempted.
Verified corrections: writer publishes terminal failure before continuation release; stop rejects work/late input and clears retained handlers; paused revalidation/open cannot publish opened after stop; timed-out callback startup cancels/drains; joining stops receive truthful cleanup uncertainty. Simulator exposes bounded archive/brightness/unlock/input-enable plus write/removal faults. Native metadata rejects booleans/strings/negative/integral floats; target usage pairs are authoritative, scalar keys are matching criteria.
Final independent full suite passed 96/96, zero failures/skips (session12/native5/simulator3), D01 plus exactly eleven paths, all live/snapshot hashes before/after matched. Root read report/counts and rematched live/staged hashes. No native IOHID/hardware invocation; hardware and required app simulation remain unverified.
Evidence /Volumes/Data/tmp/hidhogg-v2-d02-verification/edge-closure-independent-report.txt SHA-256 85c6a4b63d9f4971b3a496317b2278a904504c5ad9f8550fb3df8168846536b1; edge-closure-independent-swift-test-escalated.log SHA-256 9f8e27a6e9f76647abd62f6535beb696e5ec2afceb68999bfecf33041f5eaa53; /Volumes/Data/tmp/hidhogg-v2-d02-owner-hashes-edge-closure.txt SHA-256 804bfba83c508d733582b801215abce8bb040292bc48ee934f15c35c9cee09a3.

Fresh v1 baseline /Volumes/Data/tmp/hidhogg-v2-baseline: Go unit/race each1,446 nodes/15 packages, vet/build,118 spike nodes, offline Xcode129/129 excluding live integration and suppressing startup. This proves v1, not v2 app simulation.

## Current implementation boundaries

swift_v2_executor owns seven R01 files: RuntimeCoordinator/RuntimeModels/RuntimeClock/RuntimeTransitionFence and their three tests. No D02/C02/Package/docs/app/CLI/Go edits. Explicit admission spans awaits, publication follows successful writes, invalid reload retains last-good, uncertain writes fail-stop. Receipt fence stamps before enqueue; stale/active receipts reconcile held state without dispatch. Store apply plus uncancelled postcommit reload; late cancellation cannot undo page success. Absolute50s heartbeat continues host-off and advances from post-write clock; marker-keyed button/encoder gestures, activity rotations, bounded64 receipt overflow fail-stop and truthful terminal cleanup.
Final independent R01 closure passed125/125, zero failures, on fresh committed D02 plus exactly seven owner paths. All live/snapshot hashes matched before and after; main directly read the report/log and rematched all seven live files. Manifest SHA-256 f3ac844ae07b1972c67c6894b86152b91fbb89e2f6e0d24e367ecd78013d9a57; evidence /Volumes/Data/tmp/hidhogg-v2-r01-closure-20261002/R01-CLOSURE-REPORT.txt and R01-full-suite-escalated.log, log SHA-256 16c0a458363fb5720d88202c9a248df4e0a5bc93ff60bbdb771fab67bc430666. Redraw now compares prepared page archive bytes, while metadata-only edits publish catalog/revision without consuming an armed write fault. Visible edits prove write cancellation and committed-file/runtime-failure separation; post-failure input causes no action/write/additional stop. The10,000-event storm, admission order, host-off/post-write heartbeat and wake/deadline cases pass. Already-dimmed wake and matching release are consumed; ready pre-dim equality may dispatch. Synthetic rendering and injected CFRunLoop tests are included; live HID/input/owner app are excluded. Core R01 is accepted; exact twelve-path commit and Task126 closure remain pending.

swift_configuration_edges owns new R02 action/execution/native-input production/test files only. Task128 is in progress for disjoint services while R01 owns its existing paths. One exec/busy refusal, validated absolute path/args/cwd/minimal PATH/timeout, process-group terminate/reap/uncertain cleanup; history32, output tails4096 each only exact get. Native text64 UTF16 units, one active+16 FIFO, preflight no prompt/explicit request only, matching up after down, metadata-only history. Preserve ordered admission; no unbounded detached fanout or generic framework. Compile native/process adapters; offline unit gates invoke only fakes. Notifications/coordinator integration follows accepted R01 and explicit ownership transfer. Final R02 closure depends on R01/D02.
R02 compile-only API evidence /Volumes/Data/tmp/hidhogg-v2-r02-api-prep/brief.md SHA-256 c261015f2bbb649bc8d3e03f81da70077f323fa0c75ac28bfed4e5c1af7148a8. macOS27 SDK/deployment26 typechecks posix_spawn/actions/attrs, standard addchdir (at26; _np deprecated), separate process group, CoreGraphics preflight/request/down-up/UTF16. Owner reports20/20 focused fake-service tests and116/116 full isolated D02+two R01 interface copies+nine R02 files. These are preliminary owner results awaiting exact source freeze and independent verification. Bounded process review found continuous output could starve supervision: the adapter now yields after65,536 bytes or64 syscall attempts per stream, and EINTR returns to supervision; no-child fake drain tests pass. Actual POSIX spawning, CoreGraphics permission/post methods and owner actions have not run. Actual synthetic process integration requires concrete boundary/depth approval; owner is preparing the reviewable harness without execution.

verification_baseline is read-only tester, completed D02 and final R01 gates plus bounded process-supervision review. Frozen R02 service verification follows its owner manifest; do not repeat parser corpus/image export/probes without new affected changes.

I01 read-only client brief /Volumes/Data/tmp/hidhogg-v2-i01-client-prep/brief.md SHA-256 b0e75bf2209dd04d62db8cb6306a87958fb6840a0ed93db058a11bc06fde1dbc, read by root. Reuse Swift strict codec/client; framing JSON+LF16384 inclusive/firstLF, recursive duplicate/exact integers/safe bounds. Actual Go method list is broader than README. Go runtime.lock/runtime.sock/runtime.json discovery and identity revalidation differ from Swift's explicit child socket; port actual readiness/cleanup. Position-patch brief /Volumes/Data/tmp/hidhogg-v2-i01-editor-wire-prep/brief.md SHA-256 ab7e5ec061c9807ceb0243367ee33c379a96292bf477326a5f39614eefd260ae was read by root. Chosen config.editor.position.patch uses exact instance_id/expected_digest/profile_id/position_id/patch params: omitted keep; field object exactly op reset or op set/value with typed closed fields/action. Empty patch is no-op; reuse existing mutation result without target echoes. Add focused Swift fixtures, preserve frozen legacy Go fixture manifest. Task130 records exact HTML decision. No I01 source/build/process/socket/native API ran.

U01 simulation must select explicit synthetic composition before default app model/preferences/native adapters. Current HidhoggApp.swift delegate constructs the default model before HIDHOGG_TEST_HOST suppresses start; bootstrap later reads environment/home and starts Go. Inject fake HID/actions/input/preferences/observers, synthetic config/runtime paths, direct isolated app executable and service readiness/graceful quit. App arguments/control are not yet implemented. Existing Supervisor cleanup-uncertain terminal guard was directly reviewed. No owner values were read.

## Next actions and operational notes

1. Complete R01 three-doc checkpoint and exact twelve-path commit against accepted final125 proof; close Task126. Then delegate I01 independent wire/discovery/CLI work with R02 coordinator paths protected.
2. Finish R02 service tests, then explicitly transfer coordinator integration for notification overlays/shared gate/writer. Exact-case sources, TTL after commit/equality expired, revalidate selections and commit dismissal before static admission. Rejected/unchanged reload preserves overlays; changed config/profile clears them. Complete independent R02 gate/commit.
3. I01 IPC/discovery/Swift CLI, U01 app ownership, U02 full existing button editor. Custom assets/Go log tail/split source files are deferred.
4. V01 comprehensive requirements/native macOS simulated-D200X run is mandatory. X01 removes production Go only after acceptance, then audit. Goal stays active until all required work passes.
5. Root alone owns .agents, TaskView, integration/curated commits and notifications. Source workers update other docs only from accepted facts.
6. Explorer/scribe reactivation fails with agent-thread limit. Available workers do bounded read-only audits/docs instead; no main source takeover. Preserve others' edits.
7. Normal SwiftPM may fail manifest sandbox before tests; narrow elevated snapshot/scratch retries pass. Git index similarly needs exact-manifest scoped elevation. Suppress Git identity/notification output; inspect commit hash/parent/title/path lists only. Use apply_patch for ledgers (shell heredoc temp was denied).
8. No actual live HID/native posting/permission/process/socket integration is authorized by compile-only/unit proof. The approved native app simulation remains a distinct final gate.

Historical decisions, superseded checkpoints and detailed proofs remain in .agents/log.md, TaskView and Git.
