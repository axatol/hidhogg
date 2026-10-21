# Handoff — 2026-10-21

## Accepted checkpoint

- Branch: `next/logitech-slice`.
- Application checkpoint: **6ce6b23** — accepted Logitech controls and macOS app lifecycle. Committed locally at the owner's request; no push.
- Fixed signed bundle: `dist/Hidhogg.app`, build **9e322504174b** (full `9e322504174bc1fc212a8e96e64d0d13261f51995891d4ad18869f215402bc92`).
- Signed executable SHA256: `d0b0b0096e61b101cdeedc55724d5d40047a5ec7f77128d72c0c5e73128a911d`.
- Final frozen suite: **316 passed** (182 XCTest +134 Swift Testing). Log `/Volumes/Data/tmp/hidhogg-nx22-tests.log`; SHA256 `733c1c40a438eba8755f66f4d502774407fab31e462c98b33581d83c24d3b575`.
- All82 source/resource manifest inputs still match the tested build. The checkpoint also includes the two required native accent asset-catalog JSON files and project evidence/design history.
- Signature/approved certificate, arm64/macOS26, resources, build identity and diff checks passed. No tests were rerun merely for check-in or roadmap documentation.

Owner confirms bindings/navigation, vertical and thumb-wheel amount, thumb direction, single-instance Restart and current wake behavior. Latest menu/window behavior accepted. Current dot is6.9pt in8pt slot with3pt gap. Launch-at-login UI shows Enabled without error; actual launch after login is untested. No live registration diagnostic remains necessary absent recurrence.

NX22 uses a single app-owned presentation coordinator: regular activation while workspace open, accessory on close, menu-only startup. Minimize/background does not close. Concrete-window close observer survives SwiftUI bridge teardown and retained-window reopen; replacement removes the prior observer and captures are weak. No device/runtime changes in NX22.

## Roadmap review and next action

TaskView Personal / HIDhogg project5 is authoritative. [Current index](../docs/roadmap.md), [ordered UI/D200X plan](../docs/d200x-roadmap.md).

1. **NX-M2 native UI alignment:** list67, milestone439. UI01#440 scope/mockup reconciliation → UI02#441 native Logitech workspace → UI03#442 Settings/alignment and owner checkpoint.
2. **NX-M3 D200X slice:** list66, milestone443. DX01#444 transport/identity → DX02#445 display → DX03#446 controls/actions → DX04#447 independent maintenance/reconnect. Later DX05#448 appearance/status, DX06#449 unresolved knob/encoder work.
3. TaskView dependency edges enforce **UI03 owner acceptance before DX01** and the UI milestone before D200X milestone. Neither implementation has started.

Recommended next action is **UI01 planning**, not immediate UI code. Read `docs/product-redesign/brief.md` and mockup README, map current functions against selected boards, and obtain a concrete code-plan approval. Native Swift components, accessibility and efficiency take priority over pixel matching. Notification history, device routing, shared actions and MCP engines are separately scoped future functionality.

D200X source: `/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/inventory.md`, rechecked through latest21Oct17:38 lifecycle addendum. Vendor/Python evidence is not Swift proof. Do not repeat accepted vendor manual cases. Native IOHID report convention, desired-page recovery and encoder applicability retain explicit gates. Roadmap entry does not authorize D200X source/device operations.

## Task reconciliation

- NX21#437 and NX22#438 accepted / Done.
- NX14#430 Restart, NX15#431 navigation and NX16#432 wake accepted / Done.
- NX17–20#433–436 closed as superseded, not retrospective acceptance of rejected/missing-dot designs.
- Thumb direction/amount and vertical amount are owner-confirmed; older broader tasks retain their residual lifecycle/resource scope. Remaining verification is not a blocker to UI planning.
- SmartShift#423 deferred; continuation#426 deferred after corrected inertia characterization. Wake speed unchanged unless it becomes a problem.

## Verification limits and workspace protection

No native app/HID/input/login/owner-process/configuration operation was performed during verification/check-in. Agent tests are injected; owner acceptance is distinct. Overnight CPU/memory, abrupt removal/crash restoration, other-mouse isolation, exceptional native failure recovery and boot login are not all established. Agree targeted depth before further testing.

Prior compile failure and intermittent thumb-wheel observer assertion are preserved in verification reports; the latter passed in the final run and is not declared fixed. Native build-system flag emits a deprecation warning. Scoped cache/build escalation was required for sandbox restrictions; do not inspect owner package authentication or environment.

Excluded local files remain untouched: `.envrc`, `.codex/`, `macos/` local metadata, diagnostic Python cache and `spikes/go-hid-d200x/d200xprobe`. Do not read sensitive configuration or broadly stage the checkout. No active workers or temporary menu-bar harness remain. No new project, native test or push is pending authorization.
