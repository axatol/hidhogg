# Native action starter catalog — DX-10

2026-10-24. Owner approved the full core set below ("Let's do it all"). **DX-10 / TaskView476 is In Progress.** Speak Text is excluded; notification/preset UI refinement is also approved.

| Category | Proposed actions | Static parameters |
|---|---|---|
| Playback | Play/Pause, Next Track, Previous Track | Operation |
| Volume | Up, Down, Toggle Mute, Set Volume | Step or target percentage; current default output |
| Sound | Bell, Play Sound | Built-in sound or selected audio file |
| Openers | Open Application, File, URL | Explicit target |
| Notifications | Send Deck Notification | Concrete topic, text, optional expiry |
| Existing controls | Shortcut, Custom Executable | Existing validated shortcut/process parameters |

Text insertion, ordered multi-actions, plugins/integrations, display-brightness actions and power/session actions are not included in the proposed starter set. A default template creates an editable action draft, never executes on selection and never replaces an existing definition automatically. Templates are distinct from DX-09's deferred dynamic notification-payload interpolation.

## Evidence and boundaries

- Local D200X investigation `~/Workspace/ai/rea/investigations/ulanzi-studio/inventory.md:98–111` recovers system open/website/text/hotkey/multimedia and sound play/stop actions. This is shipped-artifact evidence, not native Swift execution proof; media vocabulary and some runtime behavior remain incomplete.
- [Ulanzi Studio's current guide](https://docs.ulanzistudio.com/dialmini/en/software/#_5-5-action-triggers) documents media controls, application/website/file openers, text and preset/page actions. That section is a Dial Mini workflow reference, not proof of D200X parity.
- Apple documents [Core Audio default-output selection](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultoutputdevice) and [AppKit system-defined events](https://developer.apple.com/documentation/appkit/nsevent/eventtypemask/systemdefined). Specific media dispatch and per-output software volume support need focused native implementation/owner validation, not an assumed universal guarantee.

## Implementation decisions

Expose one action-ID namespace, with typed executable/native definitions and static validated parameters. Retain the legacy `actions` table unchanged and add `native_actions`, enforcing disjoint IDs and a shared 64-action limit. This avoids rewriting every legacy executable/preset representation while presenting one catalog. A wholesale action-schema replacement was considered and rejected as unnecessary migration. Save can change an ID's definition type without losing its bindings; conflicting imported preset definitions cannot overwrite existing actions.

Legacy executable-only preset packages remain version 1. Presets containing native definitions use version 2; both are strictly validated, including image integrity and native parameter fields. Native sound/file/application targets are static paths and may need retargeting on another Mac, like executable paths; image bytes remain embedded. No automatic execution during import or template selection.

Execution uses one process lane and one native lane, with eight shared waiting slots and bounded metadata history. Native controls therefore do not wait behind a long-running script. Each lane retains its ordering; cross-lane ordering is not promised, and multi-actions remain deferred. Clearing history never stops work. History eviction preserves active/queued records before removing completed entries.

Production explicitly injects the native platform service; the default test model has no platform service. Deck notifications use the existing validated in-process publisher with no recursive action execution. Media/relative-volume actions emit paired system media events; absolute volume uses writable default-output Core Audio properties and retains stereo balance, with rollback of completed channel writes after a partial failure. Unsupported outputs produce an actual action failure rather than a claimed success. [Apple key definitions](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDSystem/IOKit/hidsystem/ev_keymap.h) underpin the media constants.

Bell uses the system alert; Play Sound owns a single player, replacing the previous app-owned sound and stopping it during cleanup. File/URL/application opening uses NSWorkspace; media and shortcuts use the app's input permission preflight without requesting permission on execution. Sound/openers/absolute volume do not simulate keyboard input. Executables retain literal arguments and empty environments; no shell/CLI wrapper constructs built-ins.

Native execution, platform effects and deck publishing have injectable seams for fake checks. Host-captured origin/profile/control remains separate from persisted definitions; external requests cannot forge physical-device attribution. Notification content is never interpolated into action parameters; DX-09 remains deferred.

Verification remains offline/fake plus background native windows. No agent-triggered media, audio, volume, app opening, real scripts, device writes, clipboard or production endpoint operations. Owner manually validates playback routing and output-device volume behavior after a separately approved implementation.

## Ready for owner validation — 2026-10-24

Approved catalog and templates are implemented in signed build `715d2cc8ebfc`. Legacy and native action IDs share one list; templates create drafts, native/executable definitions can be copied into independent tile presets, and histories retain host-captured triggers. Device-triggered queued native work rejects a stale session; deck notifications additionally reject a changed profile and native shortcuts reject a changed foreground application. External API invocation cannot supply these host contexts. Stereo fallback applies the percentage to the loudest channel while scaling the others to retain balance; failed rollback has its own actual partial-write error.

Focused 44 checks passed; full retry 528 ordinary checks passed after one unrelated intermittent Logitech assertion; 3 standard native cases plus a separate all-nine-kind editor case passed. Full failure/isolated pass evidence is recorded in the workspace plan. All execution tests use injected fakes; actual output support, media routing, sound and opening effects remain the [owner checklist](d200x-parity-owner-checks.md). No universal app/output compatibility is claimed.
