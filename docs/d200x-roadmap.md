# Native UI and D200X roadmap

Requested on 2026-10-21. TaskView Personal / HIDhogg project 5 is the task source of truth. These are planned milestones, not authorization to start either implementation now.

```text
Current Logitech checkpoint + NX22 window behavior
                     |
                     v
NX-M2: Native UI alignment (owner acceptance)
                     |
                     v
NX-M3: D200X first functional slice alongside Logitech
                     |
                     v
Later D200X appearance/status features and unresolved knob work
```

## NX-M2 — Native UI alignment

TaskView list **67**, milestone **439**. Align the existing functionality with the selected device-workspace [mockups](product-redesign/mockups/README.md) and [accepted corrections](product-redesign/brief.md). Native Swift components, efficient state updates and accessibility take precedence over matching raster boards pixel for pixel.

| Stable ID | TaskView | Deliverable | Dependency |
|---|---|---|---|
| UI-01 | 440 | Compare current capabilities with mockups; agree screen/state inventory and implementation plan | Current NX22 checkpoint |
| UI-02 | 441 | Native device sidebar/workspace and current Logitech control editor | UI-01 |
| UI-03 | 442 | Settings, permission and diagnostics alignment; signed UI checkpoint and owner acceptance | UI-02 |

Retain searchable application selection, inheritance, full-area outlined bindable controls, gold accents, a connection dot beside status text, permissions inside Settings, immediate application and autosave. Existing Back/Forward history remains. Mockup-only Actions, notification history and MCP capabilities must be identified as separate functional gaps; visual alignment does not silently authorize those engines or present them as working.

**Gate:** owner accepts the native layout and existing Logitech behavior before D200X implementation starts. UI planning must settle any screen and capability questions before code changes.

## NX-M3 — First D200X functional slice

TaskView list **66**, milestone **443**. Depends on accepted NX-M2. Deliver one app that supports Logitech and a D200X session: connect, identify, display a page, route mapped controls through a native binding, maintain the session independently of rendering, and recover after reconnect.

| Stable ID | TaskView | Deliverable | Dependency |
|---|---|---|---|
| DX-01 | 444 | D200X-specific bounded codec, correct HID collection and native identity exchange | UI-03 acceptance; reviewed interface |
| DX-02 | 445 | One page plus a fresh-name incremental image update preserving other tiles | DX-01 |
| DX-03 | 446 | Mapped keypad/side-button/dial inputs, native device editor and representative configured action | DX-02 |
| DX-04 | 447 | Independent GETBASE maintenance, bounded session recovery and focused Swift acceptance | DX-01–03 |
| DX-05 | 448 | Later brightness, fonts, wide status/telemetry and optional screensaver features | DX-04; separate feature plans |
| DX-06 | 449 | Resolve knob display / custom encoder schema before implementing it | DX-04; evidence gap |

The initial interface decision must preserve device-specific controls and transports. Do not force the deck into the mouse-specific session protocol or create another runtime process. Codec, transport, rendering, action delivery and UI should have explicit responsibilities; implementation boundaries require review before coding.

## Research basis and remaining uncertainty

The current source is the external [Ulanzi Studio inventory](/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/inventory.md), reviewed on 2026-10-21, including its latest **21 October 2026, 17:38** lifecycle addendum. Preserve its Static, Device, Human and Design labels; do not claim Python/vendor observations establish Swift behavior.

- F-05–11 / Q-01: native Swift IOHID collection selection and 1,024-byte report convention need validation. Do not blindly prepend hidapi's report-ID byte. Identity, bounded frames, padding and malformed replies need fixtures.
- F-12–18: retained events establish mappings; preserve press/release and held rotation. Use column_row coordinates, wide slot `3_2`, and fresh asset names. The solution-01 helper does not establish every solution-02 behavior.
- F-23 / F-36: five-second GETBASE maintenance has bounded research evidence without redraws; long-duration behavior is not established.
- The latest addendum accepts research unplug/read failure → reopen/GETBASE and qualitative Studio lock/sleep recovery. Raw reconnect did not establish automatic normal-page restoration. Restoring Hidhogg's desired page is a proposed host behavior, and Swift recovery remains a new integration gate. Do not repeat accepted vendor wizard cases or guess command 5 as wake.
- F-33–35: brightness progression, per-slot font comparison, telemetry display agreement and screensaver quadrants have human acceptance. Global font behavior, screensaver power-cycle persistence and unobserved knob activation remain unresolved. Mode 100 / command 17 need more evidence before guessed uploads.

Verification should combine offline protocol/archive/action fixtures with one focused, owner-approved Swift integration sequence. Hardware actions, persistent display changes and native input delivery require scoped authorization. Firmware installation, vendor plugin compatibility and cloud services are excluded. Broader native action/page catalogs need separate feature definitions after the first slice.
