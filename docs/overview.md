# HIDHogg overview

Updated 28 October 2026. This describes the current native implementation; dated implementation reports retain their original evidence.

## Product

One macOS application configures Logitech MX Master 3S over a Bolt receiver and Ulanzi D200X, and reads Lofree Flow Lite84 status through its receiver. The workspace, menu-bar item and local CLI share the same in-process model and device sessions. Hardware acceptance is recorded per feature; an implemented feature is not automatically a claim of complete device compatibility.

## Architecture

~~~text
Native workspace / menu
          |
       AppModel ----- ConfigurationDocument / ConfigurationStore
          |                 validated TOML + atomic autosave
          |
          +-- BoltController -------- Logitech HID++ / IOHID
          |
          +-- FlowLite84Model -------- read-only FlowLite84Session / IOHID
          |
          +-- D200XModel ------------- D200XSession / IOHID
                 |
                 +-- Automation coordinator -- private local socket -- hidhoggctl
                 |
                 +-- Action runner ------------ native actions / executable
~~~

AppModel owns the canonical editable configuration, navigation and application lifecycle. Each device owns its transport and connection state. UI selection never owns a connection. Editing an application profile is distinct from the foreground application's active runtime profile.

Configuration is resolved from an absolute nonempty XDG_CONFIG_HOME or the standard home configuration location. Loading, revision-aware atomic saving, one-second edit debounce and explicit reload are implemented. Invalid or externally changed files do not silently replace valid state. No filesystem watcher is used. Swift TOML is pinned to 2.0.0 in the package manifest.

## Logitech ownership and recovery

The controller discovers capabilities, reclaims recognised temporary routing and verifies state before delivery. Persistent direction/resolution preferences are separate from temporary button and wheel interception. Vertical and horizontal amount controls use independent host-side accumulation and permission checks.

Connection intent survives unexpected loss and failed discovery. One retry coordinator caps its delay at 30 seconds; fresh discovery verifies routing and reapplies current settings. Explicit Disconnect or Cancel Reconnect clears intent. Sleep suspends Logitech recovery until wake. Unknown or malformed state keeps delivery inactive. [Recovery contract and owner checks](logitech-reconnection.md).

## D200X workspace and automation

The D200X implementation has one editable page, mapped key/front-button/dial controls, incremental image updates, application profiles, imported images, title styling and independent portable presets. Actions and notification history have dedicated workspace pages. The selected-control inspector assigns shortcuts or named actions; device-wide settings stay in the central device pane.

Named actions have static validated parameters: media, volume, bell/sound, application/file/URL opening, deck notifications, shortcuts and custom executables. The process and native lanes have bounded queues and metadata history. Executables receive literal argument values and an empty environment; the app does not interpolate notification text into commands.

The same-user Unix socket and CLI share validation and routing. Notification subscriptions use case-sensitive topics with a simple * wildcard. The opt-in live listener keeps bounded text in memory; persistent diagnostics/history omit message content. No external broker or network listener is required.

D200X maintenance uses periodic GETBASE while active. The approved sleep trial retains the handle, pauses maintenance and writes transient brightness 0. Wake resumes maintenance and restores the configured brightness, or 100 when unset. This is separate from the proposed idle-dimming and lock/screensaver policies, which are not implemented.

Wide device images render directly at 458×196 using the accepted logical layout; app previews remain separate. The owner reports improved physical rendering. Ulanzi's SDK documents that encoder display canvas, but one-to-one mapping of the wide-key image path is not independently established. [Decisions and validation](d200x-workspace-evolution-plan.md).

## Native application and permissions

A per-user kernel lease prevents cooperative duplicate owners. Restart hands off after cleanup; the menu-only process exposes Dock and app-switcher presence while its workspace is open. Closing the workspace leaves the device sessions running.

Settings is one scrollable page. Accessibility and Notifications have compact permission rows and shared app-drag, Refresh and Restart controls. Authorization never silently enables battery alerts. Permission requests and platform effects require explicit user actions.

## Delivery and evidence

The active package targets Apple Silicon and macOS 26+, with Swift tools 6.2. The build script signs a fixed-path Hidhogg.app and adjacent hidhoggctl without launching either or operating devices. Build output and provenance are local ignored artifacts.

Use [the roadmap](roadmap.md) for current scope, [the structure](structure.md) for module ownership, and [check-in preparation](checkin-preparation.md) for the frozen review/test record. Pairing, Bluetooth, firmware installation, vendor plugins/cloud, physical multi-page support and notification-payload execution are outside the current implementation boundary.


Seven built-in wide modes and clock format, static installed-app icon notifications, explicit screensaver image upload and temporary preview are implemented. The last sent screensaver JPEG is retained locally behind a collapsed preview. The owner confirmed the latest wide-mode/retained-preview follow-up working on28October2026; other hardware gates remain separate. Now Playing is a synthetic feasibility spike, not a production reader. Additive icon/text, badges and MCP are the requested next slice and are not implemented.

## Device registry — 31 October 2026

REG-01 replaces fixed device-list composition with UUID registrations and per-device payload files coordinated by a root schema2 registry. Legacy schema1 configuration is backed up before migration publication. The existing strict aggregate remains an editor projection; registry membership/enabled state independently gates runtime activity. Existing native adapters still manage one endpoint per supported family. No new Bluetooth discovery or hardware commands are included. See [registry plan](device-registry-plan.md) for storage transactions, limitations and verification.
