# Hidhogg overview

Status: M-02 config-driven D200X slice complete
Updated: 2026-08-26

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

The completed scaffold provides strict, bounded health/status IPC over an owner-only per-generation Unix socket. The SwiftUI supervisor attributes readiness to its launched runtime, drains bounded output tails, permits one restart, and applies deterministic TERM-to-KILL shutdown escalation. Product behavior and the public TOML schema remain deferred.

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

The direct Go runtime is the sole `M-02` execution surface. Swift supervisor wiring, SwiftUI editing, configuration watching, and lossless source mutation are deferred to later milestones. Opt-in verbose diagnostics record decoded input events and outbound D200X packets, but never raw HID paths, serial numbers, or unrelated device identities.

## Evidence policy

`UlanziDeckControl` is reference evidence only. Protocol facts may be independently reimplemented with provenance, but its product model and unverified hardware conclusions are not inherited. Automated tests, one-device observations, upstream claims, and hypotheses must be reported separately.

## Sources

- [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- [go-ctap/hid](https://pkg.go.dev/github.com/go-ctap/hid)
- [go-toml](https://github.com/pelletier/go-toml)
- [Microsoft JSONC parser](https://github.com/microsoft/node-jsonc-parser)
- [Tailscale HuJSON](https://github.com/tailscale/hujson)
- [Feasibility evidence](research.md)
