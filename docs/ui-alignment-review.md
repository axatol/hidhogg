# UI-01–03 — Visual contract review

Owner choices and implementation approved, 2026-10-22. UI-02/03 implementation is in progress. This is the concise review of the [full plan](ui-alignment-plan.md).

## Accepted choices — supersedes draft alternatives below

| Choice | Accepted behavior |
|---|---|
| 1B | Click either wheel to open device-wide settings in the inspector; no permanent wheel panel |
| 2A | Keep the app selected and listed as inherited after its last override is removed; explicit Remove deletes it |
| 3A | Cancel recording when leaving its editor or Hidhogg; resume shortcut handling |

```text
Back / Forward         → App-specific assignment inspector
Vertical / Thumb wheel → Device-wide settings inspector
```

Four targets are selectable and outlined; only Back/Forward are shortcut-bindable. Preserve the last app editing context when inspecting a wheel. Extend transient target/history state without changing TOML or domain control types. Shared restore-on-disconnect stays one device-level option. Verify empty-context save/reload and capture lifecycle. Earlier layout/recommendations below document alternatives considered; these selected choices take precedence. Product questions are resolved and implementation is approved.

## Delivery sequence

```text
UI-01                       UI-02                        UI-03
Agree flows and states  →   Native device workspace  →   Settings and verification
Owner decisions             Existing Logitech features   Owner acceptance
                                                               |
                                                               v
                                                       D200X may then start
```

| Task | Concrete output | Exit gate |
|---|---|---|
| UI-01 / 440 | Screen map, state rules, decisions and bounded code plan | Owner agrees this contract |
| UI-02 / 441 | Device sidebar, app/context selector, two button targets, inspector and wheel settings | Working existing features in the new layout |
| UI-03 / 442 | Settings categories, recovery, accessibility and signed checkpoint | Focused checks plus owner acceptance |

## Default layout proposal

```text
┌─────────────────┬──────────────────────────────┬─────────────────────────┐
│ Devices         │ MX Master 3S                 │ Back button             │
│ MX Master 3S    │ ● Connected · Bolt           │                         │
│ ● Connected     │ Editing [VS Code          ▾] │ Inherits All apps       │
│                 │                              │ [Override]              │
│                 │ Mouse schematic              │ Shortcut / No action    │
│                 │ [Back] [Forward]             │ Record / Choose / Preset│
│                 │                              │                         │
│                 │ Device settings · all apps   │                         │
│                 │ Vertical wheel / Thumb wheel │                         │
│ Settings        │ Saved on this Mac · Button shortcuts ready              │
└─────────────────┴────────────────────────────────────────────────────────┘
```

The inspector shows effective inherited values as read-only until Override is chosen. “Use All apps” removes the selected explicit override. The application selector is an **editing scope**; actual physical button delivery continues to use the foreground application. Selecting VS Code here does not activate VS Code or temporarily redirect input to it.

| Navigation | Proposed rule |
|---|---|
| Select another control/app | Keep existing history behavior; cancel the prior capture before switching |
| Back / Forward | Restore device/app/control context; cancel a capture before moving |
| Open Settings | Restore last Settings category in this workspace session |
| Click permission warning | Open Settings → Permissions directly |
| Return to device | Retain the selected app/control |
| Resize | Keep inspector access through a visible toolbar action at the current820×560 minimum |
| Close/reopen window | Retain accepted menu-only/Dock/⌘Tab behavior; no new persistent UI preferences |

Settings category changes do not add history entries. Ordinary Settings restores the last category; a permission deep link explicitly selects Permissions. Category state lives above the recreated Settings child views. Selecting a mouse target only selects its editor; it never executes the assigned shortcut.

| Application dropdown case | Rule |
|---|---|
| Open dropdown | All apps first, then configured contexts; Add application remains reachable |
| Search | Search configured application names and bundle IDs only |
| No match | Empty-result message plus Add application; no installed-app scan |
| Missing app/name/icon | Bundle-ID label and generic icon; preserve its assignments |
| Duplicate display names | Bundle-ID detail distinguishes them |
| Add an already configured app | Select existing context; do not duplicate it |
| Remove an app | Confirm if explicit assignments would be discarded; then select All apps |

## State and recovery rules

Connection, button handling and disk persistence are independent. Each wheel also has its own active/blocked state. A save failure must not make an existing valid session appear disconnected. “Ready” is session readiness, not proof of a delivered shortcut or that the currently inspected app is in the foreground. Reuse the accepted menu warning/error color meanings, with explicit text alongside them.

| Situation | Editing | Visible message/action |
|---|---|---|
| Connected and usable | Available | Connected; input readiness shown separately |
| Disconnected | Available | Disconnected; saved edits wait for connection |
| Posting permission missing | Available | Permission needed; open Permissions; direction controls retain their existing permission independence |
| Recording | Captured target only | Recording; shortcuts paused; explicit Cancel |
| Ordinary save failure | Keep valid draft editable | Not saved; existing error and Retry |
| External revision conflict | Preserve draft; no silent overwrite | Conflict; Reload offers the existing discard confirmation |
| Initial configuration load failure | Configuration editing read-only | Cannot load configuration; Reload; permissions/diagnostics remain reachable |
| Failed manual reload | Preserve previous draft; configuration editing read-only until successful reload | Reload failed; no reset or replacement of the existing file |
| Unsupported capability | Preserve saved intent; no false “active” claim | Unsupported for this connection; details show current capability/readback |
| Connection failure / uncertain cleanup | Preserve draft and existing safety gates | Failed / Needs attention; details and existing allowed recovery actions |

Conflict-specific UI must use a typed error projection, not string parsing. The current model flattens save errors into text; adding a small presentation classification is an explicit implementation seam. No file schema or conflict policy changes.

## Recording decision and transitions

```text
Idle → Record or Choose manually → Capture/edit session
                                  ├─ Accept → write captured target → Idle
                                  └─ Cancel → keep prior binding    → Idle
```

| Event | Recommended behavior |
|---|---|
| Escape, Cancel, manual-sheet dismissal | Cancel without changing the stored binding |
| Pick another app/control, use history, navigate to Settings | Cancel before navigation |
| Hide inspector, close workspace or switch away from Hidhogg | Cancel and resume shortcut handling; close any capture dialog consistently |
| Open manual editor from inline capture | Hand off the same target to the visible manual editor; do not commit or accidentally cancel during presentation |
| Disconnect or permission changes while editor stays accessible | Continue capture: offline/permission-blocked configuration remains supported |
| Begin Reload or Restart | End capture before leaving the editor; existing reload/save/lifecycle guards remain |

Current source already cancels direct app/control switches but does not cancel all navigation/focus/window paths. The recommended additional cancellation is a small behavior correction, not merely layout. Tests must prevent stale callbacks from editing a different target or leaving shortcut delivery invisibly paused.

## Assignment and persistence rules

| Concept | Meaning |
|---|---|
| All apps | Default Back/Forward assignments |
| Inherit | No per-app override; show the effective default |
| Explicit shortcut | Assignment for this control in this app only |
| Disabled / proposed “No Hidhogg action” label | Hidhogg posts no assigned shortcut; this is not a native-passthrough binding |
| Device-wide wheel settings | Independent of application selection; same ranges/defaults/restore policy |
| Editing a binding | Immediate application, one-second autosave; no Save/Enable/Apply buttons |

| Wheel panel | Main controls | Advanced/details |
|---|---|---|
| Vertical | Direction; custom amount toggle/slider/value | Input resolution; observed/effective values; active/blocker details |
| Thumb | Direction; custom amount toggle/slider/value | Observed/effective values; active/blocker details |
| Device options | Clear scope label: applies to all apps | Existing restore-on-disconnect option and ownership explanation |

Keep detailed readback/technical status available without filling the primary editor with it. Distinguish retained direction preferences from custom amount handling, which requires the active Hidhogg connection. Do not change the selected amounts, ranges or defaults as part of layout work.

While Hidhogg's binding session intercepts the buttons, Disabled also suppresses the original button action. If the entire binding session is off, native behavior resumes. Explain this near that mode; do not claim Disabled always restores native Back/Forward.

The current setter removes an application entry when its last override is removed. Keeping it as an inherited context is representable in the existing data model and is already how Add application starts. A codec/store round-trip test is still required before claiming retention works through save/reopen.

## Settings and implementation boundary

| Native category | Retained functions |
|---|---|
| General | Connect on launch, launch at login, actual macOS status/errors |
| Permissions | Both checks, request/open settings, app drag, refresh, restart recovery |
| Configuration | Path, save state/error/retry, manual reload and conflict handling |
| Diagnostics & Recovery | Bounded activity, codes/IDs/build/source, clear, app identity, restart |

| Work package | Ownership boundary |
|---|---|
| Sidebar, selector and canvas | Presentation views; existing model commands |
| Assignment inspector and wheels | Existing binding/settings actions; chosen empty-context rule and capture lifecycle |
| Navigation and status | Parent-owned transient UI route/category and typed read-only projections |
| Settings and recovery | Reorganize current functions; configuration-error editing guards |
| Independent verification | Focused state/context/capture tests, final regression and signed bundle |

No transport rewrite, new runtime, schema migration, hardware support or notification/MCP engine. No installed-app scan, idle polling or unbounded image/metadata cache. Keep standard fonts/surfaces, native keyboard/focus behavior and text labels alongside semantic colors. Use a static vector schematic and native Button overlays.

## Short acceptance gate

| Check | What it establishes |
|---|---|
| Edit All apps and one app override, then Inherit | Correct scope and chosen empty-context behavior |
| Record, cancel, switch page/app/control, close and reopen | Correct target and no invisible capture pause |
| Offline/permission-blocked edit; save error/conflict fixtures | Independent connection, input and persistence states |
| Resize, keyboard access, Settings deep link and window lifecycle | Reachable native UI without losing existing operations |

Use injected fixtures and targeted owner UI checks. Do not repeat a broad hardware or overnight campaign. Native automation/performance measurements need agreed scope. No tests or device operations were run for this planning review.

## Historical alternatives considered

Source checks behind these choices: [foreground delivery](../app/Sources/HidhoggApp/AppModel.swift#L1413), [final-override pruning](../app/Sources/HidhoggApp/AppModel.swift#L1447), [navigation handlers](../app/Sources/HidhoggApp/AppModel.swift#L441), [shortcut admission during recording](../app/Sources/HidhoggApp/AppModel.swift#L1126), and [save/reload handling](../app/Sources/HidhoggApp/AppModel.swift#L826). These are static findings; no native failure reproduction or new test run is claimed.

| # | Choice | Recommendation |
|---|---|---|
| 1 | **A:** keep wheel settings below the mouse; **B:** clicking a wheel opens its settings in the inspector | **A:** keeps device-wide settings visibly separate from app bindings |
| 2 | After the final override becomes Inherit: **A:** keep the app listed as inherited; **B:** remove it and return to All apps | **A:** predictable editing context; remove an app only through Remove |
| 3 | When leaving the editor/app: **A:** cancel recording automatically; **B:** keep it active while the window is open, with an always-visible Cancel indicator | **A:** restores shortcut handling and avoids hidden paused sessions |

The owner selected 1B/2A/3A and approved implementation on 2026-10-22; see the accepted choices at the top. Option3B was not selected.
