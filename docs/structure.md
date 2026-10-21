# Structure

Updated 2026-10-19. Current implementation boundaries:

```text
app/                     new Swift package and native SwiftUI application
  Sources/HidhoggDomain/          configuration and binding value types
  Sources/HidhoggConfiguration/   bounded TOML codec and revision-aware file store
  Sources/LogitechBolt/           HID++ protocol, IOKit transport and session
  Sources/MacOSActions/           permissions, recording, shortcut and fixed-line scroll posting
  Sources/HidhoggApp/             menu-bar entry, singleton editor, immediate preferences, autosave and lifecycle
  Tests/                         injected configuration/session/action fixtures
scripts/build-app.sh     fixed-path arm64 Release packaging and signing
dist/Hidhogg.app          ignored local build product
docs/                    current overview, decisions and milestone index
docs/product-redesign/   preserved mock-ups, accepted logo and design history
docs/archive/v2/         prior docs, protocol/schema/examples and legal artifacts
spikes/                  preserved historical experiments
scripts/diagnostics/     preserved research tooling, not app dependencies
.agents/                 main-agent session log and handoff
```

Only the main agent updates `.agents/log.md` and `.agents/handoff.md`. Frozen Logitech experiments remain in the external LogiBridge checkout; the new app must not depend on their executable artifacts. Existing local Xcode metadata left under `macos/` is outside the active build and is not production source.

Ownership policy is per-device domain/configuration state, reconciled by AppModel and serialized by BoltController. Verified persistent wheel settings are distinct from incomplete-write rollback and temporary button interception. LoginItemController isolates native main-app registration from injected tests.

NX-06 adds optional wheel resolution to domain/TOML, one combined direction/resolution request through AppModel, and per-bit attribution in BoltController. BoltWheelStatus carries both observed fields; native DevicesView exposes the resolution picker. SmartShift remains deferred as NX-07#423.

NX-11 adds optional wheelScrollAmount intent/TOML, an injected ScrollSender with fractional accumulation, independent scroll admission/epochs and temporary routing ownership in BoltController, and an opt-in native amount control. Amount-only edits are host-side; no global event tap or new runtime process. See contract56–61.

NX08/09 adds typed ThumbwheelState in LogitechBolt, independent2150 events/admission/ownership inside the same controller, optional thumbwheel configuration, and a native Thumb wheel section. Separate sender instances share axis-selectable fractional delivery without sharing timestamps/fractions. Natural is the UI name for inverted direction.

NX12 adds one lock-protected BoltRequestIDLedger per transport, with identity-checked rotating leases and shared BoltRequestTransaction framing/correlation for native and fake requests. Controller reservations query that ledger; lifetime counters are removed.

NX13 adds DiagnosticCode/DiagnosticEvent and typed Bolt failure metadata; DiagnosticsStore projects semantic channels into bounded UI/Console entries. NX14 ApplicationInstanceBootstrap is the entry point before HidhoggApp/Model; ApplicationInstanceLease owns validated persistent descriptors, and RestartCoordinator isolates bounded ownership handoff. The MenuBarExtra label mounts workspace activation. NX15 NavigationPreset lives in domain; missing-file defaults stay separate from inert empty, with a focused AppModel+Navigation adapter and native preset menu. No new package target, helper or daemon.

NX18 MenuBarStatus maps transportphase/cleanupuncertainty to aggregate UI meaning; MenuBarStatusLabel owns native templatehead/originalcolordot composition, tooltip/VoiceOver and cached indicator bitmaps. MenuBarIcon owns the selected24x20pt cachedglyph. Runtime/discovery ownership is unchanged.

NX19 MenuBarIconStyle identifies two trialassets; MenuBarIcon produces singleoriginalcolorcomposites keyedbycurrentstyle/status/light-darkappearance. HidhoggApp holds transientstyle state passed to MenuBarView Picker and MenuBarStatusLabel. Resource staging hashes both newPNGs. No additional config/runtime/lifecycle ownership.

NX22 adds an app-owned WorkspacePresentationCoordinator and a tiny native window lifecycle bridge. The shared bootstrap requests regular activation before opening; the concrete window close observer requests accessory mode. No second runtime or persistent preference. Observer lifetime follows the coordinator, not SwiftUI bridge teardown; window captures are weak.
