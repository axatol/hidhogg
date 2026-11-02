# LC-07 — Bolt receiver inventory and explicit unpair

Approved on 1 November 2026. The full receiver blocks the owner's new MX Master 4 pairing acceptance; that pairing remains unverified. Add an expandable receiver inventory to Logitech setup, with readable stored-device labels and per-slot Unpair confirmation. Preserve Hidhogg registrations and settings separately. Notification-icon follow-up remains deferred.

- [x] Confirm scope and preserve the current 958-case signed checkpoint.
- [x] Review ownership, stale-target fencing and receiver protocol evidence.
- [x] Implement all-slot inventory and verified explicit unpair transaction.
- [x] Integrate setup-panel confirmation and lifecycle cleanup.
- [x] Run synthetic regressions, independent offline gate and signed build.
- [ ] Owner checks inventory labels and explicitly selects any real unpairing, then retries MX Master 4 pairing.

```text
Logi Bolt receiver                         6 / 6 used
  Slot 1   MX Master 3S    Connected       Unpair…
  Slot 2   MX Master 4     Offline         Unpair…
  Slot 3   Unknown device  Offline         Unpair…
```

Only an explicit confirmed row authorizes a selected-slot command. Names are presentation, not identity. Re-read the complete inventory before mutation and reject stale/replaced targets. After dispatch, acknowledgement alone is insufficient: verify the selected bond disappeared and every other bond remains unchanged. Timeout/loss means uncertain outcome, not success or automatic retry. Never reset a receiver, remove another slot or automatically unpair as rollback. Hidhogg settings are retained.

Discovery, settings management, pairing and inventory/removal must share exclusive receiver ownership and lifecycle barriers. Navigation, sleep, shutdown and reload revoke pending confirmations/commands; an admitted command must drain and reconcile without being reissued. Temporary pairing identifiers stay out of diagnostics and persistence. No live device reads/writes, private configuration/log inspection or production app launch are authorized for agent verification in this slice.

Protocol evidence: [receiver name/record reads and selected-slot unpair](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/receiver.py#L461-L493). B5 selectors read all supported slots; C1 action 3 identifies a single slot. Source evidence establishes the bounded operation, not Hidhogg/macOS physical success. Existing UNKNOWN_DEVICE-as-empty inference and C548 six-slot profile limits remain as recorded in [pairing scope](logitech-bolt-pairing-plan.md).

Foundational source: `BoltReceiverProtocol`, `LogitechEndpointCatalog`, `BoltPairingSession`, `AppModel` setup/pairing lifecycle, and `LogitechSetupView`. Architecture/ownership contract was reviewed before implementation. Root owns documentation and integration decisions; workers must preserve the broad dirty main worktree.

## Implementation contract

Use a standalone `BoltReceiverManaging` interface and `BoltReceiverManagementSession` actor; leave the pairing implementation untouched. Inventory exposes opaque snapshot/row IDs, display labels, slot and reachability, with stable record identity retained only inside the actor. The UI submits snapshot/row tokens, never a raw slot authorization. A dedicated operation gate prevents actor reentry from admitting overlapping transactions. Close revokes unwritten authority and drains admitted work before releasing the native handle.

Outcomes distinguish verified removal plus fresh inventory, definite non-removal/refusal, and uncertainty after possible dispatch. A register timeout poisons the current transport lane; require a fresh session for Refresh instead of resending. Pre/post comparisons exclude reachability flags so a device going offline does not masquerade as a different bond. All other stable records must match.

The native HID open is not exclusive across applications. Another program could change a receiver slot between preflight and the slot-addressed command; this protocol offers no atomic compare-and-remove. Hidhogg can serialize its own operations, reject stale snapshots and verify the resulting inventory, but cannot eliminate that external-writer race. Physical behaviour remains unverified.

Ownership: backend worker owns new actor/types and backend synthetic tests; integration worker owns AppModel/factory/lifecycle and integration tests; root owns SwiftUI receiver/row confirmation views, documentation, integration and signing. Independent verification follows source freeze. No live receiver operation is part of agent verification.

## Delivered evidence — 1 November 2026

Independent focused gate: 58 cases pass (45 XCTest +13 Swift Testing). Full offline gate: 978 cases pass (605 XCTest +373 Swift Testing), zero failures, excluding the existing `WakeConnectionTests` and `NativeWorkspaceWindowTests` suites. Seven new AppModel tests cover snapshot authority/settings retention, receiver switching, cleanup/scan/pairing exclusion, uncertain refresh, paused-preflight navigation/sleep revocation, and late results across Refresh. Thirteen backend tests cover stable all-slot reads, offline records, invalid records, optional names, stale/duplicate tokens, exact post-diff, timeout poisoning, receiver switching, and cancellation/close drain.

Review corrected close-before-drain ordering, reuse of original receiver handles across selection, and late-result UI fences before source freeze. Paused preflight tests use a dispatch-capable outcome and prove close occurs before resuming, with no write afterward. Verified removal clears the stale full-receiver message; it retains all Hidhogg registrations/settings and never auto-pairs or reconnects.

Signed app/CLI build `5d6e183c00cb98d4679cd8162c478f507c9d15f75b6278c91046a1b677cd772c` passes strict signatures and CLI help; all311 source/test/build hashes match. Logs: `/Volumes/Data/tmp/hidhogg-lc07-{focused,full,release}.log`; manifest `/Volumes/Data/tmp/hidhogg-lc07-inputs.json`; current metadata ignored `dist/build-info.json`. Source remains uncommitted on master; no push.

No native app launch or live receiver read/write was performed for LC-07. Owner must inspect the panel's labels and explicitly choose any real Unpair operation, verify the freed slot and input continuity, then retry new MX Master4 pairing. Physical unpairing, post-unpair empty-record semantics and new pairing remain unverified. The notification-icon issue remains deferred.
