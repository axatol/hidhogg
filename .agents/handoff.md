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
- [x] C02 lossless edits/store 57f93a14451a3cb18b73e0dcb8d0654323649f51, current HEAD.
- [x] D01 corrected codec/archive/renderer independent acceptance; commit integration next.
- [ ] D02 native/simulated transport and session.
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
| D01 | 124 | In progress; final gate passed, commit/closure next |
| D02 | 125 | Pending; accepted interface plan recorded |
| R01 / R02 | 126 / 128 | Pending |
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

Compile-only IOHID probe passed installed macOS 27 SDK/deployment 26 with no native invocation, at /Volumes/Data/tmp/hidhogg-v2-d02-verification. Actual hardware descriptor/registry placement remains unverified and excluded. D02 core gate uses fake/report-level simulation; native app simulation follows U01/V01 and remains required. Task 125 preserves these qualifications.

R01 accepted plan: RuntimeCoordinator actor, immutable prebuilt candidates, explicit operation admission across awaits, publish after successful device writes, retain prior logical state/fail-stop after uncertainty. Thread-safe receipt fence stamps generation/active before actor enqueue; stale/active observations reconcile held state without dispatch. Hold admission through store.apply and noncancelled post-commit reload. Late cancellation cannot roll back page success. Fakeable monotonic clock, absolute 50-second keepalive, idle zero/equality, host sleep/wake, consumed wake/release. Test/service briefs retained by swift_v2_executor with cited Go oracles.

R02: initial press/matched release; duplicate/orphan/changed-binding suppression; bounded direct execution; explicit permission and 16-entry input FIFO; metadata-only native history, bounded exec output tails on exact get (not list); exact-case source routing; TTL after commit; revalidated overlay selection; commit dismissal before static action admission. Do not infer all histories are metadata-only. No native posts in offline verification.

## Ownership and next actions

- swift_configuration_edges: D01 frozen source plus docs/overview.md, docs/structure.md, docs/v2-plan.md; final doc proof next, then D02 after commit/activation.
- verification_baseline: D01 independent acceptance complete; reuse for D02 frozen-source gate.
- swift_v2_executor: C02 complete, R01 plan/test/service prep complete; code waits compile-stable D02 contract and task activation.
- Root owns .agents, integration, exact-manifest commits, TaskView and milestone notification.

Explorer/scribe reactivation fails with collaboration thread-limit errors. Available workers perform bounded read-only audits/document work; no main source takeover. Preserve others' edits.

Normal SwiftPM can fail manifest sandbox setup before tests; narrow elevated snapshot/scratch retries passed. Git index writes similarly need scoped elevation. Suppress Git identity and notification output; inspect only commit hash/parent/title/path lists. A root documentation heredoc failed before writes because shell temp creation was denied; apply_patch safely performs the ledger refresh.

Next: finalize D01 documentation, exact 17-path commit, close TaskView 124 by readback, activate 125 preserving accepted HTML, then notify verified milestone. Delegate D02, obtain compile-stable API, activate/delegate R01 within documented parallel boundary. Continue through V01/X01. Goal completion requires native app simulation and final pure-Swift audit.

Historical decisions/checkpoints remain in .agents/log.md, Git, docs/v1-roadmap.md and TaskView archive 120; their old next-action statements are superseded here.
