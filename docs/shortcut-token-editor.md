# BIND-01 — unified shortcut editor

Approved 2 November 2026. DPI writes stay deferred. Replace the manual key/modifier picker with a token editor for a single keyboard or mouse combination. Record, type, picker and paste edit one draft; only Apply persists it. No literal-text delivery, sequences, drag/hold or macros in this slice.

## Checklist

- [x] Owner approves token buttons, recording into the draft and plain-text copy/paste.
- [x] Preserve existing keyboard configuration; add validated mouse-click bindings.
- [x] Share canonical interchange: `${cmd}+${mouse.left}`, `${ctrl}+${shift}+C`.
- [x] Add modifier chips, searchable key/mouse picker, typing, recording and copy.
- [x] Keep application/device capture-session fencing and explicit Apply/Cancel.
- [x] Test parsing, persistence, delivery pairs/permission failures and recording without live input.
- [x] Review, run offline gate and build/sign without launching or issuing live input.
- [x] Owner accepts current behavior and requests local check-in (2 November 2026).

## Offline verification checkpoint

Source review is clear after correcting mode-selection capture presentation, static helper/type qualification and SwiftUI expression complexity. Focused suites pass 63 XCTest plus 15 Swift Testing cases. The first layout pass exposed clipped recording instructions and a wide legacy Form label column at 460 points; wrapped capture drawing plus a grouped full-width form correct both. The final targeted capture/layout pass is 6/6, with eight hidden/non-key synthetic images at 460/720 × 700. Parent inspected six representative final images. These fixtures do not present the production sheet or validate actual toolbar interaction.

Full offline gate passes 1,125 cases (660 XCTest + 465 Swift Testing), with only the existing `WakeConnectionTests|NativeWorkspaceWindowTests` exclusions. All 342 frozen inputs match before/after the full run. The completed test exec session exited zero; a separate broad process-list check was unavailable in the tester sandbox, so no claim about unrelated running processes is made. Final full log: `/Volumes/Data/tmp/hidhogg-bind01-full.log`.

Signed delivery: `dist/Hidhogg.app` and `dist/hidhoggctl`, build `bff106c775aa8d2e53cf62cc6b4735742d20832e7d64297bd845ef0d308a64eb`. App deep/strict signature, CLI strict signature and CLI help pass. All 342 frozen hashes still match after signing; release log `/Volumes/Data/tmp/hidhogg-bind01-release.log`. No agent launch/input/device action occurred. Owner reports the current behavior looks good and works well, and explicitly requests local check-in on 2 November 2026. That acceptance does not enumerate every key/layout/transport combination. Local check-in is authorized; no push.

Initial compiler failures and the initial cache-sandbox failure are retained separately under `/Volumes/Data/tmp/hidhogg-bind01-*`; no runtime failure or hardware result is inferred from those failures. The frozen input manifest currently lists 342 files, SHA-256 `6b7c29390bdb221473e643425bcf8f5cdd6e40a909cde1935f4db84ca24cd76b`. No production app launch, live input event posting, private configuration/log/HID capture or device write was performed for this slice.

Mouse delivery creates one down/up pair at the current cursor position with the same modifiers. Recording captures only events addressed to the focused capture surface; the Record button's initiating click is outside that surface. Existing D200X keyboard-only editor callers retain their supported output type. Public macOS Core Graphics supplies mouse events and flags; physical application behavior remains an owner check.

## Editing and interchange

Choose a mouse control and select Shortcut. Record opens the same editor in recording mode; Choose Manually opens it for typing or picking. Modifier buttons work before or after choosing a key/mouse trigger. Chips can be removed independently. Record replaces the local draft, and Copy Shortcut exports its canonical text; neither saves nor executes it. Apply is disabled for incomplete or invalid combinations. Cancel keeps the saved assignment. Switching device/application/editor scope invalidates stale completion callbacks.

| Plain text | Meaning |
|---|---|
| `${cmd}+C` | Command plus the C key |
| `${ctrl}+${shift}+C` | Control/Shift plus C |
| `${cmd}+${mouse.left}` | Command plus one left click |
| `${option}+${mouse.right}` | Option plus one right click |
| `${mouse.middle}` | One middle click |
| `${keycode.24}` | Physical key-code fallback |

Text is Hidhogg interchange, not shell expansion or a universal application syntax. Modifiers are canonicalized; one trigger and unique modifiers are required. Stable physical key names and explicit fallback codes avoid punctuation ambiguity; displayed labels follow the keyboard layout captured when the editor opens. Literal text/escaped dollar strings are not interpreted as text output in this shortcut-only editor. Existing keyboard TOML stays unchanged. New mouse bindings use `kind = "mouse_shortcut"` and a strict `mouse_shortcut` payload; older binaries do not understand that new kind.

## Owner checks

After reopening the signed app, choose Thumb button → Shortcut → Choose Manually. Select Command and Left click, Copy Shortcut, and paste into another binding editor; check the same chips appear. Cancel once and Apply once. Record a keyboard combination and a modified click in the capture area; check they populate the field without saving. Finally apply Command-left-click and try the physical thumb button in an application with an established Command-click behavior. No physical delivery claim follows from offline test success.
