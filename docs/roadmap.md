# Roadmap

Reviewed 2026-10-21. TaskView Personal / HIDhogg project **5** owns task status, criteria and dependencies. This file is the current index; earlier verification reports retain the chronological evidence.

## Accepted checkpoint

Local commit **6ce6b23** on `next/logitech-slice` contains the accepted Logitech application checkpoint. Signed app: `dist/Hidhogg.app`, build **9e322504174b**. Final frozen suite: **316 passed**, zero failures. Source/resource hashes match that verified build; no push has been made.

The current functional baseline is usable and owner-accepted. This does not establish every failure, resource-soak or boot-login case. Older broad acceptance tasks remain open only for their documented residual scope; they do not block UI planning.

| Area | Stable IDs / TaskView | Current evidence |
|---|---|---|
| Native foundation and TOML/XDG configuration | NX-01 / 417; NX-02 / 418 | Complete |
| Back/Forward bindings, native editor, immediate application and autosave | NX-03 / 419; NX-04 / 420 | Owner reports working; broader acceptance/resource cases remain |
| Vertical direction and input resolution | NX-05 / 421; NX-06 / 422 | Implemented and tested; retain specific physical comparison limits |
| Thumb-wheel direction and amount | NX-08 / 424; NX-09 / 425 | Both owner-confirmed; apparent amount defect was excessive baseline multiplier |
| Vertical scroll amount | NX-11 / 427 | Owner-confirmed working |
| Reusable HID++ request IDs | NX-12 / 428 | Regression-tested; extended physical-use evidence remains limited |
| Traceable Recent Activity | NX-13 / 429 | Implemented; visual refinement can be checked during UI alignment |
| Single-instance Restart and native navigation | NX-14 / 430; NX-15 / 431 | Accepted / Done |
| Sleep/wake reconnection | NX-16 / 432 | Accepted / Done; current latency acceptable for now |
| Permission-aware menu status and window-dependent Dock/⌘Tab | NX-21 / 437; NX-22 / 438 | Accepted / Done |
| Launch at login | Part of existing startup work | Owner sees Enabled without error; actual login launch untested |

NX-17–20 / tasks433–436 are closed as **superseded historical icon work**. Rejected or missing-dot designs are not retrospectively accepted.

Current evidence: [window presentation](workspace-presentation-verification.md), [menu status and login follow-up](status-and-registration-followup.md), [thumb wheel and request IDs](thumbwheel-verification.md), [vertical amount](scroll-amount-verification.md). [Acceptance boundaries](logitech-acceptance.md).

## Next: NX-M2 — Native UI alignment

TaskView **list67**, milestone **439**. Use the selected device-workspace mockups as a visual reference, with native Swift components, accessibility and efficiency taking precedence over pixel matching.

| Stable ID | TaskView | Deliverable | Dependency |
|---|---|---|---|
| UI-01 | 440 | Reconcile mockups with current capabilities; agree screens, states and implementation boundary | Accepted NX22 |
| UI-02 | 441 | Device sidebar/workspace and current Logitech control editor | UI-01 |
| UI-03 | 442 | Settings, permissions and diagnostics alignment; signed checkpoint and owner acceptance | UI-02 |

Preserve per-app inheritance, outlined full-area control selection, connection dots beside status text, gold accents, immediate application/autosave and visible errors. Identify mockup-only Actions, notification history and MCP capabilities as separate functional work; do not imply those engines already exist or silently include them in visual alignment.

**Recommended next action:** UI-01, followed by a concrete implementation plan for review. No UI redesign implementation has started.

## Then: NX-M3 — D200X functional vertical slice

TaskView **list66**, milestone **443**. **UI-03 owner acceptance blocks DX-01**; TaskView dependency edges record this order.

| Stable ID | TaskView | Deliverable | Dependency |
|---|---|---|---|
| DX-01 | 444 | Native bounded transport, correct HID collection and identity | UI-03; reviewed interface |
| DX-02 | 445 | One page and incremental display update | DX-01 |
| DX-03 | 446 | Mapped controls and representative configured native action | DX-02 |
| DX-04 | 447 | Independent GETBASE maintenance, reconnect and focused Swift acceptance | DX-01–03 |
| DX-05 | 448 | Later brightness, fonts, wide status/telemetry and optional screensaver | DX-04; separate feature plans |
| DX-06 | 449 | Resolve knob/encoder evidence gaps before implementation | DX-04; further evidence |

Deliver D200X alongside Logitech in the **same app**, with device-specific transport and controls. Research vendor/Python acceptance is not Swift proof. Preserve the latest 2026-10-21 research lifecycle results without repeating accepted vendor tests. No D200X code or hardware work has started. [Research basis, scope and gates](d200x-roadmap.md).

## Deferred and follow-up work

- **SmartShift:** NX-07 / 423 remains deferred.
- **Scroll continuation:** NX-10 / 426 is deferred; the inertia characterization was retracted, so it is not a confirmed outstanding defect.
- **Wake discovery speed:** leave unchanged unless the accepted delay becomes a problem.
- **Resource and recovery evidence:** overnight CPU/memory, abrupt device removal/crash cleanup, other-mouse isolation and exceptional native failure cases remain unverified. Do not repeat a large test campaign without agreeing scope.
- **Login at boot:** Enabled status is confirmed; actual launch after login is a distinct follow-up.
- **Later product capabilities:** shared action management, notification receipt/delivery history, device-level notification routing and MCP need separately scoped functional slices. Additional device types remain future work.
- **Excluded D200X scope:** firmware installation, vendor plugin compatibility and cloud services.

Historical lists48/49 and prior v1/v2 acceptance records remain preserved; this checkpoint does not close them. Design decisions: [contract](logitech-slice-contract.md). Research and visual history remain under `docs/product-redesign/` and the linked verification reports.
