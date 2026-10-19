# M-02-F04 owner verification: Mac display power

> Retired v1 runbook (2026-10-18): the procedure below describes the Go runtime. The V2-V01 gate used a simulated D200X and did not verify physical host sleep/wake. Preserve these steps as historical evidence, not current Swift acceptance instructions. Current verification limits are in [v2-plan.md](v2-plan.md).


Status: offline implementation tests and independent source review passed on 2026-09-26; physical D200X behavior remains unverified.

This checks macOS **display power-off/on**, not Lock Screen by itself. Locking the Mac is sufficient only if its displays subsequently sleep. Do not run a separate Go-only instance against the same D200X while testing the bundled Swift app.

1. Back up the TOML currently selected in Hidhogg Settings. Set the top-level `idle_timeout_seconds = 0` and save it. This disables Hidhogg's separate five-minute dimmer; the fixed 50-second firmware keepalive remains active. Do not change the configured `brightness` solely for this test.
2. Launch Hidhogg from Xcode and wait for `Health: ready`. With the Mac display awake, confirm the current D200X profile is visible and remains visible for more than five minutes.
3. Let the Mac display power off using the normal system setting or your usual method. Observe whether the D200X goes dark. Record whether you merely locked the Mac or confirmed the Mac display itself powered off.
4. Wake the Mac display. Confirm that the D200X restores the active profile, configured brightness, and input response. If an overlay was present before sleep, record whether it remains on the correct tile. Use a harmless configured input for this check.
5. Quit Hidhogg normally. Record any menu error and Xcode log around a failed transition. Report the visible result separately for display-off, wake redraw, brightness, and input; do not infer a pass from a successful IPC reply alone.

Optional: while the Mac display is asleep, turn an encoder once and note any transient brightness flash. Firmware has previously restored brightness on encoder rotation even when host brightness was zero; the runtime attempts one zero-brightness reassertion, but no-flash behavior is not established by offline tests.

Limits: a HID write already in progress before host-off admission cannot be preempted. A physical input selected before Go applies display-off can still run its configured action; input suppression begins when the idle-policy owner applies that state. An uncertain write fail-stops that Go process; the Swift supervisor retains its owner-approved single restart, so a replacement generation may send startup packets. Direct Go-only launches do not receive Swift-observed display state and retain the prior idle policy.
