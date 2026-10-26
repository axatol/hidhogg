# Structure

Updated 26 October 2026. The active implementation is the Swift package under app; local Xcode user metadata under macos is not a production build input.

## Modules

| Path | Responsibility |
|---|---|
| app/Sources/HidhoggDomain | Validated configuration, bindings, profiles, presets, topics and static action definitions |
| app/Sources/HidhoggConfiguration | Strict TOML codec, configuration paths and revision-aware file persistence |
| app/Sources/LogitechBolt | HID++ framing/correlation, IOHID transport, discovery, routing ownership and verified mouse reconciliation |
| app/Sources/UlanziD200X | Bounded frames, input/identity codecs, page archives, IOHID transport and generation-bound session maintenance |
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

D200XModel is independently observed by its views and owns D200X connection intent, foreground profile resolution, rendering, action context and ordered power transitions. D200XSession owns the transport, reader, handshake, maintenance query/deadline state and pause/resume revisions. The model is the sole page-write coordinator; UI views do not write HID frames.

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
