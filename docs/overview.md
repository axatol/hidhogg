# Hidhogg overview

Status: M-06 and descriptive owner-local configuration diagnostics complete; startup reassertion fix planned
Updated: 2026-09-11

## Goal

Hidhogg is a personal-use macOS 26+ utility for local HID integrations. Version 1 targets one Ulanzi D200X and one configured page. A future adapter may support Lofree Flow Lite key mapping, macros, and lighting; that device is not part of version 1.

Hidhogg is configuration-driven. The GUI edits common fields immediately, the runtime watches for external edits, and invalid or conflicting changes must not replace the last-known-good runtime configuration.

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

The SwiftUI scaffold provides strict, bounded health/status IPC over an owner-only per-generation Unix socket. The supervisor attributes readiness to its launched runtime, drains bounded output tails, permits one restart, and applies deterministic TERM-to-KILL shutdown escalation. Direct-Go milestones now own the production D200X runtime, strict TOML schema, discovery, profiles, executable press actions, execution history, and transactional reload; broader notification behavior and SwiftUI configuration editing remain deferred.

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

`M-02` introduces a milestone-private, versioned single-file schema solely to prove the Go runtime's first physical vertical slice. It requires all 14 D200X display positions and rejects unknown fields. This does not replace the planned root/device configuration model; migration to that broader model remains explicit future work.

The direct Go runtime remains the active execution surface while SwiftUI product work is deferred. It loads the explicit strict TOML, owns D200X display/input/brightness policy, exposes profiles and bounded executable-action history, and transactionally reloads external edits through an immutable effective snapshot. Lossless source mutation and SwiftUI editing remain deferred. Opt-in verbose diagnostics record decoded input events and outbound D200X packets, but never raw HID paths, serial numbers, or unrelated device identities.

`M-03` adds direct-Go discovery through one caller-owned, owner-only runtime directory. A persistent advisory lock coordinates cooperating runtimes; strict generation metadata becomes visible only after IPC binding, device initialization, and serving readiness. The controller revalidates directory, lock, metadata, socket, peer UID, and generation attribution around each discovered call. Explicit socket and instance arguments mode remains temporarily available for Swift supervision and deterministic tests.

`M-04` adds named profiles and atomic full-page activation. `M-05` adds press-only built-in profile activation and bounded asynchronous executable actions with immutable submission data and read-only execution history. `M-06` adds manual and automatic transactional reload: the runtime prepares a complete immutable candidate, serializes required writes with profile activation, applies brightness and idle settings through the existing policy owner, and publishes one atomic effective revision only after success. The watcher observes the explicit file's parent directory so direct and atomic-save edits are supported; invalid pre-write candidates retain the last-known-good runtime state.

`M-02-F01` adds bounded owner-run diagnostics and an isolated one-frame `d200xprobe` research CLI. These surfaces measured brightness-zero input, firmware-screensaver wake packets, and captured small-window modes without broadening the experimental outbound-command surface. The selected production policy uses a fixed 50-second `0x0002` keepalive and an optional `idle_timeout_seconds` setting that defaults to 300; zero disables application dimming without disabling keepalive. On idle the runtime sets brightness to zero, then restores configured brightness and consumes the first complete known physical gesture. Automatic and bounded owner-present physical gates passed on 2026-09-03.

## Evidence policy

`UlanziDeckControl` is reference evidence only. Protocol facts may be independently reimplemented with provenance, but its product model and unverified hardware conclusions are not inherited. Automated tests, one-device observations, upstream claims, and hypotheses must be reported separately.

## Sources

- [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- [go-ctap/hid](https://pkg.go.dev/github.com/go-ctap/hid)
- [go-toml](https://github.com/pelletier/go-toml)
- [Microsoft JSONC parser](https://github.com/microsoft/node-jsonc-parser)
- [Tailscale HuJSON](https://github.com/tailscale/hujson)
- [Feasibility evidence](research.md)
