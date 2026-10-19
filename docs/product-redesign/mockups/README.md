# First navigation concepts

Generated 2026-10-19 with the built-in imagegen tool. Asset: [01-navigation-concepts.png](01-navigation-concepts.png). This is a visual design artifact, not implemented software. The working app and existing repairs were not changed.

## Prompt brief

Create a landscape comparison board headed “Hidhogg — one app, all your devices”, with three full native macOS windows side by side. Use restrained gray sidebars, blue selection, native title bars and forms. Include synthetic Ulanzi D200X, MX Master 3S and Lofree Flow Lite examples with a VS Code context.

- **A — Device workspace (recommended starting point):** three-column editor. Device sidebar, selected mouse/control visualization, All apps / VS Code context selector, shortcut inspector and a “Saved on this Mac” status.
- **B — Application workspace:** application sidebar first. A VS Code workspace shows a mouse assignment, a deck assignment and a keyboard assignment in stacked rows, with an assignment inspector.
- **C — Bindings workbench:** searchable flat cross-device table, device/application filters and a selected-assignment detail pane.

All three share coherent styling but deliberately differ in information hierarchy. No runtime/TOML controls, raw device IDs, cloud accounts, firmware flashing or fictitious support guarantees. Research caveats belong in the board footer, not product-facing developer badges. Device diagrams and example actions are illustrative; the Flow Lite variant and full device layouts are not settled.

## Review notes

The board is legible enough to compare navigation. It is not a device-layout reference: the small deck and keyboard thumbnails do not establish physical key counts or control placement. “Thumb button” is an indicative selection, not a verified HID control identity. The proposed keyboard binding and shared app contexts require product and adapter validation. Green permission/saved indicators are synthetic states, not readings from the current app.

Select a direction or combine elements before designing the detailed device editor, overview, offline/permission states and action picker. Any later clickable prototype or application code requires a concrete plan and owner approval.

## Expanded direction A — 2026-10-19

- [Overview and mouse](02-overview-and-mouse.png)
- [Deck and offline keyboard](03-deck-and-keyboard.png)
- [Action picker and permissions](04-actions-and-permissions.png)

Generated and visually inspected with built-in imagegen, using board 01 as style reference. Prompt briefs: native light macOS windows, persistent device sidebar, device-specific canvas and inspector, synthetic states, separate local save/connection/execution status. Board 02 corrected misleading green permission indicators and mouse control naming.

Limitations: hardware drawings and keyboard legends are illustrative; Flow Lite support remains unverified. Board 03 green sidebar dots are placeholders; prefer neutral shields from boards 02/04. Add device does not promise pairing support. Save wording and unsaved-change states need refinement. Applied denotes activated configuration, not successful action execution. Shared-action mutation effects, profile/page ownership and save scope remain open before an interactive prototype. No app code or bundle changed.

## Searchable application selector — 2026-10-19

[Application bindings revision](05-application-selector.png) supersedes the segmented All apps / VS Code selectors in boards 02–04 for every device editor. Owner approved a searchable dropdown with All apps, configured applications and Add application. Left shows an explicit VS Code override; right shows Safari inheriting the default and offering Override for Safari. Tabs are deferred. Generated using built-in imagegen and visually inspected; original boards preserved. All assignments are synthetic.

Prompt brief: two native macOS mouse editors preserving board 02 style; left searchable application dropdown open with All apps, VS Code, Safari, Figma, Terminal and Add application; right dropdown closed with inherited assignment. Keep device navigation, control canvas, inspector and local-save state. No segmented selectors, runtime jargon or pairing claims. Exact prompt saved alongside the image.

## Controls, status and remaining top-level pages — 2026-10-19

- [Control outlines and connection status](06-controls-and-status.png): neutral outlines for available targets, blue selection, sidebar connection labels and detailed device status. Supersedes earlier device-editor control affordances.
- [Notification management](07-notifications.png): source-to-display routes, preview, local test and route editor.
- [Action library and editor](08-action-library.png): types, usage references, shared-edit impact warning and duplication alternative.
- [App rules and general settings](09-app-rules-and-settings.png): app-centric overview of the same device overrides, plus application preferences and permission links.

Built-in imagegen; board 05 supplied as style reference. All outputs visually inspected. Corrected a contradictory offline banner in 06 and duplicate sidebar selection in 07. Exact generation prompts saved beside these boards; subsequent correction prompts changed only offline copy/navigation and sidebar selection respectively. No source, device operations or signed bundle changed.

Design proposals: Notifications is now a top-level navigation item. Routes configure local sources and eligible display controls; no system-wide notification capture or external messaging integration is claimed. Existing source-filtered display-only behavior informs the design (docs/overview.md:16–18); notification messages cannot define actions. Route scope across device pages/profiles, expiry handling, Recent retention and test delivery while disconnected remain unresolved. Action library editing proposes shared references: save updates all listed uses, while duplication provides an alternative. This requires owner agreement and an explicit rebind flow before implementation. App rules reviews the same per-device application assignments; it is not a second priority/profile engine.

Coverage: every currently named top-level page has a static concept. Recent notification detail, sequence/action-type forms, create/delete dialogs, empty/error states and onboarding are not exhaustively mocked. Settings toggles, transport details, statuses, control diagrams and usage counts are illustrative. Keyboard support and exact available controls remain unverified. Disconnected status should use neutral styling consistently; board 09 red dots are a remaining visual inconsistency.

## Owner correction: history, device configuration and MCP — 2026-10-19

- [Notification history and device binding](10-notification-history-and-device.png) supersedes board 07. Global Notifications is a received-message log. Configuration belongs to each device/control. Show device, binding and delivery outcome or Unhandled. Receipt, device display and press-action execution are separate events.
- [Settings, Permissions and MCP](11-settings-permissions-mcp.png) supersedes standalone Permissions navigation across earlier boards. Permissions lives within Settings, alongside proposed MCP controls.

Built-in imagegen; board 08 used as visual reference. Both outputs inspected; board 11 corrected hardcoded OS permission-page wording. Exact generation prompts saved beside images. Board 10 deck grid is a schematic control list, not the D200X physical layout. Synthetic statuses and messages only. No implementation changes.

Owner requirements: device-level notification configuration; searchable received history with handling outcome and matched binding; MCP support for configuring bindings, listing notifications and changing settings; merge Permissions into Settings. Proposed MCP additions: device/capability discovery, reusable-action management, configuration validation, local test notifications and activity inspection. Permission defaults, transport/authentication and final tool names are not agreed. One app remains the sole device/runtime owner; MCP must delegate to it, not create another device runtime.

History must snapshot the binding/context/action at receipt rather than silently relabel old events after edits. One message may have multiple delivery outcomes; expand per destination. Unhandled (no matching binding), matched-but-offline, failed and displayed must remain distinct. Retention, persistence, message content storage and bounds require an explicit decision; no indefinite in-memory log. MCP reads should be filterable/paginated and writes should use the same validation as the UI. Notification content is data, never executable instructions.

## Connection-indicator correction — 2026-10-19

Owner accepted the look and requested the dot immediately beside the status text: device name on first line, then “● Connected” or “○ Disconnected” on the second line. This supersedes dot placement in existing boards; their pixels have not been revised. Logo exploration is indexed in ../logos/README.md.
