# Repository structure

Status: production scaffold complete
Updated: 2026-08-24

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
│   ├── ipc/               local transport and message handling
│   └── runtime/           orchestration and lifecycle
├── macos/
│   ├── Hidhogg/           SwiftUI menu-bar application
│   └── HidhoggTests/      supervisor, security, fixture, and live IPC tests
└── spikes/                retained feasibility evidence
```

Config and device ports will be declared only at an exercised consumer boundary. Action, notification, D200X, HID, and TOML implementation packages are deferred until a production use case requires them.

The Xcode build embeds the Go command as `Hidhogg.app/Contents/MacOS/hidhogg-runtime`. The distinct helper name is required because `Hidhogg` and `hidhogg` collide on the default case-insensitive macOS filesystem.

## Ownership boundaries

| Area | Responsibility | Excludes |
|---|---|---|
| HID spike | Transport feasibility and physical evidence | Production session architecture |
| Config spike | Lossless mutation and conflict behavior | Published configuration compatibility |
| Documentation | Verified facts, decisions, gates, and handoff | Unsupported hardware claims |
| Future device adapter | Device-specific discovery, protocol, rendering, and capabilities | GUI and shared action semantics |
| Go runtime | Runtime lifecycle and bounded local health/status service | Product actions, configuration, and HID access |
| SwiftUI client | Menu-bar status, runtime supervision, and local health client | Direct HID ownership and settings editing |
| Internal IPC | Versioned, bounded local messages and process health | Remote access and executable commands |
