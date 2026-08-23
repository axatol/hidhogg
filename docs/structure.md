# Repository structure

Status: production scaffold planning
Updated: 2026-08-24

```text
hidhogg/
├── docs/                 product, architecture, roadmap, and evidence
├── .agents/              durable decisions and session handoff
└── spikes/               disposable feasibility programs and fixtures
    ├── go-hid-d200x/     cgo-free D200X transport investigation
    └── config-editing/   lossless TOML and JSONC comparison
```

Production application directories remain absent until `M-01-P01` freezes the scaffold contracts.

The authorized `M-01` scaffold will introduce the following boundaries after `M-01-P01`:

```text
hidhogg/
├── api/
│   └── protocol/          internal IPC contract fixtures and specification
├── cmd/
│   ├── hidhogg/           Go runtime entry point
│   └── hidhoggctl/        local CLI entry point
├── internal/
│   ├── ipc/               local transport and message handling
│   └── runtime/           orchestration and lifecycle
├── macos/
│   └── Hidhogg/           SwiftUI menu-bar Xcode project
└── spikes/                    retained feasibility evidence
```

Config and device ports will be declared only at an exercised consumer boundary. Action, notification, D200X, HID, and TOML implementation packages are deferred until a production use case requires them.

## Ownership boundaries

| Area | Responsibility | Excludes |
|---|---|---|
| HID spike | Transport feasibility and physical evidence | Production session architecture |
| Config spike | Lossless mutation and conflict behavior | Published configuration compatibility |
| Documentation | Verified facts, decisions, gates, and handoff | Unsupported hardware claims |
| Future device adapter | Device-specific discovery, protocol, rendering, and capabilities | GUI and shared action semantics |
| Future runtime | Configuration authority, event routing, actions, and adapter lifecycle | Device-specific framing |
| Future SwiftUI client | Menu-bar status and common-field edits | Direct HID ownership in a Go-core design |
| Internal IPC | Versioned, bounded local messages and process health | Remote access and executable commands |
