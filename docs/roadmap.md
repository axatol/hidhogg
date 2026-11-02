# Roadmap

UI-FREEZE-01 signed (2 November 2026): owner interaction99.7%CPU traced to large-range native slider tick layout. One-line fix preserves integer pressure values; failing4.7s layout now about0.02s, fullUInt16range covered. All1,098 offline tests and333input hashes pass; strict signed build4013fd4; owner reports freezing resolved, while DPI writes remain open. [Diagnosis/evidence](ui-interaction-freeze.md). Shared interactive3S/MX4 canvas proposal remains queued for confirmation.

MX-SET-01 signed partial checkpoint (2 November 2026): SmartShift, capability-gated wheel/thumb/button controls and MX4 haptics/panel settings; explicit scroll defaults; 1,097 offline tests pass,333 matching inputs. Build df12cc3 awaits owner verification. Pointer speed explicitly deferred; target DPI V2 reads work but writes remain research-blocked. [Scope and evidence](mouse-settings-milestone.md). Commit accepted scope automatically.

MX-SET-01 in progress (2 November 2026): owner approved combined MX3S/MX4 settings including independent pointer speed/DPI, SmartShift, wheel controls, supported haptics/panel sensitivity and physical controls. Scroll directions become explicit: vertical Standard, thumbwheel Natural by default. [Milestone checklist](mouse-settings-milestone.md). Padding/initial MX4 settings accepted and committed as 5973d41; older pending/uncommitted entries below are historical.

UI-PAD-01 / LC-05A offline verified and signed (2 November 2026): consistent custom-card insets and capability-gated MX4 main-wheel direction/input resolution/restoration. Shared HIDPP2121V1 codec/planner establishes feature-version separation for eventual full3S/4 hardware coverage. Independent focused321/full1,056 pass;326 source hashes and strict signatures match. Owner visual/physical acceptance remains open; other hardware adapters remain later slices. [Scope and coverage roadmap](padding-mx4-settings-plan.md).

Check-in readiness (2 November 2026): owner confirms the signed MX4 discovery correction works, with current behavior as expected. No blocker found in accumulated D200X presets/scripts/Lock Screen and Logitech association/pairing/receiver-management source. That checkpoint deferred padding; UI-PAD-01 now implements it with owner visual acceptance pending. Notification icons, discovery ACK ordering and numeric error/admission evidence remain open; new Bluetooth pairing remains planned.

BOLT-KIND-01 offline verified and signed (2 November 2026): one-line low-nibble device-kind normalization; five independent MX4 tests RED→GREEN, focused304/full1,037 pass. Owner confirms discovery/current flow works on the signed build; actual prior wire value remains unknown. [Evidence/checklist](logitech-discovery-regression-2026-11-02.md).

Pairing recovery offline verified and signed (2 November 2026): stable repeated-advertisement candidates, receiver-driven challenge highlighting and fresh-inventory retry recovery. Focused 299/full 1,032 pass on the final runs; initial thumbwheel-only full failure is preserved with cause unconfirmed. Real pairing remains owner acceptance. [Scope/checklist](logitech-pairing-recovery-plan.md).

UI padding follow-up (2 November 2026): the missing internal GroupBox/card inset audit is implemented in UI-PAD-01 above, separately from pairing diagnosis; synthetic narrow/wide captures pass, owner visual acceptance remains pending.


Notification setup/unified device list implemented, verified and signed (2 November 2026): approved verified temporary notification bits and last-read display retention; owner then requested one Devices list for stored, paired and discovered entries. One Devices list retains last-read rows while stale mutation authority is revoked; verified temporary notification setup precedes discovery, with guarded cleanup. Full1,011 tests pass, strict signatures/help and318 input hashes match. New Bluetooth discovery/pairing remains next; real discovery/cleanup still needs owner verification. [Plan/checklist](logitech-notification-discovery-plan.md).

Native receiver-boundary diagnostics implemented, verified and signed (2 November 2026): approved read-only flag query returned `0x000000`; anonymous callback/filter counters are now available. Full990 offline cases pass and315 input hashes match the signed build; an initial thumbwheel recorder assertion failed once and passed in subsequent full/isolated/focused checks. Additional research corroborates discovery framing but does not establish a discovery-specific flag requirement. No notification flags are being changed. [Evidence/scope](logitech-discovery-ui-followup.md).

Logitech discovery UI follow-up implemented, offline verified and signed (2 November 2026): first-click disclosure state, phase-correct loading and anonymous typed-event counters. Full981 cases and signed app/CLI verification pass. Physical discovery timeout remains unconfirmed; native first-click/resizing and next-attempt counters await owner checks. No notification-flag writes were added. [Scope/checklist](logitech-discovery-ui-followup.md).

LC-07 receiver management implemented, offline verified and signed (1 November 2026): approved expandable stored-pairing inventory and explicit selected-slot Unpair with confirmation, stale-target checks and post-operation inventory verification. Hidhogg settings remain separate. Full978 offline cases, strict signatures and311 input hashes pass. The full receiver blocks MX Master 4 pairing acceptance until the owner explicitly removes an old bond; real unpairing remains owner-operated. [Scope/checklist](logitech-receiver-management-plan.md).

Deferred owner-reported issue (1 November 2026): the macOS low-battery notification shows a generic placeholder instead of the Hidhogg app icon or an appropriate device icon. Investigate notification attribution/icon rendering later; no fix or acceptance claim yet. Proposed next receiver slice: show all stored pairings, including offline devices, and provide explicit per-slot Unpair with confirmation and refreshed inventory verification. Removing a Hidhogg registration remains distinct from deleting a receiver bond; implementation was approved and is tracked in LC-07 above.


Pairing follow-up delivered (1 November 2026): existing mice remain visible through a new-pairing attempt/failure. Approved anonymous read-only checks found six returned pairing records, five offline, on the attached receiver; the capacity error now explains that offline stored pairings occupy slots. Full958 offline cases and signed app/CLI verification pass. Uncertain outcomes require Refresh before selection or retry. No pairing/unpairing writes were performed. [Evidence](logitech-compact-setup-plan.md#pairing-follow-up--1-november-2026).


Compact Logitech setup implemented, offline verified and signed (1 November 2026): one centre-pane connection view shows existing Bolt/Bluetooth mice and new connection options immediately after choosing Logitech. Inline Bolt pairing saves then opens the device. Full gate passes 955 cases with two existing suite exclusions; native UI/hardware acceptance remains open. New Bluetooth pairing remains unavailable. [Scope/checklist](logitech-compact-setup-plan.md).

LC-04 implemented, offline verified and signed (1 November 2026), ahead of LC-03 Bluetooth pairing: receiver-selected Bolt pairing plus the existing chooser correction. Full gate passes 940 checks with two documented existing suite exclusions. Hardware pairing, allocation/empty-slot assumptions and input continuity remain owner checks. [Plan/checklist](logitech-bolt-pairing-plan.md).

LC-02 implemented, offline verified and signed (1 November 2026): explicit existing-device association, persisted identity/reconnection and basic read-only MX Master 4 support. Full gate passes 908 checks with two documented existing suite exclusions. Owner subsequently confirmed chooser visibility after the LC-04 SDK enum correction; association/reconnect and new pairing acceptance remain open. [Scope/checklist](logitech-lc02-plan.md).

Post-LC01 receiver ambiguity warning and vertical direction mapping are offline verified and signed (1 November 2026); owner confirmed direction works while connected. LC-02 adds guarded saved-target uncertain-cleanup recovery; the older legacy fake suite remains excluded. [Evidence](logitech-direction-ambiguity-fix.md).

LC-01 implemented, offline verified and signed (1 November 2026): UUID-scoped mouse editing and runtime ownership, preserving existing storage. LC-02 adds explicit endpoint selection; one active managed Logitech backend remains the boundary. [Scope/checklist](logitech-lc01-plan.md).

Historical planning checkpoint before LC-01/02/04: MX Master 3S/4, existing connections and new pairings were requested; current implementation status is recorded above. [Proposed slices and evidence](logitech-connectivity-pairing-plan.md).

Scripts-page simplification is implemented, signed and offline verified (1 November 2026): executable scripts only, New Script button, retained history; built-in actions remain in Tile Presets. [Scope](scripts-page-plan.md).

Updated 1 November 2026. TaskView Personal / HIDhogg project 5 owns stable task IDs, dependencies and completion status. This file is the concise implementation/acceptance index. [Earlier dated checkpoints](roadmap-history-2026-10-26.md) are historical evidence.

## Current checkpoint

DX-PRESET-01 implemented and signed, 1 November 2026: complete Tile Presets bundle appearance and behavior, include all 16 supported-action defaults with icons, configure actions inline, apply copies within the edited profile, and preserve manual controls. Paired dial rotation presets preserve press; press/front controls reuse action-only tile presets. Focused68/full862 offline cases pass and source/build manifests match. Native usability and physical effects remain owner checks; source remains uncommitted with Lock Screen. [Contracts/evidence](d200x-preset-assignment-plan.md).

DX-LOCK-01 implemented and signed, 1 November 2026: parameter-free Lock Screen action uses the existing Control–Command–Q shortcut path, with normal action selection/preset support. Twenty-seven fake-only tests pass; actual Mac lock behavior remains an owner check. Brightness, pages and multi-actions are not part of this slice. [Implementation and evidence](d200x-lock-screen-plan.md).

1 November 2026 D200X steering: pages/folders remain out of scope; review individual Studio actions before multi-actions. Brightness controls and Lock Screen are the requested candidates. [Action catalog and target distinctions](d200x-action-catalog-review-2026-11-01.md). D200X versus Mac display brightness still needs clarification; no action-extension feature code has started.

1 November 2026: owner accepts the Bluetooth/menu/count checkpoint and requests local check-in. The threshold now saves valid typing after 200 ms; Return/focus loss remain immediate. Consolidated 822 offline tests plus final UI-only targeted/probe checks pass. Immediate next focus is D200X feature parity: [fresh review and proposed multi-action slice](d200x-next-parity-review-2026-11-01.md). No new D200X feature implementation is approved by that proposal; Logitech Bluetooth work remains queued.

BT-05 is focused-verified and signed on 1 November 2026: connected/enabled menu-bar count, ordinary disconnections neutral to a healthy aggregate, explicit errors preserved, and editable battery threshold. Nineteen focused tests pass. Owner accepted BT-04 layout; count/threshold native checks remain open. [Evidence](menu-connection-count.md).

BT-04 UI corrections are offline verified and signed on 31 October 2026: shared sidebar/Add Device alignment, wrapping component battery readings, bounded menu sizing with direct child-status observations, and startup selection repair. Full 812 offline tests pass; actual menu/startup/sidebar acceptance remains open. [Evidence](bluetooth-ui-followup.md).

BT-03 is offline verified and signed on 31 October 2026: optional generic Bluetooth battery thresholds, connection dots/class icons and a compact menu popover with right-aligned values and a second component line. Independent focused/full gates and signed delivery pass; results are recorded in the linked checklist and build-info. Actual notification delivery and popover interaction remain owner checks. See [scope/checklist](bluetooth-monitoring-plan.md).

Mainline branch: master. This native Logitech/D200X checkpoint was prepared on next/d200x-slice after e2744ad. The 116-file reviewed source checkpoint ca60802 was published to master on 26 October 2026 and its remote head was verified. Signed checkpoint873e84a8bb59 passed566unique offline/background checks.

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
| DX-05 | 448 | Brightness/image/title baseline plus signed seven wide modes and explicit screensaver controls; Now Playing spike complete | Owner hardware gates, metrics availability and screensaver placement/persistence; production media provider is separate |
| DX-06 | 449 | Research/evidence gap; TODO | Encoder layout command/mapping verification before implementation |
| DX-07 | 454 | Local notifications, CLI/API and executable triggers implemented; baseline owner-confirmed | Remaining lifecycle, timeout and history cases |
| DX-08 | 470 | App profiles/topics/presets plus signed static app-icon notification API/CLI/action/render flow | Owner icon/fallback/TTL/preset/physical checks; flashing deferred |
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

## Next device: Flow Lite84

Requested and FL-01 approved 26 October 2026. The native receiver-based read-only status slice is implemented, locally signed and tested; a bounded receiver status read succeeded. Owner app/hardware acceptance remains open. Lighting and explicit system-mode writes are implemented in the approved slices below; physical acceptance remains open. [Feasibility and evidence](lofree-flow-lite-feasibility.md).

| Stable ID | TaskView | Proposed deliverable | State |
|---|---:|---|---|
| FL-M1 | 492 | Native status and controls milestone | In progress; FL-01 approved 26 October 2026 |
| FL-01 | 493 | Battery/charging, keyboard/receiver versions and read-only lighting/OS state | Signed status/activity-refresh and useful battery-event handling;69 current focused checks pass; owner acceptance of intermittent-reply fix is pending; unanswered-read retries remain unapproved; [evidence](flow-lite84-implementation.md) |
| FL-02 | 494 | White-backlight effects/state, brightness, speed and idle-off | Implemented and signed; 128 focused tests pass before the final view-only grid change; 200 ms auto-apply, readback and separate Undo; owner reports controls/grid work; persistence edge cases remain; [plan](flow-lite84-lighting-plan.md) |
| FL-03 | 495 | Explicit Mac/Windows mode control | Implemented and signed; 200 ms automatic mode selection/readback and separate Undo; owner reports working; broader physical mapping/persistence checks remain; [plan](flow-lite84-system-mode-plan.md) |

Battery precision is not yet measured. The vendor's host estimate has a known boundary defect, so do not copy it as an accuracy guarantee. Firmware installation, pairing/reset, macros and keymap changes are outside this slice. The new receiver-specific module is independent of Logitech/D200X; the signed dist artifact now includes FL-01, with physical/app acceptance still open.

27 October 2026 approved follow-up is implemented and signed: include the keyboard in Connect on launch and refresh battery/status on keyboard activity at most hourly. Passive global/local event monitors do not access key contents; there is no polling timer. Sleep/Disconnect pause monitoring, and manual full Refresh remains. Independent offline verification passes 75 focused checks. Live event registration, battery consumption and secure-input/permission behaviour remain unmeasured; owner validation is open. Existing vendor status-change refreshes remain separate from the keyboard-activity throttle. General reply-routing/read-retry changes remain separately unapproved.

28 October 2026 reliability follow-up is implemented and signed, with 69 independent focused checks passing: fully validated, identity-confirmed unsolicited battery updates are accepted without completing/extending unrelated queries, and globally valid off-current ordinary replies are ignored. Newer battery observations survive batch completion; their timestamp is labelled received-at. Owner physical acceptance remains open. This supersedes the earlier Part A approval status; read retransmission (Part B) remains unapproved. [Revised scope](flow-lite84-read-reliability-plan.md).

## Next work

The current [check-in checkpoint](checkin-preparation.md) records local mainline integration and the preserved26October publication history. Flow Lite84 FL-01 is ready for owner validation.

1. Perform the FL-01 owner checklist, assess battery granularity/charging and physical light/system mapping, and observe any repeated invalid responses; review separate FL-02/03 write boundaries afterwards. [Owner checklist](flow-lite84-implementation.md).
2. Retain the remaining owner checks for D200X sleep and Logitech recovery; test the other native effects and app-profile/preset paths as needed.
3. Review the proposed idle-brightness and lock/screensaver policy after the sleep trial; those behaviours remain unimplemented.
4. DX-09 remains a deferred research slice for safe notification data passing. No production interpolation is currently implemented or approved.

## Proposed and deferred

- Active/idle brightness defaults of 100% / 10% with a 10-second timer, and lock-to-screensaver policy remain proposed. The accepted sleep trial alone does not implement either.
- Physical multiple pages remain deferred.
- Unresolved encoder displays (mode100/command17), screensaver timeout/original restoration and flashing effects require further evidence and scope.

28 October 2026: the earlier display/icon baseline passed206 independent fake-only tests plus5 isolated CLI smoke cases. The current signed mode-switch/retained-preview follow-up passed38 focused checks and received owner confirmation. The [display controls plan](d200x-display-controls-plan.md) records decisions/evidence, and the [Now Playing spike](d200x-now-playing-spike.md) includes synthetic rendered previews and public API compile probes. No live player is connected. Screensaver timeout/original restoration, mode100/command17, flashing and universal production media support remain outside this initial slice. Owner hardware gates remain; no agent-operated device changes were performed.
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


28 October 2026 follow-up implemented, hardware acceptance pending (DX-05): owner approved five-second on-device screensaver preview with latest crop/zoom timer reset, then restoration of current active tiles. New-source confirmation retained; lock/sleep/disconnect invalidate pending preview. Default artwork repositioned and inspected inside wide screen window. See docs/d200x-display-controls-plan.md; hardware acceptance remains pending.

28 October 2026 DX-05 follow-up implemented: numeric command6 fields and scheduler transitions corrected for reported stuck CPU/RAM/GPU mode; retained/collapsible last-sent screensaver preview added. Independent38focusedchecks and signed build pass; owner confirms this reported issue appears resolved. Other hardware gates remain separate.

28 October 2026 owner confirmation: latest wide-mode switching and retained screensaver preview appear to work. Earlier screensaver timing/persistence/lock/sleep gates remain separate.

## Approved next direction — 31 October 2026

Hardware-focused coverage replaces general Options+ parity. Sequence: (1) dynamic device registry and per-device UUID configuration files with migration; (2) generic discovery of already-paired Bluetooth devices and optional battery monitoring; (3) Logitech Bluetooth transport/capability and cross-transport identity investigation; (4) MX Master 3S Bluetooth configuration; (5) middle-click, thumb-rest direct press, wheel-mode button, DPI and SmartShift; (6) MX Master 4 support. Pairing stays in macOS. Disable retains configuration but stops management/monitoring; Remove leaves OS pairing intact. Do not automatically merge transport identities without evidence. Actions Ring, Flow, directional gestures and software-only parity are excluded. This direction is approved; no new registry/Bluetooth implementation has started.

Lofree startup timeout: one close/reopen attempt timed out, manual Connect succeeded. Owner has not reproduced it as of31October2026 and approved checkpointing. No cause or fix claimed; no retry policy changed.

## REG-01 — In progress, 31 October 2026

Dynamic device registration and versioned per-device configuration migration is the active approved slice. See [plan/checklist](device-registry-plan.md). Generic Bluetooth discovery/battery monitoring remains next; no Bluetooth scanning, new Logitech controls or live-device operations in REG-01. Existing drivers retain one live endpoint per supported family pending targetable discovery.

REG-01 delivered31October2026 for owner acceptance: UUID registry, dynamic sidebar/menu, Add/Disable/Remove and legacy backup/per-device migration implemented. Independent733offline checks and signed build `dd887ea4d396f757794e6cf40d526269eb3542d44b18694a4c1062d41b2f4a08` pass; native/physical owner checks remain. One registration per existing supported family; generic Bluetooth next. No commit/push of this new slice. [Evidence](device-registry-plan.md).

REG-FS-03 delivered31October2026: flat family/UUID/shortSHA filenames, nested migration and safe postpublication cleanup; independent97focused checks and signed build `a9dab2eb3641c0292bd9fb8d263a60e166e64dc27b75bf5d91c9589b9bf889f7` pass. Registration IDs preserved. Owner live migration/cleanup acceptance pending. See [registry evidence](device-registry-plan.md).

Accepted registry/UI/hashed-storage checkpoint committed locally on master31October2026; no push. Generic paired Bluetooth discovery and battery monitoring is next.

BT-01 in progress31October2026: generic existing-paired Bluetooth discovery and battery monitoring, multiple generic UUID registrations, public-API evidence first. No Logitech-specific Bluetooth commands, pairing or live agent inventory access. [Plan](bluetooth-monitoring-plan.md).

BT-01/BT-02 delivered31October2026 for owner verification: generic paired discovery, multiple UUID monitoring, System Information battery and DeviceAddress/IORegistry fallback, app-wide permission row, lifecycle fencing. Focused88/full786offline cases pass, signed build `4cd8c060ff105e838591902ae0ea297aa90ddc4d9dea36ecd2574144203638a5` verified; no live device writes. Owner confirms initial discovery/AirPods; updated fallback trial pending. Both existing device readiness-test corrections explicitly approved and verified. See [plan/evidence](bluetooth-monitoring-plan.md). No check-in/push yet.
