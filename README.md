<p align="center">
  <img src="docs/product-redesign/logos/27-selected-serpent-padded.png" width="160" alt="HIDHogg gold serpent and control deck logo">
</p>

# HIDHogg

A native Swift macOS app for configuring **Logitech MX Master 3S over a Bolt receiver** and **Ulanzi D200X** from one workspace. The mainline branch is `master`; acceptance is recorded per feature rather than claiming complete hardware compatibility.

## Current capabilities

- Back and Forward shortcut bindings, with defaults for all apps and per-app overrides.
- Vertical and thumb-wheel direction and custom scroll amount controls.
- Battery status, firmware information and optional low-battery notifications.
- A native device editor, menu-bar connection status, launch-at-login support and background operation.
- TOML configuration under `$XDG_CONFIG_HOME/hidhogg/` or `~/.config/hidhogg/`, automatic saving and manual reload.
- Bounded diagnostic activity with event IDs and source references.

The D200X implementation includes one editable page, key/front-button/dial bindings, brightness 1–100, imported key images and title styling, automatic app profiles and independently editable tile presets. Named actions include media, volume, bell/sound, app/file/URL opening, deck notifications, shortcuts and custom executables. Actions, Tile presets and compact notification history have dedicated workspace pages. Topic filters support a simple `*` wildcard. It retains incremental updates and independent session maintenance. See the [workspace decisions and validation checklist](docs/d200x-workspace-evolution-plan.md) for current verification status.

The signed `dist/hidhoggctl` supports notification emission/clearing/history and named action invocation. See the [D200X owner checks](docs/d200x-parity-owner-checks.md) for commands, execution limits and verification.

Wide-tile device images render at 458×196; the owner has confirmed improved physical text rendering. The current sleep trial retains the D200X connection, pauses maintenance and sets transient brightness to zero, then restores brightness on wake. Its physical sleep behaviour remains an owner check.

Multiple physical pages, notification-payload passing into actions, multi-actions, wider telemetry/screensaver controls, Bluetooth transport, Lofree Flow Lite and MCP remain deferred or proposed. See the [roadmap](docs/roadmap.md) and [check-in preparation](docs/checkin-preparation.md).

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

The native Logitech and D200X implementation is maintained on `master`. The previous implementation is preserved at checkpoint `4b3248d` on `v2`.
