# Current storage follow-up — REG-FS-03

Flat filenames and cleanup supersede the earlier nested/recovery-history layout described below. Registration UUIDs are unchanged; the filename revision is the first12lowercase hex characters of SHA-256 over serialized payload bytes. Final verification evidence is recorded in the REG-FS-03 section. Earlier checkpoints remain historical.

# Device registry and per-device configuration — REG-01

31 October 2026. Owner approved starting the next planned task after local checkpoint027bf69. Scope: UUID registrations, dynamic device list, Add/Disable/Remove and separate device configuration with migration. Generic Bluetooth discovery/battery belongs to the following slice; Logitech Bluetooth identity/configuration and additional mouse hardware controls follow later.

## Checklist

- [x] Establish registry, runtime ownership and configuration transaction interfaces.
- [x] Implement validated registration/domain values and persistent UUID identity.
- [x] Implement safe legacy migration and per-device storage with conflict/failure protection.
- [x] Integrate dynamic sidebar and Add/Disable/Remove with lifecycle cleanup.
- [x] Verify migration, isolation, conflicts and lifecycle using synthetic fixtures.
- [x] Review UI source and build signed app without live device operations.
- [ ] Owner native narrow/wide layout and device-lifecycle acceptance.
- [x] Record evidence, limits and owner checks.

## Constraints

Do not inspect the owner's actual configuration, Bluetooth inventory, environment or device payloads. Use temporary synthetic files/tests. Preserve existing device settings, app profiles, actions and preset data. Do not infer same physical device from model/receiver slot. Registration UUID is distinct from verified endpoint identity. Existing singleton adapters cannot claim multiple identical-device management until endpoint selection exists. No automatic Bolt/Bluetooth merging. Disable retains settings but stops management/monitoring; Remove retains macOS pairing. No firmware/pairing/reset, Bluetooth discovery or new hardware commands in this slice.

## Current evidence

AppConfiguration validates one fixed Logitech model profile; D200X configuration is optional and also contains shared actions/presets. AppModel owns one controller per supported family, and WorkspaceRoute is a fixed enum. ConfigurationStore provides secure bounded single-file reads/optimistic revision/atomic rename. Multi-file transaction publication and clean failure recovery need explicit design before storage edits.

## Selected implementation boundary

Use a workspace registry plus typed UUID registrations, retaining the legacy aggregate as an editor compatibility projection rather than weakening its strict schema. Publish a root manifest that references versioned per-device files under devices/<registration UUID>/<revision UUID>.toml. Cover root and referenced bytes in optimistic revision checks; unreferenced files from failed publication are ignored. Preserve exact legacy bytes before migration publication. Do not promise a filesystem-wide transaction against uncoordinated malicious writers; preserve the existing ordinary external-edit conflict guarantee.

D200X actions/presets remain in its payload in this slice, and imported assets retain the original configuration-directory base. Do not relocate assets implicitly. Supported native families each have one registration/runtime adapter; adding a removed family restores a supported entry, not fabricated physical discovery. Generic Bluetooth discovery remains next. This bound follows actual singleton endpoint selectors and is not multi-identical-device hardware support.

## Verification cases

- Legacy bindings, per-app profiles, D200X actions/presets/images and launch preferences survive migration; backup bytes equal original.
- Invalid legacy/registry/payload files fail without publishing replacement defaults.
- Missing or symlinked referenced files fail safely; references are UUID-derived paths, not arbitrary traversal strings.
- Root and referenced-file external changes conflict; failed publication leaves the previous root/loadable configuration authoritative.
- UUID identity survives save/reload, rename, disable/enable and navigation; removed registration settings do not silently reappear.
- Disabling/removing a connected, connecting or recovering device stops management and invalidates pending effects; startup/wake cannot revive disabled entries.
- Remaining devices retain configuration and runtime state when another is disabled/removed.
- Removing the selected item chooses a valid remaining route or empty state; empty registry can Add again.
- Save/reload preserves newer edits during async persistence and presents conflicts without data loss.
- Existing protocol, input-admission, lifecycle and configuration regression suites remain green.

## Implemented behaviour

The registry uses schema2 in config.toml. Each referenced payload uses schema1, validates its UUID and family against the root reference and lives at devices/<UUID>/<revisionUUID>.toml. Loading valid legacy schema1 migrates it only after an exact config.toml.legacy-v1.backup is preserved. Invalid data fails closed. Files retain private permissions, symlink rejection, size bounds and byte-based conflict checks. A private writer lock serializes cooperating writers. New payloads publish before root; unchanged payloads are reused. Retired/orphaned versions remain on disk for recovery and are not automatically deleted. Remove means removal from the active registry, not secure erasure of historical versions or macOS unpairing.

Current native adapters admit one registration per supported family (MX Master3S, D200X, FlowLite84). Add restores a missing supported family with a new UUID and defaults. No Bluetooth inventory is queried. Sidebar/menu rows follow registrations; disabling retains settings and blocks lifecycle/connection/input/monitor paths. Enabling permits management again; explicit Connect remains available. UUIDs describe registrations and do not establish hardware identity. Legacy editor projections remain strict; absence/disabled status is checked independently so fallback projections cannot activate removed hardware. D200X assets retain their original configuration-directory base.

Initial focused gate passed91 tests before the final capture-revocation correction; the subsequent independent733-test gate covers final source. No production app/HID/owner config was accessed.

## Verified delivery — 31 October 2026

Independent offline package gate:733 passed, zero failures. Per target: app326, configuration65, automation38, Logitech149, Lofree92, Ulanzi36, MacOSActions27. WakeConnectionTests and NativeWorkspaceWindowTests excluded; native visual/physical acceptance is not claimed. Log /tmp/hidhogg-reg01-broader-test.log. All20changed Swift/test inputs matched pre/post test hashes; root postbuild canonical manifest digest f3ac907679a7d71e7a4094c56f6ba74a7616ed76d0f17d44179b5a027c7e997e matches independent posttest. Package.swift/Package.resolved unchanged. Test process session exited0; OS process enumeration unavailable.

Signed app/CLI build `dd887ea4d396f757794e6cf40d526269eb3542d44b18694a4c1062d41b2f4a08` passes strict signatures. Release log /Volumes/Data/tmp/hidhogg-reg01-release-20261031.log;233current source/resource/test hashes recorded in ignored dist/build-info.json; tested postbuild manifest /Volumes/Data/tmp/hidhogg-reg01-postbuild.sha256. No production app launch, live migration, private configuration/identifier inspection or hardware operations. Source remains uncommitted on master after027bf69.

Owner checks: launch signed app and verify previous settings/profiles/assets retained; disable each device and confirm connection/monitoring stop; verify Enable then Connect; remove/re-add a supported device and inspect empty-list recovery if desired; check sidebar/menu in narrow/default layouts. Migration backup and retained historical payloads are intentional. Next implementation slice is generic paired Bluetooth discovery/battery monitoring; no scan/pairing or Logitech Bluetooth work in this build. TaskView unavailable (Network Error); repository plan/roadmap hold current progress.

## REG-UI-02 — 31 October 2026

Owner approved moving management controls from the top bar into each device settings card. Added shared DeviceManagementControls; all3header cards now contain Enable/Disable, Remove confirmation and disabled-only status. Sidebar context menu retained; standalone banner removed. Runtime/model handlers unchanged. Signed app/CLI build `d2d61c8eaff18b09834eafcae7cbc42de4de2108d5b5ff69574650b5656af625` passes strict signatures;234current input hashes recorded. Prior733-test registry gate not repeated for view-only relocation. Shared component visually inspected offscreen at320/760px, enabled/disabled, synthetic models/no-op actions and never-shown windows. No production app/device/configuration operations. Native whole-workspace acceptance remains owner check. Release /Volumes/Data/tmp/hidhogg-reg-card-release-20261031.log. Changes uncommitted.

## Approved simplification — REG-FS-03, 31 October 2026

Owner approved flat devices/<family>.<HidHogg UUID>.<12-character SHA256>.toml paths, content reuse/collision checks and post-publication cleanup, including migration from existing nested UUID revisions. Active registration UUID remains stable; hardware identifiers remain separate and are not added by this change. Preserve original legacy backup. Cleanup removes only recognizable app-owned obsolete payloads after durable root publication; unrelated/symlink/unrecognizable externally edited files remain untouched. Cleanup failure is best-effort and retried after later successful publication, not reported as a failed committed save. Existing aggregate external-edit checks and manual TOML reload semantics remain. No production configuration access or live migration by agents.

- [x] Flat content-addressed reference codec with legacy nested decoding.
- [x] Atomic publication, collision rejection and postcommit cleanup.
- [x] Synthetic migration/failure/cleanup/collision regressions.
- [x] Independent configuration regression gate, signed build and updated provenance.

REG-FS-03 source frozen: worker configuration gate73/73 passed. New root references use12lowercase hex SHA-256 revisions; legacy UUID revisions still decode under schema2 and migrate on load. Files are reused only after exact-byte checks, private mode repair and file/parent sync. Only EEXIST staging races may be reused; write/sync errors propagate. Cleanup is after root rename+sync, retains active refs and validates owned payload identity/shape/hash before unlink. Root bytes are checked inside unlink/rmdir helpers immediately before deletion. Ordinary external changes stop cleanup; the writer lock coordinates cooperating app writers, not arbitrary uncoordinated editor races. Independent scoped gate and signed build pending.

## REG-FS-03 verified delivery — 31 October 2026

Signed app/CLI build `a9dab2eb3641c0292bd9fb8d263a60e166e64dc27b75bf5d91c9589b9bf889f7` passes strict signatures. Flat payload names are devices/<family>.<registration UUID>.<12lowercase SHA256>.toml. Registration IDs/settings are retained; legacy UUID-based nested refs migrate on load after durable publication. Original legacy-v1 backup remains. Cleanup keeps current refs and only removes recognizable obsolete managed files after root sync; ignores unrelated/symlink/corrupt/manual-edited hash-mismatched files. Failed cleanup doesn't invalidate the committed config and retries on a later successful publication. No history UI or universal external-editor transaction guarantee.

Worker73config tests and independent97focused tests (73configuration+24AppModelIntegration) pass; no failures. Independent log /Volumes/Data/tmp/hidhogg-regfs03-focused-20261031-170329.log.21-file pre/post/postbuild manifests match SHA2569892c4cefb54295b122e82ca2a3e853859d8cc83f14ebfd7ad68484e42d1156b; final manifest /Volumes/Data/tmp/hidhogg-regfs03-postbuild.sha256. Existing733-registry gate is historical; not repeated for this scoped backend change. Release log /Volumes/Data/tmp/hidhogg-regfs03-release-20261031.log;234current build input hashes in ignored build-info. No app/HID/private configuration or live cleanup/migration performed. Changes remain uncommitted on master after027bf69. Owner next: restart updated app, confirm IDs/settings unchanged and flat files, obsolete recognized files removed; no agent actual-directory inspection.

## Owner acceptance — 31 October 2026

Owner reports the simplified device filename/cleanup change looks good and Add, Disable and Remove work as expected. Earlier card placement also received acceptance. These confirmations cover the reported user flows; fault-injection cases remain offline evidence, not additional hardware claims. REG-01/REG-UI-02/REG-FS-03 are ready for a separately authorized check-in. Changes remain uncommitted on master; no push authorized. Generic paired Bluetooth discovery/battery monitoring is the next planned implementation slice.

31 October 2026: owner authorized local check-in of accepted REG-01/REG-UI-02/REG-FS-03. All234signed-build input hashes match current source; strict app/CLI signatures pass. Evidence: earlier733offline registry gate, subsequent97focused storage/app-integration gate and shared-control offscreen layout review. No additional tests needed for documentation-only acceptance updates. No push authorized.
