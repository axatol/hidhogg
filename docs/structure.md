# Repository structure

Status: M-09-B and M-10-A1 owner-visible editor verification passed; broader M-10-A remains open
Updated: 2026-10-01

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
| Config edit/store | Keyed profile label/clone/delete and coordinate tile-label mutations, lossless preservation, exact-digest conflict checks, atomic source replacement, and separate file/reload outcomes | Generic TOML editing, external-editor compare-and-swap guarantees, and Swift mapping ownership |
| Configuration watcher | Parent-directory event filtering, trailing debounce, and automatic reload hints | Source mutation, retry of unchanged invalid content, and runtime restart |
| D200X adapter | Exact device selection, framing, configured page rendering, serialized session, and input decoding | Runtime policy, actions, notifications, reconnect |
| Native input | Plain text/Enter construction and posting, native FIFO, permission checks/explicit request, metadata-only history, native object lifetime | Application delivery guarantees, foreground-app inspection, subprocess fallback, and executable admission policy |
| Runtime discovery | Persistent advisory lock, strict readiness metadata, guarded stale recovery, and client identity revalidation | HID policy, remote discovery, PID authority, and non-cooperating same-UID processes |
| SwiftUI client | Menu-bar status, runtime supervision, foreground-app mappings, and typed profile settings editor | Direct HID ownership and TOML source mutation |
| Internal IPC | Versioned, bounded health, profiles, execution history, reload/status, typed profile-editor mutations, input diagnostics and notification emit/clear messages | Remote access, executable submission, and full configuration contents |
