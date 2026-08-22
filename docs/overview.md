# Hidhogg overview

Status: feasibility investigation
Updated: 2026-08-22

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

## Provisional architecture

Architecture remains gated by `S-01` in [roadmap.md](roadmap.md):

```text
Pure-Go HID gate passes          Pure-Go HID gate fails
----------------------          -----------------------
Go runtime authority            Native Swift runtime authority
SwiftUI menu-bar client         SwiftUI menu-bar application
Unix-socket CLI API             Unix-socket CLI endpoint
```

In either result, device adapters expose capabilities rather than assuming every HID has displays. The D200X adapter exposes inputs, displays, and brightness. A future Flow Lite adapter would expose inputs, lighting, and on-device key mapping.

## Configuration direction

TOML passed the bounded `S-02` fixture suite and is the current provisional recommendation. Required GUI edits must preserve untouched comments, whitespace, ordering, and unknown fields byte-for-byte. The tested JSONC/HuJSON fallback did not satisfy that preservation contract. The owner has not yet declared a stable format.

```text
~/.config/hidhogg/
├── config.toml or config.jsonc
├── assets/
└── devices/
    └── desk-deck.toml or desk-deck.jsonc
```

The root file owns application settings and shared library metadata. Each device file owns its adapter selection, settings, one-page layout, notification filters, and stable library references.

## Evidence policy

`UlanziDeckControl` is reference evidence only. Protocol facts may be independently reimplemented with provenance, but its product model and unverified hardware conclusions are not inherited. Automated tests, one-device observations, upstream claims, and hypotheses must be reported separately.

## Sources

- [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- [go-ctap/hid](https://pkg.go.dev/github.com/go-ctap/hid)
- [go-toml](https://github.com/pelletier/go-toml)
- [Microsoft JSONC parser](https://github.com/microsoft/node-jsonc-parser)
- [Tailscale HuJSON](https://github.com/tailscale/hujson)
- [Feasibility evidence](research.md)
