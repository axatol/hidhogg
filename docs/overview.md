# Hidhogg overview

Status: v1 remains the implemented Go-owned runtime; the owner approved a pure Swift v2 migration on 2026-10-02. No v2 production runtime implementation is claimed here.
Updated: 2026-10-02

## Goal

Hidhogg is a personal-use macOS 26+ utility for local HID integrations. Version 1 targets one Ulanzi D200X and one configured page. A future adapter may support Lofree Flow Lite key mapping, macros, and lighting; that device is not part of version 1.

Hidhogg is configuration-driven. The runtime watches for external edits and retains the last-known-good state after invalid or conflicting changes. The GUI currently supports typed profile creation, label editing, and conservative deletion; broader position/action editing remains M-10 work.

## Product model

- Physical HID inputs run statically configured local actions.
- A local CLI emits display-only notifications containing a source, text, and optional lifetime.
- Tiles filter notifications by source and retain the newest match until expiry, CLI clearing, or physical selection.
- Selecting a notification dismisses it and runs the tile's statically configured action.
- A shared library provides stable references to source artwork and executable-plus-argument actions.
- Inbound events cannot provide or invoke executable commands.

## Selected architecture

The owner selected a Go runtime authority with a SwiftUI menu-bar client and Unix-socket CLI API on 2026-08-24:

```text
SwiftUI menu-bar client
           |
      Unix socket
           |
 Go runtime authority
           |
  Device adapters
```

Reconnect reliability is an accepted implementation assumption, while repeated-cycle reliability remains unverified.

For the `M-01` scaffold, the SwiftUI app launches and supervises the Go runtime. Packaging work may later replace this with a separately managed process, but `launchd`, login-item installation, signing, and distribution are outside `M-01`.

The SwiftUI app uses strict, bounded IPC over an owner-only per-generation Unix socket. The supervisor attributes readiness to its launched runtime, drains bounded output tails, permits one restart, and applies deterministic TERM-to-KILL shutdown escalation. Go owns the production D200X runtime, strict TOML schema, discovery, profiles, executable press actions, execution history, transactional reload, local notification overlays, and typed source mutations. Swift owns foreground-app mappings and the profile editor UI. M-09-B lifecycle and M-10-A1 tile-label owner verification passed on 2026-10-01.

## Approved v2 target

The current implementation remains v1. The approved v2 target moves runtime, strict TOML v4 configuration, source editing, D200X handling, profiles, actions, notifications, IPC, and device lifecycle into Swift. The native macOS app will own the runtime and device; a Swift CLI will provide status and notification operations. The existing Go implementation remains the parity reference until independent v2 acceptance passes. Go removal follows that gate. The v2 plan and TaskView direct-ID map are in [v2-plan.md](v2-plan.md); the exact v1 roadmap is preserved in [v1-roadmap.md](v1-roadmap.md).

The first v2 configuration foundation is the standalone, dependency-free SwiftPM library at `macos/HidhoggCore`, targeting macOS 26. It strictly decodes schema v4 into immutable normalized profiles and the deterministic 14-position layout. Its vendored strict TOML engine is extended locally for TOML 1.1; the decoder preserves explicit-field presence during validation and reports safe diagnostics with complete field paths. Syntax/type and unknown-key locations use UTF-8 byte columns; semantic, missing-key, and schema-version diagnostics use `0:0`. This package is not yet wired into the app or CLI, so Go remains the production configuration owner. The independent unit suite passed 30/30 and the pinned current-source TOML 1.1 corpus passed with no failures or skips; detailed counts and provenance are in [v2-plan.md](v2-plan.md).

The editor scope includes existing button appearance, actions, and notification sources. Custom assets, the proposed Go log tail, and split profile files are deferred. Offline acceptance runs the native macOS app with a simulated D200X; it does not use a real device, selected configuration, existing owner app, or native input injection. No v2 production runtime implementation is claimed until its TaskView tasks pass their gates.

Every Xcode-built app embeds the required Go runtime as `Contents/MacOS/hidhogg-runtime`; it does not search `PATH` or depend on `/usr/local/bin`. The application delegate starts that runtime eagerly at application launch and coordinates asynchronous cleanup before normal termination.

Device adapters expose capabilities rather than assuming every HID has displays. The D200X adapter exposes inputs, displays, and brightness. A future Flow Lite adapter would expose inputs, lighting, and on-device key mapping.

## Configuration direction

TOML passed the bounded `S-02` fixture suite and was selected by the owner on 2026-08-24. Required GUI edits must preserve untouched comments, whitespace, ordering, and unknown fields byte-for-byte. The tested JSONC/HuJSON fallback did not satisfy that preservation contract. No public configuration schema has been declared.

```text
~/.config/hidhogg/
├── config.toml
├── assets/
└── devices/
    └── desk-deck.toml
```

The root file owns application settings and shared library metadata. Each device file owns its adapter selection, settings, one-page layout, notification filters, and stable library references.

`M-02` introduced a milestone-private, versioned single-file schema to prove the Go runtime's first physical vertical slice. Its original format required all 14 D200X display positions and rejected unknown fields. This does not replace the planned root/device configuration model; migration to that broader model remains explicit future work.

`M-10-F01` implements compact schema v4: keyed profiles and coordinates, omitted blank tiles, strict explicit values, and a complete deterministic runtime layout. Existing selected files are preserved and require explicit conversion; earlier schema versions are deliberately rejected. Offline Go/Swift gates and independent review pass; owner physical acceptance remains pending. See [the contract and migration guide](compact-config-v4.md).

The Go runtime loads strict TOML, owns D200X display/input/brightness policy, exposes profiles and bounded executable-action history, and transactionally reloads external edits through an immutable effective snapshot. A private lossless adapter and exact-digest store now support typed profile label/clone/delete edits; the SwiftUI editor invokes those operations without owning TOML writes. Opt-in verbose diagnostics record decoded input events and outbound D200X packets, but never raw HID paths, serial numbers, or unrelated device identities.

`M-03` adds direct-Go discovery through one caller-owned, owner-only runtime directory. A persistent advisory lock coordinates cooperating runtimes; strict generation metadata becomes visible only after IPC binding, device initialization, and serving readiness. The controller revalidates directory, lock, metadata, socket, peer UID, and generation attribution around each discovered call. Explicit socket and instance arguments mode remains temporarily available for Swift supervision and deterministic tests.

`M-04` adds named profiles and atomic full-page activation. `M-05` adds press-only built-in profile activation and bounded asynchronous executable actions with immutable submission data and read-only execution history. `M-06` adds manual and automatic transactional reload: the runtime prepares a complete immutable candidate, serializes required writes with profile activation, applies brightness and idle settings through the existing policy owner, and publishes one atomic effective revision only after success. The watcher observes the explicit file's parent directory so direct and atomic-save edits are supported; invalid pre-write candidates retain the last-known-good runtime state.

`M-05-F01` originally introduced schema v3; its source layout is superseded by M-10-F01's [compact v4 format](compact-config-v4.md). Action `gesture = "press"` executes once on initial down and ignores release; `gesture = "release"` requires a matching prior down with an unchanged binding and is the default when omitted. Duplicate downs do not retrigger. Profile/reload transitions cancel pending actions while held-key state prevents accidental rearming; idle-wake gestures remain consumed. Earlier configuration versions are rejected rather than translated.

`M-05-F02` adds native `type_text` and Enter-only `key_press` actions through purego/CoreGraphics, with 16 waiting slots plus one active action. The native FIFO does not change executable admission. Runtime-owned permission checking/requesting, `input.status`, and read-only `doctor` use IPC; startup/status/doctor never prompt or post test input. History is metadata-only and distinguishes posting from verified delivery. The owner approved deploy migration and confirmed numpad and permission/status/doctor functionality on 2026-09-18; automatic and architecture gates pass. Scenario-specific observations and lifecycle limits are qualified in `native-input-decisions.md`; owner commands are in `native-input-runbook.md`.

`M-07` implements local `notifications.emit/clear` and discovery-aware CLI commands. Optional schema-v3 `notification_sources` select active-profile tiles; bounded text overrides their labels until replacement, optional TTL expiry, clearing or tile-local physical selection. The existing coordinator composes full-page updates over an immutable configured baseline. Changed profile/configuration transitions clear overlays; unchanged/rejected reloads preserve them. Selection authorizes only static configured actions after successful dismissal. As of 2026-09-19 implementation, independent whole-tree automatic, final architecture, and owner physical gates pass. Dimmed emission did not wake or brighten the owned D200X; manual wake retained the overlay and the next selection dismissed only its tile. See `m07-notification-plan.md` and `m07-notification-runbook.md` for limits and verification.

`M-02-F01` adds bounded owner-run diagnostics and an isolated one-frame `d200xprobe` research CLI. These surfaces measured brightness-zero input, firmware-screensaver wake packets, and captured small-window modes without broadening the experimental outbound-command surface. The selected production policy uses a fixed 50-second `0x0002` keepalive and an optional `idle_timeout_seconds` setting that defaults to 300; zero disables application dimming without disabling keepalive. On idle the runtime sets brightness to zero, then restores configured brightness and consumes the first complete known physical gesture. Automatic and bounded owner-present physical gates passed on 2026-09-03.

`M-02-F04` adds a Swift-app-only host display-power observer. Documented macOS screen sleep/wake notifications and an initial Core Graphics state query feed a generation-bound `display.host_state.set` request to Go. The Go idle-policy owner darkens on display sleep, suppresses dark-state actions, and restores the latest effective profile, notification overlay, configured brightness, and input stream on wake. A pending host-off request is serialized against reload brightness writes; a write already in flight cannot be preempted. The fixed keepalive continues. The owner must set top-level `idle_timeout_seconds = 0` in the selected TOML to disable Hidhogg's separate application dimmer. Direct Go-only launches retain the prior policy. Offline Go and Swift tests pass; physical display sleep/wake remains unverified. This follows display power, not Lock Screen alone. See [owner verification](m02-f04-host-display-runbook.md).

## Evidence policy

`UlanziDeckControl` is reference evidence only. Protocol facts may be independently reimplemented with provenance, but its product model and unverified hardware conclusions are not inherited. Automated tests, one-device observations, upstream claims, and hypotheses must be reported separately.

## Sources

- [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- [Apple NSWorkspace screen sleep notification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification)
- [Apple NSWorkspace screen wake notification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification)
- [Apple Core Graphics display sleep query](https://developer.apple.com/documentation/coregraphics/cgdisplayisasleep%28_%3A%29)
- [go-ctap/hid](https://pkg.go.dev/github.com/go-ctap/hid)
- [go-toml](https://github.com/pelletier/go-toml)
- [Microsoft JSONC parser](https://github.com/microsoft/node-jsonc-parser)
- [Tailscale HuJSON](https://github.com/tailscale/hujson)
- [Feasibility evidence](research.md)
