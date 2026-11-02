# LC-02 — Existing-device association and basic MX Master 4

Approved 1 November 2026: select an already-paired Logitech mouse among Bolt receivers/slots or direct Bluetooth, persist verified hardware association against its current Hidhogg UUID, reconnect automatically to that association, and include basic MX Master 4 compatibility. No new pairing, firmware, haptics or movement gestures.

- [x] Confirm approved scope and inspect current LC-01 boundaries and earlier research.
- [x] Add optional association/model metadata and explicit preferred runtime UUID without changing existing settings or payload paths.
- [x] Add bounded read-only endpoint catalog/probe and unique identity resolution over Bolt/Bluetooth.
- [x] Add existing-device selection UI, saved association, startup/reconnect matching and actionable absent/ambiguous state.
- [x] Support MX4 identity/battery/firmware/capability reporting without requiring the 3S V5 control path; refuse unevidenced writes.
- [x] Verify synthetic identity/selection/persistence/lifecycle invariants; signed delivery; document manual owner checks.

Hardware identity uses feature 0003 unit/model/transport evidence; zero/missing/conflicting identity never authorizes settings. Slot, name and current OS handle are locators. Primary corroboration: [Solaar get_ids](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp20.py) reads unit bytes 1–4, model bytes 7–12 and transport mask byte 6. Both local research reports remain authoritative evidence indexes, with their hardware limitations.

Keep the LC-01 backend/lease ownership and current content-addressed payload transactions. Save association before admitting writes. New receiver/transport handles require fresh identity and capabilities, but should match the saved mouse rather than ask the owner to choose again. Never automatically adopt another mouse or unpair anything. Generic monitoring preferences must remain intact.

One active managed Logitech backend remains the LC-02 boundary; concurrent management is LC-06. Preferred registration is explicit and independent of editor selection. Additional registered mice retain independent settings; choosing another active target must complete cleanup first. A read-only MX4 connection is a valid basic result even where specific control writes remain unsupported.

The chooser displays model, transport and a stable eight-character SHA-256 fingerprint of the verified unit/model identity. The fingerprint is a selection aid, not an authentication mechanism or physical receiver/slot number; full validated identity remains the matching authority. Inventory does not add battery/firmware requests just to populate the chooser.

No agent-operated device inventory, identifier reads, HID writes, real pairing or production app launch. Owner operates the signed app for hardware verification. Preserve both dirty worktrees; port selected transport concepts instead of merging the earlier tree wholesale.

Verified 1 November 2026: app source compiles; focused synthetic gate passes 216 checks; full offline gate passes 908 checks (568 XCTest + 340 Swift Testing), zero failures. The full command excludes the existing WakeConnectionTests and NativeWorkspaceWindowTests suites; those exclusions are not counted as passes. Source review and tests cover persisted ownership, no implicit adoption, exact identity resolution, rollback capacity, queued-operation cancellation and same-target uncertain-cleanup recovery. Selector and cross-owner switching remain strict. Signed app/CLI build `13f26bd284bf2948b9eb241e2d5803e05ebf1aeb7b986e86d08b5108d4653649` verifies, CLI help exits successfully, and all 289 captured source/test/build inputs remain unchanged. Physical hardware acceptance remains pending; source is uncommitted on `master`.

Current logs: `/Volumes/Data/tmp/hidhogg-lc02-focused.log`, `/Volumes/Data/tmp/hidhogg-lc02-full.log`, `/Volumes/Data/tmp/hidhogg-lc02-release-20261101.log`. Input manifest: `/Volumes/Data/tmp/hidhogg-lc02-inputs.json`. Delivery: `dist/Hidhogg.app` and `dist/hidhoggctl`.

## Owner verification after signed delivery

1. With both Bolt receivers attached, associate the intended existing MX Master 3S connection. Verify its settings, then restart Hidhogg with Connect on launch enabled: it should resolve the saved identity without asking again.
2. Disconnect and reconnect that mouse. Confirm saved scroll direction and button behaviour return. An absent mouse must not cause another mouse to be adopted.
3. Where available, repeat existing-device association over direct Bluetooth. Changing the saved transport is an explicit association operation; no new OS or Bolt pairing is created by this slice.
4. With an MX Master 4 available, associate its existing connection and refresh information. Verify battery, firmware and read-only capability information where reported. Input/wheel settings must remain unavailable for this basic compatibility slice.
5. Disable or remove the preferred registration with another mouse configured. Confirm no other mouse is automatically selected or controlled.

Synthetic verification cannot establish physical identifier stability, correct native HID interface eligibility on every receiver variant, battery/firmware availability on an untested MX4, or owner acceptance of native presentation. Those remain hardware checks.

The native catalog currently recognizes Logitech vendor `046D`, Bolt receiver product `C548`, and direct Bluetooth products `B034` (MX3S) / `B042` (MX4), with strict HID++ descriptor checks. Other product variants, including an unconfirmed USB-C receiver ID or MX4 Business Bluetooth ID, are not inferred from their names. They require verified descriptor/protocol evidence before widening the allowlist.
