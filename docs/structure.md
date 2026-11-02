# Structure

Updated 26 October 2026. The active implementation is the Swift package under app; local Xcode user metadata under macos is not a production build input.

## Modules

| Path | Responsibility |
|---|---|
| app/Sources/HidhoggDomain | Validated configuration, bindings, profiles, presets, topics and static action definitions |
| app/Sources/HidhoggConfiguration | Strict legacy/registry TOML codecs, versioned device payloads and coordinated revision-aware publication |
| app/Sources/LogitechBolt | HID++ framing/correlation, IOHID transport, discovery, routing ownership and verified mouse reconciliation |
| app/Sources/UlanziD200X | Bounded frames, input/identity codecs, page archives, IOHID transport and generation-bound session maintenance |
| app/Sources/LofreeFlowLite84 | Receiver-specific read-only status codec, exact non-seizing discovery and serialized session |
| app/Sources/FlowLite84StatusProbe | Developer-only, explicit --read-only one-snapshot diagnostic; not bundled in the app |
| app/Sources/MacOSActions | Permission adapters, shortcut/scroll posting and injected native media, volume, sound and opener services |
| app/Sources/HidhoggAutomation | Local wire protocol/server, notification overlay store, bounded process/native action lanes and metadata history |
| app/Sources/HidhoggApp | Native workspace/menu, canonical app model, device models and editor/lifecycle composition |
| app/Sources/HidhoggCLI | hidhoggctl client for the existing local service; it does not launch the app |
| app/Tests | Domain, codec, fake transport/action/server, model and opt-in background window tests |
| app/Branding.xcassets | App accent and decorative template device icons |
| scripts/build-app.sh | Signed arm64 release packaging of the app and adjacent CLI |
| docs | Current architecture/roadmap, decisions, acceptance records and preserved research/mockups |
| .agents | Main-agent continuity log and handoff |
| dist | Ignored local signed artifacts and source/build provenance |
| spikes, scripts/diagnostics | Historical experiments and research tools, not runtime dependencies |

## Ownership boundaries

AppModel owns ConfigurationDocument, autosave/reload, workspace navigation, startup and Logitech connection intent. BoltController owns one selected transport, request-ID ledger, capability discovery, recognised routing reclamation and verification. WakeRecoveryCoordinator owns the cancellable application retry schedule. Native input admission checks remain tied to verified generations.

LC-02 adds `LogitechAssociation` for persisted unit/model identity and transport preference, plus an explicit preferred registration UUID. `LogitechEndpointCatalog` enumerates eligible native endpoints; bounded read-only probes resolve their current slots against that identity. `MouseConnectionSelectorView` presents existing verified candidates. Association is saved before targeted discovery, and editor selection does not select the runtime owner. MX Master 4 bypasses the MX3S button/control path; LC-05A independently admits validated main-wheel preferences while other management remains read-only. See [scope, verification and hardware limits](logitech-lc02-plan.md).

LC-07 adds `BoltReceiverManaging`, public inventory/outcome types and the standalone `BoltReceiverManagementSession` actor. It owns pinned receiver handles, opaque snapshot/row authority, all-slot reads, single selected Unpair and post-diff verification. AppModel serializes this session with runtime management/scans/pairing and lifecycle cleanup. The original `BoltReceiverManagementView`/`BoltStoredPairingRowView` remain compiled but inactive in setup. Current `LogitechDevicesListView` combines cached inventories, verified endpoints, remembered registrations and new Bolt candidates; `LogitechStoredBoltDeviceRow` owns fresh-token confirmation. No registry/schema mutation is part of receiver unpairing. See [contracts and limits](logitech-receiver-management-plan.md).

Advertisement device kind is normalized from byte7 low nibble per shipped native parser evidence. Literal MX4 field-layout tests cover upper bits, true kind/authentication exclusion and identity conflicts; these are synthetic protocol checks, and the owner separately confirmed the reported discovery failure resolved. [Correction evidence](logitech-discovery-regression-2026-11-02.md).

`HIDPP2121V1` is the pure shared capability/mode codec and owned-field preference planner. `BoltController` keeps feature/identity/token/lifecycle validation, readback and narrow physical-wheel mutation authority. `BoltWheelStatus.supportsInversion` is separate from feature readiness; `supportsManagement` staysfalse for MX4, preserving button/thumbwheel/capture exclusion. AppModel resolves capability-based settings availability and routes wheel-only requests through the non-amount interface. Version-specific button/mechanical/sensor adapters are later work. `CardContentPadding` centralizes custom-card insets while native Form layout is retained. [Scope](padding-mx4-settings-plan.md).

Pairing recovery separates protocol/session evidence from presentation. `BoltPairingSession` joins bounded transient discovery-counter aliases onto candidates identified by parsed session metadata, preserves discovery errors through cleanup, and reconciles terminal authentication failure with fresh full receiver inventory. `BoltPairingChallengePresentationState` derives the highlighted action from receiver progress and entry completion; `BoltPairingChallengeView` renders that state. AppModel owns the fresh-connection/all-accessible-receiver recovery gate and keeps stale cached rows separate from action authority. Implementation is offline verified and signed; hardware behavior remains an owner check. See [pairing recovery](logitech-pairing-recovery-plan.md).

LC-04 adds `BoltReceiverProtocol` for receiver register framing/correlation and typed notifications, and `BoltPairingSession` for one pinned receiver's discovery, authentication, cancellation and record/identity verification. `LogitechIdentityReader` shares the dynamic feature lookup with the existing controller. `LogitechSetupView` composes endpoint inventory and inline Bolt pairing sections on one centre-pane route. `LogitechSetupDestination` distinguishes addition from reassociation; AppModel owns staged persistence, cleanup barriers and truthful late-success outcomes. Older `BoltPairingView` and `MouseConnectionSelectorView` remain compiled without workspace sheet entry points. See [compact setup](logitech-compact-setup-plan.md). Ordinary model construction remains inert; production injects a fresh pairing session. See [Bolt scope and hardware limits](logitech-bolt-pairing-plan.md).

D200XModel is independently observed by its views and owns D200X connection intent, foreground profile resolution, rendering, action context and ordered power transitions. D200XSession owns the transport, reader, handshake, maintenance query/deadline state and pause/resume revisions. The model is the sole page-write coordinator; UI views do not write HID frames.

FlowLite84Model owns read-only keyboard connection intent, lifecycle and the hourly keyboard-activity throttle. Production composition injects AppKitKeyboardActivityMonitor; tests default to an inert monitor. The monitor reports activity without accessing key contents and owns native event-monitor registration/removal. FlowLite84Session serializes full and battery-only read batches; full-snapshot and battery timestamps are separate. Startup follows the shared Connect on launch preference without overriding an earlier explicit keyboard decision.

Configuration paths and file state belong to HidhoggConfiguration. Static values and validation belong to HidhoggDomain. Live device handles, notification text, capture sessions and action-origin context are not persisted into those values.

## Workspace and editing

WorkspaceView composes the device sidebar, management pages and native HSplitView inspector. WorkspaceInspectorInitialWidthAdapter performs the bounded initial divider adjustment. Do not replace this with the previously rejected SwiftUI inspector bridge.

Mouse artwork uses cached native vector paths from the approved SVG. Region buttons and callouts select controls without issuing transport requests. D200XDeckView similarly owns selection and geometry; its keys/front controls/dial gestures retain their physical mappings.

ActionsView, NotificationsView and TilePresetsView own their management layouts. ConfiguredExecutableArgumentsDraft retains stable rows of literal argument strings for the executable editor, preserving empty values and embedded newlines. D200XControlInspectorView owns temporary assignment/capture UI, while model methods apply the selected edit. Application selectors edit one profile without changing runtime selection. Clear writes an explicit disabled override; Use All Apps Default removes the override.

D200XAssetStore bounds imported and stored image data. D200XPageRenderer draws PNGs off the main actor. Device wide output uses 458×196; the explicit preview destination keeps its previous bitmap/layout. D200XTilePresetPackage validates portable copied images and optional immutable action definitions before applying independent copies.

## Automation and platform effects

D200XAutomationCoordinator joins local requests, subscriptions, transactional notification overlays and captured control/profile origins. NotificationOverlayStore bounds receipt/history state and handles replacement, expiry and dismissal. Message text is retained only by the opt-in bounded live listener.

ConfiguredActionRunner separates one executable lane and one native lane, sharing eight queued slots and bounded history. Clearing history does not stop running work. AppNativeActionRunner validates captured runtime context before physical native effects. NativeActionSender and its injected services contain AppKit/Core Audio operations; tests use fakes.

LocalAutomationServer owns a private same-user Unix endpoint. It rejects unsafe existing endpoints rather than deleting them. HidhoggCLI uses the shared protocol and does not retry potentially consequential requests automatically.

## Permissions, lifecycle and tests

LowBatteryNotificationController separates saved per-device alert preference from app-wide authorization and the operational episode latch. Compact permission rows request only through explicit user actions; rendering/refreshing does not prompt.

The per-user application lease precedes SwiftUI model construction. WorkspacePresentationCoordinator and small native adapters control window visibility and activation. Device models remain alive when the workspace closes.

Default tests use synthetic configuration, devices and action services. NativeWorkspaceWindowTests is opt-in, uses non-key background windows and fake adapters, and cannot prove physical input or platform effects. Only the main agent edits .agents/log.md and .agents/handoff.md.

Detailed evidence: [D200X decisions](d200x-workspace-evolution-plan.md), [native actions](native-action-catalog-proposal.md), [Logitech recovery](logitech-reconnection.md), [permissions](settings-permissions-plan.md).

## Device registry (REG-01)

WorkspaceConfiguration owns UUID registration metadata and typed per-family payloads. AppModel holds the registry plus the existing strict editor projection; registry membership/enabled state gates runtime management independently of that projection. Existing hardware adapters remain singletons with one registration per supported family. Sidebar and menu enumerate registrations. ConfigurationStore coordinates migration backup, per-device payload publication and root registry publication; FileRevision covers root and every referenced payload. Payload filenames are flat and content-hashed; obsolete recognizable files are collected only after durable registry publication. Legacy nested paths remain readable and migrate on load. The configuration-directory asset base is unchanged.

## Generic Bluetooth monitoring (BT-01)

GenericBluetooth isolates public paired inventory/authorization/connection notifications, conservative System Information and IORegistry battery parsers, and a bounded read-only process reader. GenericBluetoothModel owns UUID/endpoint observation state, one coalesced refresh lane and registration/lifecycle generations. Platform adapters are explicit production injections; ordinary test/model construction is inert. AppModel persists normalized paired-address endpoints in generic payloads, with multiple generic registrations and one native family adapter each. Generic navigation is UUID-specific; shared management controls capture removal identity. Source data/names/addresses are never diagnostic output.

GenericBluetoothConfiguration holds endpoint, battery-alert preferences and optional icon override. GenericBluetoothAlertCoordinator consumes accepted sample identifiers, owns per-registration/component notification latches and fences asynchronous delivery against lifecycle changes; LowBatteryNotificationController remains the shared authorization owner. MenuBarDeviceRow owns aligned status presentation within the menu-bar popover; BluetoothDeviceIcon uses reported class metadata or an explicit override, falling back to a drawn Bluetooth symbol.


The discovery UI follow-up uses one AnyLayout subtree in LogitechSetupView with parent-owned Stored Pairings expansion. BoltDiscoveryDiagnostics carries numeric per-attempt typed-event counts in BoltPairingStatus; BoltDiscoveryDiagnosticsView displays selectable summaries without adding log/persistence paths. See docs/logitech-discovery-ui-followup.md.


BoltNativeInputDiagnostics is a numeric-only callback disposition snapshot owned by the native worker. BoltReceiverTransport supplies an unavailable default; native transport returns serialized RAM counts and retains a close snapshot. BoltPairingSession merges snapshots monotonically within the current generation and resets on the next attempt. No raw report or identity is added to diagnostics. Discovery details renders native availability separately from typed-event counts.


BoltReceiverNotificationLease calculates the temporary0x900 mask/owned additions. BoltPairingSession owns its setup/readback/cleanup lifetime with cancellation and verification drain barriers; separate status messages/attention preserve verified outcomes and surface cleanup uncertainty. AppModel caches all receiver inventories for display while retaining only one fresh active management snapshot as Unpair authority. Full successful refresh replaces ephemeral receiver IDs atomically. See docs/logitech-notification-discovery-plan.md.

## Combined mouse settings — 2 November 2026

MouseHardwarePreferences stores per-registration intent; strict TOML codecs preserve sparse optional bindings and explicit directions. BoltHardwareSettings exposes capability/readback state; HIDPPHardwareSettings plans snapshots, while BoltController retains identity/IO/ownership/restore. Granular flags authorize button/wheel/thumb writes independently. AppModel debounces hardware200ms and reconciles per-app button subsets behind a dispatch fence; MouseHardwareSettingsView owns workspace settings. V2 DPI is read-only and independent pointer speed deferred. See docs/mouse-settings-milestone.md.
