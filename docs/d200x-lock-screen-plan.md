# Lock Screen action — 1 November 2026

Owner approved only the Lock Screen action. Brightness, pages and multi-actions remain outside this implementation.

Provide a first-class `lock_screen` action in Actions → New Action and the normal named-action assignment picker. It has no editable execution parameters and uses the documented Control–Command–Q chord through the existing permission-checked shortcut sender. Selecting, creating or saving an action must not execute it. Explicitly running or triggering the saved binding requests screen locking; tests use fake input handlers only.

Keep domain validation/codec, native platform delivery and UI responsibilities separate. Preserve existing session and shortcut-delivery safety checks; no new shell command, private API, Automation permission or HID command is introduced. A newly saved kind cannot be read by older strict decoders that do not recognise it.

Necessary integration includes exhaustive labels/forms in the action chooser and tile preset editors. Existing metadata-only history retains the action ID/status/trigger; it must not infer historical action type from mutable current configuration.

- [x] Owner selects and approves Lock Screen only.
- [x] Strict action kind, UI template/editor and fixed shortcut execution.
- [x] Fake-input, validation/round-trip and action integration checks: 27 passed (16 XCTest + 11 Swift Testing), zero failures.
- [x] Signed app build and source manifests: strict app/CLI signatures pass; all 252 inputs match before/after tests/build.
- [ ] Owner triggers the action and checks actual Mac lock behavior.

[Apple keyboard shortcut reference](https://support.apple.com/en-us/102650) and [action catalog review](d200x-action-catalog-review-2026-11-01.md).

## Delivery evidence

Signed build `6dc189afc119e861954af37c693282a7cdecb72f1be3344888b6354cd4a9d21e`. Input manifest SHA-256 `108b03b326d239ea81fdf3bb41f48c931a2781c35d791e7b58af516562f72cd4`. Logs: `/Volumes/Data/tmp/DX-LOCK-focused-20261101.log`, `DX-LOCK-verification.json`, `DX-LOCK-postbuild.sha256`, `hidhogg-lock-screen-release-20261101.log`. The focused filter covers NativeAction and TilePreset cases and explicitly skips WakeConnectionTests/NativeWorkspaceWindowTests. The existing opt-in editor-render fixture now includes Lock Screen but was not run. Action chooser interaction is source-reviewed, not exercised in a live app. No actual lock, input event, app, permission prompt or device operation was performed.

Use **Actions → New Action → Lock Screen**, enter an action ID such as `lock-screen`, and save. Select the desired D200X tile/control, choose that saved action, then trigger it when ready to lock the Mac. This requests locking via the standard shortcut; no post-lock readback is claimed.
