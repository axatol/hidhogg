# Repository structure

Status: M-06 follow-ups and M-05-F02 native input complete
Updated: 2026-09-18

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
│   ├── d200x/             production D200X protocol, transport, rendering, and session
│   ├── diagnostic/        bounded physical-test orchestration and evidence output
│   ├── discovery/         locked runtime-directory lifecycle and generation discovery
│   ├── ipc/               local transport and message handling
│   ├── nativeinput/       CoreGraphics backend, bounded native FIFO, permission lifecycle
│   └── runtime/           orchestration and lifecycle
├── macos/
│   ├── Hidhogg/           SwiftUI menu-bar application
│   └── HidhoggTests/      supervisor, security, fixture, and live IPC tests
├── scripts/diagnostics/   owner-run archival wrappers and synthetic validation
└── spikes/                retained feasibility and one-frame protocol evidence
```

Config and device ports are declared only at exercised consumer boundaries. Production packages now cover strict TOML loading, D200X transport/rendering, profiles, press actions, bounded child execution/history, transactional reload, and parent-directory file watching. Notification behavior remains deferred.

The current strict configuration is schema v3. `internal/config` validates and defaults scalar press/release gestures; `internal/profile` owns immutable effective bindings; `internal/runtime/actions.go` owns held-input latches and matched-release candidates. `internal/runtime/idle.go` reconciles suppressed physical events without submitting actions. The generated linting schema is `schema/hidhogg-d200x-v3.json`.

The Xcode build embeds the Go command as `Hidhogg.app/Contents/MacOS/hidhogg-runtime`. The distinct helper name is required because `Hidhogg` and `hidhogg` collide on the default case-insensitive macOS filesystem.

## Ownership boundaries

| Area | Responsibility | Excludes |
|---|---|---|
| HID spike | Transport feasibility and physical evidence | Production session architecture |
| Config spike | Lossless mutation and conflict behavior | Published configuration compatibility |
| Documentation | Verified facts, decisions, gates, and handoff | Unsupported hardware claims |
| Go runtime | Lifecycle, strict configuration orchestration, one D200X session, profiles/actions, bounded execution history, runtime-owned keepalive/idle coordinator, transactional reload, and local IPC | Notifications, multi-device policy, and source editing |
| Configuration | Strict single-file decode, semantic validation, deterministic schema, immutable reload candidates, and semantic diffing | Mutation, lossless preservation, and root/device composition |
| Configuration watcher | Parent-directory event filtering, trailing debounce, and automatic reload hints | Source mutation, retry of unchanged invalid content, and runtime restart |
| D200X adapter | Exact device selection, framing, configured page rendering, serialized session, and input decoding | Runtime policy, actions, notifications, reconnect |
| Native input | Plain text/Enter construction and posting, native FIFO, permission checks/explicit request, metadata-only history, native object lifetime | Application delivery guarantees, foreground-app inspection, subprocess fallback, and executable admission policy |
| Runtime discovery | Persistent advisory lock, strict readiness metadata, guarded stale recovery, and client identity revalidation | HID policy, remote discovery, PID authority, and non-cooperating same-UID processes |
| SwiftUI client | Menu-bar status, runtime supervision, and local health client | Direct HID ownership and settings editing |
| Internal IPC | Versioned, bounded health, profiles, execution history, and reload/status messages | Remote access, executable submission, and configuration contents |
