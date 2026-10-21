# HIDHogg — Logitech-first rebuild

Approved 2026-10-19. Swift native, performant and efficient take precedence over pixel matching the mock-ups.

## Product goal

One macOS application configures multiple input-device types. The first vertical slice supports an already-paired Logitech MX Master 3S over Bolt, with Back and Forward keyboard-shortcut bindings, All apps defaults and per-application overrides. Local edits persist independently of connection; saved, connected, permission and applied states remain distinct.

Configuration uses an absolute nonempty `XDG_CONFIG_HOME` plus `hidhogg/config.toml`, falling back to `~/.config/hidhogg/config.toml` when unset, empty or relative. The implementation uses pinned swift-toml 2.0.0. Missing-file configurations default Back/Forward to named Page Back/Page Forward Command-bracket presets; existing files are preserved. Presets retain physical-key semantics and application/layout overrides. Startup loading, validated atomic autosaves and an explicit **Reload configuration** button are implemented; no filesystem watcher/hot reload. Valid editor changes apply while connected and save one second after the last edit. Disk persistence is separate from runtime application. Reload validates the entire candidate before replacing state; invalid or unsupported files preserve the last valid document and active preferences and produce an error. Resolve pending local edits before reload; detect external edits before saving. Previous TOML compatibility is not provided. See [implementation decisions](logitech-slice-contract.md) for limits and alternatives.

Owner requested in-app back/forward navigation after the foundation reset. Navigation history should restore the selected page, device, application context and control without discarding unsaved edits. Use standard macOS toolbar affordances; disable directions with no history. This is application navigation, separate from the mouse's configurable Back/Forward bindings.

## Architecture

One SwiftUI application owns device sessions and action delivery. A pre-SwiftUI bootstrap acquires a private per-user kernel lease before constructing AppModel; cooperative duplicate launches request the owner’s workspace and exit. Restart hands off only after verified cleanup and recovers only with ownership reacquired; brief process overlap is possible. Legacy running copies must be closed once when updating. A native menu-bar item is the entry point. Startup is menu-only; while the workspace is open, regular activation supplies Dock and native app-switcher presence. Closing the workspace restores accessory mode; minimizing or switching apps does not. Open Hidhogg opens or raises one workspace window; closing it leaves the same model/session running. Launch is menu-only, with no restored workspace. Native List/sidebar, Form, Picker, Button and sheets form the editor. A Logitech transport module uses session-scoped discovery and serialized requests; no separate receiver-owning daemon or reused D200X coordinate model. Device discovery makes one attempt after valid initial configuration loading when Connect on launch is enabled (default on), including Restart. Explicit Connect remains available after failure or when disabled. Optional Launch at login registers this same app through SMAppService.mainApp; macOS owns its status. Discovery reconciles current preferences. Action delivery requires configured shortcuts and permission. Wheel inversion and input resolution are independent of keyboard permission. Optional Custom scroll amount captures this mouse’s wheel and posts fixed line events with permission; a 0.25–10× vertical multiplier is independent of device resolution. It adds no acceleration or momentum; application behavior remains a physical acceptance gate. Temporary wheel routing is always released on orderly stop, separately from retained physical preferences. The Scroll section offers optional Low/High input resolution and last verified readback; absent preference leaves resolution unchanged. Direction and resolution share a serialized native mode transaction. Device resolution does not guarantee application animation behavior. Hidhogg owns its configured wheel preference: verified direction changes remain after Disconnect/Quit by default. Optional per-device restoration returns attributable changes to the connection baseline; temporary button interception is always released when shortcut handling stops. Firmware persistence across power cycles is unverified. Edits made while disconnected are saved for the next explicit connection. Disconnect/sleep do not reconnect automatically.

Thumb-wheel direction and fixed amount use their own0x2150 state, admission and sender; existing configs leave them unmanaged. Custom thumb-wheel amount uses raw-count horizontal line output and requires posting permission; native direction-only changes do not. No claim of exact Options+ acceleration or gestures.

Request IDs rotate and are reusable after exact successful completion; uncertain requests retire theirs and cleanup capacity remains reserved. No lifetime15-request allowance or silent reconnection.

Use event-driven observation, bounded queues/history and explicit cancellation. Do not introduce idle UI polling. Measure resource use in the actual app before claiming efficiency.

## Build and delivery

One arm64 macOS 26+ Swift application. The fixed local output is `dist/Hidhogg.app`, bundle identifier `com.hidhogg.app`. Use the established local Apple Development identity; do not silently fall back to ad-hoc signing. The old compiled app was explicitly retired. No automatic app launch or permission requests during builds.

## Scope and gates

The approved reset/foundation is NX-01. Physical Back/Forward support follows fresh capability discovery, focused protocol work and explicit owner-run hardware gates. Back has bounded prior evidence; Forward remains unvalidated. Preserve existing Logitech frozen spikes externally; do not mutate them or import diagnostic executables into production.

Pairing, Bluetooth transport, gestures, SmartShift wheel modes/automatic-switch threshold (NX-07#423), further scrolling controls beyond thumb-wheel direction/amount, other devices, notification log and MCP are deferred after the first slice. They remain product requirements, not cancelled work.

## Evidence

- [Design decisions and mock-ups](product-redesign/brief.md); visual suggestions are not native-component guarantees.
- [Rebuild decisions](rebuild-decisions.md).
- [LogiBridge current handoff](/Users/axatol/Workspace/hans-m-song/logibridge/docs/handoff.md), reviewed 2026-10-19: bounded transport/Back/app/wheel observations, incomplete full acceptance.
- [Historical v2 archive](archive/v2/README.md); previous source checkpoint `4b3248d` on `v2`.

Settings Recent Activity is left-aligned, bounded and traceable by stable codes plus the same event ID/build/source in Console. [Diagnostic catalog](diagnostics.md) and [current verification](workspace-verification.md) describe error privacy, ownership and native acceptance limits.

## Ordered future milestones — 2026-10-21

NX-M2 aligns existing capabilities with the selected mockups using native Swift components. Owner UI acceptance is a prerequisite for NX-M3 D200X implementation alongside Logitech. These remain planned work, not a started device migration. [Scope and research gates](d200x-roadmap.md).
