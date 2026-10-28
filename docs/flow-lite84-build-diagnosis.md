# FL-01 build-output diagnosis

26 October 2026. Diagnosis only; no production/test source, permissions, mount options or existing caches changed. Previous signed dist artifact remains unchanged. Current toolchain reports Apple Swift 6.4 and macOS 27 SDK, targeting macOS 26.

## Subsequent permission retry

The owner reapplied Full Disk Access to WezTerm and requested continuation. Both exact external-volume overwrite repros (Clang and Swift) then passed without cache deletion or filesystem permission changes by the agent. The original external-cache focused test command also completed successfully: 28 backend, eight model and three menu cases passed. Log: /Volumes/Data/tmp/hidhogg-flowlite-fda-focused.log. This strongly supports the execution context's macOS privacy access as the blocker, although the earlier logs did not establish the precise denied TCC transaction. The workspace-cache workaround and build-script change are no longer required. The separate native height assertion correction and remaining full/native/release/probe gates are being resumed.

Final continuation completed: native height assertion corrected to the existing minimum-size contract; 6/6 explicit fake native checks and604 unique full/background checks pass; fixed-path app/CLI signed and verified; bounded read-only receiver snapshot succeeded after one earlier invalid-response attempt. See [final evidence and owner gates](flow-lite84-implementation.md). No build-script cache allowlist change was made. The sections below retain the earlier diagnosis record, not the current blocked state.

## Confirmed boundary

| Controlled probe | Result |
| --- | --- |
| Direct Swift emit-module to a new /Volumes/Data/tmp output | Pass |
| Same command overwriting that output | EPERM / Operation not permitted |
| Same command with compiler -disable-sandbox | Same EPERM |
| Same command creating then overwriting app/.build output | Both pass |
| Empty Clang preprocessing output on /Volumes/Data/tmp | First create passes, second overwrite fails EPERM |
| Python write-open/read-write/no-follow/truncate and identical-byte restore on disposable external module | Pass |
| Existing cache module metadata | Normal writable owner mode; no ACL or immutable flag observed |
| Swift reading a public source copy from external temp | Pass |
| Package test build using workspace app/.build cache | Compiles and executes tests |

This isolates a tool/process/location-dependent external-volume output overwrite restriction. It is not specific to Flow Lite source, SwiftPM dependency resolution, one old cache or ordinary POSIX mode bits. The mount reports APFS with noowners, but that is an observation, not proof of cause. Scoped sandbox/TCC log inspection did not establish a specific denying policy. Do not claim TCC, noowners or the legacy build-system option is the proven cause; no chmod/chown, ownership-enable, Full Disk Access or security-disable change was made.

An early backend-only default build passed while the legacy native build failed. That was insufficient to establish a build-system cause: a subsequent default package test build also failed on external-cache Ulanzi outputs. The smaller direct compiler/Clang reproducer is the decisive evidence.

## Reproduction and usable workaround

Run the following twice with a unique disposable output stem. The first direct emission creates outputs; the second reproduces EPERM on the external output. This does not open HID.

```sh
swiftc -emit-module -parse-as-library -swift-version 6 \
  -target arm64-apple-macosx26.0 -module-name LofreeFlowLite84 \
  app/Sources/LofreeFlowLite84/*.swift \
  -o /Volumes/Data/tmp/LofreeFlowLite84-diagnosis.swiftmodule
```

Changing only the output to app/.build/LofreeFlowLite84-diagnosis.swiftmodule passes creation and overwrite. Practical test workaround:

```sh
swift test --disable-sandbox --package-path app --scratch-path app/.build \
  --filter 'FlowLite84|MenuBarStatusTests'
```

Logs are under /Volumes/Data/tmp: hidhogg-flowlite-diagnosis-direct.log, direct-repeat.log, direct-nosandbox.log, workspace.log, workspace-repeat.log, default-tests.log and workspace-tests.log (all with the hidhogg-flowlite-diagnosis- prefix). The native/default comparison logs are retained with the same prefix.

## New validation evidence

The workspace-cache focused run executed 28 backend Swift Testing cases, eight model XCTest cases and three menu-status XCTest cases successfully: 39 passes. It also selected the fake native workspace render case. That case rendered both synthetic window sizes, but failed two height assertions: actual 592 vs expected 560 and 832 vs 800. Independent read-only tester review found that the new case asserts exact hosting-view height while neighboring checks using the same titled-window/toolbar harness accept at least the requested height. This does not establish a production layout defect; the consistent 32-point difference is compatible with the harness's window chrome. No test assertion was changed. Overall focused command exit status remains failure until that case is resolved. The fake captures show header/battery content, but lower GroupBox regions are blank in the bitmap; lower-field visual rendering remains unverified.

No full suite, accepted native gate, live receiver query, release packaging, provenance refresh, commit or push is claimed. The release script currently permits scratch directories only under external /Volumes/Data/cache or /Volumes/Data/tmp. Supporting the proven workspace-cache workaround in that script would be a separate source edit; no script change was made during diagnosis.
