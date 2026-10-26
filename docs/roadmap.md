# Roadmap

Updated 26 October 2026. TaskView Personal / HIDhogg project 5 owns stable task IDs, dependencies and completion status. This file is the concise implementation/acceptance index. [Earlier dated checkpoints](roadmap-history-2026-10-26.md) are historical evidence.

## Current checkpoint

Mainline branch: master. This native Logitech/D200X checkpoint was prepared on next/d200x-slice after e2744ad. Check-in review and verification are complete for the 116-file reviewed set; the owner authorised publication to the repository mainline on 26 October 2026. Signed checkpoint873e84a8bb59 passed566unique offline/background checks.

The owner has confirmed baseline notifications/scripts, native media controls, action search and the improved 458×196 wide-tile rendering. These confirmations do not close every hardware, permission or platform-effect gate. [Remaining owner checks](d200x-parity-owner-checks.md).

## Implementation and acceptance

| Stable ID | TaskView | Current state | Remaining gate |
|---|---:|---|---|
| UI-01 | 440 | Approved design contract; Done | None |
| UI-02 / UI-03 | 441 / 442 | Native workspace, mouse canvas and sizing implemented; visual improvements owner-confirmed | Residual keyboard/resize/window interactions in their checklists |
| UI-04 | 451 | Single scrollable Settings and compact permission rows implemented | Actual permission prompt/deep-link/drag/Restart flows |
| INFO-01 / INFO-02 | 452 / 453 | Mouse battery/firmware and optional alerts implemented | Remaining firmware comparison and real notification delivery |
| DX-01 / DX-02 | 444 / 445 | Native identity/transport, one page and incremental updates implemented | Broader device/lifecycle acceptance |
| DX-03 | 446 | Keys, front buttons and direct dial gesture assignments implemented | Remaining physical control/profile cases |
| DX-04 | 447 | Independent maintenance/recovery plus retained-connection sleep trial implemented | Whether brightness 0 stays black through screensaver delay and restores on wake |
| DX-05 | 448 | Brightness, image/title styling and accepted wide rendering implemented | Wider telemetry/screensaver scope is incomplete |
| DX-06 | 449 | Research/evidence gap; TODO | Encoder layout command/mapping verification before implementation |
| DX-07 | 454 | Local notifications, CLI/API and executable triggers implemented; baseline owner-confirmed | Remaining lifecycle, timeout and history cases |
| DX-08 | 470 | App profiles, topics, portable independent presets and management pages implemented | Remaining profile/preset/physical checks |
| DX-09 | 475 | Deferred safety spike; TODO | Approve the spike, compare literal arguments/JSON stdin/restricted templates, then separately approve implementation |
| DX-10 | 476 | Static native action catalog/templates implemented; media owner-confirmed | Volume/output, sound, openers and remaining native effects |

Tasks with residual gates remain In Progress; the TODO research/spike items are not implementation commitments. NX-M3 / TaskView443 is the parent D200X milestone, not a claim that all optional parity work is complete.

## Logitech checkpoint

The accepted baseline includes Back/Forward bindings, per-app overrides, direction and custom amounts for both wheels, traceable diagnostics, single-instance Restart, permission-aware menu state and workspace-dependent Dock/app-switcher presence.

Automatic recovery is implemented under exclusive mouse ownership: retain intent after unexpected loss, rediscover and verify routing, reapply settings, cap retry delay at 30 seconds, and cancel on explicit Disconnect/Cancel Reconnect. Physical receiver/mouse recovery remains an owner gate. [Contract and checklist](logitech-reconnection.md).

| Stable ID | TaskView | Follow-up |
|---|---:|---|
| NX-07 | 423 | SmartShift deferred |
| NX-10 | 426 | Scroll continuation deferred; no confirmed inertia defect |
| NX-16 | 432 | Earlier wake delay accepted; do not optimise without a demonstrated problem |
| NX-17–20 | 433–436 | Superseded historical icon work |
| NX-21 / NX-22 | 437 / 438 | Permission-aware status and Dock/app-switcher behaviour accepted |

## Next work

1. Publish the owner-authorised [check-in checkpoint](checkin-preparation.md) to master and verify the remote head.
2. Run the short remaining owner checks for D200X sleep and Logitech recovery; test the other native effects and app-profile/preset paths as needed.
3. Review the proposed idle-brightness and lock/screensaver policy after the sleep trial; those behaviours remain unimplemented.
4. DX-09 is the next recommended research slice: safely pass notification data into actions. No production interpolation is currently implemented or approved.

## Proposed and deferred

- Active/idle brightness defaults of 100% / 10% with a 10-second timer, and lock-to-screensaver policy remain proposed. The accepted sleep trial alone does not implement either.
- Physical multiple pages remain deferred.
- Wide telemetry, custom screensaver management and unresolved encoder displays require separate evidence and scope.
- Text insertion, ordered multi-actions, third-party integrations/plugins, Bluetooth, firmware installation and cloud services are outside the current slice.
- Actual login-after-boot, overnight resource use, abrupt-removal cleanup and other-device isolation retain their distinct acceptance limits.
- Additional device types and MCP remain future work.

## Evidence

- [Workspace decisions and dated verification](d200x-workspace-evolution-plan.md)
- [Owner acceptance checklist](d200x-parity-owner-checks.md)
- [Static action catalog and decisions](native-action-catalog-proposal.md)
- [Logitech recovery](logitech-reconnection.md)
- [Compact permissions](settings-permissions-plan.md)
- [Historical checkpoint index](roadmap-history-2026-10-26.md)
