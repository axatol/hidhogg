# Discovery investigation and BOLT-KIND-01 correction — 2 November 2026

- [x] Inspect the supplied screenshot and current state/visibility paths.
- [x] Clarify whether a candidate appeared and when the failure occurred.
- [ ] Approve the bounded implementation scope below before code changes.
- [ ] Reproduce state-order and diagnostic blind spots with synthetic reports.
- [ ] Implement/review/verify the approved slice and deliver a signed build.
- [ ] Owner verifies discovery on the physical receiver.

Owner reports no MX Master 4 row at any point, then an error after about 30 seconds on the signed recovery build. Screenshot: Receiver discovery ended with an error; 322 advertisement events, 322 decoded, zero rejected/unsupported model; two discovery statuses; zero recovery/transport failures. Native callbacks338, register replies14, receiver notifications324; setup and restoration verified. No new live HID/diagnostic reads or private captures/logs/config are authorized or performed. Source remains broad dirty master, unstaged.

## Confirmed source behavior

`BoltDiscoveryDiagnostics.decodedAdvertisements` counts every successfully parsed advertisement fragment, including name-only/incomplete observations. Unsupported-model count does not cover unsupported device kind or authentication. It therefore does not establish a selectable mouse. `receiveDiscoveryStatus` collapses any nonzero receiver discovery error into one generic failure without retaining its code in the anonymous diagnostics. The Devices UI only presents new candidates in awaitingSelection, so terminal failure hides candidates even if present. That visibility behavior alone cannot explain the owner's report of no row throughout the attempt.

`start()` publishes discovering after awaiting the C0 write and native diagnostic snapshot, without checking whether intervening notifications already published awaitingSelection. This is a source ordering risk, not yet a reproduced cause of the owner's attempt. The configured discovery window is30 seconds, consistent with the reported delay but not proof of error1/timeout.

## Proposed bounded implementation

Expose fixed-schema anonymous evidence: metadata versus name-fragment counts, selectable candidate count, unsupported-kind/authentication counts, and the terminal receiver discovery state/error numbers with known human-readable labels. No names, addresses, unit IDs, raw reports or challenge values. Preserve defaulted API compatibility and clone/reset semantics.

Add synthetic tests for candidate-before-start-ACK ordering and terminal states, plus known-product advertisements with unsupported kind/authentication and name-only traffic. Correct startup publication so an already found candidate or terminal state cannot be overwritten by searching. Keep discovery failure truthful; retain found rows as non-actionable last-seen evidence where useful, and keep pairing blocked after cleanup until safe fresh recovery. Do not blanket-ignore receiver errors or weaken metadata/authentication/conflict checks. Exact candidate-retention UI scope remains subject to approval.

This slice should identify which path produces322 decoded fragments with no row; it does not promise the underlying physical discovery problem is fixed without that evidence. Physical pairing, general padding, notification icons and new Bluetooth pairing remain out of scope.

## Research-to-implementation audit — 2 November 2026

Owner asks why repeated patches have failed despite substantial available research. This is an implementation/verification process gap; no new physical root cause is established by this audit.

The canonical 1 November priority specification already requires retaining numeric errors (transaction rules and discovery/pairing status table), handling notifications during outstanding requests, testing delayed ACK/state reduction, and distinguishing source-closed packet layouts from owner hardware acceptance. Current source collapses receiver discovery errors into a generic string with no retained terminal code in diagnostics, and unconditionally publishes searching after the awaited discovery-start operation even if a candidate state was already published. Those are concrete gaps against the stated contract; neither proves why this physical run had no visible row.

Synthetic report builders encode the same offsets/model/kind/authentication defaults the production decoder expects. They meaningfully verify internal behavior, malformed-input handling and safety, but do not independently establish actual MX Master 4 advertisement admission. Broad passing totals include unrelated features. Reporting a signed/offline-verified slice as delivered was technically bounded, but insufficiently emphasized that new-mouse discovery/pairing remained unresolved.

Current observed chain: receiver events reach structural decoding322 times; eligible metadata count, candidate creation/publication and terminal error value remain unknown. No visible row for30s is owner-confirmed. More aggregate counts alone do not establish event order or rejection cause.

Corrected investigation sequence: (1) map relevant source-backed field/transition requirements to current code and independently derived fixtures, marking unresolved assumptions; (2) verify event-order/timeout branches from documented vectors; (3) use a bounded in-app decision/phase trace containing only anonymous protocol categories and reason/status codes to localize the physical failed stage; (4) reproduce that exact branch in a regression, apply the minimal fix, and owner-verify a stable MX4 candidate before broadening UX/recovery work. Instrumentation is evidence gathering, not a claimed discovery fix. The earlier patch proposal is provisional until this mapping identifies the necessary edit. No code, builds/tests, runtime reads or hardware operations in this audit.

Sources: `~/Workspace/ai/rea/investigations/logi-options-plus/hidhogg-pairing-mouse-protocol-spec-2026-11-01.md` (lines19,48–54,73–90,266–276); `app/Sources/LogitechBolt/BoltPairingSession.swift` (start, receiveAdvertisement, receiveDiscoveryStatus); `app/Sources/LogitechBolt/BoltDiscoveryDiagnostics.swift`; `app/Tests/LogitechBoltTests/BoltPairingSessionTests.swift` synthetic advertisement helpers.

## Targeted shipped-flow investigation supplied — 2 November 2026

Owner points to `~/Workspace/ai/rea/investigations/logi-options-plus/bolt-discovery-sequence-2026-11-02.md`. Parent read the complete report and compared current discovery source. No code/test/build/device operation was performed.

Highest-priority concrete mismatch: the report's base-metadata row (line95) identifies device kind as byte7 low nibble. Hidhogg advertisement decoding currently stores the entire byte (`BoltPairingSession.swift:1531`), and both candidate admission and selection require equality with2. Pairing-record decoding already masks its kind with0x0F (`:1596`). A synthetic recognized MX4 metadata report with kind byte0x82 would therefore be structurally decoded, remain zero unsupported-model, but produce no selectable candidate. This matches the shape of owner evidence; actual device byte7 is unknown, so physical cause remains unconfirmed. Current report helpers write the production kind constant2 and miss this independent field-width case.

Proposed first correction: source-derived literal vectors for byte7 values0x02/0x82/0x81, MX4 product/auth fields and repeated flag changes; verify mouse normalization and true non-mouse/unsupported-auth/conflicting identity exclusion. Normalize the kind field to its documented nibble without broadening authentication or weakening report-length/identity guards. Implementation requires owner confirmation; this is a specific field-mapping correction, not another speculative timeout workaround.

Additional report consequences: advertisements are independent of ACK, UI retention is separate from bus/callback maps, native 53 resets parser stores, and ordinary UI dispatches Pair then discovery cancel without proving actual wire scheduling. Current start-ACK candidate overwrite remains an ordering issue to test. Native long-name continuation arithmetic is unresolved and differs from Web Connect; do not silently treat either implementation as the other or copy PID-only UI deduplication. These findings do not justify an immediate wholesale assembler/state/pair-order rewrite. Stop/pair ordering cannot explain a row absent before selection.

Independent read-only follow-up agrees that the byte7 nibble mismatch is the highest-priority actionable source discrepancy. Parent verified `BoltPairingSessionTests.swift` has no `0xB042` or `.mxMaster4` positive candidate fixture; its only MX4 mention is a name string in the assembly test. Add an independent literal MX4 metadata vector with flagged kind0x82 as the first regression, rather than reusing production constants. Early-ACK ordering is the next separate regression; native status-reset/pair-order differences remain explicit policy choices, and the native name arithmetic anomaly stays unresolved. No code/build/test/device operation performed.

## Approved BOLT-KIND-01 implementation — 2 November 2026

Owner approved the focused kind-field correction and independent MX Master 4 regressions. Active checklist:

- [x] Confirm source-backed field mapping and owner approval.
- [x] Reproduce flagged mouse exclusion with independent literal MX4 reports.
- [x] Normalize kind to its low nibble; preserve authentication/identity/length guards.
- [x] Independently review and verify focused plus full offline gates.
- [x] Sign app/CLI and reconcile source hashes.
- [x] Owner confirms discovery/current flow works on the signed build (2 November 2026); actual previous wire value remains unknown.

Implementation owns only BoltPairingSession.swift and its focused test file. General phase/ACK/UI/name/pair-order changes are outside this approved slice. Prechange files captured against the delivered321-input manifest in /Volumes/Data/tmp/hidhogg-kind-baseline. No commit/push/live device operation authorized.

BOLT-KIND-01 source frozen: one production line normalizes `report[7] & 0x0F`; five literal-vector MX4 tests cover normalization, plain/upper-bits-set admission and fake-receiver selection, UUID retention across upper-bit changes, genuine non-mouse/authentication exclusions and semantic-kind conflict. RED ran five tests: three failed on the expected decoder/admission setup, two passed; GREEN passes all five. Logs `/Volumes/Data/tmp/hidhogg-kind-{red,green}.log`. These are synthetic field-layout vectors, not captured mouse frames. The final321-input manifest `/Volumes/Data/tmp/hidhogg-kind-inputs.json` differs from delivered recovery source in exactly the session source and its test file. Independent focused/full gates are running; signing pending.

BOLT-KIND-01 independent review has no actionable findings. Focused304 passes (60 XCTest+244 Swift Testing); full1,037 passes on its first run (620+417), including all thumbwheel tests. Existing exclusions remain exactly WakeConnectionTests and NativeWorkspaceWindowTests. Final321 hashes match before/after; only the session source/test differ from the previous delivery. Logs /Volumes/Data/tmp/hidhogg-kind-{focused,full}.log. Signed build is in progress; real prior packet and physical discovery outcome remain unknown.

## BOLT-KIND-01 signed delivery — 2 November 2026

Signed app/CLI build `504408b9669e116a78b4fd580b02d6053119dc27460a6727720fcc6bed01ab82` passes strict signature verification; CLI help exits0 without contacting the app. Final321 hashes match after independent tests and signing. Focused304/full1,037 pass on their first independent runs, with the two existing suite exclusions unchanged. The five exact new MX4 tests reproduce kind82 rejection before correction and pass afterward while retaining genuine exclusion/conflict behavior. Complete delivery metadata/log hashes: dist/build-info.json.

Production change is only the researched low-nibble normalization; five source-derived synthetic tests were added. No ACK/state/UI/continuation/authentication/identity/length-policy change. All source remains uncommitted/unstaged on master `3dc576fcadfd41e2fedba4761efbce719704f2bc`; no push, production app launch or live device operation. Actual raw kind from the failing receiver attempt remains unknown: this verifies a decoder correction, not physical discovery recovery. Owner next reopens the signed app and checks MX4 discovery/selection. If still absent, the remaining admission/phase evidence is unresolved; do not represent the nibble hypothesis as proven physical cause.

## Owner acceptance and check-in — 2 November 2026

After the signed BOLT-KIND-01 build, owner reports: “that worked, all working as expected.” This closes the reported MX4 discovery failure and accepts the current working flow. It supports the researched kind-field correction as the effective fix; no original packet was captured, so the actual previous byte remains unknown. This statement does not separately enumerate destructive unpair/fault-injection, multiple-receiver, sleep or cancellation edge cases.

Check-in readiness: the current321 input hashes still match the tested/signed build, focused304/full1,037 pass with the same two excluded suites, strict app/CLI signatures pass, and independent scope audit finds no blocker. Source snapshot includes accumulated accepted D200X Lock Screen/presets/scripts and Logitech association/pairing/receiver management/recovery, not only the nibble correction. Remaining nonblocking follow-ups: padding consistency, battery-notification icon, researched early-ACK candidate-phase ordering and bounded numeric status/eligibility evidence. New Bluetooth pairing and other future features remain roadmap work. No additional functional code change is part of check-in.
