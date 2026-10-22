# NX-M2 — Expanded native UI alignment plan

## Accepted decisions — 2026-10-22

Owner selected **1B/2A/3A**, superseding draft recommendations below:

- Four outlined selectable targets. Back/Forward open app-specific assignment inspectors; wheels open device-wide settings inspectors. No permanent wheel panel. Preserve last app context and restore selected target in transient history; no wheel shortcut types or TOML changes.
- Retain inherited app contexts after final override removal; only explicit Remove deletes them. Verify codec/store empty-context round-trip.
- Cancel recording on editor/app exit, including navigation, hidden inspector and workspace closure. Preserve logical manual-sheet handoff and visible offline editing; prevent stale callbacks.

Shared restore-on-disconnect remains one device-level option in wheel inspector Device options. Remaining work packages and protected runtime/schema boundaries are unchanged. Owner approved implementation on 2026-10-22. Earlier recommendations below are alternatives considered.

Original proposal prepared 2026-10-21; owner approved UI-01 through UI-03 implementation on 2026-10-22. The accepted choices above supersede earlier alternatives below. TaskView milestone439/list67 owns the work. The accepted source baseline is6ce6b23; documentation checkpoint isbf95c02. Start with the [visual review, workflow tables and owner questions](ui-alignment-review.md).

## Outcome

Make the existing Logitech functionality understandable through the selected device-workspace design: select the device, choose an application, select Back or Forward, and edit its assignment in a native inspector. Keep wheel preferences visibly device-wide. Settings remains inside the same workspace. Preserve the current device/runtime behavior, autosave and menu/window lifecycle.

The reference hierarchy is [boards05/06](product-redesign/mockups/README.md), with the later status-dot correction and [board11](product-redesign/mockups/11-settings-permissions-mcp.png) for Settings. Gold accents, native controls and current accepted behavior supersede the boards' blue accents, manual Save buttons and separate Permissions navigation. The boards are visual references, not device capability specifications.

## Proposed workspace

```text
┌──────────────────┬────────────────────────────────┬─────────────────────────┐
│ Devices          │ MX Master 3S                   │ Back button             │
│ MX Master 3S     │ ● Connected · Bolt             │                         │
│ ● Connected      │                                │ VS Code override        │
│                  │ Application [VS Code        ▾] │ Assignment [Shortcut ▾] │
│                  │                                │ [⌘ [                  ] │
│                  │       Mouse illustration       │ [Record] [Choose…]      │
│                  │      [Back] [Forward]           │ [Preset ▾]              │
│                  │      outlined targets          │ [Use All apps]          │
│                  │                                │                         │
│                  │ Device settings — all apps     │                         │
│                  │ Vertical wheel / Thumb wheel   │                         │
│                  │ Direction, amount, resolution  │                         │
│                  │                                │                         │
│ Settings         │ Saved on this Mac · Bindings active                       │
└──────────────────┴──────────────────────────────────────────────────────────┘
```

The diagram is structural, not a pixel layout. Show only the existing Logitech profile and working navigation. A disconnected device stays selectable/editable. Future D200X, keyboard, Actions, Notifications, App Rules and MCP entries appear when their implementation exists.

## UI-01 / Task440 — Capability and interaction contract

**Deliverable:** an agreed screen inventory, state matrix, capability map and implementation boundary. This draft performs the initial mapping; owner review remains the exit gate.

| Current behavior | Proposed presentation | Work classification |
|---|---|---|
| One Logitech profile; Back/Forward shortcut bindings | Device row, two selectable bindable targets, assignment inspector | Existing capability; new layout |
| All apps defaults and sparse app overrides | Searchable application dropdown; explicit inheritance/override controls | Existing data/behavior; new selector |
| Record Shortcut, manual key/modifier entry, navigation presets | Native controls inside inspector | Relocation; preserve recording lifecycle |
| Vertical direction/resolution/amount and thumb direction/amount | Device settings panel marked “all apps” | Existing capability; new layout |
| Persistent wheel preferences and optional restore-on-disconnect | Device-level setting with current observed/effective state details | Relocation; preserve semantics |
| One-second autosave, manual Reload, save conflict/error/retry | Small saved-state indicator, contextual errors, Configuration settings | Preserve behavior; remove duplicated presentation |
| Connection, permission and input-admission state | Distinct connection and execution summaries | Read-only presentation projection |
| Startup/login, permission recovery, diagnostics | Four Settings categories | Relocation; existing functionality |
| Mockup action library, notification history/routing and MCP | Later functional slices | No current engine to expose |

Source grounding: [DevicesView](../app/Sources/HidhoggApp/DevicesView.swift), [SettingsView](../app/Sources/HidhoggApp/SettingsView.swift), [binding/context methods](../app/Sources/HidhoggApp/AppModel.swift#L654), and [domain controls](../app/Sources/HidhoggDomain/Configuration.swift#L3). Only Back and Forward are bindable; the application dictionary does not provide per-app wheel preferences. The mockup README's older reference to existing source-filtered display notifications does not describe this accepted Logitech package; treat it as historical design context, not a capability claim for this slice.

**Required states:** connected, disconnected, connecting/stopping, connection failed, missing permission, unsupported wheel capability, recording, inherited/explicit/disabled assignment, configuration loading/load failed, saving/saved/save failed and cleanup uncertainty. Distinguish unsaved edits prompting before Reload from an external file-revision conflict that prevents saving against a stale revision. Preserve the existing error messages and safe retry/reload paths; do not infer error kinds by parsing displayed strings. Offline/permission-blocked states keep editing available; current loading/restart guards remain.

**Exit checks:** every existing user operation has a destination; UI-only changes are separated from functional gaps; connection/save/activation vocabulary is agreed; the proposed decisions below are reviewed. No simulator, hardware test or source change is required to complete this planning task.

## UI-02 / Task441 — Device workspace and current Logitech editor

**Deliverable:** a signed app where the existing Logitech controls use the agreed workspace. Depends on UI-01 approval.

1. **Navigation and device row.** Use native sidebar selection, device name and a dot immediately beside status text. Retain back/forward history and current selection behavior. The configured profile name does not strengthen the existing protocol-level candidate identification claim. Keep detailed connection/capability/cleanup information on the device page.
2. **Application context.** All apps, configured applications, search and Add application in one dropdown/popover. Label it as editing scope: runtime delivery still resolves the foreground app at each physical press. Reuse the existing native application-bundle picker and model methods. Display a name/icon when available, with bundle-ID fallback; cache metadata on list changes, not every view render. No scan of all installed apps or second rule engine. Keep current history semantics for app/control changes.
3. **Bindable targets and inspector.** Back and Forward are both outlined and clickable across their full target areas; selected outline uses the gold accent. Use native Buttons with labels and keyboard/VoiceOver access. Recommend a small static vector mouse schematic with native Button overlays; it needs no external illustration asset or rendering engine. Inspector exposes Disabled/Shortcut for defaults and Inherit/Disabled/Shortcut for an app, plus preset, record, manual entry and cancel.
4. **Inheritance.** An inherited app assignment shows its effective shortcut and origin. An explicit override affects only that control in that app. Returning to Inherit removes the selected override. The current setter also deletes the app when its final override disappears; retaining that context versus returning to All apps is an owner decision, not settled behavior. Disabled posts no Hidhogg shortcut and is not native passthrough while the button session is intercepting. Keep the existing remove-app model action. Proposed UI safeguard: confirm removal when it would discard explicit assignments, naming the app and affected assignment count; Cancel leaves configuration unchanged.
5. **Device settings.** Vertical and thumb-wheel controls stay in a separate native panel labelled device-wide/all apps. Preserve all current direction/resolution/amount ranges, defaults, restore policy and capability/readback/blocker messages. A selected app must not imply app-specific scrolling. Wheel controls are settings, not additional shortcut-bindable hotspots.
6. **Status.** Connection, local persistence and binding readiness get separate labels. “Connected” does not mean a shortcut was delivered; “Saved” does not mean device reconciliation succeeded. Derive a minimal read-only UI projection from current state, including actual input admission; do not infer readiness solely from a connected transport or parse existing UI strings.

**Implementation boundary:** split the current large device Form into views with clear responsibilities: sidebar, device header/status, application selector, control canvas, assignment inspector and wheel settings. Keep one canonical configuration/draft and existing model commands. Presentation selection/search are transient UI state. Explicit small behavior seams for review are empty-app-context normalization/retention, canceling capture when its logical editor becomes inaccessible, read-only configuration editing after load failure, and typed save-failure presentation. These reuse existing configuration/cancel/recovery actions; they are not a transport, runtime-transition or schema rewrite. Defaults remain unchanged. No schema migration is expected for empty-context retention, but codec/store round-trip coverage is required before claiming it works.

Prefer the current [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) with a native [inspector](https://developer.apple.com/videos/play/wwdc2023/10161/), Form, Picker, Button and system sheets. Preserve access at the existing minimum window size; the inspector can be shown through a toolbar action when space is constrained. No additional package, runtime, polling loop or repeated artwork decoding.

**Acceptance checks:** select either target by its whole area and by keyboard; switch All apps/app context and verify the correct inheritance; edit via preset/record/manual controls; confirm switching target/app cancels the old recording; edit offline and observe saving; confirm device-wide wheel settings are unaffected by app selection. Existing device operations must continue to call the same model actions.

The visual review adds explicit capture transitions for history, Settings navigation, inspector visibility, app deactivation and workspace closure. Opening the manual shortcut sheet is a hand-off of the capture target, not an accidental cancellation. Disconnect or posting-permission changes do not prevent visible offline configuration. A capture callback must not commit to another target after navigation/cancellation. No observed production failure is claimed; these are source-audited lifecycle gaps to cover in the new UI.

**Parallel boundary:** after the owner approves the contract, one worker can own shell/context/canvas and another inspector/wheel subviews. The parent owns shared navigation/status interfaces and final integration. They must not both rewrite AppModel or the root workspace. Use an explorer for bounded context and an independent tester for the final gate.

## UI-03 / Task442 — Settings, accessibility and accepted checkpoint

**Deliverable:** coherent Settings and a reviewed native UI checkpoint. Depends on UI-02 integration; owner acceptance closes NX-M2 and releases the D200X implementation dependency.

Proposed native categories within the existing Settings workspace:

| Category | Existing operations retained |
|---|---|
| General | Connect on launch, Launch at login, actual macOS registration state/errors |
| Permissions | Accessibility and event-post checks, request/open System Settings, app icon drag, refresh, restart |
| Configuration | Actual file path, saved/error status, retry saving, manual reload and discard/conflict flow |
| Diagnostics & Recovery | Bounded Recent Activity, event IDs/codes/build/source, clear, process/build/bundle identity, restart |

Recommend a native category selector/TabView inside the existing workspace rather than another app window. Category selection is transient; preserve the accepted Dock/⌘Tab behavior and current route history. A permission warning on the device page should open the Permissions category directly. Restart remains readily accessible from the permissions flow even if its shared action is also exposed in Recovery. Do not add MCP controls or a Notifications page merely to fill the mockup.

**Accessibility and appearance:** native focus, keyboard navigation, meaningful labels and non-color state text; light/dark and increased text size; gold accent with native semantic warning/error/success colors; no clipped controls or inaccessible inspector at the supported window sizes. Use system surfaces and fonts. Keep expensive image/application metadata work out of frequently evaluated view bodies.

**Verification:** focused model/presentation tests for context/target/recording/status routing and the existing regression suite once the final source is frozen. Verify the signed fixed-path bundle. Source review checks for new polling, repeated decoding and unbounded view observation. Agree any native automation/performance measurement separately; do not claim an overnight bound or repeat a broad hardware campaign.

**Short owner gate:** (1) device/app/control selection and one binding edit; (2) wheel settings and offline/saved/error presentation; (3) permission recovery/Settings plus window close/reopen and keyboard accessibility. Keep these targeted. Record actual observations separately from synthetic test results.

## Proposed decisions for review

| Decision | Recommendation | Alternative considered |
|---|---|---|
| Navigation before additional adapters | Only the real Logitech device row and Settings | Mockup placeholders would imply unsupported functionality |
| Control canvas | Two bindable targets; wheel preferences in a device-wide panel | Four visually equivalent targets could suggest per-app wheel bindings |
| Mouse artwork | Small static vector schematic with native Button overlays | A detailed illustration requires an approved asset and separate hit-region alignment |
| Application selector | Search configured contexts; Add uses the existing app picker | Enumerating all installed apps adds scope and metadata work |
| Removing an application | Confirm before discarding explicit assignments | Immediate removal is current behavior but can discard overrides unexpectedly |
| Right-hand editor | Native inspector; all editing remains reachable when resized | Permanently fixed columns may clip the current minimum window |
| Save/apply | Retain immediate apply and one-second autosave | Manual Save in older boards is superseded |
| Connection wording | “Connected” separate from binding/input readiness | Current “Enabled” title combines transport and execution |
| Settings | Four native categories in the same workspace | Extra windows/nested permanent sidebars add navigation complexity |
| Model changes | Minimal read-only projection and transient presentation state | Broad runtime/configuration refactoring is not required for alignment |

The bounded code plan was approved on 2026-10-22, with the accepted choices at the top of this document taking precedence. Broader action, notification and MCP work remains a separate roadmap decision; D200X implementation remains after the accepted NX-M2 checkpoint.
