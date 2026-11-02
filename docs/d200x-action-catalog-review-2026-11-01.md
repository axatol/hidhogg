# D200X individual-action review — 1 November 2026

User direction: keep pages/folders out of scope and examine useful individual actions before prioritising multi-actions. Brightness and Lock Screen are explicit candidates. No feature code, device/media operation or key delivery was performed in this review.

Later 1 November scope decision: the owner approves Lock Screen only. A named `lock_screen` action has been implemented through the existing shortcut sender; verification and owner acceptance are tracked in the [Lock Screen plan](d200x-lock-screen-plan.md). Brightness remains deferred.

## Recovered Studio actions versus HidHogg

The local catalog is a **Studio 3.1.9 snapshot recovered on 20 October 2026**, not proof of every action in current Studio releases. Shipped manifests establish action declarations, not complete macOS execution or D200X encoder applicability. Source: [bundled action catalog](/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/artifacts/2026-10-20/bundled-action-catalog.json), [parameters and dispatch findings](/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/findings.md).

| Studio action | Current HidHogg coverage |
|---|---|
| Open application/file; Website | Open App, Open File and Open URL actions implemented |
| Hotkey | Shortcut action implemented |
| Multimedia | Play/Pause, previous/next track and volume up/down/mute/set implemented; complete Studio multimedia value enumeration remains unresolved |
| Close application | No named native action |
| Text (including optional Enter/typing mode) | No named text-insertion action |
| Hotkey Switch | No alternating-shortcut action |
| Play Audio | Play Sound implemented; Studio output-device, play/fade mode and volume parameters are not all implemented or verified |
| Stop Audio | No bindable Stop Sound action; current player stops during lifecycle cleanup |
| Multi Action, Multi Action Switch, Random Action, Delay | Not implemented; not selected as the immediate next slice |
| OBS integration | Catalog declares recording, streaming, scenes/sources, replay buffer and audio mixer actions; no dedicated integration in HidHogg |
| Ulanzi lighting integration | On/Off, Brightness, CCT, Hue and effects declared; no dedicated integration in HidHogg |

The separate Dial-only and TC002 declarations are not D200X parity requirements. Page/folder/profile-navigation catalog actions are deliberately excluded here. Current Hidhogg source: [NativeAction kinds/validation](/Users/axatol/Workspace/axatol/hidhogg/app/Sources/HidhoggDomain/NativeAction.swift), [platform executor](/Users/axatol/Workspace/axatol/hidhogg/app/Sources/MacOSActions/NativeActionSender.swift).

## Brightness has separate targets

- **D200X screen:** HidHogg already has a saved device setting and serialized brightness command. A named Set Brightness / Increase / Decrease action would be new. The investigation establishes a settings/command path, not a recovered Studio bindable deck-brightness action. Host desired brightness is available; firmware readback is not. [Current model](/Users/axatol/Workspace/axatol/hidhogg/app/Sources/HidhoggApp/D200XModel.swift), [brightness investigation](/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/feature-investigation.md).
- **Mac display:** current HidHogg media keys do not include brightness. Public SDK `IOKit/hidsystem/ev_keymap.h` defines brightness-up/down key types 2/3, so extending the existing system-key adapter is a plausible implementation. No key was sent and no display compatibility was established. Absolute percentages and arbitrary external-monitor support need a separate adapter/evidence decision.
- **Lighting/other devices:** catalog entries named Brightness belong to Ulanzi lighting and TC002 integrations. They do not establish universal Mac-monitor or D200X brightness actions.

The current [official Dial Mini guide](https://docs.ulanzistudio.com/dialmini/en/software/) describes Studio brightness use and shared action categories, but its gesture/lighting/sleep instructions are device-specific. Do not transfer them wholesale to D200X.

## Lock Screen

Apple documents **Control–Command–Q** as Lock Screen ([Mac keyboard shortcuts](https://support.apple.com/en-us/102650)). HidHogg can represent that chord with its existing shortcut action; a named preset/action would improve discoverability. This review does not establish a dedicated Studio macOS Lock Screen action. An [official Studio forum discussion](https://www.bbs.ulanzistudio.com/archiver/tid-416.html) mentions a Windows Shortcuts plugin; that is not evidence of equivalent macOS built-in support. No locking command was executed.

## Proposed order, awaiting scope confirmation

1. Lock Screen and brightness actions, once the user confirms D200X versus Mac display targets. Prefer named first-class actions/presets in the existing Actions page, available to keys and ordinary dial gestures.
2. Text snippets, graceful Close App, Stop Sound, and alternating shortcuts as the next individual-action group.
3. Dedicated integrations or multi-actions only after a separate selected scope. Pages remain excluded.

Implementation should reuse existing permission checks, configured action history, serialized deck session and fake platform adapters. Neither private display APIs nor new live-device operations are selected by this research. Platform effect and physical display acceptance remain owner checks.
