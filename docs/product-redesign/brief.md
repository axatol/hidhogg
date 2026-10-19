# Hidhogg product redesign — first mock-ups

Date: 2026-10-19. Planning and visual exploration only; no replacement implementation approved. This is separate from the existing documents named V2, which describe the Swift migration.

## Question

How should one native macOS app configure a heterogeneous set of HID devices without making every device behave like a D200X tile grid?

Owner-selected initial set: Ulanzi D200X, Logitech MX Master 3S, Lofree Flow Lite. Flow Lite key-count variant is unspecified; keyboard illustrations are indicative. Capabilities in mock-ups are proposals, not hardware-support claims.

## Checklist

- [x] Review existing goal, current scope and relevant implementation lessons.
- [x] Read authored Options+ and Ulanzi research summaries; preserve static-versus-runtime qualifications.
- [x] Confirm the initial three-device set with the owner.
- [x] Produce a first visual comparison of navigation models; see [mock-ups](mockups/README.md).
- [x] Review alternatives with the owner; A/device workspace selected.
- [x] Expand A into overview, three device editors, action picker and permission/offline states.
- [ ] Agree the product model and main workflows before interactive prototype or application code.

## Proposed common behavior

- A main application window manages all devices; the menu bar provides quick access and status.
- Each device has a visual control editor shaped for its own keys, buttons, wheels or dials.
- Reusable actions and app-specific overrides can span device types; the exact profile ownership model remains a design question.
- Local editing remains available offline. Saved configuration, connection, permissions and successful application of changes are separate states.
- Only capabilities established for that device/connection should appear as available controls. A large static action catalog is not proof that every action works on every control.
- Permissions have a clear status and shortcut; app identity and signed packaging remain stable.
- Idle resource use and bounded observation lifetimes are requirements. The recent short memory probes do not establish an overnight bound for the new design.
- A technical runtime screen or TOML path is not the primary editing workflow. Storage format, migration and implementation architecture are deferred.

## Initial alternatives

1. **Device workspace — recommended starting point.** Persistent device sidebar, device canvas and action inspector; select All apps or an app override above the canvas.
2. **Application workspace.** Select an application/workflow first, then configure its behavior across all three devices in one workspace.
3. **Bindings workbench.** Searchable cross-device assignment table with a selected-control inspector, favoring dense editing over hardware visualization.

All visual data is synthetic. Disconnected and permission-blocked states should be designed deliberately rather than represented as generic runtime failure. The first images explore information hierarchy; they do not settle persistence, profile switching or auto-apply semantics.

## Approved next visual pass

Owner selected A and approved the next mock-up set on 2026-10-19. Produce three boards with six screens: overview/mouse, deck/keyboard, action picker/permissions. Use the selected device sidebar throughout. Keyboard editor demonstrates offline editing; the permissions screen demonstrates blocked execution while editing remains available.

Proposed state convention for review: Save persists local configuration; an independent status reports applied, waiting for device or permission-blocked. This is a mock-up proposal, not a final implementation contract. App overrides inherit All apps unless a control has its own override. Device-specific gesture/control choices must not become universal fields for every device. Flow Lite layout remains indicative; no assumption that Fn or every key is remappable.

## Evidence and limits

- `docs/overview.md:9` records the broad HID goal but scopes the first release to one D200X; the current migration plan is likewise D200X-centered.
- `/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/README.md` and `action-catalog.md` describe static component/action inventories. MX Master 3S over Bolt is a prospective validation target, not a validated Hidhogg adapter. Pairing, transport behavior and action availability still require bounded runtime validation.
- `/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/pairing-buttons-scrolling.md` distinguishes button assignments, app context, software scroll parameters and mechanical wheel behavior. Bluetooth OS pairing and Bolt pairing must not be conflated.
- `/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/findings.md` identifies distinct Keypad/Encoder controller declarations, pages and local action definitions; this is shipped-artifact evidence, not complete verified device behavior. Plugin compatibility is a separate decision.
- Ulanzi's official D200X page advertises 14 LCD controls, three rotary encoders and two additional keys: https://www.ulanzi.com/pl-eu/collections/ulanzi-instructions/products/d200x-creative-deck . Physical hardware capability is not proof of Hidhogg support.
- Lofree's vendor download page advertises key remapping/macros for Flow Lite: https://www.lofree.com.au/pages/download-center . No Flow Lite investigation folder exists in the provided research inventory; native protocol, connection-mode and persistence behavior are not established here.

No user configuration, raw captures, pairing secrets, device identifiers or target applications were accessed for this design exercise. Investigation documents may change while parallel research continues; this brief records only the reviewed 2026-10-19 snapshot.

## Application selector revision — 2026-10-19

Owner approved replacing the segmented application selector with a searchable dropdown. Board 05 shows the revised convention for all device editors: All apps defaults, per-application overrides and explicit inherited assignments. Tabs are deferred. This remains a static design proposal.

## Expanded page coverage — 2026-10-19

Owner requested outlines for all bindable controls, blue selected outlines, sidebar connection status and detailed device-page status; board 06 demonstrates these. Owner then requested remaining pages, especially notifications/actions. Boards 07–09 add notification routing, shared action management, app-rule overview and general settings. All top-level navigation pages now have static concepts; detailed forms and edge states remain incomplete. Shared-action edit propagation, route scope/history retention and save semantics remain proposals for review. No implementation approval is implied.

## Canonical owner corrections — 2026-10-19

Notifications is a global receipt/delivery log, not a routing-management page. Show matched device/control binding and delivery outcome, or unhandled; configure source filters at device/control level. Board 10 replaces board 07. Permissions moves into Settings; board 11 replaces the standalone navigation convention. MCP support is requested for bindings, notification listing and settings; device discovery, action management, validation, tests and activity are proposed additions.

MCP is an interface to the single app-owned runtime, not another runtime. Proposed read/write capability toggles do not establish transport or per-client authorization design. MCP tools expose model-callable operations; see the [official tools specification](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2026-07-28/server/tools.mdx), reviewed 2026-10-19. Implementation/version/transport decisions remain deferred. History retention and multi-destination outcomes must be bounded and explicitly designed before implementation.

## Connection indicator and identity — 2026-10-19

Owner accepted the current look with one correction: put the connection dot immediately beside the Connected/Disconnected status text, not beside the device name/icon. Canonical row: device name on first line; dot plus status on second line. Existing boards retain their older placement and are superseded by this convention. Owner requested Nidhogg-inspired multi-headed logo exploration; logos/01-logo-directions.png supplies four unselected raster concepts. No application icon replaced.

## Accepted identity and native UI requirement — 2026-10-19

Owner accepted logos/27-selected-serpent-padded.png and requested gold/black accents in the application design, plus Swift native components in mock-ups. Proposed convention: warm gold accent on charcoal/dynamic system surfaces; retain native semantic warning/error/success colours and legible contrast. Exact colour tokens are not selected. Existing generated raster boards are visual concepts, not proof of native components. Main proposed separate synthetic-data SwiftUI prototype for device editor, notification history and Settings, using standard sidebar/List, Form, Table, Picker, Button, Toggle and sheets, custom device canvas only. Code-write approval requested and pending; working app/bundle unchanged.
