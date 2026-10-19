# HIDHogg — Logitech-first rebuild

Approved 2026-10-19. Swift native, performant and efficient take precedence over pixel matching the mock-ups.

## Product goal

One macOS application configures multiple input-device types. The first vertical slice supports an already-paired Logitech MX Master 3S over Bolt, with Back and Forward keyboard-shortcut bindings, All apps defaults and per-application overrides. Local edits persist independently of connection; saved, connected, permission and applied states remain distinct.

Configuration uses an absolute nonempty `XDG_CONFIG_HOME` plus `hidhogg/config.toml`, falling back to `~/.config/hidhogg/config.toml` when unset, empty or relative. The implementation uses pinned swift-toml 2.0.0. Startup loading, validated atomic saves and an explicit **Reload configuration** button are implemented; no filesystem watcher/hot reload. Successful UI saves update memory. Reload validates the entire candidate before replacing state; invalid or unsupported files preserve the last valid document and produce an error. Resolve unsaved drafts before reload; detect external edits before save. Previous TOML compatibility is not provided. See [implementation decisions](logitech-slice-contract.md) for limits and alternatives.

Owner requested in-app back/forward navigation after the foundation reset. Navigation history should restore the selected page, device, application context and control without discarding unsaved edits. Use standard macOS toolbar affordances; disable directions with no history. This is application navigation, separate from the mouse's configurable Back/Forward bindings.

## Architecture

One SwiftUI application owns device sessions and action delivery. Native List/sidebar, Form, Picker, Button and sheets form the editor. A Logitech transport module uses session-scoped discovery and serialized requests; no separate receiver-owning daemon or reused D200X coordinate model. Device discovery starts only after Connect; action delivery requires explicit enablement and permission.

Use event-driven observation, bounded queues/history and explicit cancellation. Do not introduce idle UI polling. Measure resource use in the actual app before claiming efficiency.

## Build and delivery

One arm64 macOS 26+ Swift application. The fixed local output is `dist/Hidhogg.app`, bundle identifier `com.hidhogg.app`. Use the established local Apple Development identity; do not silently fall back to ad-hoc signing. The old compiled app was explicitly retired. No automatic app launch or permission requests during builds.

## Scope and gates

The approved reset/foundation is NX-01. Physical Back/Forward support follows fresh capability discovery, focused protocol work and explicit owner-run hardware gates. Back has bounded prior evidence; Forward remains unvalidated. Preserve existing Logitech frozen spikes externally; do not mutate them or import diagnostic executables into production.

Pairing, Bluetooth transport, gestures, advanced scrolling, other devices, notification log and MCP are deferred after the first slice. They remain product requirements, not cancelled work.

## Evidence

- [Design decisions and mock-ups](product-redesign/brief.md); visual suggestions are not native-component guarantees.
- [Rebuild decisions](rebuild-decisions.md).
- [LogiBridge current handoff](/Users/axatol/Workspace/hans-m-song/logibridge/docs/handoff.md), reviewed 2026-10-19: bounded transport/Back/app/wheel observations, incomplete full acceptance.
- [Historical v2 archive](archive/v2/README.md); previous source checkpoint `4b3248d` on `v2`.
