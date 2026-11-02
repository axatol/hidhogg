# BOLT-CRASH-04 — native HID callback lifetime

Resumed by owner on **2 November 2026** after further crashes. The approved interactive mouse-diagram scope is paused until the crash work is addressed. No diagram source or artwork changes have started.

## Approved report comparison

Only exception/termination details, binary identity and the faulting-thread stack were extracted from owner-provided crash2.log, crash3.log and crash4.log. All raw reports are locally Git-excluded. No configurations, other-thread stacks, HID payloads or private identifiers were exposed.

| Report | Event, AEST on 2 November 2026 | Evidence |
| --- | --- | --- |
| crash2.log | 18:28:13.8294 | Main-thread Swift release/closure destruction and SwiftUI platform-item layout; earlier build. |
| crash3.log | 19:19:43.0044 | Normal041d3ef5; worker thread7; input callback in BoltHIDWorker.open; SIGBUS. |
| crash4.log | 19:24:22.0773 | Normal041d3ef5; worker thread4; swift_retain inside BoltHIDWorker.receive; SIGSEGV. |

Neither newer report matches the separate ASan diagnostic artifact. The prior lack of visible sanitizer output was therefore not proof of a successful instrumented reproduction. Report comparison: `/Volumes/Data/tmp/hidhogg-crash-comparison-redacted.json`.

## Reproduced contract defect

Hidhogg registers report/removal callbacks with an unretained worker context, then tries to unregister using nil callback and nil context. The endpoint catalog retains an IOHIDDevice wrapper and passes that same wrapper into later transports. Identity-probe close followed by receiver inspection is one concrete reuse path.

Apple's source stores report/removal callbacks as data records in context-compared callback sets. Null-context removal does not match the prior worker context. Close delegates to the client interface; it does not clear the user-space callback sets. Report delivery copies the set and invokes its entries. [Pinned Apple callback implementation](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/hid.subproj/IOHIDDevice.c#L1939-L2015), [close](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/hid.subproj/IOHIDDevice.c#L516-L528).

The offline source-fragment reproduction ran the actual production unregister-call expressions against a registry following that context-key contract. It returned exit1: both retired callback registrations remained while the unrelated live registration was preserved. Command: `python3 /Volumes/Data/tmp/hidhogg-native-callback-contract-repro.py`; evidence `/Volumes/Data/tmp/hidhogg-native-callback-contract-red.log`.

A second native CoreFoundation experiment reproduced the callback table's context-only equality/default byte-hash inconsistency using synthetic CFData records. Even original-context/nil-callback removal did not remove the registration on this host. Output: `same_context_different_callback_hash_equal=false`, `same_context_unregister_removed_registration=false`. Source/binary `/Volumes/Data/tmp/hidhogg-callback-cfset-check.swift` and adjacent executable. This is a callback-contract reproduction, not a hardware crash reproduction.

## Proposed correction and verification

- [x] Compare approved crash fields and identify the native callback failure path.
- [x] Independently verify primary-source callback registration/removal semantics.
- [x] Reproduce stale registrations and same-context removal limitations without hardware.
- [x] Confirm minimal native ownership/lifetime design with independent architecture review.
- [x] Obtain owner approval for private per-connection native handles and safe callback/buffer lifetime.
- [x] Add regressions exercising actual registration/teardown integration with a native API stub, repeated opens and delayed callbacks; observe failure before correction.
- [x] Isolate native handles across transports and prevent retired callbacks from accessing freed worker/buffer state.
- [x] Run relevant offline, sanitizer and release gates; preserve attempts and exact input hashes.
- [ ] Owner verifies repeated Connect/disconnect and receiver removal with the new signed candidate.

This mechanism fits the native crash stacks and provides a concrete defect to fix. It does not yet establish that every earlier SwiftUI failure shares the same cause. No agent device query/write, production launch or memory-content inspection occurred.

## Approved implementation contract

Owner approved proceeding on2November2026. Give selected connections private IOHIDDevice instances and revalidate the service key/eligibility; derive Bluetooth output elements from the private instance. Native input/removal/matching callbacks carry nonreused opaque tokens rather than object addresses. A local locked admission registry resolves tokens to weak owners and tracks admitted callbacks; retired/missing tokens are dropped before touching state or report bytes. Teardown retires/drains callback admission and keeps native objects/buffers alive through worker shutdown. Callback unregister is best-effort cleanup, not a memory-lifetime guarantee.

Tests must exercise the actual worker via an injected native boundary that deliberately retains callbacks after unregister. Repeated same-service opens, late callbacks after retirement/release, callbacks during close, private-client identity, close failure and resource reclamation are required. Output packet changes should stay limited to what this contract demonstrably requires; no AppModel/domain/settings behavior changes are planned.

## Actual-worker behavioral RED

The implementer introduced a native API seam while deliberately preserving old callback admission and cached-device selection. Tests invoke the exact C input callback installed by worker.open, not receive directly. The focused RED run exited1 with2tests/5assertion failures: retiredInstalledInputCallbackCannotReachClosedWorker observed diagnostics increasing1→2 after close; sameServiceReopenUsesDistinctPrivateClientsAndNeverSchedulesCatalogDevice observed0private creations and both registrations/schedules using the cached wrapper. Log /Volumes/Data/tmp/hidhogg-bolt-native-lifetime-red.log. No deliberate use-after-free or actual hardware crash was induced.

Output completion must continue to complete accepted requests while submissions are sealed. Callback admission is retired only after accepted operations drain; completion mutation uses that same admission lease rather than a submissions-sealed check. The existing single-completion packet ownership contract remains unless a specific failing case requires change.

## Buffer lifetime refinement

The first callback/isolation correction passed9focused tests, then review identified that releasing a Swift wrapper does not prove the underlying native object has been destroyed. Apple can retain that native object while applying callbacks. The buffer is therefore associated with the actual private IOHIDDevice using the public Objective-C retained-association API; storage owns no device/worker reference, and the association is never cleared during close. Current published IOKit creates HIDDevice as NSObject and performs native cleanup before superclass deallocation; this is a supported-target implementation dependency, not a universal CFType guarantee. [Association contract](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjectiveC/Chapters/ocAssociativeReferences.html), [native object construction](https://github.com/apple-oss-distributions/IOKitUser/blob/main/hid.subproj/IOHIDDeviceObjc.m), [native destruction](https://github.com/apple-oss-distributions/IOKitUser/blob/main/hid.subproj/HIDDeviceBase.m).

Expanded11-test GREEN exercises the real association helper with an inert native-object surrogate retained beyond the worker/wrapper: normal/error close, pre-trampoline buffer writes after teardown, rejection of retired callbacks, then buffer reclamation after final native-owner release. Log /Volumes/Data/tmp/hidhogg-bolt-native-lifetime-green-native-owner.log. Initial GREEN harness failure was an invalid ObjectIdentifier comparison after resource reclamation/address reuse; harness corrected to retain the first resource during distinct-client comparison, with explicit reclamation cases added. Initial/failing attempt remains preserved.

Parent approved a narrow native sendReport adapter for the three existing output submission sites, solely to test accepted-send completion while new submissions are sealed and late completion after callback retirement. Packet ownership and wire semantics remain unchanged; final immutable-buffer binding and send-completion gates are pending.

## Frozen implementation checkpoint

Implementer final focused GREEN passes15tests; adjacent worker/diagnostics checks pass29. New sendReport adapter accepts the existing internal device wrapper, extracts raw IOHIDDevice only in production, and preserves the three output paths/wire/packet ownership. The API stub uses nil-raw device wrappers and inert NSObject native owners; only existing nonoptional C matching/catalog argument types use inert CF sentinels, never passed into IOKit. The initial implementer ASan compilation was interrupted (exit130) before tests; no sanitizer verdict is claimed for it.

Four implementation/test paths changed from the signed NAME-02 source: IOKitBoltTransport.swift, new BoltHIDNativeAPI.swift, new BoltHIDCallbackRegistry.swift, and new BoltNativeCallbackLifetimeTests.swift. No catalog, controller, application, settings or device-write policy changes. Final363inputs frozen at /Volumes/Data/tmp/hidhogg-bolt-crash04-inputs.json SHA256d567bf224b2b1dd300e53d366378245ec6fc2d691bda20bdcfc27f4ba7426e5a. Independent review and focused/full/optimizedASan gates now own the caches; source edits are suspended pending results.

## Independent rollback finding

The first independent focused backend gate passed327SwiftTesting cases, but architecture review found an uncovered failure combination: registerInput=false triggered immediate rollback, discarded an unverified native-close result and cleared device references; subsequent closeAndWait could see no device and falsely report closed. Full/ASan gates were stopped before running. Implementer is adding the combined registration-failure/native-close-error regression before a minimal sticky teardown-uncertainty correction. This is a local-close acknowledgement issue, not a new hardware crash claim. Initial363manifest and focused log remain preserved.

## Corrected rollback and final independent gate

The combined rollback regressions ran RED:2test functions/4parameter cases/14issues. They reproduced both false closed acknowledgement and successful unsafe retry/private creations1→2 after an unverified rollback close. Minimal worker-local nativeTeardownUnverified now remains sticky, blocks another open and preserves unverified when later teardown finds no device. Complete lifetime GREEN passes17tests. Logs /Volumes/Data/tmp/crash04-rollback-{red,green}.log. Independent architecture/source reviews confirm the finding resolved; hardware validation is still pending.

Corrected final363manifest /Volumes/Data/tmp/hidhogg-bolt-crash04-inputs-final.json SHA256682f802ac73ee2ed6c21160921855e5fedd4d8f5de9ee64320d4e111439afffb. Only transport and lifetime tests differ from the first363freeze, which remains preserved. Independent focused/full and optimizedAddressSanitizer verification is running against this corrected frozen set; no source edits or simultaneous builds by the parent/implementer.

## Signed owner-test candidate

Independent final gates pass:329SwiftTesting backend cases; full676XCTest+511SwiftTesting=1,187 with exactly the existing WakeConnectionTests and NativeWorkspaceWindowTests exclusions; optimizedReleaseAddressSanitizer329backend cases with no sanitizer diagnostics. All363inputhashes match before/after tests/build. Logs /Volumes/Data/tmp/hidhogg-crash04-{focused-final,full,asan-final,release,cli-help}.log.

Normal signed build40529d5e0a5199a8ce8a79cf647574e067ca2186294a55c526a045088d1d4a75 is in dist/Hidhogg.app and adjacentCLI. Appdeep/strict and CLIstrict signatures/help pass; normalbinarydoesnotloadASan. Matchedsymbols preserved /Volumes/Data/tmp/hidhogg-crash04.app.dSYM. No agent app launch, device/input operation, private configuration inspection or push. Existing naming/layout work is preserved. Native correction is uncommitted pending owner hardware verification on basea531d87; no all-crashes-resolved claim.

Owner next quits any running Hidhogg copy, opens the normal distapp, Connects the saved mouse, repeats Disconnect/Connect, and checks receiver removal/reinsertion with one/two receivers. No device removal/unpairing or settings reset is required. Interactive mouse-diagram scope remains approved but paused for this verification.

## Owner acceptance — 2 November 2026

Owner reports no further crash so far and believes the fix is working. This is current-use acceptance for a native-only local checkpoint, without an asserted duration or exhaustive hardware matrix. The native-only source/test overlay independently passes313backendtests against the committed baseline; all338Swiftinputs in that isolated snapshot remain available under /Volumes/Data/tmp/hidhogg-native-commit-check. Naming/layout edits are outside this checkpoint. Continue observing stability and reopen diagnosis if symptoms recur.
