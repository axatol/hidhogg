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

Production application directories are intentionally absent until the architecture and configuration gates are resolved.

## Ownership boundaries

| Area | Responsibility | Excludes |
|---|---|---|
| HID spike | Transport feasibility and physical evidence | Production session architecture |
| Config spike | Lossless mutation and conflict behavior | Published configuration compatibility |
| Documentation | Verified facts, decisions, gates, and handoff | Unsupported hardware claims |
| Future device adapter | Device-specific discovery, protocol, rendering, and capabilities | GUI and shared action semantics |
| Future runtime | Configuration authority, event routing, actions, and adapter lifecycle | Device-specific framing |
| Future SwiftUI client | Menu-bar status and common-field edits | Direct HID ownership in a Go-core design |
