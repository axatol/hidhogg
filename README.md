<p align="center">
  <img src="docs/product-redesign/logos/27-selected-serpent-padded.png" width="160" alt="HIDHogg gold serpent and control deck logo">
</p>

# HIDHogg

A native Swift macOS app for configuring **Logitech MX Master 3S** and **Ulanzi D200X** from one workspace. Existing Logitech connections can be associated over Bolt or direct Bluetooth; MX Master 4 has identity/status plus capability-gated wheel, button, SmartShift, haptic and panel settings. Target DPI V2 is read-only pending its write contract; independent host pointer speed is deferred. The mainline branch is `master`; acceptance is recorded per feature rather than claiming complete hardware compatibility. See the [LC-02 scope and hardware checks](docs/logitech-lc02-plan.md).

**Add Device → Logitech Mouse…** shows Bolt/Bluetooth options and existing mice on one centre-pane page. Add a verified existing mouse or pair through Bolt inline; the app saves and opens the device without a model-first placeholder or completion step. **Change Connection…** retains an existing registration's settings. New Bluetooth pairing remains unavailable. Offline checks and signing pass; native usability, receiver allocation, authentication and input continuity remain owner checks. See [compact setup](docs/logitech-compact-setup-plan.md) and [Bolt scope and assumptions](docs/logitech-bolt-pairing-plan.md).

One **Devices** list combines ready-to-pair Bolt results, verified Bolt/Bluetooth mice, Hidhogg-remembered registrations and stored receiver entries. Last-read rows stay visible during pairing; Unpair needs a fresh inspection and explicit confirmation. Receiver removal retains Hidhogg settings. Discovery temporarily enables only missing wireless/software-present notification bits, verifies setup, and uses guarded cleanup. The implementation is signed/offline verified; real discovery, flag restoration and input continuity remain owner checks. See [unified-list scope and evidence](docs/logitech-notification-discovery-plan.md).

Pairing candidates retain one identity across repeated discovery counters. Authentication highlights the current receiver-confirmed click, then the separate both-button confirmation. After a failed or uncertain attempt, **Refresh Devices** rechecks connections and receiver inventory before Add or an explicit retry; it does not resend Pair automatically. Offline tests and signing pass; physical pairing remains an owner check. See [recovery evidence and checks](docs/logitech-pairing-recovery-plan.md).

Discovery has an expandable **Discovery details** section with anonymous per-attempt event counts and native callback/filter counts, retained after timeout. The disclosure uses one adaptive view tree and loading follows pairing phases. The owner confirmed the reported MX4 discovery failure resolved after the researched device-kind correction; additional acknowledgment/error-detail hardening remains planned. See [discovery evidence](docs/logitech-discovery-regression-2026-11-02.md).

Custom card content uses consistent internal spacing. Logitech wheel mode decoding/change planning now lives in a shared `HIDPP2121V1` module; further model differences will use explicit feature-version adapters rather than copied controllers. The padding and first MX4 settings slice are signed/offline verified; physical write/readback/restoration still needs owner acceptance. [Plan and hardware roadmap](docs/padding-mx4-settings-plan.md).

## Current capabilities

- MX Master 3S Back and Forward shortcut bindings, with defaults for all apps and per-app overrides.
- Token-based shortcut editing with typed/pasted combinations, recording into an editable draft, and plain-text copying. Mouse assignments can send one left/right/middle click with modifiers; the owner has accepted the current behavior. [Editor and interchange](docs/shortcut-token-editor.md).
- Change Connection retains the mouse registration/settings when moving to a replacement Bolt receiver. Local shutdown is checked separately from old-device cleanup; unresolved cleanup remains visible until the same mouse is freshly verified. [Candidate verification and open crash investigation](docs/bolt-pairing-completion-crash.md).
- MX Master 3S vertical and thumb-wheel direction and custom scroll amount controls.
- MX Master 3S/4 capability-gated wheel/thumb settings, SmartShift and selective direct button assignments; MX4 haptic/panel pressure controls. Readback and owned restoration are verified offline; physical acceptance remains pending. [Checkpoint and DPI/pointer limits](docs/mouse-settings-milestone.md).
- Battery status, firmware information and optional low-battery notifications.
- A native device editor, menu-bar connection status, launch-at-login support and background operation.
- TOML configuration under `$XDG_CONFIG_HOME/hidhogg/` or `~/.config/hidhogg/`, automatic saving and manual reload.
- Bounded diagnostic activity with event IDs and source references.

Devices now have stable HidHogg registration UUIDs, with Add, Enable/Disable and Remove controls in the workspace. Sidebar and menu-bar entries follow the registry. Configuration uses a root registry plus versioned per-device TOML files; valid legacy configuration is migrated with an exact backup. Existing device settings, D200X actions/presets and image locations are preserved. Logitech registrations retain independent settings with one explicitly selected active backend; D200X and Flow Lite84 retain one registration each, and multiple generic Bluetooth monitoring entries are supported. Device filenames use the model family, stable registration UUID and a 12-character SHA-256 revision. Obsolete recognizable payloads are cleaned after successful publication; the original migration backup is retained. See the [registry plan and migration checks](docs/device-registry-plan.md).

Generic paired Bluetooth devices can be added through **Add Device → Paired Bluetooth Device** for connection and battery monitoring. Bluetooth permission is managed in Settings. Battery values come from macOS reports and, where needed, a strictly matched read-only registry fallback; component readings such as earbuds/case are retained. Cached data and unsupported device/schema coverage remain explicit. The generic monitoring path performs no nearby scanning, pairing, device connection or Logitech configuration. See [evidence and owner checks](docs/bluetooth-monitoring-plan.md).

Generic devices support optional low-battery alerts with a configurable threshold, connection indicators and device icons with a Bluetooth fallback. The menu-bar popover aligns battery values on the right and puts earbud/case readings on a second line. The menu-bar icon shows a connected/enabled device count, with ordinary disconnections neutral to an otherwise healthy status. Battery thresholds accept typing with a 200 ms debounce as well as the stepper. The sidebar/popover/count layout is owner-accepted; actual notification delivery and cached-data freshness remain owner checks. See [scope and verification](docs/menu-connection-count.md).

The D200X implementation includes one editable page, key/front-button/dial bindings, brightness 1–100, imported key images and title styling, automatic app profiles and complete tile presets. Tile Presets bundle display style and behavior, with icon-bearing defaults for all 16 supported action templates and inline configuration. Select a control and Choose Preset, or keep editing manually; a separate Actions-page creation step is unnecessary. Dial Rotation presets apply left/right together; press uses the tile-style picker. Presets apply as copies within the edited profile, and None clears the old assignment. Scripts provides reusable executable configuration and run history; built-in actions are configured through Tile Presets. Topic filters support a simple `*` wildcard; notification history has its own workspace page. Incremental updates and independent session maintenance remain. See [preset flow and verification](docs/d200x-preset-assignment-plan.md) and the [workspace decisions](docs/d200x-workspace-evolution-plan.md).

Device-wide controls now include seven built-in wide-display modes, 12/24-hour time and an explicitly applied custom screensaver image. Notifications can display an installed application's icon using optional `app_id` / CLI `--app-id`, with text fallback; static notification actions and presets retain it. The earlier [display/icon baseline](docs/d200x-display-controls-plan.md) passed206 independent offline checks; the current mode/retained-preview follow-up passed38 focused checks. Other physical appearance, metrics availability and screensaver persistence remain [owner checks](docs/d200x-parity-owner-checks.md). The [Now Playing spike](docs/d200x-now-playing-spike.md) is a synthetic prototype and provider investigation, not a live player integration.

The signed `dist/hidhoggctl` supports notification emission/clearing/history and named action invocation. See the [D200X owner checks](docs/d200x-parity-owner-checks.md) for commands, execution limits and verification.

Wide-tile device images render at 458×196; the owner has confirmed improved physical text rendering. The current sleep trial retains the D200X connection, pauses maintenance and sets transient brightness to zero, then restores brightness on wake. Its physical sleep behaviour remains an owner check.

Multiple physical pages, notification-payload passing into actions, multi-actions, remaining telemetry/screensaver controls, new direct Bluetooth pairing and MCP remain deferred or proposed. See the [roadmap](docs/roadmap.md) and [check-in preparation](docs/checkin-preparation.md).

The original [Lofree Flow Lite84](docs/lofree-flow-lite-feasibility.md) now has signed receiver-based read-only status: battery/charging/voltage, keyboard firmware and lighting/OS snapshots. Routine refresh omits the unreliable receiver-firmware query. Offline/background checks pass; a full initial receiver read and later two receiver-status reads succeeded. Physical/app acceptance, battery accuracy, receiver firmware and the current keyboard-online flag discrepancy remain open. See the [evidence and owner checklist](docs/flow-lite84-implementation.md). Lighting now uses icon-labelled effect choices and five-stop sliders, with 200 ms debounced application/readback and separate connection-local Undo controls. Mac/Windows mode also applies automatically after 200 ms. The lighting choices form a four-by-two grid including Off. See the [controls plan](docs/flow-lite84-system-mode-plan.md) for scope and first physical-write checks.

The keyboard follows Connect on launch and supports keyboard-activity-triggered battery refresh at most hourly, with no polling timer. Activity from any keyboard qualifies; key contents are not accessed. Manual Refresh still reads the full status. The activity feature passes offline checks; live monitoring and battery impact remain owner checks.

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


The latest screensaver controls include a temporary five-second deck preview and a retained, collapsible last-sent image. Wide-mode switching and retained preview have owner confirmation. Additive icon-and-text notifications, badge counts and MCP configuration/device-state tools are requested next work, not current capabilities.
