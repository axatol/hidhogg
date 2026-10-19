# V2 Swift migration plan

Updated: 2026-10-18

TaskView project 5 owns current task status. This document is a durable requirements, dependency and direct-ID map; it is not a second status board.

## Approved goal

Replace the production Go runtime with a pure Swift macOS application that owns the D200X runtime and device. Retain a Swift CLI for notifications and status. Keep the requested user-facing feature set and strict TOML v4 contract, then complete the existing button editor for appearance, actions and notification sources. Owner-authorized improvements may change v1 implementation behavior; migration acceptance does not require wholesale byte-level compatibility.

The owner approved this migration on 2026-10-02. Simulator acceptance means the native macOS app running against a simulated D200X. Apple Simulator is not a target for macOS applications.

## Current and target architecture

The historical, committed v1 baseline is Go-owned: Go provides strict configuration loading, lossless edits, D200X protocol/rendering, runtime profiles and actions, reload, idle/display policy, notifications, IPC and the CLI. The accepted v2 implementation now uses a native Swift app that owns the Swift runtime and device, with a Swift CLI for status and notifications.

The accepted v2 implementation moves runtime, configuration, device and service responsibilities into Swift. I01/U01 are committed at `d714dfefae7c0bae7d1592018ab857b0793c59f1` and `2418f54c6c70782936f72c23e26b8e19f00326fc`. The implementation contains no C bridge or runtime-file lock. Its MVP assumes one app-owned process using a private UUID-generation runtime directory; owner-only permissions and identity-guarded cleanup remain, while shared explicit-directory multiprocess use is unsupported and singleton use is not enforced. V01 passed on 2026-10-18. X01 removed the Go implementation and diagnostic entry points; its independent deletion/retention audit, post-removal tests, production builds, and controlled simulated-app smoke passed.

## Scope and constraints

- Preserve TOML v4 keyed profiles/coordinates, defaults, sparse blank-tile behavior, strict explicit-value rejection and predecessor-schema rejection.
- Preserve exact-digest conflict checks, lossless untouched bytes, transactional file replacement, and distinct file-write/runtime-reload outcomes.
- Preserve profile activation, last-known-good reload, 50-second keepalive, configured idle behavior, host display sleep/wake policy, decoded input and consumed wake gestures.
- Preserve configured press/release behavior, bounded action execution and history, explicit native-input permission behavior, and local source-filtered notification overlays.
- Render configured `#RRGGBB` and `#RRGGBBAA` colors with conventional straight-alpha inputs and PNG output. The owner accepted native CoreText/Core Graphics behavior over byte-level compatibility with Go's premultiplied `color.RGBA` path; zero-alpha RGB is normalized to transparent black. Synthetic boundary tests cover low alpha, RGB components above alpha, and zero alpha without promising exact byte preservation for every 8-bit color under premultiplied drawing.
- Complete GUI fields for button appearance, actions and notification sources. Custom assets remain deferred.
- Do not access selected user configuration, real D200X hardware, native input injection or the existing owner app during offline work. Use synthetic data and the simulated D200X.
- Preserve the exact v1 roadmap, protocol reference, renderer font/provenance, research notes, and the approved spike evidence. V2-X01 removed the Go implementation and retired its diagnostic wrappers after V01 acceptance.
- The historical Go log-tail and split-profile-file proposals remain deferred.

## TaskView authority and direct-ID manifest

Destination: Personal organization 2, HIDhogg project 5. List 48 is v1 legacy tracking; list 49 is v2 Swift migration. TaskView task 120 is the historical roadmap migration manifest. Its complete status means the archive import was verified; it does not mean all underlying legacy tasks are complete.

TaskView list_tasks omits known records, including records discoverable by recursive subtasks and direct get_task. Use this verified direct-ID map; do not infer task absence from list results. The full 103-code status/qualification index and compact original contracts are stored in TaskView task 120.

### Verified legacy mappings

| Local code | TaskView ID | Parent |
|---|---:|---:|
| M-03-F01 | 53 | — |
| M-08-P01 | 54 | — |
| M-08-C01 | 55 | 54 |
| M-08-I01 | 56 | 54 |
| M-08-R01 | 57 | 54 |
| M-08-U01 | 58 | 54 |
| M-08-V01 | 59 | 54 |
| M-09-A | 60 | 54 |
| M-10-A | 61 | 54 |
| M-09-B | 62 | 54 |
| M-10-B | 63 | 54 |
| M-02-F04 | 66 | — |
| M-08-F01 | 67 | — |
| M-08-F02 | 68 | — |
| M-10-F01 | 69 | — |

Do not reparent these records or change their completion state without new evidence. The 2026-09-21 log records that completed historical milestones had not been migrated at that point; the archive consolidates the full old roadmap without manufacturing a separate task for every nested verification label.

### V2 task map and dependencies

TaskView stores the dependency edges. The code/ID table is a locator; current state belongs in TaskView.

| Code | TaskView ID | Depends on |
|---|---:|---|
| V2-P01 | 121 | — |
| V2-C01 | 122 | V2-P01 |
| V2-C02 | 123 | V2-C01 |
| V2-D01 | 124 | V2-P01, V2-C01 |
| V2-D02 | 125 | V2-D01 |
| V2-R01 | 126 | V2-C01, V2-C02, V2-D02 |
| V2-R02 | 128 | V2-R01, V2-C02, V2-D02 |
| V2-I01 | 130 | V2-R01, V2-R02 |
| V2-U01 | 132 | V2-D02, V2-R01, V2-R02, V2-I01 |
| V2-U02 | 134 | V2-C02, V2-R02, V2-U01 |
| V2-V01 | 136 | V2-C01, V2-C02, V2-D01, V2-D02, V2-R01, V2-R02, V2-I01, V2-U01, V2-U02 |
| V2-X01 | 138 | V2-V01 |

Each TaskView task note holds its goal, scope, constraints, acceptance criteria, roles, dependencies, verification gates, blockers and parallel boundaries.

## Work packages

V2-P01 reviews current behavior/parity and test gaps, verifies the curated v1 checkpoint, and branches v2 from that checkpoint. The v1 commit is a1a64ed on master; the local v2 branch starts at the same commit.

V2-C01 implements strict Swift TOML v4 decoding and normalized layout in the standalone, dependency-free `macos/HidhoggCore` SwiftPM library, targeting macOS 26. It preserves omitted-versus-explicit values during schema validation, rejects unknown/duplicate/wrong-type input, and returns immutable `Sendable` configuration values with the deterministic 14-position layout. The strict decoder extends the vendored parser's existing typed-tree engine for TOML 1.1; it does not add a second parser. Configuration diagnostics use static bounded details and complete field paths. Syntax/type and unknown-key locations are parser-backed UTF-8 byte columns; semantic validation, missing-key, and schema-version diagnostics report `0:0`. The package was initially separate from production runtime ownership; accepted I01/U01 now compose the Swift package in the native app and CLI.

The independent corrected-source Swift package suite passed 30/30 on 2026-10-02, including complete dotted-key diagnostics with UTF-8 byte locations. The corrected-source official TOML 1.1 run used `toml-test` v2.2.0, commit `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`, and passed 214 valid plus 467 invalid cases with zero failures or skips. The seven vendored parser source files matched the final frozen-source hash manifest. The run log is `/Volumes/Data/tmp/hidhogg-v2-c01-verification/toml-test-v2.2.0-1.1-final.log`. The temporary runner change removed its explicit `NO_COLOR` lookup and disabled color by default; test selection and comparison were unchanged.

V2-C02 adds typed `keep`/`set`/`reset` position patches, profile-label updates, profile clone/delete operations, and a transactional source store using the same vendored strict TOML engine. Parser byte spans and inline-table metadata let edits replace only the selected source range while preserving untouched valid fields and their comments, whitespace, ordering, and multiline/trailing-comma inline-table formatting. The editor still strictly validates the whole source and rejects unknown fields. The store checks an exact-byte digest before mutation and immediately before same-directory atomic rename, then reports unchanged, committed, or uncertain file outcomes with the resulting digest/bytes. Runtime reload remains a separate outcome for the coordinating owner. The independent C01+C02 package suite passed 59/59, and the refreshed TOML 1.1 corpus passed 681/681 cases on 2026-10-02. C02 is committed as `57f93a14451a3cb18b73e0dcb8d0654323649f51`; the reviewed vendor commit is 603c402868e1fb5c4348d130f16e73b401f531f8.

V2-D01 adds internal D200X frame encoding/report normalization, inbound frame assembly and input decoding, safe typed outbound batches, deterministic classic-ZIP archive construction, and full-page rendering from normalized profiles. The codec preserves 1024-byte packet and 1025-byte report-ID-zero layouts, big-endian command/little-endian payload length, 1016-byte first payload, 1024-byte continuation payloads, and the 16 MiB limit. Its batches model startup as unlock → full-page upload → brightness → enable-input-stream; keepalive sends only enable-input-stream. V2-D02 owns transport serialization so those startup writes remain one transaction.

The renderer produces thirteen 196×196 tiles and one 458×196 wide tile, uses the bundled Go Regular font for wide-label requests, preserves the firmware manifest fields, and content-addresses/deduplicates PNGs by SHA-256. It uses CoreText for glyph layout/rasterization and Core Graphics/Image I/O for images. To retain precision while compositing, it draws on a 16-bit premultiplied working surface, converts to 8-bit straight RGBA, then encodes PNG; zero-alpha RGB normalizes to zero. Local synthetic tests inspect decoded `.last` provider bytes for exact uniform background channels at alpha 0, 1, 2, 127, 128, 254, and 255, and exercise an upright L shape in centered and bottom-aligned regions. CoreText fallback/shaping equality with the Go rune renderer is not claimed; the mixed `A` plus U+0378 case verifies valid input and visible output only.

The local isolated C01+D01 snapshot passed 47/47 tests, and the combined package on the committed C02 base passed 76/76. Independent D01 verification then hash-matched the 11-path overlay and passed the full suite 76/76 plus a 77/77 export-adapter suite. The external checker decoded 18 deterministic ZIP archives/56 members, validated CRC/extraction/manifests/content hashes/deduplication/classic-ZIP metadata/padding/repeat determinism, confirmed 8 PNG8 straight-RGBA background cases and labeled alpha-zero normalization, checked the upright centered L bounds `(216, 76)-(244, 121)` and bottom bounds `(216, 131)-(244, 176)`, and reconstructed a 14,598-byte upload from 15 ID-zero reports. Logs are `/Volumes/Data/tmp/hidhogg-v2-d01-verification/c02-d01-final-swift-test-escalated.log`, `/Volumes/Data/tmp/hidhogg-v2-d01-verification/c02-d01-final-export-tests.log`, and `/Volumes/Data/tmp/hidhogg-v2-d01-verification/independent-zip-png-final.log`; the verified source hashes are in `D01-SHA256SUMS` in that directory. CoreText fallback glyph identity and Go-versus-Swift compressed-byte parity are not claimed. This gate does not verify app/runtime wiring, native transport, simulator behavior, or physical hardware.

V2-D02 implements native D200X selection/session and protocol-faithful simulation in HidhoggCore. Backend selection occurs before backend construction, so simulated mode does not instantiate native discovery. The native path validates the target identity and usage pair, USB interface 0, and exact 1024-byte output size, and rejects zero or multiple eligible candidates before open. Typed report batches are serialized as whole operations; native input is copied and delivered independently through a dedicated CFRunLoop, while simulated input stays inside the simulator backend. Stop is nonblocking, while `waitUntilStopped` returns the bounded `closed` or `cleanupUncertain` outcome after callback unregister, unschedule, drain, and close. The independent edge-closure gate hash-matched the exact 11-path overlay on the D01 base and passed 96/96 package tests, including 12 session, 5 native-validator/lifecycle, and 3 simulator tests with no skips. The report is `/Volumes/Data/tmp/hidhogg-v2-d02-verification/edge-closure-independent-report.txt`; the manifest is `/Volumes/Data/tmp/hidhogg-v2-d02-owner-hashes-edge-closure.txt`. That gate used synthetic and fake-backed Core behavior only; it did not invoke native discovery or device I/O. A later controlled U01 candidate gate passed simulated-app readiness and graceful termination. Physical hardware remains excluded from offline acceptance.

V2-R01 adds the standalone Swift coordinator for profile activation/reload, idle and host-display lifecycle, keepalive, and configuration-edit reloads. One admission gate serializes transitions across awaited session operations. The coordinator publishes a profile or candidate catalog only after its required device writes succeed; an invalid reload retains the last-known-good catalog and revision. Reload compares the rendered archive bytes, so profile-label or action/source metadata changes still commit to the catalog without an unnecessary HID write. A committed source edit proceeds through reload even if the caller is cancelled, while file and runtime outcomes remain distinct. The coordinator leaves configured action execution and notification overlays to later slices.

The input callback stamps each event with generation/transition state before actor enqueue. The receipt mailbox holds at most 64 events; overflow latches one terminal failure and one cleanup path rather than dropping an event and risking a stuck binding. Already-dimmed known wake gestures consume both the press and matching release. An absolute 50-second keepalive continues while the host display is off and skips missed intervals using the post-write monotonic time, avoiding catch-up bursts. The independent R01 gate on 2026-10-02 used committed D02 base `478e2a7` plus the exact seven-path overlay and passed 125/125 package tests with zero failures. All overlay hashes matched before and after testing; the checksum-manifest digest was `f3ac844ae07b1972c67c6894b86152b91fbb89e2f6e0d24e367ecd78013d9a57`. The gate used synthetic/fake seams only: it did not open live HID, inject native input, launch the owner app, or run native app simulation. The log is `/Volumes/Data/tmp/hidhogg-v2-r01-closure-20261002/R01-full-suite-escalated.log`. At the R01 checkpoint, the production app/CLI still used Go and app simulation remained pending; the later accepted I01/U01 integration is summarized below.

V2-R01 moves profiles, activation/reload, idle and host-display policy into the Swift runtime. V2-R02 moves configured actions, native input permission/FIFO/history and notification overlays. V2-I01 supplies bounded Swift IPC, discovery/readiness, status and notification CLI parity.

V2-U01 made the native app own runtime and device lifecycle and removed Go child startup after service parity. V2-U02 completed the six-field button editor. V2-V01 passed independent unit, failure-edge, and native macOS simulated-D200X acceptance on 2026-10-18. V2-X01 removed the retired Go implementation and diagnostics and completed the final Swift build and documentation audit; verification details follow.

## Verification and closure

Implementation proceeds through bounded subagents; the main agent integrates their work and maintains the `.agents` decision and handoff ledger. Keep modules focused, use early returns, and avoid premature modularization, speculative features, or abstraction for hypothetical reuse. Each task receives a commit only after its focused and full Swift tests, feature and edge/failure tests, and independent verification pass. The final acceptance reports each requirement pass/fail/not-run and exercises the native app with the simulated D200X. No real device, selected configuration, existing owner app or native input injection is part of this offline task.

V2-V01 passed on commit `08a44f8`. The report at [`/Volumes/Data/tmp/hidhogg-v01-final-acceptance-20261018.md`](/Volumes/Data/tmp/hidhogg-v01-final-acceptance-20261018.md) records 206 passing Core tests, 152 passing app tests, and the native simulated-app save/reopen, conflict, editor, reload, and cleanup checks. Physical hardware and native input injection were not exercised.

The X01 candidate removed 165 implementation/test/module/fixture paths from the approved 173-path Go inventory, retained eight static spike artifacts, and removed eight Go diagnostic entry points. It preserves `api/protocol/v1/**`, `docs/research.md`, the exact `docs/v1-roadmap.md`, all font and provenance resources, the eight approved spike artifacts, and the `scripts/diagnostics/ulanzi-lldb/` research subtree. The diagnostics README identifies the removed owner-run wrappers as retired; no Go diagnostic port is included.

The independent post-removal audit matched all 99 frozen Swift source/test/project hashes before and after verification. A bounded source scan found no tracked `.go`, `go.mod`, or `go.sum` files under `cmd` or `internal`. Four production builds passed: app Debug/Release and Swift CLI Debug/Release; all four executables were Mach-O arm64, and the production app did not define `HIDHOGG_TEST_HOST`.

The first full Core run executed 206 tests and failed one assertion at `RuntimeCoordinatorTests.swift:232` (`releaseWasProcessedBeforeTimerWake`). The focused test passed once and in ten sequential repeats; a later full suite passed 206/206. The timing cause remains unconfirmed, and no source changes were made between runs. Safe app unit selectors passed 139/139. One app selector that starts a runtime generation and Unix-domain server was excluded from that unit run; the separate controlled native smoke exercised app readiness and CLI status instead. The verification report is [`final-verification-report.txt`](/Volumes/Data/tmp/hidhogg-v2-x01-final-20261018/final-verification-report.txt), SHA-256 `77127708a382f1ff664773cbc32fee1d8623787b0a2319d8980216609c513fa4`.

The parent-owned native simulated-app smoke passed: Settings opened, closed and reopened; Release CLI status remained `ready` for the same generation with protocol version 1; shutdown exited 0, emptied the runtime root, removed the simulation root, and required no watchdog escalation. Evidence is [`native-smoke-terminal.log`](/Volumes/Data/tmp/hidhogg-v2-x01-final-20261018/native-smoke-terminal.log), SHA-256 `f3e358b86b12a997175b8c73c2141669cba6837694fe5c3b3778b07115cb80f8`. The smoke used a synthetic configuration and simulated D200X. Physical HID, native input injection, actual child-process execution, and isolated cold-launch behavior remain unverified.


## Verified R02 runtime services — 2026-10-03

R02 adds bounded configured executable execution and native-input queues/history, immutable captured actions, and source-filtered notification overlays. Notification lifetimes begin after successful display commit; expiry catches newly overdue entries after slow writes. Selection revalidates captured bindings and dismisses overlays before static action admission. Owned shutdown awaits action services and the device session and preserves cleanup uncertainty. The coordinator supplies monotonic-to-wall date conversion and coherent reload views with actual display-update outcomes for IPC.

Independent verification used committed R01 `b2d3c628bedaecb5e80dc0bbd784806b64cc86e0` plus exactly thirteen frozen R02 paths: 160 XCTest cases passed, zero failures or skips, and all live/snapshot hashes matched before and after testing. Evidence: `/Volumes/Data/tmp/hidhogg-v2-r02-independent-final-20261003/final-report.txt`; overlay manifest SHA-256 `df8acfbf9b1fbaf4e5bad6da09e4a4629f10539c9fce0ecc306fee9a0835dbcb`. This gate used fake process/input adapters and synthetic rendering; actual child execution, sockets, native HID/input, permission prompts and app simulation were not exercised. At the 2026-10-03 R02 checkpoint, app/CLI acceptance and the native simulated-app gate remained outstanding; I01/U01 acceptance is recorded below.

Implementation: `macos/HidhoggCore/Sources/HidhoggCore/RuntimeActionServices.swift`, `RuntimeExecution.swift`, `RuntimePosixProcessRunner.swift`, `RuntimeNativeInput.swift`, `RuntimeNotifications.swift`, and the existing coordinator/models. Focused tests reside in `macos/HidhoggCore/Tests/HidhoggCoreTests/`.

## Accepted I01/U01 integration — 2026-10-18

V2-I01 is committed as `d714dfefae7c0bae7d1592018ab857b0793c59f1` (17 Core paths); V2-U01 is committed as `2418f54c6c70782936f72c23e26b8e19f00326fc` (9 app paths). The native Swift app owns runtime/device lifecycle, and the Swift CLI provides status and notification operations. Independent Core verification passed 205/205 tests. The app fake suite passed 7/7; the controlled simulated-D200X no-lock app gate completed graceful quit and left its runtime root empty. ARM64-only Debug and Release builds passed. The implementation contains no C bridge or runtime-file lock. Its process model is one app-owned process using a private UUID-generation directory; owner-only directory/socket permissions and identity-guarded cleanup remain. Shared explicit-directory multiprocess use is unsupported, and singleton use is not enforced.

The corrected CLI integration gate exited 0 after checking status readiness, protocol and runtime UUID, profiles, notification emit/clear, and full temporary-directory cleanup. Evidence is `/Volumes/Data/tmp/hidhogg-v2-i01-socket-cli-harness/corrected-result.txt`, SHA-256 `36e65eb39d14fc217b5e0fc955f21f90d0e441ffcf2664a766eef6784cd46ab9`. An initial harness assertion for an active field failed; the test contract was corrected without production changes, and the corrected gate passed. U02 editor work and V01 acceptance are complete. X01's later post-removal checks are recorded in [Verification and closure](#verification-and-closure).
