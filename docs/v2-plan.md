# V2 Swift migration plan

Updated: 2026-10-02

TaskView project 5 owns current task status. This document is a durable requirements, dependency and direct-ID map; it is not a second status board.

## Approved goal

Replace the production Go runtime with a pure Swift macOS application that owns the D200X runtime and device. Retain a Swift CLI for notifications and status. Keep the requested user-facing feature set and strict TOML v4 contract, then complete the existing button editor for appearance, actions and notification sources. Owner-authorized improvements may change v1 implementation behavior; migration acceptance does not require wholesale byte-level compatibility.

The owner approved this migration on 2026-10-02. Simulator acceptance means the native macOS app running against a simulated D200X. Apple Simulator is not a target for macOS applications.

## Current and target architecture

Current v1 remains Go-owned: Go provides strict configuration loading, lossless edits, D200X protocol/rendering, runtime profiles and actions, reload, idle/display policy, notifications, IPC and the CLI. The SwiftUI app supervises the bundled Go runtime and presents the current profile editor.

The approved v2 target moves those runtime, configuration, device and service responsibilities into Swift. The native app owns runtime and device lifecycle. A Swift CLI provides status and notifications. No v2 production runtime is implemented yet; the TaskView records track future work.

## Scope and constraints

- Preserve TOML v4 keyed profiles/coordinates, defaults, sparse blank-tile behavior, strict explicit-value rejection and predecessor-schema rejection.
- Preserve exact-digest conflict checks, lossless untouched bytes, transactional file replacement, and distinct file-write/runtime-reload outcomes.
- Preserve profile activation, last-known-good reload, 50-second keepalive, configured idle behavior, host display sleep/wake policy, decoded input and consumed wake gestures.
- Preserve configured press/release behavior, bounded action execution and history, explicit native-input permission behavior, and local source-filtered notification overlays.
- Render configured `#RRGGBB` and `#RRGGBBAA` colors with conventional straight-alpha inputs and PNG output. The owner accepted native CoreText/Core Graphics behavior over byte-level compatibility with Go's premultiplied `color.RGBA` path; zero-alpha RGB is normalized to transparent black. Synthetic boundary tests cover low alpha, RGB components above alpha, and zero alpha without promising exact byte preservation for every 8-bit color under premultiplied drawing.
- Complete GUI fields for button appearance, actions and notification sources. Custom assets remain deferred.
- Do not access selected user configuration, real D200X hardware, native input injection or the existing owner app during offline work. Use synthetic data and the simulated D200X.
- Do not remove Go from production before the V2-V01 parity and simulator gate passes. V2-X01 owns the final removal and audit.
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

V2-C01 implements strict Swift TOML v4 decoding and normalized layout in the standalone, dependency-free `macos/HidhoggCore` SwiftPM library, targeting macOS 26. It preserves omitted-versus-explicit values during schema validation, rejects unknown/duplicate/wrong-type input, and returns immutable `Sendable` configuration values with the deterministic 14-position layout. The strict decoder extends the vendored parser's existing typed-tree engine for TOML 1.1; it does not add a second parser. Configuration diagnostics use static bounded details and complete field paths. Syntax/type and unknown-key locations are parser-backed UTF-8 byte columns; semantic validation, missing-key, and schema-version diagnostics report `0:0`. The package remains separate from the Go-owned production runtime until later integration.

The independent corrected-source Swift package suite passed 30/30 on 2026-10-02, including complete dotted-key diagnostics with UTF-8 byte locations. The corrected-source official TOML 1.1 run used `toml-test` v2.2.0, commit `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`, and passed 214 valid plus 467 invalid cases with zero failures or skips. The seven vendored parser source files matched the final frozen-source hash manifest. The run log is `/Volumes/Data/tmp/hidhogg-v2-c01-verification/toml-test-v2.2.0-1.1-final.log`. The temporary runner change removed its explicit `NO_COLOR` lookup and disabled color by default; test selection and comparison were unchanged.

V2-C02 adds typed `keep`/`set`/`reset` position patches, profile-label updates, profile clone/delete operations, and a transactional source store using the same vendored strict TOML engine. Parser byte spans and inline-table metadata let edits replace only the selected source range while preserving untouched valid fields and their comments, whitespace, ordering, and multiline/trailing-comma inline-table formatting. The editor still strictly validates the whole source and rejects unknown fields. The store checks an exact-byte digest before mutation and immediately before same-directory atomic rename, then reports unchanged, committed, or uncertain file outcomes with the resulting digest/bytes. Runtime reload remains a separate outcome for the coordinating owner. The independent C01+C02 package suite passed 59/59, and the refreshed TOML 1.1 corpus passed 681/681 cases on 2026-10-02. C02 is committed as `57f93a14451a3cb18b73e0dcb8d0654323649f51`; the reviewed vendor commit is 603c402868e1fb5c4348d130f16e73b401f531f8.

V2-D01 adds internal D200X frame encoding/report normalization, inbound frame assembly and input decoding, safe typed outbound batches, deterministic classic-ZIP archive construction, and full-page rendering from normalized profiles. The codec preserves 1024-byte packet and 1025-byte report-ID-zero layouts, big-endian command/little-endian payload length, 1016-byte first payload, 1024-byte continuation payloads, and the 16 MiB limit. Its batches model startup as unlock → full-page upload → brightness → enable-input-stream; keepalive sends only enable-input-stream. V2-D02 owns transport serialization so those startup writes remain one transaction.

The renderer produces thirteen 196×196 tiles and one 458×196 wide tile, uses the bundled Go Regular font for wide-label requests, preserves the firmware manifest fields, and content-addresses/deduplicates PNGs by SHA-256. It uses CoreText for glyph layout/rasterization and Core Graphics/Image I/O for images. To retain precision while compositing, it draws on a 16-bit premultiplied working surface, converts to 8-bit straight RGBA, then encodes PNG; zero-alpha RGB normalizes to zero. Local synthetic tests inspect decoded `.last` provider bytes for exact uniform background channels at alpha 0, 1, 2, 127, 128, 254, and 255, and exercise an upright L shape in centered and bottom-aligned regions. CoreText fallback/shaping equality with the Go rune renderer is not claimed; the mixed `A` plus U+0378 case verifies valid input and visible output only.

The local isolated C01+D01 snapshot passed 47/47 tests, and the combined package on the committed C02 base passed 76/76. Independent D01 verification then hash-matched the 11-path overlay and passed the full suite 76/76 plus a 77/77 export-adapter suite. The external checker decoded 18 deterministic ZIP archives/56 members, validated CRC/extraction/manifests/content hashes/deduplication/classic-ZIP metadata/padding/repeat determinism, confirmed 8 PNG8 straight-RGBA background cases and labeled alpha-zero normalization, checked the upright centered L bounds `(216, 76)-(244, 121)` and bottom bounds `(216, 131)-(244, 176)`, and reconstructed a 14,598-byte upload from 15 ID-zero reports. Logs are `/Volumes/Data/tmp/hidhogg-v2-d01-verification/c02-d01-final-swift-test-escalated.log`, `/Volumes/Data/tmp/hidhogg-v2-d01-verification/c02-d01-final-export-tests.log`, and `/Volumes/Data/tmp/hidhogg-v2-d01-verification/independent-zip-png-final.log`; the verified source hashes are in `D01-SHA256SUMS` in that directory. CoreText fallback glyph identity and Go-versus-Swift compressed-byte parity are not claimed. This gate does not verify app/runtime wiring, native transport, simulator behavior, or physical hardware.

V2-D02 implements the native Swift HID path and simulated D200X after D01 verification and tracking activation. Real hardware is outside this migration's offline acceptance.

V2-R01 moves profiles, activation/reload, idle and host-display policy into the Swift runtime. V2-R02 moves configured actions, native input permission/FIFO/history and notification overlays. V2-I01 supplies bounded Swift IPC, discovery/readiness, status and notification CLI parity.

V2-U01 makes the native app own runtime and device lifecycle and removes the Go child only after service parity. V2-U02 completes the existing button editor fields. V2-V01 independently verifies unit and failure edges plus native macOS app workflows with the simulated D200X. V2-X01 removes production Go dependencies and performs the final build/documentation audit after V2-V01.

## Verification and closure

Implementation proceeds through bounded subagents; the main agent integrates their work and maintains the `.agents` decision and handoff ledger. Keep modules focused, use early returns, and avoid premature modularization, speculative features, or abstraction for hypothetical reuse. Each task receives a commit only after its focused and full Swift tests, feature and edge/failure tests, and independent verification pass. The final acceptance reports each requirement pass/fail/not-run and exercises the native app with the simulated D200X. No real device, selected configuration, existing owner app or native input injection is part of this offline task.

The existing Go implementation remains available as the parity reference until V2-V01 passes. V2-X01 must verify that production builds no longer include Go while preserving approved reference fixtures and the exact v1 roadmap archive.
