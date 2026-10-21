# NX-05 — wheel and immediate-preferences verification

Updated 2026-10-20. Device-side vertical inversion for the already-paired MX Master3S/Bolt slice now applies automatically while connected, including alongside keyboard bindings. No Save or Apply button is required. Optional `wheel_inverted` remains nil=unmanaged,false=standard,true=reversed; verified settings remain applied on Disconnect/quit by default; optional restoration returns attributable changes to the connection baseline. Button interception is always released. Keyboard permission is independent.

## Current evidence

Independent frozen-source package gate: **188 tests passed**, zero failures (111 XCTest +77 Swift Testing). Log: `/Volumes/Data/tmp/hidhogg-resolution-independent-passed.log`. Earlier runtime-specific gate52 included native15-ID fixtures with8–12 capability rows, enabled wheel changes, retained wheel ownership on button Disable, cleanup uncertainty and cancelled/stale operations. Full details and gaps: [main verification](logitech-verification.md).

Current signed `dist/Hidhogg.app`: arm64/macOS26+, `com.hidhogg.app`, startup build `0d561b8fb66a`, executable SHA256 `4287ed1da2117539880f068975df58966902585d6a5990d220bb560bb1cd1c1e`. Deep/strict signature and established certificate fingerprint verified; native accent/icon/notices present. Source remains uncommitted pending owner acceptance. Earlier explicit-Apply checkpoint111/111 and buildba856da1f948 are superseded by this correction.

Current NX-06 adds optional Low/High reporting and per-bit wheel ownership. [Current resolution evidence and two checks](resolution-verification.md).

## Quick owner check

1. Close old copies and competing mouse software; launch the updated menu-bar app, choose Open Hidhogg from the serpent menu, and inspect the startup connection result; use Connect if disabled or unsuccessful.
2. Choose Standard/Reversed and scroll immediately, including while button shortcuts are active. Stop editing for one second; disk status should become Saved.
3. Disconnect with restoration off: direction should remain. To check opt-in restoration, reconnect, enable the toggle, change direction and disconnect; it should return to that connection baseline. [Detailed current checks](ownership-verification.md).

No physical production-device operation or frozen experiment rerun occurred. [Prior bounded research](/Users/axatol/Workspace/hans-m-song/logibridge/docs/research/wheel-v6-success-2026-10-19.md) supports the protocol path, not production acceptance. Unsupported/diverted wheel modes fail closed. Request IDs remain finite per handle; repeated changes may require deliberate reconnection. Ownership/readback safeguards and cleanup reserve remain. Physical direction/isolation, receiver removal, crashes, contention and real idle resources remain owner gates. Restart process exit is also unverified in the native app because the isolated probe failed before AppKit callback.
