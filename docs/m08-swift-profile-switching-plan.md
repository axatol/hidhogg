# M-08 Swift foreground profile switching plan

Status: implementation-ready draft on 2026-09-23; production changes require owner contract confirmation.

Historical v1 plan, superseded by the accepted Swift-owned runtime and app composition. Go-runtime and supervisor references below describe the retired implementation, not current operations. See [v2-plan.md](v2-plan.md).

## Outcome

Restore compatibility between the bundled Swift menu app and the current Go runtime, then switch Go-owned profiles when the foreground macOS application's bundle identifier matches a Swift-owned mapping.

```text
NSWorkspace activation
        |
        v
bundle identifier -- exact mapping --> profile ID
                                      |
                                      v
                         profiles.activate over IPC
                                      |
                                      v
                             Go owns D200X state
```

The Swift process owns observation and mappings. Go exposes the profile catalog and accepts profile IDs; Go never receives or stores application identifiers.

## Grounded constraints

- The existing Swift supervisor launches `hidhogg-runtime` with `--socket-path` and `--instance-id` only. The Go runtime now also requires an absolute `--config-path`, so the bundled app cannot currently reach readiness.
- Swift protocol support is limited to `health` and `status`. Go already implements bounded protocol-v1 `profiles.list` and `profiles.activate` methods.
- Apple documents [`NSWorkspace.didActivateApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification) as the application-activation signal and requires registration with the workspace notification center. [`NSRunningApplication.bundleIdentifier`](https://developer.apple.com/documentation/appkit/nsrunningapplication/bundleidentifier) is optional, so a missing identifier must be ignored rather than guessed.
- Existing explicit socket/instance mode remains the narrowest compatibility path. Migrating Swift to runtime-directory discovery is not required for this milestone.

## Stable tasks

### M-08-P01 — Freeze the Swift contract

- Decide how the owner selects and persists the absolute Go configuration path.
- Decide how bundle-identifier-to-profile mappings are edited and persisted.
- Define startup, unmatched application, missing bundle identifier, duplicate activation, runtime restart, and stale profile behaviour.
- Gate: owner confirms the decisions before production code changes.

### M-08-C01 — Restore bundled runtime compatibility

- Add one validated absolute configuration path to supervisor configuration and the runtime launch request.
- Surface a bounded, actionable missing/invalid-path state in the menu app.
- Preserve one-restart supervision and generation cleanup.
- Acceptance: the bundled runtime reaches ready with the selected configuration and launch tests prove the exact arguments.

### M-08-I01 — Extend the Swift IPC client

- Add strict request/response support for `profiles.list` and `profiles.activate` without weakening existing health/status validation.
- Keep frame, request-ID, instance-ID, peer-owner, and timeout checks.
- Acceptance: fixtures cover success, `changed:false`, malformed results, server errors, bounds, and reconnect after a supervised runtime restart.

### M-08-R01 — Observe and map the foreground application

- Seed state from `NSWorkspace.shared.frontmostApplication`, then observe activation notifications from `NSWorkspace.shared.notificationCenter`.
- Resolve only non-empty bundle identifiers through an exact mapping.
- Fetch the valid profile catalog from Go; reject or visibly mark mappings whose profile IDs are absent.
- Coalesce repeated activation of the same effective profile. Serialize activation requests; do not speculate about an in-flight outcome.
- Acceptance: deterministic injected-observer tests prove initial activation, matching, unmatched/nil identifiers, duplicate suppression, ordering, runtime unavailability, and recovery.

### M-08-U01 — Minimal owner configuration surface

- Provide only the controls needed to select the Go TOML file and manage exact bundle-identifier/profile mappings from the live Go profile catalog.
- Do not add profile editing, pages, action editing, arbitrary process inspection, or configuration-file mutation.
- Acceptance: the owner can configure one application mapping without command-line preference editing.

### M-08-V01 — Independent and owner verification

- Automatic: Swift unit/integration tests, current Go tests, bundle/build verification, and no regression to cleanup/restart behaviour.
- Owner: select a valid TOML file, map two applications to distinct profiles, alternate focus, verify one corresponding profile transition per effective change, verify a known unmapped application activates the default profile while nil/empty bundle identifiers do nothing, restart the Go child once, and verify switching resumes.

## Proposed module structure

```text
HidhoggApp / HidhoggAppModel
    |
    +-- AppPreferencesStore
    |       configuration path
    |       bundle ID -> profile ID mappings
    |
    +-- RuntimeSessionController
    |       creates/stops ProcessSupervisor generations
    |       publishes exact socket + instance endpoint
    |
    +-- ForegroundApplicationObserver
    |       initial frontmost application
    |       NSWorkspace activation events
    |
    +-- ProfileSwitchCoordinator
            profile catalog refresh
            mapping validation
            serialized activation
            observable switching state
```

Expected production files and responsibilities:

- `AppPreferences.swift`: immutable preference snapshot, validation, `UserDefaults` persistence, and injectable store protocol.
- `RuntimeSessionController.swift`: child-runtime lifecycle across initial selection and configuration-path changes. It creates a fresh supervisor rather than making `ProcessSupervisor` reusable.
- `ProfileClient.swift`: strict `profiles.list` and `profiles.activate` requests and typed responses over the existing transport.
- `ForegroundApplicationObserver.swift`: an injected stream of bundle identifiers sourced from `NSWorkspace.shared.notificationCenter` plus the initial `frontmostApplication`.
- `ProfileSwitchCoordinator.swift`: the only owner of mapping-to-activation decisions and in-flight serialization.
- `SettingsView.swift`: TOML selection, application-bundle selection, profile selection, invalid-mapping display, and removal.
- `HidhoggApp.swift`: composition and presentation only; it must not absorb persistence, IPC parsing, observation, or switching policy.

Existing `Protocol.swift`, `UnixSocketClient.swift`, and `Supervisor.swift` should be extended only at their established protocol, transport, and process-supervision boundaries.

## Preference contract

- Use app-local [`UserDefaults`](https://developer.apple.com/documentation/foundation/userdefaults), which Apple documents as appropriate for nonsensitive app settings and property-list values. Store the configuration path as a string and mappings as a string-to-string dictionary; sort keys only for presentation.
- Add `PrivacyInfo.xcprivacy` with the app-local UserDefaults approved reason `CA92.1`. Apple documents UserDefaults as a required-reason API and requires the use to be declared in the bundle privacy manifest. Declare no collected data or tracking because this design transmits and collects neither.
- Do not store TOML contents, profile definitions, application names, executable paths, icons, launch history, or foreground history.
- Configuration path must be absolute, non-empty, and selected through `NSOpenPanel`. Go remains authoritative for TOML parsing and semantic validation.
- The current target is not App Sandbox enabled. M-08 therefore does not add security-scoped bookmarks. Enabling App Sandbox later requires a separate persistence migration before distribution.
- Add mappings by selecting one `.app` bundle and reading only its `CFBundleIdentifier`; reject missing or empty identifiers. A dictionary makes duplicate bundle identifiers replacement decisions explicit rather than ambiguous.
- Initial implementation bound: at most 128 mappings; each bundle identifier and profile ID must be valid non-empty UTF-8 without control characters or NUL and at most 255 UTF-8 bytes. Profile IDs must also exist in the latest catalog before the mapping becomes active.
- Writes publish one complete validated preference snapshot. Invalid stored preferences are retained for diagnosis but are not used to launch or activate.

## Runtime lifecycle contract

State is explicit:

```text
configurationRequired
        |
        v
starting -> ready -> stopping -> stopped
    |        |          ^
    v        v          |
 failed   path changed--+
```

- With no valid selected path, the app does not launch the Go child and shows `Configuration required`.
- Selecting a valid path creates a new `ProcessSupervisorConfiguration` containing the embedded executable and absolute configuration path, then starts one supervisor.
- Changing the path first quiesces profile switching, cleanly stops the current child/generation, then creates a new supervisor. No two children overlap.
- `ProcessSupervisor` remains single-use. `RuntimeSessionController` owns replacement and publishes an endpoint only while the matching generation is ready.
- Launch arguments remain exact legacy mode plus configuration: `--socket-path`, generation socket, `--instance-id`, generation ID, `--config-path`, selected path.
- A failed child retains bounded failure text in the existing menu state. Automatic behaviour remains exactly one restart for the same selected path.
- Quit stops observation and switching admission before terminating the child, then waits for generation cleanup as today.

## Profile IPC contract

- Add `profiles.list` and `profiles.activate` to the Swift method model without using a permissive catch-all result.
- Requests preserve protocol version, canonical request ID, exact instance ID, newline framing, 16-KiB limit, phase timeouts, endpoint validation, and same-effective-UID peer validation.
- `profiles.list` accepts only the exact Go result shape: instance ID and 1..31 unique summaries with ID, label, default flag, and current flag. Exactly one current and exactly one default profile are required.
- `profiles.activate` accepts only the requested profile ID and `changed`; unlike the list result, the existing Go activation result does not contain an instance ID. A successful response must echo the requested profile ID, while the envelope request ID still binds it to the request and endpoint generation.
- Extend the allowed server error taxonomy only with error codes already emitted by the Go profile methods. Unknown codes and response fields remain rejected.
- A timeout, disconnect, endpoint change, or malformed response produces an outcome-unknown/degraded state. It is never automatically retried against the same generation.

## Foreground-switching contract

- On each ready generation, obtain a fresh profile catalog, then inspect the current foreground application once.
- Observe subsequent activation events only through `NSWorkspace.shared.notificationCenter`. Ignore events without a non-empty bundle identifier.
- Mapping comparison is exact and case-sensitive. Unmatched applications preserve the current profile.
- Refresh `profiles.list` before an activation decision. This makes the next foreground transition observe Go-side catalog reloads without polling or a new push protocol.
- Repeated observations resolving to the already current or already requested profile perform no activation request.
- The coordinator serializes requests. If A is in flight and B becomes latest, finish classifying A, then evaluate B against a fresh catalog. Never overlap activation requests.
- After an outcome-unknown result, publish degraded state and wait for a new foreground event, mapping edit, manual retry, or runtime generation. Do not silently repeat the uncertain request.
- A mapping edit re-evaluates the current foreground application. A runtime generation change discards cached catalog/current-profile state and performs the startup evaluation once.
- A profile missing from the current catalog leaves the current profile unchanged and marks that mapping invalid. There is no fallback activation.

## Minimal user interface

Menu bar content:

- lifecycle/health text;
- current profile or switching/degraded status when known;
- `Settings…`;
- `Retry Profile Switch` only when the last outcome is unknown or transiently unavailable;
- `Quit`.

SwiftUI `Settings` scene:

- configuration section with selected path, `Choose…`, and validation/runtime status;
- mappings table with application bundle identifier, selected live profile, validity state, and remove action;
- `Add Application…` opens `NSOpenPanel` for one `.app`, extracts its bundle identifier, then requires a profile selection from the current catalog;
- no raw TOML editor, profile editor, free-form bundle-ID field, application enumeration, automatic inference, or mapping history.

Apple documents [`Settings`](https://developer.apple.com/documentation/swiftui/settings) as the SwiftUI-managed macOS preferences scene, [`SettingsLink`](https://developer.apple.com/documentation/swiftui/settingslink)/`openSettings` as its presentation mechanisms, and [`NSOpenPanel`](https://developer.apple.com/documentation/appkit/nsopenpanel) as the standard file-selection panel.

## Implementation order and gates

### 1. M-08-C01 — Compatibility restoration

Edit surface: `Supervisor.swift`, `HidhoggApp.swift`, new preferences/runtime-controller modules, `PrivacyInfo.xcprivacy`, Xcode resource wiring, supervisor/app-model tests, and the live-test configuration seam.

Gate: no foreground APIs or profile IPC. Unit tests prove no launch without configuration, exact launch arguments, selection-triggered start, serialized path-change restart, one-restart preservation, and cleanup. Verify the built bundle contains the privacy manifest with only the app-local UserDefaults reason. Build all three Xcode configurations.

### 2. M-08-I01 — Strict profile client

Edit surface: `Protocol.swift`, `UnixSocketClient.swift`, new `ProfileClient.swift`, shared fixtures, and protocol/client tests.

Gate: cross-language success/error fixtures and generated strict mutations pass; maximum catalog remains below the frame limit; health/status behaviour is unchanged.

### 3. M-08-R01 — Observer and coordinator

Edit surface: new observer/coordinator modules, app-model composition, and deterministic fake-based tests.

Gate: initial foreground evaluation, exact match, unmatched/nil, duplicate suppression, rapid A-to-B ordering, invalid profile, unavailable runtime, unknown outcome, explicit retry, mapping edit, generation replacement, and shutdown all pass without launching applications or posting input.

### 4. M-08-U01 — Settings and menu surface

Edit surface: new settings views and narrow `HidhoggApp.swift` presentation wiring.

Gate: preference/store tests plus Xcode build. Manual UI review confirms path/application selection, profile choices, invalid mapping visibility, and no hidden child overlap when changing paths.

### 5. M-08-V01 — Integrated verification

- Independent review of module boundaries, strict parsing, lifecycle serialization, cancellation, and preference failure handling.
- Automatic: Swift tests, current Go tests/race/vet, schema determinism, embedded-runtime build phase, Debug/Release/Test app builds, and diff checks.
- Owner-visible: configure one TOML and two application mappings; alternate focus; confirm exact profile transitions, duplicate suppression, unmatched preservation, path-change restart, one forced child failure/recovery, and clean quit.
- Distribution signing, notarization, login items, and App Sandbox remain explicitly unverified.

## Failure presentation

User-visible states must be actionable but bounded:

- configuration missing or invalid: identify the setting, not TOML contents;
- runtime launch/readiness failure: existing bounded supervisor failure plus `Choose Configuration…`;
- invalid mapping: identify the bundle identifier and missing profile ID;
- IPC unavailable or outcome unknown: retain the desired mapping, show degraded state, and offer explicit retry;
- malformed/foreign response or endpoint substitution: treat as a security/runtime failure, never as a missing mapping.

No foreground history, configuration contents, device identifiers, executable arguments, or unrelated application metadata are logged.

## Recommended decisions for confirmation

1. Persist the selected TOML path and mappings as small Swift application preferences; do not duplicate Go profile definitions.
2. Match bundle identifiers exactly and case-sensitively. Treat duplicate bundle identifiers as invalid configuration.
3. Superseded on 2026-09-24: a known nonempty unmatched bundle identifier activates the catalog default profile; nil/empty identifiers leave the current profile unchanged and clear the remembered foreground-app identity. The earlier unmatched-retains-current policy is historical.
4. On Swift startup and after runtime recovery, query `profiles.list`, inspect the current foreground application, and activate its mapped profile once if valid.
5. A mapping to a profile absent from the current Go catalog is disabled and shown as invalid; there is no fallback profile.
6. Keep legacy explicit socket/instance supervision for M-08. Discovery migration is separate work.
7. Select applications through an `.app` picker and persist only their bundle identifiers; do not provide free-form identifiers initially.
8. Changing the selected TOML path performs an orderly child restart immediately.
9. Refresh the catalog on each mapped foreground transition rather than polling continuously.
10. Treat timeout/disconnect as outcome unknown and require a new event or explicit retry; never automatically retry the same uncertain activation.
11. Bound persisted mappings to 128 entries and each identifier to 255 UTF-8 bytes; reject control characters and NUL.

## Explicit exclusions

- Go-side bundle identifiers or application observation.
- Configuration mutation through Go IPC or `config.get`.
- Profile/page/action editors, regex or wildcard matching, per-window rules, delayed switching, histories, analytics, and automatic mapping inference.
- Login-item, signing, notarization, distribution, or launchd work.

## Uncertainty

Apple's documentation establishes the observation mechanism but does not, on the cited pages, specify a permission prompt for this use. Built-app behaviour still needs verification. The current repository has no foreground-observation implementation or tests. Runtime restart semantics for pending profile activation must be fixed by M-08-P01 rather than inferred during implementation.
