# Complete control presets — approved implementation, 1 November 2026

Owner wants presets to bundle tile appearance and behavior without first creating a separate named action. Manual configuration must remain available. Dial rotation needs paired left/right presets; dial press should use the tile-style action/preset flow. Owner approves keeping this in Tile Presets and requires defaults with icons for all currently supported actions. Manual edits, copy/current-profile/None-clears and action-only press semantics form the accepted boundary. Preserve the existing uncommitted Lock Screen implementation.

## Verified current boundary

`D200XTilePreset` already stores appearance, optional binding and embedded native/executable action definitions. `TilePresetEditorView` edits appearance but selects a copy of a separately configured action. `TilePresetsView` applies through an optional Include action toggle. `D200XModel.applyTilePreset` only accepts screen tiles. No paired rotation preset type exists. These findings come from the current source; previous uncommitted Lock Screen code must be preserved.

## Proposed experience

- A tile inspector offers **Choose preset…** beside normal manual configuration. A searchable chooser previews appearance and describes behavior; choosing Apply sets both together. Existing manual controls remain usable afterward.
- The preset editor contains a live preview, text/image/style fields and inline action type/options. A separate Actions-page creation step or manually managed action ID is not required. Existing named actions/custom executables remain advanced options.
- Dial rotation has its own preset category, storing left and right assignments together (for example Volume Down / Volume Up). Applying it changes both rotations atomically and leaves press unchanged. Both directions remain manually editable.
- Dial press uses the same action/preset chooser as tiles. Appearance is only applied to actual screen tiles; this slice does not add custom encoder-display commands. Front buttons may reuse the same action-only path.
- Starter presets should make the existing Lock Screen action immediately assignable; a Volume dial preset can reuse implemented volume actions. Preset management can group Tiles/Press and Dial Rotation within the existing library.

## Accepted application semantics

1. Apply a **copy**, not a live link: later preset edits do not change already assigned controls. Manual adjustments do not edit the library preset.
2. Apply within the currently edited app profile, respecting existing All Apps inheritance.
3. A complete tile preset explicitly specifies an action or None. None clears the old assignment; it must not silently retain a prior action underneath a new appearance.
4. Applying/configuring/saving presets never invokes actions. Keep existing import review and collision safety; manage generated action identifiers internally without overwriting unrelated definitions.
5. Preserve existing presets and package import/export. Prefer reusing the current tile model plus a separate paired rotation model over a new general-purpose action engine.

## Gates

- [x] Owner approves the flow and asks for all supported-action defaults with icons.
- [x] Define bounded domain/config/package changes and UI ownership.
- [x] Implement complete tile assignments, inline action authoring, and paired rotation presets.
- [x] Fake configuration/assignment tests cover atomic pairs, inheritance, no execution, old preset compatibility and action collisions.
- [x] Signed build and source manifests.
- [ ] Owner native usability and physical-effect checks.

Pages, brightness actions, multi-actions and new encoder-display behavior remain outside this proposal.

## Implementation contracts

Core owns domain/configuration, assets/packages, pure application and D200XModel methods. UI owns the shared action-template catalog/forms, preset library/editor and control inspector chooser. Root owns documentation and integration. No live app/device/private configuration/notification or platform effects are part of verification.

- Retain D200XTilePreset and tile package versions 1/2. Add D200XDialRotationPreset(name,left,right,actions,nativeActions) and configuration.dialRotationPresets, default empty, TOML dial_rotation_presets. Required rotation bindings may be disabled; only the exact referenced definitions may be embedded, at most two. Preserve old configurations/packages.
- Add pure D200XPresetApplication.applying overloads for tile and rotation presets. Tile targets accept screen tiles, front buttons and dial press; only screen tiles receive appearance. None becomes explicit disabled, including app-profile overrides. Rotation writes both left/right atomically, preserving press/held controls/topics/appearance. Remap colliding embedded action IDs internally across native/executable maps without overwriting unrelated definitions; reject limits before publishing one validated result. Applying a preset never runs it.
- New model entry points: applyTilePreset(id:String); applyTilePreset(preset:D200XTilePreset, control:D200XControl, applicationID:String?); applyDialRotationPreset(id:String,dialIndex:Int); applyDialRotationPreset(preset:D200XDialRotationPreset,dialIndex:Int,applicationID:String?). Direct variants reject a stale control/profile context; ID variants apply to current selection. Add save/remove/package/import rotation counterparts and importPresetImage(data:Data) async throws -> String. Keep legacy includeAction overloads for current tests/callers; new UI uses complete application.
- Rotation package is a separate bounded strict envelope, kind dial_rotation, version1, with no image. Imports keep definitions inside the preset and do not register or execute them. Existing tile package import/export stays intact. UI import dispatcher uses kind to select the appropriate decoder, with existing regular-file/no-follow/size limits.
- Core asset store adds importImage(data:Data) throws -> String using the existing normalized/content-hashed PNG path. UI rasterizes SF Symbol catalog icons into bounded transparent PNG data; saved/applied tile presets use ordinary appearance.imageAsset. No new appearance/renderer schema is required. Materialize the icon before a config edit; failure never publishes a missing asset reference.
- UI catalog covers all 16 existing action templates: Play/Pause, Next/Previous, Volume Up/Down/Mute/Set, Bell, Play Sound, Open Application/File/URL, Deck Notification, Keyboard Shortcut, Lock Screen, Custom Executable. Add Blank/None, plus paired Volume and Previous/Next rotation starters. All have library icons. Configurable paths/URLs/notification content/shortcut/executable start as non-applicable drafts until required input validates, not executable example values.
- Inline forms configure native, shortcut or executable snapshots without a separate Actions-page step or manually managed action ID. Existing named definitions remain an advanced copy option. Generate preset IDs internally from stable draft identity; use human names in normal UI. Keep imports reviewable, never executing on selection/save/apply.
- The chooser previews display and behavior, captures target/profile, and applies a complete copy. Opening/browsing does not clear manual settings; only explicit Apply changes configuration. Manual controls remain available after application. Defaults are a built-in catalog, not eagerly written to user configuration. Icons use the existing asset pipeline when saved/applied. Custom rotation entries may use a derived action/dial library icon; no physical dial display is added.

Validation: pure/model/config/package/catalog fixtures, no action execution or device writes; atomic pair and None/inheritance behavior, collision/limit failures, all-template coverage, legacy package/config round trips, stale async context rejection, and offscreen UI layouts. Build/sign the fixed dist app. Owner performs native assignment/physical-effect acceptance. No unrestricted native-window tests or live platform adapters.

### Shared UI contracts

Forms/catalog owner provides `D200XActionTemplate` (16 cases matching current ActionsView, title/systemSymbol/requiresConfiguration) and `D200XPresetActionDraft` with `init()` for None, `init(template:)`, `init(binding:actions:nativeActions:)`, and `snapshot(actionID:) throws -> D200XPresetActionSnapshot`. Snapshot has binding:D200XBinding?, actions:[String:ConfiguredExecutable], nativeActions:[String:NativeAction]. Draft exposes validationMessage:String?, summary:String and systemSymbol:String. Invalid/incomplete template drafts cannot snapshot. Advanced existing-action copies are immutable snapshots.

Reusable `D200XPresetActionEditorView(draft:Binding<D200XPresetActionDraft>, configuration:D200XConfiguration?)` edits only the draft. `D200XPresetFieldsView(model:D200XModel, name:Binding<String>, appearance:Binding<D200XTileAppearance>, action:Binding<D200XPresetActionDraft>, showsAppearance:Bool)` provides human-name/preview/appearance plus the inline action form; no save/apply side effect. `D200XPresetIconRenderer.pngData(systemSymbol:) throws -> Data` creates bounded transparent white-glyph PNGs. Generate action identifiers and preset IDs internally; normal forms show names, not ID fields.

TilePresetEditorView retains its current initializer, optionally adding initialTemplate:D200XActionTemplate? = nil. A new DialRotationPresetEditorView uses the same model/selectedID/draftID/onSaved initializer pattern. Both are library-save wrappers; chooser owns its captured target/app context and explicit Apply. Library/chooser owner may build direct draft-to-preset values from the shared snapshot and materialize template icons via the model image-data import before applying. Forms/catalog owner will communicate any unavoidable signature adjustment before dependent edits.

## Implementation checkpoint

Core worker owns domain/config/model/application/packages/assets and bounded fixtures. Forms/catalog worker owns shared types/forms/icons and both library editors. Library worker owns the Tile Presets page, control inspector chooser, and kind-routed import review. Sources are frozen and integrated verification passes; earlier domain/config builds and failed compiler/fixture iterations are retained as history.

## Verified complete-preset delivery — 1 November 2026

All 16 supported action templates plus Blank/None appear under Tile Presets with icons. Volume and Previous/Next dial starters are paired. Incomplete paths, URL, notification content, shortcut or executable remain drafts until valid. Tile/press preset creation uses inline action fields and generated IDs. The control chooser applies complete copies while preserving manual controls. None clears the current assignment, including per-app inheritance. Press/front assignments ignore appearance; rotation changes left/right together without changing press/held mappings. Matching definitions reuse IDs across fresh drafts; 100 repeated Lock Screen applications do not fill the registry. Deleted profiles cannot be recreated by a stale chooser.

Built-in glyphs are 256-pixel white PNGs with transparent margins and caption space. In-memory previews and saved assets share the base-image renderer, leaving notification title semantics unchanged. Browsing creates no asset files. Tile packages retain versions 1/2 and their schema. New dial packages have strict kind/version/nested validation and a 256 KiB limit; dispatcher uses regular-file/no-follow/size checks and imports retain action review. Nonempty dial_rotation_presets requires a decoder that recognises the new field.

Independent focused gate passes68; full offline gate passes862 (535XCTest+327SwiftTesting), zero failures. WakeConnectionTests/NativeWorkspaceWindowTests are explicitly excluded. Separate offscreen fixtures use never-shown windows, prohibited activation, fake input, temporary assets and zero edit/action assertions; captures are in /Volumes/Data/tmp/DX-PRESET-offscreen. The tile editor is scrollable beyond the fixed captured viewport. Native interaction and physical behavior remain owner checks.

Signed app/CLI build6c525941148c110394225a35c911533ba417eee8baa8a2e7a5ebc6d0d14f72fc passes strict signatures. All269Swift/package/script inputs match focused/full test/build manifests; digest a84c79b9b8985ff01134379b7116d92ae718c61c537f74e003a5053bebfdb997. Logs /Volumes/Data/tmp/DX-PRESET-focused.log, DX-PRESET-full.log, DX-PRESET-verification.json, DX-PRESET-postbuild.sha256 and hidhogg-complete-presets-release-20261101.log. Earlier four compiler issues and one invalid test-fixture root are preserved in the result; the fixture was corrected without weakening strict-key checks.

No production app, device/HID command, real keyboard/lock event, notification, media query, environment inspection or private configuration was used. Owner should restart updated app, select a tile and Choose Preset, apply a complete Lock Screen preset when ready, configure URL/shortcut inline, and apply dial Volume while confirming press stays unchanged. Check current-app-profile scope, None clearing, manual edits and package sharing. Source remains uncommitted after master3dc576f, including the earlier Lock Screen source/tests and individual-action review docs; no push or new check-in is requested.
