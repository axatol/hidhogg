# Hidhogg handoff

Updated: 2026-10-02

## Active objective

Review v1, move tracking into TaskView, create v2, replace production Go with a Swift macOS app owning runtime/device plus a Swift CLI, and complete button appearance/actions/notification-source editing. Use subagents for implementation and verification; commit each independently accepted task. The persistent goal remains active.

Owner approvals on 2026-10-02: commit existing source as v1; Swift app owns runtime plus Swift CLI; native macOS app with simulated D200X satisfies the simulator gate; report complete diagnostic field paths/UTF-8 byte origins; improvements need no backwards compatibility. Use conventional straight-alpha colours and native CoreText, retaining requested features and strict TOML v4.

Offline boundaries: no selected configuration, owner app, real HID enumeration/open, native input posting or configured owner actions. Synthetic fixtures, fake adapters and later isolated native app simulation are authorized. Never inspect environment values, prohibited secret paths, PII or license/author text. Opaque licenses are copied/hashed only.

## Progress and checkpoints

- [x] Architecture review, fresh v1 baseline and TaskView migration.
- [x] v1 master checkpoint a1a64ed9d2e910951f38cf7189c2b499fb14fa10, 110 curated paths.
- [x] Local v2 setup 2eec28b273e8c9236d95485560b13cc687248a6a.
- [x] C01 strict configuration bba1dc616cfaa2734a4659e33788d7f9a5c1b606.
- [x] C02 lossless edits/store 57f93a14451a3cb18b73e0dcb8d0654323649f51.
- [x] D01 corrected codec/archive/renderer fb038c882d18ff67f64efce911bc5d50896dc473, current HEAD.
- [ ] D02 native/simulated transport and session: core source independently accepted 96/96; exact commit/TaskView closure next.
- [ ] R01 profiles/reload/idle/host state; R02 actions/input/notifications.
- [ ] I01 Swift IPC/CLI; U01 app ownership; U02 complete button editor.
- [ ] V01 full independent requirements and native app simulation.
- [ ] X01 remove production Go and final audit after V01.

No push/tag/PR. Protected unrelated untracked paths: .codex/, .envrc, Xcode workspace metadata, diagnostics Python cache and spike binary.

## TaskView

Personal organization 2, HIDhogg project 5; list 48 legacy, list 49 v2. Listing omits directly proven records: use get_task by known ID, HTML notes and exact readback. Never infer IDs or URLs.

| Stable task | ID | Verified state |
| --- | --- | --- |
| P01 / C01 / C02 | 121 / 122 / 123 | Complete |
| D01 | 124 | Complete |
| D02 | 125 | Core source accepted 96/96; commit and closure next |
| R01 | 126 | In progress; compiled D02 interface permits coordinator source |
| R02 | 128 | Pending |
| I01 | 130 | Pending |
| U01 / U02 | 132 / 134 | Pending |
| V01 / X01 | 136 / 138 | Pending |

Archive 120 is complete for import only: exact sanitized 103-code manifest, 86,059 UTF-8 bytes. Fifteen known legacy records retain hierarchy/completion. Verified graph: 30 acyclic v2 edges, four legacy edges. docs/roadmap.md is a locator. docs/v1-roadmap.md is byte-identical to v1, SHA-256 034e4200aed491671193bc927c40f221d51d86e8fc1939eb6b7ae88369eef129.

## Verified core

Standalone dependency-free SwiftPM package macos/HidhoggCore, tools 6.0, deployment macOS 26. Production app/runtime/CLI still use v1 Go; package integration is pending.

C01 extends one strict source-backed TOML engine for 1.1. Do not use the lossy parser route. Explicit-field validation, exact-byte key/model identity, complete safe diagnostic paths and deterministic 14-position layout are preserved. Syntax/type/unknown-key locations use UTF-8 byte columns; semantic/missing/schema use 0:0. Vendor swift-toml-edit v3.0.0 commit 603c402868e1fb5c4348d130f16e73b401f531f8. Independent C01 suite passed 30/30.

C02 provides typed keep/set/reset patches and profile label/clone/delete, strictly validates original/candidate source, and preserves untouched valid fields/trivia. Store outcomes are unchanged/committed/uncertain with exact bytes/digest; same-directory replacement separates file outcome from runtime reload. Post-rename sync failure is uncertain without rollback. Final hash-to-rename race is not atomic external-editor compare-and-swap; preserve basic mode bits, not ACL/xattrs. Runtime admission must span apply and reload.

Independent C01+C02 passed 59/59; refreshed parser passed 681/681 TOML 1.1 cases (214 valid, 467 invalid, no failures/skips). Pinned toml-test v2.2.0 commit ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c; temporary runner removes only explicit NO_COLOR lookup/defaults colour off. Evidence: /Volumes/Data/tmp/hidhogg-v2-c02-verification. Eleven source hashes matched. C02 TaskView closure and notification succeeded.

D01 framing: 1024-byte packets, synthetic 1025-byte ID-zero reports, big-endian command, little-endian length, 1016 initial / 1024 continuation payload, 16 MiB cap. Startup is unlock → full page → brightness → enable input; keepalive is enable input only. Renderer: thirteen 196×196 tiles plus 458×196 wide tile, bundled Go Regular/CoreText, content-addressed PNGs, deterministic classic ZIP with firmware-safe padding. Draw into 16-bit premultiplied pixels, convert to 8-bit straight RGBA PNG.

The first D01 independent gate found low-alpha precision loss and inverted text. Corrected-source final proof supersedes it: eleven frozen hashes match; full C02+D01 passed 76/76, temporary exporter plus full suite 77/77. External zipfile/Pillow checks passed 18 archives/56 members, CRC/extraction, canonical manifests, content hashes/dedup/determinism, eight exact PNG8 RGBA backgrounds, zero-alpha RGB including labeled output, fitting/contrast/compositing, and 14,598-byte upload reconstructed from 15 ID-zero reports. Upright L bounds center (216,76)-(244,121), bottom (216,131)-(244,176). Root read logs/hashes and viewed corrected images. No defect remains; fallback glyph identity and Go compression-byte parity are unasserted.

D01 evidence: /Volumes/Data/tmp/hidhogg-v2-d01-verification, snapshot c02-committed-plus-d01-final, c02-d01-final-swift-test-escalated.log, independent-zip-png-final.log, independent_verify_final.py, orientation-final/. Unit-log SHA-256 d07433a91666aae807c26a03a7b342f19d6e07fc2e0cd110ddadbf02b7b18de7; external-log 94956274b4edf44a1ad81180f63dbfeb496229cf93bfe5e5ef6d8f5934e0a975; manifest 336f54a970206525d1d69c5b73b1ff7b2a49ba34645d0c869f64ce9cad4f3127. Commit manifest /Volumes/Data/tmp/hidhogg-v2-d01-commit-manifest.paths has 17 paths including root ledgers/three docs, excluding C02 and protected untracked files.

Fresh v1 baseline at /Volumes/Data/tmp/hidhogg-v2-baseline: Go unit/race each 1,446 nodes/15 packages, vet/build, 118 spike nodes, offline Xcode 129/129 with live integration excluded/test host suppressing startup. This proves v1 only, not v2 app integration.

## Accepted next contracts

D02 chooses simulation before native discovery. Match VID 2207/PID 0019, DeviceUsagePage 000c/DeviceUsage 1; validate actual DeviceUsagePairs, USB bInterfaceNumber 0, output report size exactly 1024. Refuse zero/multiple candidates before DeviceOpen; never ManagerOpen all matches. Native ID zero receives exactly 1024 bytes after stripping synthetic zero, no padding/truncation.

Input is copied/decoded independently of writes. Complete outbound batches serialize and fail-stop after write/removal uncertainty. Use one dedicated CFRunLoop callback model plus separate writer queue; idempotent nonblocking stop also works from callbacks. Separate completion waits in-flight write then unregister/unschedule/drain/close before context/buffer release. Do not mix dispatch cancellation. Existing OS writes cannot be preempted.

Confirmed D02 API: factory make(selection: .simulated/.native), async candidates(), async open(candidate, onInput, onFailure), async perform(typed batch), synchronous stop(), async waitUntilStopped() returning a bounded closed/cleanupUncertain outcome. Input/failure callbacks are synchronous Sendable closures; fake backend injection supports paused writes without native construction. The first report failure aborts the remaining batch. The seven-file stage-one overlay compiled in isolation without HID invocation; subsequent session/native corrections changed two hashes, so that build is provisional rather than final-source acceptance. Root required a typed cleanup result because an asynchronously enqueued failure callback cannot reliably gate restart; prior write failure stays separate from confirmed teardown.

Compile-only IOHID probe passed installed macOS 27 SDK/deployment 26 with no native invocation, at /Volumes/Data/tmp/hidhogg-v2-d02-verification. Actual hardware descriptor/registry placement remains unverified and excluded. D02 core gate uses fake/report-level simulation; native app simulation follows U01/V01 and remains required. Task 125 preserves these qualifications.

R01 accepted plan: RuntimeCoordinator actor, immutable prebuilt candidates, explicit operation admission across awaits, publish after successful device writes, retain prior logical state/fail-stop after uncertainty. Thread-safe receipt fence stamps generation/active before actor enqueue; stale/active observations reconcile held state without dispatch. Hold admission through store.apply and noncancelled post-commit reload. Late cancellation cannot roll back page success. Fakeable monotonic clock, absolute 50-second keepalive, idle zero/equality, host sleep/wake, consumed wake/release. Test/service briefs retained by swift_v2_executor with cited Go oracles.

R02: initial press/matched release; duplicate/orphan/changed-binding suppression; bounded direct execution; explicit permission and 16-entry input FIFO; metadata-only native history, bounded exec output tails on exact get (not list); exact-case source routing; TTL after commit; revalidated overlay selection; commit dismissal before static action admission. Do not infer all histories are metadata-only. No native posts in offline verification. Compile-only preparation passed macOS 27 SDK targeting 26: posix_spawn/actions/attrs, standard posix_spawn_file_actions_addchdir (available at 26; _np deprecated), separate process group and CoreGraphics permission/event signatures. Evidence /Volumes/Data/tmp/hidhogg-v2-r02-api-prep; brief SHA-256 c261015f2bbb649bc8d3e03f81da70077f323fa0c75ac28bfed4e5c1af7148a8, probe f98f2efdb461460248d3610c3a4111ef502b00716581d2483674941b0545d448. Root read the brief and confirmed the empty typecheck log hash. No spawn/permission/native behavior was exercised; source task remains pending.

U01 simulation preparation found the current delegate constructs HidhoggAppModel before HIDHOGG_TEST_HOST suppresses model.start(). Default construction uses standard preferences; default bootstrap later reads environment/home and normal startup launches the Go child. Existing injection seams are only unit-level. The required native app simulation must select explicit test composition before model/default preferences/native adapters are constructed, inject synthetic config and fake HID/actions/input/preferences/observers, directly launch the isolated app executable with explicit arguments, and use I01 readiness plus graceful shutdown control. No launch or owner preference/config values were read in this static audit. Root verified the early constructor and current Supervisor cleanup-failure terminal guard in source. App simulation arguments/control are not implemented yet.

## Ownership and next actions

- swift_configuration_edges: D02 executor, owning new device session/native backend/simulator and focused tests; necessary Sendable annotations to committed D01 values are allowed. D01/docs are committed; no new docs until verified D02 checkpoint.
- verification_baseline: D02 correction-2 independently passed 95/95 with all 11 hashes matched. The final three-file test refinement is now under a fresh isolated 96-test gate. Preliminary R01 utility proof and R02 compile-only preparation are historical evidence, not full runtime acceptance.
- swift_v2_executor: R01 runtime coordinator/models and focused Runtime tests, authorized after D02's isolated interface build and exact task 126 readback. No D02/D01/C02/Package/docs edits. Clock/fence owner gate passed 83/83 on committed D01 plus exactly four files; root matched all four hashes and read the log. Final coordinator acceptance requires independently verified D02.
- Root owns .agents, integration, exact-manifest commits, TaskView and milestone notification.

Explorer/scribe reactivation fails with collaboration thread-limit errors. Available workers perform bounded read-only audits/document work; no main source takeover. Preserve others' edits.

Normal SwiftPM can fail manifest sandbox setup before tests; narrow elevated snapshot/scratch retries passed. Git index writes similarly need scoped elevation. Suppress Git identity and notification output; inspect only commit hash/parent/title/path lists. A root documentation heredoc failed before writes because shell temp creation was denied; apply_patch safely performs the ledger refresh.

Integration complete: D01 commit fb038c882d18ff67f64efce911bc5d50896dc473 has exact 17 manifest paths, parent 57f93a1, branch v2 and a verified clean tracked tree at commit time. TaskView 124 is complete; 125 and 126 are in progress with exact HTML readback. Status-only D01 Discord notification exited 0 with output suppressed. No later source commit exists. Next: freeze and independently verify D02, commit its exact manifest while excluding R01, then gate the completed coordinator. Continue through V01/X01; goal completion requires native app simulation and final pure-Swift audit.

Current source checkpoint on 2026-10-02: R01's four independent files passed owner and preliminary independent 83-test gates. Root matched all four live hashes and independently read the passing log. Independent evidence is /Volumes/Data/tmp/hidhogg-v2-r01-utility-verification; manifest SHA-256 989af7d2e5936b58f4f24e1d907961774ff5a8fd6176b73a89314cda4ccd269d; test-log SHA-256 048b8cdb860368ed074db0ae7abeabaf88b540416295ab7992f2170e8e856649. No production defect; concurrent overlap and in-flight system-sleep cancellation are modest test limitations forwarded to the runtime owner for meaningful full-suite checks. D02's stage-one build log /Volumes/Data/tmp/hidhogg-v2-d02-owner-build.log reports success. Root checked /Volumes/Data/tmp/hidhogg-v2-d02-owner-hashes-stage1.txt: five files still match; session/native changed during accepted corrections. Full coordinator source is delegated; final R01 closure still requires verified D02.

D02 verified corrections: terminal write failure is published inside the serial writer before continuation release; stop rejects new work and ignores late input; retained handlers clear after drain; opening state is rechecked after paused revalidation; callback-thread timeout is cancelled and drained. Native stop joiners await the actual cleanup result. Actual well-typed DeviceUsagePairs is authoritative while scalar keys remain manager matching criteria. Simulator state includes archive/brightness/unlock/input-enable and write/removal faults. These now pass frozen-source fake/injected tests. No live hardware was inspected.

Historical decisions/checkpoints remain in .agents/log.md, Git, docs/v1-roadmap.md and TaskView archive 120; their old next-action statements are superseded here.

Latest D02 checkpoint: final owner and independent suites passed 96/96, zero failures/skips, on D01 plus exactly 11 frozen paths. Root read the independent report/log and rematched all live hashes. The last refinement changed only three test/helper files, adding negative/integral-float metadata rejection and admitted-open stop/drain/once-only teardown with truthful cleanupUncertain. Final manifest /Volumes/Data/tmp/hidhogg-v2-d02-owner-hashes-edge-closure.txt SHA-256 804bfba83c508d733582b801215abce8bb040292bc48ee934f15c35c9cee09a3. Independent report /Volumes/Data/tmp/hidhogg-v2-d02-verification/edge-closure-independent-report.txt SHA-256 85c6a4b63d9f4971b3a496317b2278a904504c5ad9f8550fb3df8168846536b1; independent log edge-closure-independent-swift-test-escalated.log SHA-256 9f8e27a6e9f76647abd62f6535beb696e5ec2afceb68999bfecf33041f5eaa53. Normal manifest setup denial preceded compilation; the authorized scoped retry passed. The test-only async-autoclosure error was corrected before passing proof. Core source is accepted; exact commit/TaskView closure follow. Native IOHID/hardware and required app simulation remain unexecuted.

R01 coordinator/models and dedicated tests now exist. Root routed required corrections: host-off keepalive, post-write absolute deadlines, encoder marker02 press/release/activity and marker-keyed held state, terminal uncertain cleanup, and bounded receipt overflow fail-stop. Initial package compilation/existing tests are provisional. A dedicated test hang was traced to RuntimeTestSession reading an optional pause gate before creation and losing an early resume; owner confirmed and is correcting its deterministic gate. The cleanup-uncertain assertion must expect failed. R01 is using a private copy of /Volumes/Data/tmp/hidhogg-v2-d02-verification/independent-correction2-snapshot/macos/HidhoggCore plus only Runtime-owned overlays to avoid in-flight D02 test changes. Full feature/frozen-source proof remains pending and must use the final accepted D02 checkpoint. The early four-file utility manifest is historical; the fence has since gained conditional begin support.

I01 read-only client/service preparation is at /Volumes/Data/tmp/hidhogg-v2-i01-client-prep/brief.md, read by root. Existing Swift codec/client checks are reusable, but runtime-directory discovery/revalidation differs from the current app's explicit child socket. Current position-editor wire is label-only; define a typed digest-checked full-position patch before U02. TaskView 130 was converted to HTML with exact readback and remains pending. No process/socket/native API gate ran; confirm the concrete depth of synthetic socket/CLI integration before execution.
