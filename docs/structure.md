# Repository structure

Status: v1 remains the production runtime. The standalone Swift core contains the C01/C02 configuration foundation, D01/D02 D200X core, and independently verified R01/R02 runtime services; app and CLI integration acceptance remain pending.
Updated: 2026-10-03

This file distinguishes the current repository layout from the approved target. The current Go packages and SwiftUI supervisor remain in place until the v2 parity and simulated-device acceptance gate passes.

```text
hidhogg/
├── api/                  internal IPC specification and shared fixtures
├── cmd/                  Go runtime and CLI entry points
├── docs/                 product, architecture, roadmap, and evidence
├── .agents/              durable decisions and session handoff
├── internal/             Go runtime and local IPC implementation
├── macos/                SwiftUI application, supervisor, client, and tests
└── spikes/               disposable feasibility programs and fixtures
    ├── go-hid-d200x/     cgo-free D200X transport investigation
    ├── go-native-input/  isolated cgo-free CoreGraphics text/key event probe
    └── config-editing/   lossless TOML and JSONC comparison
```

The repository also contains the isolated `macos/HidhoggCore` SwiftPM package for V2-C01, V2-C02, V2-D01, V2-D02, and V2-R01. It has one library target and one test target, with no external SwiftPM dependencies. The package owns strict Swift schema-v4 decoding, normalized immutable configuration values, its vendored TOML engine, typed lossless edits and a digest-guarded transactional source store, internal D200X framing/session/simulation, deterministic ZIP archive construction, page rendering, and a profile/reload/idle/host-display coordinator. It embeds the Go Regular font resource for wide labels. The package is not integrated with the app or CLI; Go remains the production runtime, configuration, and device owner. Configured action services, notification overlays, and IPC remain separate migration work.

C02's independent package suite passed 59/59 tests and its refreshed TOML 1.1 corpus passed 681/681 cases on 2026-10-02. The verified C02 implementation is commit `57f93a14451a3cb18b73e0dcb8d0654323649f51`.

The independent D01 gate passed on 2026-10-02 against that C02 commit plus the hash-matched 11-path D01 overlay: the full package suite passed 76/76 and the export-adapter suite passed 77/77. An external ZIP/PNG checker validated 18 deterministic archives and 56 members, PNG8 straight-RGBA color/alpha behavior, alpha-zero label normalization, centered and bottom-aligned L bounds, and 14,598 upload bytes reconstructed from 15 reports. It does not establish app/runtime integration, native transport, simulator behavior, or physical-device acceptance. Evidence is under `/Volumes/Data/tmp/hidhogg-v2-d01-verification/`.

On 2026-10-02, the independent R01 gate used committed D02 base `478e2a7` plus the exact seven-path coordinator overlay and passed 125/125 package tests with zero failures. The frozen overlay hashes matched before and after the run. These tests used fake sessions and synthetic seams; they did not open live HID, inject native input, launch the owner app, or run the native app simulation. The full log is `/Volumes/Data/tmp/hidhogg-v2-r01-closure-20261002/R01-full-suite-escalated.log`.

The completed `M-01` scaffold has the following production boundaries:

```text
hidhogg/
├── api/
│   └── protocol/v1/       internal IPC contract fixtures and specification
├── cmd/
│   ├── hidhogg/           Go runtime entry point
│   ├── hidhoggdiag/       bounded owner-run D200X diagnostic entry point
│   └── hidhoggctl/        local CLI entry point
├── internal/
│   ├── config/            strict milestone-private TOML model and schema generation
│   ├── configedit/        private lossless typed TOML mutation adapter
│   ├── configstore/       exact-digest, same-directory atomic source replacement
│   ├── d200x/             production D200X protocol, transport, rendering, and session
│   ├── diagnostic/        bounded physical-test orchestration and evidence output
│   ├── discovery/         locked runtime-directory lifecycle and generation discovery
│   ├── ipc/               local transport and message handling
│   ├── nativeinput/       CoreGraphics backend, bounded native FIFO, permission lifecycle
│   ├── notification/      device-independent bounded emit/clear contract and validation
│   └── runtime/           orchestration and lifecycle
├── macos/
│   ├── HidhoggCore/      isolated SwiftPM config/editor/store, D200X core, runtime coordinator, and synthetic tests
│   ├── Hidhogg/           SwiftUI menu-bar application
│   └── HidhoggTests/      supervisor, security, fixture, and live IPC tests
├── scripts/diagnostics/   owner-run archival wrappers and synthetic validation
└── spikes/                retained feasibility and one-frame protocol evidence
```

Config and device ports are declared only at exercised consumer boundaries. Production packages now cover strict TOML loading, D200X transport/rendering, profiles, press actions, bounded child execution/history, transactional reload, parent-directory file watching, and typed profile-source edits. M-07 adds local source-filtered notification overlays.

`internal/notification` owns request validation and neutral result/error types. `internal/runtime/notifications.go` owns ephemeral overlays, expiry and selection in the existing profile/reload coordinator; configured snapshots remain the baseline. IPC and CLI adapt that service without owning a device writer. The owner sequence is in `docs/m07-notification-runbook.md`.

For M-02-F04, `macos/Hidhogg/HostDisplayPowerObserver.swift` owns documented macOS display-state observation and reconciliation, while `HostDisplayPowerCoordinator.swift` serializes generation-bound IPC delivery. `internal/runtime/host_display.go` bridges the typed request to the existing idle-policy owner in `idle.go`; that owner decides host-state brightness and input suppression. `internal/ipc` validates the exact request and response. No Swift component writes HID packets. Physical verification remains owner-operated.

The current strict configuration is schema v4. `internal/config` owns keyed source decoding/projection and normalizes sparse profiles to 14 wire-ordered tiles; profile keys are identities and tile IDs are coordinates. Missing tiles become blank black tiles without actions/subscriptions. Its generated linting schema is `schema/hidhogg-d200x-v4.json`; predecessor source formats are rejected, not automatically migrated. `internal/configedit` preserves unrelated source bytes while editing keyed inline or expanded values. See [migration and defaults](compact-config-v4.md).

`internal/config` validates and defaults scalar press/release gestures; `internal/profile` owns immutable effective bindings; `internal/runtime/actions.go` owns held-input latches and matched-release candidates. `internal/runtime/idle.go` reconciles suppressed physical events without submitting actions.

The Xcode build embeds the Go command as `Hidhogg.app/Contents/MacOS/hidhogg-runtime`. The distinct helper name is required because `Hidhogg` and `hidhogg` collide on the default case-insensitive macOS filesystem.

## Ownership boundaries

| Area | Responsibility | Excludes |
|---|---|---|
| HID spike | Transport feasibility and physical evidence | Production session architecture |
| Config spike | Lossless mutation and conflict behavior | Published configuration compatibility |
| Documentation | Verified facts, decisions, gates, and handoff | Unsupported hardware claims |
| Go runtime | Lifecycle, strict configuration orchestration, one D200X session, profiles/actions, bounded execution history, keepalive/idle policy, transactional reload, typed profile-source edits, local notification overlays and IPC | Remote ingestion, multi-device policy, and arbitrary source editing |
| Configuration | Strict single-file decode, semantic validation, deterministic schema, immutable reload candidates, and semantic diffing | Mutation, lossless preservation, and root/device composition |
| Swift configuration foundation (V2-C01) | Standalone strict Swift v4 decode, normalized 14-position layout, TOML 1.1 parser extension, and safe diagnostics | Production app/CLI wiring, device/runtime ownership, source mutation, and transactional storage |
| Swift configuration edits/store (V2-C02) | Typed keep/set/reset field patches, profile label/clone/delete operations, same-engine byte-preserving edits, exact-digest atomic file replacement, and distinct file outcomes | Editor UI, runtime reload policy, generic TOML mutation, and external-editor compare-and-swap guarantees |
| Swift D200X core (V2-D01) | Internal typed frame/report codec, input decoding, deterministic classic-ZIP archive, and CoreText/Core Graphics/Image I/O page renderer | HID discovery/writes, serialized device session, simulator transport, and runtime policy |
| Swift D200X transport (V2-D02) | Selects simulation before native backend construction; serializes complete typed batches; delivers copied native input independently on a dedicated CFRunLoop while simulated input stays in the simulator backend; awaited stop reports `closed` or `cleanupUncertain` | Configured action services, notifications, app/CLI integration, and physical hardware acceptance |
| Swift runtime coordinator (V2-R01) | Serializes profile activation, reload, idle, host-display, keepalive, and source-edit operations; publishes after required writes; fences receipt-time input; uses a bounded fail-stop mailbox | Configured action execution, notifications, IPC/app integration, and native app simulation |
| Config edit/store | Keyed profile label/clone/delete and coordinate tile-label mutations, lossless preservation, exact-digest conflict checks, atomic source replacement, and separate file/reload outcomes | Generic TOML editing, external-editor compare-and-swap guarantees, and Swift mapping ownership |
| Configuration watcher | Parent-directory event filtering, trailing debounce, and automatic reload hints | Source mutation, retry of unchanged invalid content, and runtime restart |
| D200X adapter | Exact device selection, framing, configured page rendering, serialized session, and input decoding | Runtime policy, actions, notifications, reconnect |
| Native input | Plain text/Enter construction and posting, native FIFO, permission checks/explicit request, metadata-only history, native object lifetime | Application delivery guarantees, foreground-app inspection, subprocess fallback, and executable admission policy |
| Runtime discovery | Persistent advisory lock, strict readiness metadata, guarded stale recovery, and client identity revalidation | HID policy, remote discovery, PID authority, and non-cooperating same-UID processes |
| SwiftUI client | Menu-bar status, runtime supervision, foreground-app mappings, and typed profile settings editor | Direct HID ownership and TOML source mutation |
| Internal IPC | Versioned, bounded health, profiles, execution history, reload/status, typed profile-editor mutations, input diagnostics and notification emit/clear messages | Remote access, executable submission, and full configuration contents |

## Approved v2 ownership targets

These are TaskView work boundaries, not directories or implemented modules. The repository layout remains the v1 tree above while the migration is in progress.

| Target responsibility | TaskView task | Current v1 owner |
|---|---|---|
| Strict TOML v4 decoding and normalized layout | V2-C01 #122 | Go configuration |
| Lossless typed edits and transactional source store | V2-C02 #123 | Go config edit/store |
| D200X protocol and page rendering | V2-D01 #124 | Go D200X adapter |
| Native HID and simulated D200X | V2-D02 #125 | Go D200X adapter / Swift tests |
| Profiles, reload, idle and display lifecycle | V2-R01 #126 | Go runtime and Swift host-display observer |
| Actions, native input, notifications and history | V2-R02 #128 | Go runtime, Go native-input package and notification service |
| IPC, discovery and Swift CLI parity | V2-I01 #130 | Go IPC/CLI plus Swift client |
| App ownership of runtime and device | V2-U01 #132 | SwiftUI supervises the Go child |
| Complete existing button editor | V2-U02 #134 | SwiftUI profile editor (partial) |
| Independent unit, edge and simulator acceptance | V2-V01 #136 | Go and Swift test suites |
| Remove production Go dependencies after acceptance | V2-X01 #138 | Go remains in production |

TaskView project 5, list 49 owns these task states and dependencies. The full requirements and direct-ID map are in [v2-plan.md](v2-plan.md). Historical v1 contracts remain in [v1-roadmap.md](v1-roadmap.md).


## Verified R02 runtime services — 2026-10-03

R02 adds bounded configured executable execution and native-input queues/history, immutable captured actions, and source-filtered notification overlays. Notification lifetimes begin after successful display commit; expiry catches newly overdue entries after slow writes. Selection revalidates captured bindings and dismisses overlays before static action admission. Owned shutdown awaits action services and the device session and preserves cleanup uncertainty. The coordinator supplies monotonic-to-wall date conversion and coherent reload views with actual display-update outcomes for IPC.

Independent verification used committed R01 `b2d3c628bedaecb5e80dc0bbd784806b64cc86e0` plus exactly thirteen frozen R02 paths: 160 XCTest cases passed, zero failures or skips, and all live/snapshot hashes matched before and after testing. Evidence: `/Volumes/Data/tmp/hidhogg-v2-r02-independent-final-20261003/final-report.txt`; overlay manifest SHA-256 `df8acfbf9b1fbaf4e5bad6da09e4a4629f10539c9fce0ecc306fee9a0835dbcb`. This gate used fake process/input adapters and synthetic rendering; actual child execution, sockets, native HID/input, permission prompts and app simulation were not exercised. App/CLI acceptance and the required native simulated-app gate remain outstanding.

Implementation: `macos/HidhoggCore/Sources/HidhoggCore/RuntimeActionServices.swift`, `RuntimeExecution.swift`, `RuntimePosixProcessRunner.swift`, `RuntimeNativeInput.swift`, `RuntimeNotifications.swift`, and the existing coordinator/models. Focused tests reside in `macos/HidhoggCore/Tests/HidhoggCoreTests/`.
