# Check-in preparation

26 October 2026. Working branch: next/d200x-slice; baseline: e2744ad. The owner authorised committing and publishing this verified checkpoint to the repository mainline on 26 October 2026. GitHub confirms the default branch is master and there is no main branch.

## Scope

| Group | Included work |
|---|---|
| D200X workspace and automation | Appearance, application profiles, notifications/topics, local API/CLI, static native/executable actions, independent portable presets and direct control assignments |
| D200X lifecycle and rendering | Retained-connection sleep trial, brightness reapplication and accepted 458×196 wide rendering |
| Logitech recovery | Retained connection intent, fresh verified routing, bounded retries and explicit cancellation |
| Native presentation | Compact permission rows, device sidebar assets, menus and workspace inspector refinements |
| Documentation and packaging | Current overview/structure/roadmap, preserved checkpoint history, signing of app plus CLI and targeted local-artifact ignores |

The feature groups share AppModel, D200XModel, package and configuration changes. A single complete checkpoint is safer than pretending the current file boundaries are independent commits. Smaller commits require reviewed hunk separation and validation of each intermediate tree.

## Standards

One medium-severity, high-confidence issue was identified and resolved: the executable editor previously joined arguments with newlines when loading and split them when saving, changing empty or embedded-newline arguments during unrelated edits. The owner approved the fix on 26 October 2026. The editor now uses stable, separate argument rows and passes their raw values directly to existing validation/save logic. Round-trip regressions cover empty and multiline values, timeout-only edits, row editing/removal and the 64-argument cap. Independent re-review closed the blocker; no further blocking standards or security defect was substantiated.

## Specification

No additional concrete specification blocker was found. Implemented scope is represented in the current plans; proposed idle dimming, lock/screensaver policy and payload execution remain unimplemented/unclaimed. Hardware and platform-effect acceptance remain separate. Shared model/configuration/package files couple the candidate commit groups.

Review totals: Standards/correctness 1 issue found and resolved; Specification 0 additional blockers. Current blocking findings: 0.

## Final verified checkpoint

- Signed app/CLI build: 873e84a8bb590aa1f887da82754ecc9dc8aa2c3a3b7d90ed78f54708813346bc.
- Full offline package: 345 XCTest cases, including five intentional native skips, plus 221 Swift Testing cases; zero failures. This is 561 passing ordinary checks.
- Explicit background native-window suite: 5/5 passed. Combined unique passing cases: 566. The focused argument/usability run passed 10 cases, overlapping the full run.
- The new 320×560 native case renders separate empty, multiline and normal argument rows without saving or executing anything. Pointer-driven editing is not claimed by that rendering check.
- Logs: /Volumes/Data/tmp/hidhogg-argv-fix-full-2026-10-26.log, /Volumes/Data/tmp/hidhogg-argv-fix-native-2026-10-26.log and /Volumes/Data/tmp/hidhogg-checkin-argv-release-20261026.log.
- Strict signatures and CLI help passed. Local provenance has 198 matching source/resource/test hashes plus signed artifact and log hashes. Only the approved editor and native test changed among the prior 196 inputs; two new draft/regression files were added.
- Remaining physical/platform checks below do not become accepted solely because this offline checkpoint passed.

## Frozen baseline verification

- Full offline package: 340 XCTest cases, including four intentional native skips, plus 221 Swift Testing cases; zero failures. This is 557 passing ordinary checks.
- Explicit background native-window suite: 4/4 passed. Combined unique passing cases: 561.
- Logs: /Volumes/Data/tmp/hidhogg-checkin-frozen-full-2026-10-26.log and /Volumes/Data/tmp/hidhogg-checkin-frozen-native-2026-10-26.log.
- Signed build 3a7adfa11f7b: all 196 source hashes, app/CLI hashes, referenced log hashes and signatures verified against dist/build-info.json. CLI help exits without contacting a service.
- Tests use synthetic configuration, devices and services. No production app, HID, real scripts, platform effects, clipboard or permission prompts were exercised.

This is the preserved pre-fix baseline; the final checkpoint above supersedes it for current source verification.

## Reproduce the offline gates

```sh
swift test --package-path app --scratch-path /Volumes/Data/cache/hidhogg-workspace-independent --disable-sandbox --build-system native
swift test --package-path app --scratch-path /Volumes/Data/cache/hidhogg-workspace-independent --disable-sandbox --build-system native --filter NativeWorkspaceWindowTests
```

Run these sequentially. The explicit native gate uses fake services and non-key background windows. The native build-system option is the verified local invocation; SwiftPM currently warns that it is deprecated.

## Excluded files

Local .envrc, .codex, Xcode xcuserdata, Python bytecode caches, the generated D200X probe executable and dist products are excluded. Targeted ignore rules protect these paths; their contents were not read or altered. Source SVG assets and asset-catalog metadata are included.

The explicit path list is [checkin-files.txt](checkin-files.txt): 116 reviewed files are staged. Staged paths and source blob hashes are verified against the reviewed tree and signed-artifact manifest. Local environment/user artifacts and dist remain excluded. The owner has now authorised the actual check-in and push to master; verify the resulting remote head.

## Remaining owner gates

- D200X sleep: whether 0% stays black after the normal screensaver delay and restores on wake.
- Logitech recovery after real receiver/mouse disappearance and return, including both wheels and Cancel Reconnect.
- Remaining volume/output, sound/opener, permission-flow, profile and preset cases. Media, baseline notifications/scripts, action search and improved wide rendering have owner confirmations.
- Actual login-after-boot, overnight resources and exceptional cleanup retain separate limits.

## Preparation checklist

- [x] Audit the current change set and excluded local artifacts.
- [x] Review standards/correctness and approved specification scope independently.
- [x] Verify the frozen source, signed artifacts and background native windows.
- [x] Consolidate the current overview, structure and roadmap; preserve dated checkpoint evidence.
- [x] Resolve the argument-editor blocker with approval, then verify/package the final source.
- [x] Reconcile final tracker/handoff facts and stage the explicit reviewed file set.
- [x] Owner authorises the actual check-in and mainline push.

## Suggested checkpoint commit

Title: Add D200X automation and verified device recovery

Include the profile-aware deck actions, notifications/CLI, portable presets, lossless executable editor, higher-resolution wide rendering, retained-connection sleep trial, Logitech recovery, native permissions/assets and current documentation as one dependency-complete checkpoint. Validation: 566 unique offline/background tests and signed build873e84a8bb59 with198matching source inputs. Remaining manual gates stay documented.
