# Repository structure

Status: M-02 config-driven D200X slice complete
Updated: 2026-08-26

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
    └── config-editing/   lossless TOML and JSONC comparison
```

The completed `M-01` scaffold has the following production boundaries:

```text
hidhogg/
├── api/
│   └── protocol/v1/       internal IPC contract fixtures and specification
├── cmd/
│   ├── hidhogg/           Go runtime entry point
│   └── hidhoggctl/        local CLI entry point
├── internal/
│   ├── config/            strict milestone-private TOML model and schema generation
│   ├── d200x/             production D200X protocol, transport, rendering, and session
│   ├── ipc/               local transport and message handling
│   └── runtime/           orchestration and lifecycle
├── macos/
│   ├── Hidhogg/           SwiftUI menu-bar application
│   └── HidhoggTests/      supervisor, security, fixture, and live IPC tests
└── spikes/                retained feasibility evidence
```

Config and device ports are declared only at exercised consumer boundaries. `M-02` introduced production TOML loading and D200X packages; action and notification packages remain deferred.

The Xcode build embeds the Go command as `Hidhogg.app/Contents/MacOS/hidhogg-runtime`. The distinct helper name is required because `Hidhogg` and `hidhogg` collide on the default case-insensitive macOS filesystem.

## Ownership boundaries

| Area | Responsibility | Excludes |
|---|---|---|
| HID spike | Transport feasibility and physical evidence | Production session architecture |
| Config spike | Lossless mutation and conflict behavior | Published configuration compatibility |
| Documentation | Verified facts, decisions, gates, and handoff | Unsupported hardware claims |
| Go runtime | Lifecycle, strict configuration orchestration, one D200X session, diagnostic events, and bounded health/status service | Actions, notifications, reload, and multi-device policy |
| M-02 configuration | Strict single-file decode, semantic validation, and deterministic schema | File watching, mutation, root/device composition |
| D200X adapter | Exact device selection, framing, configured page rendering, serialized session, and input decoding | Runtime policy, actions, notifications, reconnect |
| SwiftUI client | Menu-bar status, runtime supervision, and local health client | Direct HID ownership and settings editing |
| Internal IPC | Versioned, bounded local messages and process health | Remote access and executable commands |
