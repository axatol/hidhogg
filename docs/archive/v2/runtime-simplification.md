# In-process runtime simplification

Task: V2-A01 #414. Authorised 2026-10-18. Status: implemented and independently verified; ready for owner decision review.

## Approved behavior

- One app process owns the runtime engine. App operations use direct typed Swift calls; external CLI retains its socket adapter and security protections.
- App/device/Settings remain usable if CLI socket setup fails; report external connectivity separately.
- Each operation captures its session; retired handles reject new work. Retain admission and drain accepted mutations on shutdown. Cancellation before admission must not mutate; cancellation after commitment must not imply rollback.
- One session-owned module shares reload state and configuration transaction behavior across app, watcher and CLI. Preserve disk-source digest versus active configuration and separate commit/reload results.
- Remove unused app transport and clearly obsolete terminology; retain useful session identity/concurrency/orchestration state machines.
- Verification includes focused contracts, arm64 build and bounded temporary simulated app with synthetic TOML plus external CLI. No physical device, keyboard posting or owner configuration.

## Decision record

### D1 — One session-owned operations module

Choose a RuntimeOperations actor shared by direct app callers, file watcher and IPCServiceBinding. Alternative: separate direct app operations beside existing binding. Rejected because configuration reload counters, outcomes and source validation could diverge. Keep one coordinator/admission mechanism; no registry or second policy implementation.

### D2 — Retired handles and admitted work

Choose captured session handles, not a forwarding handle that resolves the current session when invoked. Operations track work for retirement: close ingress, cancel work queued before coordinator admission, drain work already admitted. Alternative: let socket shutdown define retirement. Rejected because direct callers no longer pass through its handler drain. Preserve coordinator admission and post-commit completion semantics.

### D3 — Typed payloads and transport errors

Choose Core payloads without request/instance wire fields; IPC adapter projects existing wire contract. Alternative: invoke JSON handlers in-process. Rejected because it removes socket I/O but retains transport coupling and validation complexity in app calls. Keep safe diagnostics and explicit stale/rejected/uncertain outcomes.

### D4 — Optional external connectivity

Publish session identity/operations separately from optional CLI endpoint and its visible failure. Alternative: fail runtime startup if CLI socket cannot start. Rejected by owner: app/device must remain usable. Retain external path/UID/identity/framing protections and partial-resource cleanup.

### D5 — App test seam

Choose a small app-owned async operations protocol, with RuntimeOperations conforming and test actors substituting at the same seam. Alternative: construct a real Core runtime for every UI state-machine test, or retain sync socket fakes. Rejected because existing orchestration tests need deterministic delayed completions without wire coupling. Core payloads are shared; no duplicate app payload family.

### D6 — Failed optional endpoint cleanup

Choose immediate best-effort stop/identity-guarded cleanup of partially started CLI resources, retaining references when cleanup is uncertain for final shutdown. Alternative: leave a hidden server running after a failed health check. Rejected because reporting connectivity unavailable should not orphan endpoint resources. Startup cancellation remains cancellation rather than a CLI warning.

### D7 — Deterministic retirement/admission verification

Choose minimal internal read-only admission/retirement observation predicates for tests. Alternative: infer queue entry from preflight counters or fixed Task.yield counts. Rejected by adversarial review because preflight is not admission and scheduler timing cannot prove that concurrent retirement entered. No public interface/new queue/admission behavior change.

### D8 — Clone source and digest ordering

Resolve an omitted clone source from the same digest-validated source within shared operations. Alternative: extra editor snapshot read in the wire adapter. Rejected because changed invalid TOML could replace a stale-source rejection with decode failure and allow state from separate reads to diverge. Add regression for stale clone after external invalid bytes.

### D9 — Optional clone-source semantics

Source verification (baseline IPCServiceBinding.swift:502–505 at baseline 2bd2fb6) establishes omitted source means the disk configuration default profile, not an empty profile or necessarily the current profile. Preserve that behavior in a typed public clone operation resolving optional source after digest validation; keep the coordinator edit enum's resolved required source unchanged. Alternative: substitute the UI current/default snapshot or change nil to empty clone. Rejected because snapshot may be stale and empty-clone would change product behavior. Correct misleading current-profile UI copy to default-profile wording if present. This resolves the app executor's reported optional-source contract blocker.

### D10 — Simulation readiness and CLI reachability

Choose ready markers keyed by session identity with explicit cli_state=available/unavailable; endpoint paths appear only when available. Alternative: keep readiness gated on a socket path. Rejected because a usable direct app session with failed optional CLI must still be ready. Normal synthetic smoke independently exercises CLI reachability; degraded state is covered by deterministic app-composition fixtures.

### D11 — Constructible typed result

Add a public value initializer for existing RuntimeActivationResult (profileID, changed, revision). Fields were public but the implicit initializer was not accessible to app-owned fake adapters. Alternative: @testable-import Core solely to construct test values. Rejected because the app's public typed seam should support external substitutes without privileged access. No runtime behavior change; Core source ownership extended only for the constructor, independent gates must account for the added path.

### D12 — Remove app transport tests, retain app guarantees

Delete app-only ProfileClient/ConfigEditorClient/UnixSocketClient/Protocol wire implementation and app wire-specific tests after migrating actual callers. Extract ProfileValidation/UUIDValidation and preserve app validation plus all four endpoint-directory/path security cases. Core CLI protocol/discovery/client/server tests remain. Settings 42→41 tests: four endpoint→runtime test renames, only obsolete 10-second socket-factory timeout removed. Profile 17/display 4 behavioral test names preserved. Exact final inventory/execution counts follow independent gate; do not describe removed transport tests as retained 1:1.

### D13 — Never adopt an unowned endpoint during fallback cleanup

Final adversarial review found inherited removeRuntimeGeneration logic lstat-adopted any currently present owner-only socket before unlinking. New optional-CLI fallback reused it even when startup failed before creating a socket. Choose server-owned socket removal by its recorded identities; app cleanup removes only its identity-matched empty generation directory. Alternative: infer ownership from current UID/mode/path. Rejected because those facts do not establish which socket this attempt created. Preserve remaining entries and report uncertainty. Extend synthetic reserved-metadata fixture with a preexisting socket and assert both survive startup failure and quit.

### D14 — Preserve accepted identifier syntax

Final review found a new test rejected digit-leading IDs though baseline and extracted validation permit initial ASCII alphanumeric bytes. Correct the test to accept digits and reject leading punctuation; do not change production validation during transport refactor. Alternative: narrow IDs incidentally. Rejected as unrelated behavioral change.

### D15 — Portable short fixture roots after a filesystem stall

The stalled app test sample was in its first mkdir, before runtime construction. New bounded shell mkdir probes both on /Volumes/Data/tmp and /private/tmp succeeded in 0.019 s, so a general volume stall was not reproduced and the cause remains unconfirmed. Choose standard short /private/tmp roots for only the two new composition fixtures, matching existing runtime convention and socket-length constraints. Alternatives: rerun the whole unchanged suite blindly; infer/fix a product deadlock without evidence; request new OS permissions for a mounted-volume fixture. Rejected. No product code/scheduling change. Isolate originally stalled selector with external 90-second bound before full suite. Original interrupted evidence retained; temporary phase logs reverted unexecuted.

### D16 — Retain useful lifecycle structure

Retain session identity, profile/display orchestration and existing observer mechanisms. Alternative: combine this transport change with an observer rewrite or broad lifecycle renaming. Rejected to preserve tested ordering and keep the implementation review bounded. The historical Supervisor.swift filename still contains active generation-directory and lifecycle utilities; it is not a process supervisor. No child runtime or helper was introduced.

## Verification

All final checks used the frozen source. The CLI adapter retains its protocol, discovery, peer-UID, framing and identity protections.

| Gate | Result | Evidence under verification root |
|---|---|---|
| Full Core suite | 212 passed, zero failures | CoreFinal/full-suite.log |
| Safe app suite | 125 passed, zero failures; watchdog not fired | AppTestsR3/safe-app-suite.log and .xcresult |
| Production Debug app | Build passed, arm64, no test-host define | AppDebug/build.log |
| Production Release CLI | Build passed, arm64 | CLIRel/release-build.log |
| Native app with simulated D200X and real CLI | Passed; graceful exit 0, no watchdog escalation, runtime and simulation roots removed | Smoke/smoke-a01smk1-escalated.log; SmokeArtifacts/a01smk1/harness-result.json |

Verification root: `/Volumes/Data/tmp/hidhogg-runtime-simplification-20261018`.

The app suite excluded only `HidhoggSimulationCompositionTests.testExplicitSimulationCompositionStartsReadyAndQuitsGracefully`; the separate native app/CLI gate exercised the actual packaged app and socket path. That gate verified ready/protocol 1, default and office profiles, activation in both directions, notification emit/clear, and a shared instance UUID where the protocol returns it. Degraded-CLI tests exercised direct reads, edits and status with no endpoint, and preservation of pre-existing metadata/socket entries when cleanup is uncertain.

Final source manifest: `final-source-manifest-r3.json`, 100 entries (94 present and six expected deletions), zero mismatches after tests, builds and smoke. SHA-256: `ff4e8e9993ae3fef46c407ecafc67fe198c21ec7dd64aa9afd10e2f553f3376b`.

### Build artifacts

- App: `/Volumes/Data/tmp/hidhogg-runtime-simplification-20261018/AppDebug/DerivedData/Build/Products/Debug/Hidhogg.app`.
- App executable SHA-256: `c20428f1d7c7f9c114ee4908f6d2da7543816d9e5c907a5516ea358a4ca74212`.
- CLI: `/Volumes/Data/tmp/hidhogg-runtime-simplification-20261018/CLIRel/SwiftPM/out/Products/Release/hidhoggctl`.
- CLI SHA-256: `80ceb9da900f0e879eae3ce46f3c8d31bc2a813d236937eb7cbd6d43735ac502`.

### Final evidence hashes

- Core log: `5a82099f3e3b7e031d17757ce164800eeeb2e9ba418538d532cf043d46c14806`.
- App suite log: `92b56d0ed39be2a4fd4d47b7c177d1ea00743ef5ffb0377879c84b98d9104112`.
- Smoke log: `82c6b05ab76744be83fa89cc1f3e9bb4bd9edfad787f5636435ea8ace995df15`.
- Smoke result: `198f885abaea256441aa44df9308eb2e73ebe0ca486cb0c17704b6b2c63a3032`.
- Reviewed smoke script: `b41cc20b1fc5fd8e40287976b2f3b020d2e3cafbb4d4fad6a5c427d6e3fb7d52`.

### Qualifications and retained failures

An earlier app-suite run stalled in the first fixture `FileManager.createDirectory`/`mkdir`, before runtime construction. A two-second sample of the exact test host established that location, not a product deadlock. The run was interrupted with scoped SIGINT (exit 75), and its cause remains unconfirmed. Bounded shell probes at both temporary locations succeeded. After moving only the two new test fixtures to standard short OS temporary paths, the isolated test passed in 0.027 seconds, then the full app suite passed. Original evidence is retained in `AppTests/xcodebuild-test.log` (SHA-256 `6f095689fba3e576c8173b82120f629f52471389325c9f80fca45f78e0b28766`) and `AppTests/hung-testhost.sample.txt` (`411abd23d7df8e4b2fb217c835817fe85788f2f38de90efd889f72810f93a65f`). Temporary phase diagnostics were reverted without execution.

Earlier compile-only attempts exposed missing imports, privileged test imports and fixture initialization/isolation errors; corrected before the passing suite. Sandbox-restricted package builds and the first smoke attempt stopped before product execution; the scoped retries passed. An overbroad manifest request including TOML was rejected before execution; all approved manifests excluded configuration files.

No physical HID, native keyboard posting, real configured-action execution or GUI interaction was performed. Owner configuration, environment values and unrelated untracked files were not inspected. The actual smoke app PID was absent after exit. No push, installation or deployment was performed.

### Owner confirmation

The owner confirmed that the new build still works after the in-process refactor. They also reported that the screen had locked earlier. The timing relative to the interrupted fixture test and any causal relationship remain unverified; this does not establish the cause of that stall.

## Completion checklist

- [x] Concrete interface and bounded ownership
- [x] Shared typed operations and CLI adapter
- [x] Direct app callers and session lifecycle
- [x] Adversarial review and corrective regressions
- [x] Independent Core/app tests and arm64 production builds
- [x] Synthetic native app/CLI integration and cleanup
- [x] Decisions, alternatives, scope audit and handoff
