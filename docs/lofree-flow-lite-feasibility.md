# Lofree Flow Lite84 feasibility

**Evidence date:** 26 October 2026. **Target:** the original 84-key Flow Lite84, configured through the observed 2.4 GHz receiver. The user confirmed “firmware status/version” means read-only version display; firmware installation is outside this assessment. The official catalog lists Flow Lite84 and Flow Lite100 separately, and lists Flow 2 separately with VIA, so their controls and firmware claims do not transfer to this target. ([Flow Lite84 product page](https://www.lofree.co/products/flow-lite84-mechanical-keyboard), [Download Center](https://www.lofree.co/pages/download-center), accessed 26 October 2026.)

## Feature assessment

| Feature | Evidence and feasibility | Limitation / gate |
|---|---|---|
| Receiver discovery | A native read-only query previously identified the observed 2.4 GHz receiver path and read the keyboard identity and four keymaps. The observed collection is specific to that receiver; successful typing over Bluetooth or USB does not establish configuration access over those transports. ([manual validation](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/manual-validation.md>), [transport contract](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/transport-swift.md#identity-and-discovery>)) | Scope the first connection slice to this matched receiver. Packaged-app permissions and other transports remain unverified. |
| Battery reporting | Lofree documents physical indicator states: charging blinks white, charged stays white, below 20% blinks red slowly, and below 5% blinks red rapidly. The recovered client reads a battery reply containing a reported level, charging flag, and voltage; its displayed percentage is host-derived and smoothed. ([Flow Lite84 manual](https://cdn.shopify.com/s/files/1/2779/9046/files/Flow_Lite84_User_Manual.pdf?v=1747372676), [battery reconstruction](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/macros-lighting-settings.md#battery-and-asynchronous-state>)) | The earlier native probe allowlist did not include battery command 4, and no actual battery telemetry was validated. Static replay found an anomalous percentage boundary at 4,110 mV. Treat percentage as an estimate until device readings are checked; do not present the vendor smoothing algorithm as measured accuracy. ([transport contract](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/transport-swift.md#commands-and-replies>)) |
| Firmware version | The native transport contract identifies separate keyboard and receiver version queries; an earlier hardware read observed keyboard firmware `v1.61` on 19 October 2026. That is a dated observation, not a claim about the current device or latest release. ([transport contract](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/transport-swift.md#commands-and-replies>), [manual validation](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/manual-validation.md>)) | Read-only version display is feasible. Public product/download pages inspected here do not specify a current firmware version or release policy; flashing is excluded. ([product page](https://www.lofree.co/products/flow-lite84-mechanical-keyboard), [Download Center](https://www.lofree.co/pages/download-center)) |
| Backlight | The official specification says white backlight. The user manual documents a physical shortcut that cycles `Steady / Breathe / Off`, plus `Fn+F5/F6` brightness adjustments. ([product page](https://www.lofree.co/products/flow-lite84-mechanical-keyboard), [Flow Lite84 manual](https://cdn.shopify.com/s/files/1/2779/9046/files/Flow_Lite84_User_Manual.pdf?v=1747372676)) | The retained web-configurator reconstruction describes a separate light state and mode, seven named effect IDs, and brightness stored as 0–4 but displayed as 1–5. A prior owner correction says the web control uses `Static` and level 1 means off; that level mapping remains unverified. The manual documents hardware shortcuts, not the complete web-configurator control model. Keep these evidence sets separate until the UI semantics are verified. ([feature matrix](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/feature-matrix.md#user-facing-features>), [lighting reconstruction](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/macros-lighting-settings.md#lighting-bytes-and-controls>)) |
| Mac / Windows mode | Lofree lists macOS and Windows compatibility and describes Key Mapper for Windows and Mac. Its manual documents `Fn+N` for Windows/Android system keys and `Fn+M` for Mac/iOS system keys. ([product page](https://www.lofree.co/products/flow-lite84-mechanical-keyboard), [Download Center](https://www.lofree.co/pages/download-center), [Flow Lite84 manual](https://cdn.shopify.com/s/files/1/2779/9046/files/Flow_Lite84_User_Manual.pdf?v=1747372676)) | This confirms user-operated shortcuts. The recovered configurator also writes a `CurrentSystem` setting, but that write path and its persistence have not been hardware-validated. Start with the documented shortcuts; consider native mode control only as a separately scoped, backed-up, readback-verified setting. ([Swift reconstruction](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/swift-reconstruction.md#feature-coverage>), [settings reconstruction](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/macros-lighting-settings.md#polling-and-generic-hidden-settings>)) |

## First vertical slice

1. Propose a receiver-scoped, read-only native status view for identity, online state, battery/charging/voltage, keyboard/receiver versions and targeted lighting/current-system snapshots. Battery command 4 is an explicit addition to the previous probe allowlist, not permission inherited from the old run. Code can first be developed and tested with fakes; an active read-only receiver probe needs the owner's approval of this expanded scope. Label the returned level as reported, keep last-read/stale state visible, and keep any host-derived estimate distinct until real readings are compared. Do not read private macros or keymap content merely to show these status fields. ([transport contract](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/transport-swift.md#commands-and-replies>), [Flow Lite84 manual](https://cdn.shopify.com/s/files/1/2779/9046/files/Flow_Lite84_User_Manual.pdf?v=1747372676))
2. Treat setting writes as a later, separately authorized slice. For one setting at a time, capture exact original bytes, preview the change, read back the exact field, verify its physical effect, and restore the original. Resolve the lighting labels before exposing a level/mode picker. ([Swift reconstruction](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/swift-reconstruction.md#implementation-boundary>), [manual validation](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/manual-validation.md>))

Do not include firmware flashing, pairing, reset, macros, or keymap writes in this slice. The previous hardware checks establish unchanged keymaps after power cycle and receiver reconnection, not persistence of newly written settings. ([manual validation](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/manual-validation.md>))

## Proposed native roadmap

TaskView Personal / HIDhogg project 5, list 78. The assessment itself performed no native implementation or live device queries. Subsequently, on 26 October 2026, the owner approved FL-01 implementation and bounded read-only status queries after fake validation; FL-M1/FL-01 are now In Progress. The [implementation contract and checklist](flow-lite84-implementation.md) tracks that work. FL-02/03 writes remain separately gated. FL codes are separate from the investigation's historical LF84 probe IDs.

| Stable ID | TaskView | Deliverable | Gate |
|---|---:|---|---|
| FL-M1 | 492 | Flow Lite84 native status and controls milestone | Review and approve the staged scope |
| FL-01 | 493 | Exact receiver/session, battery/charging, versions and read-only lighting/OS snapshots in the native workspace | Fake codec/model checks, signed build, separately approved bounded status queries; verify battery precision and physical-mode meaning |
| FL-02 | 494 | Verified white-backlight settings | FL-01, exact originals, resolved labels/levels, explicit write approval, acknowledgement/readback and restoration |
| FL-03 | 495 | Deliberate Mac/Windows mode change | FL-01, compare stored selector with manual Fn+N/Fn+M, explicit write approval and restoration |

~~~text
FL-01: read-only status and snapshots
                    |
          +---------+---------+
          |                   |
FL-02: lighting        FL-03: OS mode
backed up + verified  deliberate + verified
~~~

Suggested module boundary: a model-specific Flow Lite84 codec/session owns the exact receiver and serialised queries; its app model owns observed/stale state and the native device page. Keep it alongside the Logitech and D200X modules, with no shared protocol assumptions and no normal keyboard-input interception. An editing profile/tab must never change physical OS mode implicitly. This is a proposal grounded in the [native transport contract](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/transport-swift.md#swift-module-design>) and [OS selector findings](</Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/bindings-profiles.md:40>), not an implemented interface.

## Current assessment checklist

- [x] Re-read the current local investigation instead of relying on older memory.
- [x] Confirm the completed historical receiver query and reconnect/power-cycle evidence.
- [x] Check current official product/download sources and visually inspect the official manual.
- [x] Record user-confirmed firmware-status requirement and the battery/lighting/OS uncertainties.
- [x] Create stable proposed tasks and dependencies in the existing HIDhogg project.
- [ ] Owner approves FL-01 implementation and explicitly scoped active reads.
- [ ] Implement, test and validate the approved first slice.

## Sources

Official product, download, and manual pages above were accessed on 26 October 2026. The official one-page manual was rendered locally from the linked PDF for visual inspection; its labels above are from the English panel. Local investigation records under `/Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/` provide dated static, synthetic, and prior hardware evidence; those evidence classes are identified separately above.
