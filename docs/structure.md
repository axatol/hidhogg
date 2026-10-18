# Repository structure

Status (2026-10-18): V2-V01 passed independent unit and simulated-app acceptance on commit `08a44f8`. The V2-X01 candidate passed its source/removal audit, 99/99 source-integrity check, post-removal tests, ARM64 production builds, and controlled simulated-app smoke. The first full Core run had one assertion failure of unconfirmed cause; a focused rerun and later full run passed. Physical hardware, native input injection, and isolated cold launch remain unverified. Evidence and scope qualifications are in [v2-plan.md](v2-plan.md).

Platform: macOS 26+ on Apple Silicon (`arm64`) only. Intel is unsupported in Debug, Test, and Release configurations.

## Current layout

```text
hidhogg/
├── .agents/              main-owned durable decisions and session handoff
├── api/protocol/v1/      retained v1 wire specification and fixtures
├── docs/                 current architecture plus preserved v1 history/research
├── macos/
│   ├── HidhoggCore/      Swift configuration, edits/store, D200X, runtime, IPC, CLI, and tests
│   ├── Hidhogg/          native SwiftUI application and app lifecycle
│   └── HidhoggTests/     app, client, and controlled lifecycle tests
├── schema/               retained TOML v4 schema artifact
├── scripts/diagnostics/
│   ├── README.md         notice for retired Go diagnostic entry points
│   └── ulanzi-lldb/      preserved static LLDB research utilities
└── spikes/               preserved research artifacts only
    ├── config-editing/   README, JSONC/TOML fixtures, and results.json
    ├── go-hid-d200x/     README
    └── go-native-input/  README
```

The Go runtime, CLI, source modules, and Go diagnostic wrappers have been retired from this candidate. The tracked Go-named spike artifacts are preserved as research material and are not production build inputs. The exact v1 roadmap, protocol reference, renderer font/provenance, and research notes remain for historical context. V1 Go commands in those records describe the retired implementation and are not current operating instructions.

## Current ownership

| Area | Responsibility | Boundary |
|---|---|---|
| `macos/HidhoggCore` | Strict TOML v4 decoding, typed lossless edits, digest-guarded source storage, D200X protocol/session/simulation, rendering, runtime policy, actions, notifications, IPC, discovery, and Swift CLI | No Go production dependency; app-owned runtime composition is in `Hidhogg` |
| `macos/Hidhogg` | Native SwiftUI app, runtime/device lifecycle, settings UI, and generation-owned IPC server composition | Uses simulated D200X for offline app acceptance; no physical-device claim |
| `macos/HidhoggTests` | App lifecycle, client, protocol, editor, and simulation checks | Does not establish physical HID or native-input delivery |
| `api/protocol/v1` | Retained wire-protocol specification and fixtures | Historical contract reference; not a Go implementation |
| `scripts/diagnostics/ulanzi-lldb` | Preserved static preflight and temporary evidence helpers | Separate authorization gate; does not launch or attach to the application |
| `spikes` | Preserved tracked README, fixture, and result evidence | No tracked spike executable or Go module remains in the candidate |
| `docs/v1-roadmap.md` | Exact archived v1 roadmap | Preserved unchanged |

V2-V01 acceptance used 206 Core tests, 152 app tests, and the controlled native macOS app with simulated D200X. Save/reopen, conflict, row/action editing, reset, reload, and cleanup checks passed. The test and GUI gate did not use physical hardware or native input injection. The full report is [`/Volumes/Data/tmp/hidhogg-v01-final-acceptance-20261018.md`](/Volumes/Data/tmp/hidhogg-v01-final-acceptance-20261018.md).

V2-X01's independent source/removal audit and final verification passed. TaskView project 5, list 49 remains authoritative for migration task status; the task map and detailed acceptance evidence are in [v2-plan.md](v2-plan.md).
