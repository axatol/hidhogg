# Add Device mock-up — 1 November 2026

Approved scope: unified existing-device and new-pairing entry, Bolt receiver selection, Bluetooth discovery, authentication, verification and completion; include existing Bluetooth battery monitors and already-added/cancel/timeout/no-receiver paths.

Prototype: `/Volumes/Data/tmp/hidhogg-pairing-mockup/index.html`. Open this self-contained file in a browser, or use `http://127.0.0.1:8769` while the local preview server is running. The Chrome preview tab was left open for review. Expand Preview scenarios for direct entry to recovery cases.

All state is simulated and memory-only. No radio scans, pairing, device access or configuration writes. Bolt challenges remain placeholders pending research. Receiver capacity is explicitly synthetic. Cancellation text acknowledges that an actual OS/receiver bond might complete before cancellation and must be reconciled without automatic unpairing.

The Bluetooth happy path was clicked through to simulated registration in Chrome; its completion adds and selects the mock mouse in the sidebar. The initial page was visually reviewed. Other scenarios are implemented but have not received equivalent interactive verification. No production app changes or build were made for this mock-up. Visual acceptance and final pairing API/protocol details remain open.

## Native flow follow-up — 1 November 2026

Owner confirmed the existing Bolt mouse now appears after the SDK enum correction, but prefers this mock-up's flow to the LC-04 native implementation. This confirms list visibility only, not successful association/reconnect or new physical pairing.

Historical native differences before the compact revision: Add Device selects a model and creates its registration before pairing (`WorkspaceView.swift`, `AppModel.addDeviceAndPair`); existing-device association and pairing use separate sheets. The mock-up instead starts with Existing device / Pair new device, discovers candidates before registration, includes review/already-added handling, and ends with completion plus Open Device/Add Another Device.

Owner approved the revision and requested fewer steps: show Bolt/Bluetooth immediately after choosing Logitech. The implemented centre-pane overview combines existing mice with inline Bolt pairing, stages registration until verified save, then opens the device automatically. Reassociation preserves saved settings. New Bluetooth pairing remains visibly unavailable. No completion screen is required. See [current scope and verification](logitech-compact-setup-plan.md). The simulated prototype remains design evidence only, not hardware proof.
