# Flow Lite84 lighting controls — FL-02

Current signed controls build `b874794ee483170c425e0a777962baed19cc3a5a00f59a5ac8ced767b2854111` (29 October 2026); lighting auto-applies after500ms, system mode remains explicit. See [current follow-up](flow-lite84-system-mode-plan.md); earlier FL-02 evidence below is historical.

29 October 2026. Owner approved human-readable lighting status and receiver-based lighting writes, background fake tests and a signed app build. Agent-operated physical writes are not authorized; the owner performs the first device changes in the app. Work continues on local master after checkpoint9d9b2c2.

## Boundary

Expose named effects4Trailing,5Breathing,6Wave,7Reactive,8Ripple,9Snake,10Steady; enabled state; brightness/speed raw0–4 displayed1–5; idle-off units1/3/6/12/30/60/90 displayed10seconds/30seconds/1minute/2minutes/5minutes/10minutes/15minutes. Unknown values stay explicit. Idle0 is not labelled Never; brightness1 is not claimed physically off without a confirmed mapping. The earlier owner/static-label correction and retained vendor menu do not establish additional mode IDs. White backlight only.

Revised29October2026: intentional lighting edits auto-apply500ms after the last adjustment; rendering/default initialization and reconnect never write. System-mode changes remain explicit Apply. See [accessible controls and system-mode follow-up](flow-lite84-system-mode-plan.md) for the current debounce/queue boundary. Keep drafts separate from verified readback, preserve unrelated bytes and colorIndex, and read original affected lighting regions before mutation. Validate command7 acknowledgements, then read exact affected bytes back before reporting success. No automatic write retries. A sent-but-unconfirmed outcome is reconciled by bounded reads and reported as unknown, not claimed rolled back or atomic. Explicit restoration uses only the captured original lighting bytes for the current session; no factory-default claim or reconnect reapply.

No macro/keymap/full-user-configuration reads, OS-mode changes, firmware, pairing, reset, RGB/music or generic flash writes. Existing battery/status receive correlation and write-completion barrier remain intact. The receiver online flag is known ambiguous for this owner; supported connected identity and real transaction/readback establish eligibility, not that flag alone.

## Checklist

- [x] Typed readable lighting values and partial edit contract.
- [x] Strict scoped write codec/ack/readback and original capture/restoration.
- [x] Explicit UI draft/apply/verified status with lifecycle-safe model.
- [x] Fake codec/session/model regressions, including retained raw unknown levels, and independent focused gate.
- [x] Final signed app/CLI build and frozen-source provenance.
- [ ] Owner physical effect/level/idle mapping, restore and persistence checks.

## Evidence and ownership

Primary retained evidence: /Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/macros-lighting-settings.md (lighting bytes/control labels), transport-swift.md (command7/8, checksums, ack/readback requirements) and feature-matrix.md (model-specific scope). Lofree's product page confirms white backlight: https://www.lofree.co/products/flow-lite84-mechanical-keyboard (checked29October2026). Static/synthetic vectors are not physical write acceptance.

flowlite_lighting_backend owns LofreeFlowLite84 module/tests; flowlite_lighting_ui owns app keyboard model/view and model tests. Root owns this plan, integration review, durable handoff and release packaging. Independent verification waits for a shared source freeze; builds stay offscreen and use external scratch paths.


## Implementation checkpoint

The session returns a confirmed snapshot for Apply/Restore so the UI does not depend on AsyncStream delivery order. Model adoption preserves newer same-identity battery receipts and their availability flags during lighting changes. Unknown receiver online state does not independently disable supported writes; selecting a known effect is required for parameter edits, while enabled/idle edits can stand alone. Drafts remain separate from readback; only Apply/Restore mutate the device.

Strict scope includes scalar pairs8496/8498/8500 and known effect headers8672–8864, with original checksums/colorIndex preserved. Global checksum/scope/identity failures during mutation close the session and report an unknown outcome. Only a valid scoped but ambiguous acknowledgement can use still-open read reconciliation; no send is repeated. Original values are memory-only and connection-local.

Implementation gates:74 module tests and18model tests passed before independent verification; an initial battery-order failure was corrected rather than relaxing the assertion. Root's small availability-flag merge follow-up and verifier's close/no-reuse assertions are included in the final independent gate. First UI gate failed for a missing module import; fixed before test execution. No physical keyboard write occurred.

Root background visual checks use the actual view with synthetic model/no-op actions and a never-shown, non-key window. Native GroupBox capture did not render its layers correctly, so final known/unavailable fixtures use a synthetic SwiftUI GroupBox style for layout inspection; they do not establish actual native appearance or interaction. Artifacts: /Volumes/Data/tmp/hidhogg-fl02-ui/known.png and unknown.png. No production app launch/input/permission flow was exercised.


## Earlier build checkpoint — superseded by final checkpoint below

Signed app/CLI build `71076e8c6b0e04b4c7db9b5cff76e0191491c0adec4aabc42020e89f67763968` completed29October2026; strict signatures pass. Independent74module+18model tests pass, with15scoped inputs unchanged before/after tests/build. Manifest /Volumes/Data/tmp/hidhogg-fl02-verify-20261029-postbuild.sha256 (digest5c1b54c0bf3c1d955d1b78903a7956c09aca723e7ad251eeaa255604463d9031); logs /Volumes/Data/tmp/hidhogg-fl02-verify-20261029-module.log and -model.log. Build log /Volumes/Data/tmp/hidhogg-fl02-release-20261029.log. Ignored dist/build-info.json records230source/resource/testinputs. No fullsuite was rerun for this scoped feature; the earlier635check checkpoint remains historical. Changes are uncommitted onmaster.

Owner trial: restart dist/Hidhogg.app, connect the receiver, note the readback, select a known effect and one small brightness change, then Apply. Confirm actual effect/brightness against verified readback. Use Restore previous lighting within the same connection and compare. Test idle-off timing separately; it is not whole-keyboard/radio sleep. Reconnect must not resend lighting or retain another session's restoration bytes. Check physical persistence separately. A missing/mismatched acknowledgement must not be treated as a successful write merely because the device visibly changed.


Final audit follow-up: prior71076build and74+18gate remain recorded above, but are superseded pending correction. Session snapshot/readback had converted raw parameter levels>4 to nil, bypassing the view's Unknown(raw) labels. Backend is preserving checksum-valid reported raw levels while keeping edits restricted to0–4, then updating real-session regressions. Physical write scope is unchanged. Repeat focused gate and replacement signed build are required before handoff.


## Final audited checkpoint

The unknown-level correction is complete: checksum-valid raw speed/brightness201/255 survive initial read, partial apply and exact restoration; no false unavailable flags. User edit values remain restricted0–4. Independent74module+18model tests pass again, with15input hashes unchanged through tests/rebuild; final manifest /Volumes/Data/tmp/hidhogg-fl02-verify-20261029-r2-postbuild.sha256, digest930e4564757a4e0ecf402eb5c8d25093628eb085d27c4fc66880400d12228932. Final module/model logs use -r2-module.log and -r2-model.log under the same prefix. Signed build `b0c380a6e45b999f632b95e1230b6f6d236675a390f852822e03cd4284826f6a` and strict app/CLI signatures pass; /Volumes/Data/tmp/hidhogg-fl02-final-release-20261029.log. This checkpoint supersedes pending statuses above. No agent-operated device write; owner effect/ack/timing/persistence/restore checks remain open.
