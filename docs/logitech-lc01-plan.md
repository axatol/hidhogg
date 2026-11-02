# LC-01 — UUID-scoped mouse state

Approved 1 November 2026. Isolate mouse settings and runtime ownership by registration UUID while preserving current persistence, bindings, enabled state and other devices. No discovery, new pairing, MX4 protocol writes or automatic hardware association.

- [x] Confirm existing singleton projection and runtime coupling.
- [x] Define a bounded integration seam and compatibility policy.
- [x] Implement UUID-targeted state and ownership without permitting ambiguous endpoint activation.
- [x] Verify old configuration preservation, disjoint settings, stale work and cleanup admission.
- [x] Build signed artifacts and document owner acceptance checks.

Both existing worktrees contain unrelated uncommitted changes. Preserve them; the earlier Bluetooth branch is a read-only reference. New mouse endpoint selection remains LC-02, so no implementation may infer a target mouse from registration order or name.

## Integration contract

Keep current manifest/payload persistence. Add explicit UUID projection/application; legacy projections refuse ambiguous mouse selection. Keep workspace as canonical draft and reproject the current selected UUID after saves/reloads. Existing single-mouse behavior remains compatible.

Retain one existing hardware backend with an explicit UUID ownership lease and invalidation epoch. Revoke admission before cleanup and retain cleanup uncertainty before reacquisition. Until LC-02 resolves endpoints, exactly one total mouse registration (including disabled records in the count) is required for activation. Additional records may be independently edited but cannot start ambiguous hardware management.

Input delivery, reconciliation, restoration and battery observation use owner settings rather than another editor selection. Route identity and delayed shortcut capture must include or verify the target registration. No automatic transfer when a record is disabled or removed.

## Owner acceptance after signed delivery

1. Open the updated app and confirm existing mouse settings, application bindings, enabled state and unrelated devices remain present.
2. With the original single registration, check its existing connection and configured wheel/button behavior. This is a physical acceptance check, separate from fake-backend tests.
3. Add another mouse registration. Confirm it is selected independently and management explains that endpoint selection is required; do not expect concurrent physical management in LC-01.
4. Give the two registrations different settings, switch between them and reopen the app. Confirm both retain their values.
5. Disable/remove a registration and confirm no other registration receives its settings or shortcuts. Discovery, model4 eligibility and actual association are later slices.

## Focused verification

Independent focused gate passed 69 XCTest cases: 23 registry/store checks and 46 app checks (device information 4, app integration 30, mouse isolation 7, presentation coordination 5). Evidence: `/Volumes/Data/tmp/hidhogg-lc01-focused.log`. The isolated cases cover a disabled second record at startup, shortcut editing without runtime activation, blocked saves across selection, stale work/status, successful cleanup and refusal when cleanup returns false even with a clean status.

Verification corrected an explicit-type inference error, two test compilation errors and obsolete singleton expectations and a real same-owner re-enable regression after successful sleep cleanup. Earlier attempt logs remain in `/Volumes/Data/tmp/hidhogg-lc01-focused-compile1.log`, `hidhogg-lc01-focused-compile2.log` and `hidhogg-lc01-focused-run1.log`. No assertions were removed to bypass the cleanup guarantee; clean fake sessions now explicitly confirm cleanup, with false-result refusal covered separately.

## Final delivery

LC-01 implementation is complete; owner hardware acceptance remains open. Final focused gate passes 58 XCTest checks. Full final-source gate passes 549 XCTest plus 322 Swift Testing tests (871 reported tests), zero failures, excluding `WakeConnectionTests` and `NativeWorkspaceWindowTests`. Logs: `/Volumes/Data/tmp/hidhogg-lc01-focused-final.log`, `/Volumes/Data/tmp/hidhogg-lc01-full-final.log`.

The broader gate caught and corrected independent input-generation handling; scroll/thumbwheel generations are validated by their own backend admissions, while UUID/epoch/timestamp fence ownership. Further corrections preserve global/deck editing with no selected mouse, prevent stale battery attribution, keep cleanup errors visible globally and normalize initial UUID sidebar selection. Regression cases cover these boundaries.

Signed app and CLI build `96deafbe8257702abf8b6de0e17fa097c4312c192a03f23b51151db2f8cb9c01` passes strict signature validation. Release log: `/Volumes/Data/tmp/hidhogg-lc01-release-final-20261101.log`. All 269 captured Swift/test/package/build-script inputs remain unchanged through final verification/build (`/Volumes/Data/tmp/hidhogg-lc01-inputs.json`). No production app launch, hardware commands, pairing, private configuration reads, commit or push. Existing dirty preset/scripts work remains preserved.
