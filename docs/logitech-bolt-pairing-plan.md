# LC-04 — Bolt pairing and existing-mouse chooser diagnosis

LC-07 extends the historical no-unpair boundary below with explicit confirmed selected-slot receiver management; pairing itself still never automatically unpairs or replaces a stored bond. See [current scope and verification](logitech-receiver-management-plan.md).


Current UI supersedes the historical operator entry points below: **Add Device → Logitech Mouse…** opens combined existing mice and Bolt/Bluetooth options; **Change Connection…** reassociates a saved registration. Pairing runs inline. See [compact setup and current verification](logitech-compact-setup-plan.md). Protocol assumptions and hardware limits below remain applicable.


## Selection and approval — 1 November 2026

Owner selected Bolt pairing before Bluetooth pairing and reported that Choose Existing Mouse is empty while a physical mouse still works. Owner confirmed both registration and physical mouse are MX Master 3S, connected through Bolt, with the message “No verified matching mouse is available. Wake an already-paired mouse and refresh.” A concrete implementation scope has been presented for confirmation under the supplied AGENTS.md instruction to plan and confirm before code changes. Owner approved the enum correction and Bolt implementation scope on 1 November 2026. Implementation is complete and offline verified; owner hardware acceptance is pending. No live device operation was performed by the agents.

- [x] Read current LC-02 handoff, source boundaries and pairing evidence.
- [x] Obtain scope confirmation and missing reproduction details.
- [x] Establish a red-capable loop for the reported empty chooser; correct the proven cause (SDK descriptor RED: 2 issues; GREEN: 1 passing test).
- [x] Implement receiver register framing/event transport with explicit endpoint ownership.
- [x] Implement bounded receiver-selected discovery, authentication and cancellation.
- [x] Verify terminal paired slot and fresh identity before saving the association.
- [x] Add the in-app pairing flow and paired-but-not-added recovery.
- [x] Run agreed synthetic checks, build/sign and record owner verification steps.
- [ ] Owner verifies real discovery, authentication, cancellation and reconnect.

## Implemented flow

```text
Choose receiver
       |
Read pairing records/capacity and acquire receiver session
       |
Discover -> Choose mouse -> Authenticate
       |                         |
    Cancel/timeout             Terminal pairing status
       |                         |
Release session          Verify slot and full identity
       |                         |
Restore prior intent       Save registration/association
                                 |
                         Connect using LC-02 guards
```

Existing records must not be deliberately replaced or unpaired. A sleeping or nonresponsive HID++ slot does not prove that a receiver slot is empty. Unknown occupancy/allocation or authentication states require an explicit unsupported/error result rather than a guessed command. Full-receiver and slot-zero allocation behaviour remain hardware verification limits in the research.

Pair-command acknowledgement alone is insufficient. Completion requires receiver terminal success, the assigned slot, fresh pairing-record/identity verification, and successful persistence. If pairing succeeds but saving fails or cancellation races success, show paired-but-not-added; do not unpair as rollback. MX4 remains read-only after registration. Bluetooth pairing, firmware, unpair/reset and additional MX4 control writes remain outside this slice.

## Existing chooser diagnosis

Current `AppModel.presentMouseSelector()` filters candidates by registration model and maps several backend outcomes to generic empty/error messages. `scanCurrentEndpoints()` has internal unavailable/mismatch/unsupported categories, but the chooser does not expose all of them. This establishes an observability gap, not the physical root cause.

The reproducer must distinguish native endpoint eligibility, receiver access, per-slot response, identity decoding, model filtering and lifecycle cleanup. Keep full identity checks and save-before-control admission intact. Any diagnostic additions should report fixed categories/counts only, without names, addresses, serials, unit IDs, raw reports or authentication material. No live inventory, diagnostic log read or HID request is authorized by this document.

### Confirmed source defect: native output-element type

Read-only inspection on 1 November 2026 found the prior `LogitechEndpointEligibility.isEligibleBolt` compared the native element raw type to `6`. The installed Apple SDK header `IOHIDDeviceTypes.h:125` defines `kIOHIDElementTypeOutput = 129`; the native catalog supplies `IOHIDElementGetType(...).rawValue`. A real output element therefore failed the prior predicate before slot/identity probing. The old synthetic fixture used the same incorrect raw value `6`, so its green checks did not establish native compatibility.

Applied correction: use the SDK enum constant instead of a numeric literal, and supply the SDK output type in the regression fixture. The invalid value is explicitly rejected while vendor/product/report/input checks remain. The actual predicate produced two failing assertions before the fix and one passing regression test afterward. This is a verified code-contract defect consistent with the screenshot, not a claim of owner hardware validation.

## Module boundaries

The existing `BoltTransport` is a feature/function/software-ID transaction interface. Pairing uses receiver registers plus asynchronous notifications and must have a distinct framing/matching boundary. The native sender now uses explicit 7-/20-byte frame storage and report IDs. Register matching, pairing notifications and existing feature requests share one selected native reader while retaining distinct correlation rules. Confirmed release precedes handoff back to management.

Pin the selected native receiver handle for the session. Catalog enumeration creates new opaque UUIDs, so an in-flight pairing session must not re-enumerate and resolve an expired selection token. Ensure one report reader/transaction lane for the selected receiver; active settings management and pairing must not compete for that endpoint. Restore prior saved connection intent only after the pairing lane has closed and lifecycle/identity checks still match.

Synthetic checks should cover short/long frames and reply correlation; bounded candidate fragments; stale/duplicate/interleaved events; unsupported authentication; occupied/full/unknown capacity; cancel/timeout/receiver loss; late success; persistence failure; and fresh identity before management. Native radio authentication and allocation remain manual owner checks in the signed app.

## Evidence

- Current source: `app/Sources/LogitechBolt/{BoltProtocol.swift,IOKitBoltTransport.swift,LogitechEndpointCatalog.swift,BoltController.swift}` and `app/Sources/HidhoggApp/AppModel.swift`.
- Owner research: `~/Workspace/ai/rea/investigations/logi-options-plus/hidhogg-connectivity-gap-report-2026-11-01.md`, `hidhogg-bolt-functionality-coverage-2026-11-01.md`, and relevant `protocol-workflows.md` sections.
- Additional named technical source: `hidhogg-pairing-mouse-protocol-spec-2026-11-01.md`, vendor-primary follow-up at lines 68–91. Parent independently inspected retained Web Connect source bytes 120,000–122,800. This resolves ordinary name parts 0–3, bounded count/text challenge, address-correlated entry progress and terminal slot/address layouts; it does not establish physical success. Preserve raw session addresses and challenges only ephemerally, without diagnostics.
- Primary source corroboration: [Solaar receiver register operations](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/receiver.py#L452-L490) and [pairing event handling](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/notifications.py#L476-L525). These establish protocol facts, not Hidhogg/macOS hardware results; do not copy the GPL implementation.

Verified 1 November 2026: focused gate passes 221 checks (34 XCTest + 187 Swift Testing); full offline gate passes 940 checks (580 XCTest + 360 Swift Testing), zero failures. Full gate excludes existing WakeConnectionTests and NativeWorkspaceWindowTests; excluded cases are not counted as passes. Native enum regression logs are /Volumes/Data/tmp/hidhogg-lc04-eligibility-{red,green}.log; gate logs are /Volumes/Data/tmp/hidhogg-lc04-{focused,full}.log. Signed app/CLI build 992654596b0c9b47e7d3c9f2b7d08b66c4d999f74e33340da9ce03eca5a1b6aa verifies; CLI help exits 0. Source remains uncommitted on master. No live hardware or pairing has run.

## Hardware limits and owner checks

The C548 profile uses six pairing-record selectors. A matched HID++ UNKNOWN_DEVICE (0x08) for a supported B5 selector is classified as no record. The [primary error enum](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp10_constants.py#L118-L129) establishes the generic name/value, but its context-specific empty-slot meaning is an implementation inference, not normative or Hidhogg hardware proof. Other rejections, timeouts and malformed records block pairing. Only receiver-selected allocation (slot zero) is requested; no unpair or explicit occupied-slot replacement is implemented. Pre/post records must show one new slot with existing records unchanged before registration. Receiver-full and slot-allocation behaviour remain owner checks.

Receiver labels are session ordinals; same-name mice can remain visually similar. For initial pairing acceptance, attach only the intended receiver and put only the intended new mouse into pairing mode. These labels never authorize identity matching.

1. Fully quit the old app and open dist/Hidhogg.app. With the existing MX3S working through Bolt, check Choose Existing Mouse, associate it and verify restart/reconnect with both receivers attached.
2. For a new pairing, select Pair New Mouse and the intended receiver. Use a free Easy-Switch channel, enter pairing mode and follow the shown challenge and both-button confirmation. Verify the final device information and saved settings; MX4 remains read-only.
3. Cancel before selection and during authentication. Confirm the prior saved mouse can recover. A late success must remain visible without unauthorized management; a publication already completed before cancellation can remain saved, with connection cancelled.
4. Confirm unavailable/full/unknown receiver states refuse unsupported operations. Do not treat a command acknowledgement or displayed challenge as successful pairing.

Verification used only synthetic fixtures; no live HID request or pairing operation was executed. Input continuity, physical identity stability and radio authentication remain unverified until owner acceptance.
