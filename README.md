<p align="center">
  <img src="docs/product-redesign/logos/27-selected-serpent-padded.png" width="160" alt="HIDHogg gold serpent and control deck logo">
</p>

# HIDHogg

A native Swift macOS app for configuring HID devices from one place. The accepted implementation supports **Logitech MX Master 3S over a Bolt receiver**. A native **Ulanzi D200X** first slice is implemented on `next/d200x-slice` and awaits hardware validation.

## Current capabilities

- Back and Forward shortcut bindings, with defaults for all apps and per-app overrides.
- Vertical and thumb-wheel direction and custom scroll amount controls.
- Battery status, firmware information and optional low-battery notifications.
- A native device editor, menu-bar connection status, launch-at-login support and background operation.
- TOML configuration under `$XDG_CONFIG_HOME/hidhogg/` or `~/.config/hidhogg/`, automatic saving and manual reload.
- Bounded diagnostic activity with event IDs and source references.

The D200X slice adds one editable page, key/side-button/dial shortcuts, incremental image updates and independent session maintenance. See its [implementation decisions and validation checklist](docs/d200x-implementation-plan.md) for current limits.

Bluetooth transport, Lofree Flow Lite, notification history and MCP support remain planned. See the [roadmap](docs/roadmap.md) for scope and verification gates.

## Build and run

Requires **Apple Silicon, macOS 26+**, an Xcode toolchain supporting Swift 6.2 or later, and a development-signing identity. Xcode does not need to be open.

```sh
bash scripts/build-app.sh --signing-identity YOUR_SIGNING_IDENTITY
open dist/Hidhogg.app
```

The signed app is built at the fixed path `dist/Hidhogg.app`. Grant the input permissions shown in Settings before using shortcut delivery or custom scroll amounts. Notification permission is separate and requested when enabling battery alerts.

See [build and signing instructions](docs/build.md) for cache paths, packaging and permission details. Build output is ignored by Git; builds do not launch the app or access devices.

## Project documentation

| Topic | Reference |
|---|---|
| Architecture and scope | [Overview](docs/overview.md) |
| Milestones and follow-ups | [Roadmap](docs/roadmap.md) |
| Modules and source layout | [Structure](docs/structure.md) |
| Diagnostic events | [Diagnostics](docs/diagnostics.md) |
| Design and mock-ups | [Design brief](docs/product-redesign/brief.md) |
| Device information and battery alerts | [Implementation plan and verification](docs/device-information-plan.md) |
| Historical implementation | [D200X/v2 archive](docs/archive/v2/README.md) |

The accepted checkpoint is on `master`; D200X implementation is on `next/d200x-slice`. The previous implementation is preserved at checkpoint `4b3248d` on `v2`.
