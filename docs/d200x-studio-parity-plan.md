# D200X core Studio parity proposal

28 October 2026 update: the owner approved and the signed app now implements the seven built-in wide modes/12–24h, explicit custom-screensaver preview/Apply and static app-ID notifications. The [current plan and 206-test evidence](d200x-display-controls-plan.md) supersede deferred statements for those features below. Screensaver original restoration/timeout, mode100/command17, flashing and a live Now Playing provider remain outside this initial slice; the [media spike](d200x-now-playing-spike.md) is complete. Physical acceptance remains open; no agent device writes were performed.

Reviewed2026-10-23. Owner approved appearance and local automation implementation on23October2026; deck branding/shadow removal is separately approved and delivered. Investigation reviewed through its21October2026 addenda; no22–23October addendum found in the targeted sources. Native source confirms first-slice shortcuts/page/maintenance, not complete vendor parity.

## Sequence

| Slice | Deliverable | Gate |
|---|---|---|
| Next: core appearance (DX-05 scope) | Per-device brightness, static key image import, optional host-rendered titles/style | Offline protocol/config/asset/render tests, then owner physical checks |
| Pages and profiles | Create/rename/delete/reorder pages; front-button page navigation; app-specific page/profile selection | Define selected-editing context versus live foreground behavior and migration |
| Native actions | Open app/URL, media/volume, text, ordered multi-actions with cancellation | Per-action platform permissions and focused native acceptance |
| Wide display and idle | Built-in clocks/status, truthful CPU/RAM/GPU availability, explicit custom screensaver | Separate persistent display/asset replacement boundary |
| Encoder display and integrations | Only after model-specific schema evidence; assess plugin/integration parity separately | No guessed mode100/command17 payloads |

Firmware installation, vendor plugin binary compatibility and cloud services remain outside the existing approved roadmap; full ecosystem parity is not claimed. Official product overview https://www.ulanzi.com/en-gb/collections/studio-setup/products/d200x-creative-deck describes broader integrations beyond core local features.

## Proposed next implementation boundary

- Brightness: optional saved preference, unset preserves current behavior. Native control25–100 based on research samples25/60/100; coalesced immediate changes while connected and saved with existing debounce; desired state applied on reconnect. Public device command10 decimal ASCII through serialized session. No brightness readback established: show desired/sent state, never Verified. No automatic reset on disconnect.
- Static images: native PNG/JPEG picker for all14keys including the wide key; decode with bounded byte/dimension limits, copy normalized assets into an assets directory beside the active TOML configuration, save relative content-addressed references, never depend on the source file remaining available. Explicit Remove restores label/background rendering. Preserve aspect ratio using contain-fit initially; no GIF/animation/editor/dependency in this slice.
- Titles: optional text over imported image, size/colour/placement controls rendered by existing CoreGraphics/CoreText PNG path. Retain current defaults for existing configs. These are host-rendered controls, not assertions of firmware Font command11 behavior. Keep fixed firmware font reply unchanged; global font precedence/units/fallback remain unresolved.
- Boundaries: separate asset store/render/config/session/UI responsibilities; no new process, broad action engine, plugin runner or polling loop. No physical device actions by agents. User launches/tests the built app; no firmware/reset/pairing/screensaver overwrite in this slice.
- Verification: command10 framing; old/new TOML round trips; asset copy/validation/missing asset fallback; standard/wide rendering and incremental one-slot updates; coalesced edits/generation-safe reconnect; existing background native window gate and signed fixed bundle. Scope approval required before writing feature code.

## Evidence and decisions

Research: /Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/inventory.md:138–165; feature-investigation.md:18–49; swift-specification.md:25–62. Current renderer app/Sources/HidhoggApp/D200XPageRenderer.swift already bakes labels into PNGs; app/Sources/UlanziD200X/D200XPage.swift already packages content-derived images. Native host rendering is chosen over firmware fonts to avoid unresolved precedence/units. Screensaver is deferred because replacement has no original backup and persistence boundaries remain unresolved. Pages/profiles and richer actions need independent definitions rather than assuming vendor semantics.

TaskView read-only revalidation: project5 HIDhogg exists; current task list exposes legacy V2 D200X entries124/125, but the locally documented DX task444–449 records were not returned. Do not silently remap immutable task IDs; reconcile/create approved next-slice tasks after scope approval.

## Checklist

- [x] review current implementation and latest bounded investigation
- [x] outline core parity sequence and decisions/alternatives
- [x] owner approves next appearance slice
- [x] reconcile TaskView task mapping and implementation checklist
- [x] implement and verify offline
- [ ] owner physical acceptance

## Owner-added Hidhogg capabilities —2026-10-23

Parity target includes prior Hidhogg capabilities, not only Studio features. Historical source contracts docs/archive/v2/m07-notification-plan.md:7–32 define local source-filtered notification overlays, latest-wins replacement, TTL, explicit clear and physical dismissal before configured static action; notification content never supplies executable instructions. docs/archive/v2/v2-plan.md:123 records configured executable actions, bounded queues/history and captured immutable bindings. These are historical behavior references, not working features in the current slice.

Add a dedicated local automation/notifications slice: source subscriptions on device controls, local script/CLI emission and clearing, optional TTL, bounded receipt/delivery history with matched control/outcome, configured executable/script actions, and explicit local triggering of named actions if owner confirms both directions. Preserve static action configuration separate from notification payloads; no remote/network ingestion implied. Reuse native app-owned execution, per-user local interface and event correlation; no separate legacy runtime resurrection. Confirm whether scripting means scripts driving Hidhogg, controls launching scripts, or both before feature code. This scope is proposed; next appearance slice still awaits approval.
