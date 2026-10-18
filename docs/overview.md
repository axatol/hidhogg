# Hidhogg overview

Status (2026-10-18): V2-V01 passed independent unit and simulated-app acceptance on commit `08a44f8`. The V2-X01 candidate removed the Go implementation and diagnostics; its source audit, Core rerun (206/206), safe app tests (139/139), four ARM64 production builds, and controlled simulated-app smoke passed. The first full Core run reported one assertion failure whose cause remains unconfirmed; focused repeats and a later full run passed. Details and unverified limits are in [v2-plan.md](v2-plan.md). TaskView remains the authority for task status.
Updated: 2026-10-18
Platform: macOS 26+ on Apple Silicon (`arm64`) only. Intel is unsupported in Debug, Test, and Release configurations.

## Goal

Hidhogg is a personal-use macOS 26+ utility for local HID integrations. Version 1 targets one Ulanzi D200X and one configured page. A future adapter may support Lofree Flow Lite key mapping, macros, and lighting; that device is not part of version 1.

Hidhogg is configuration-driven. The Swift runtime watches for external edits and retains the last-known-good state after invalid or conflicting changes. The GUI supports profile management and a typed six-field button editor for label, background, alignment, label size, notification sources, and action.

## Product model

- Physical HID inputs run statically configured local actions.
- The local Swift CLI emits display-only notifications containing a source, text, and optional lifetime.
- Tiles filter notifications by source and retain the newest match until expiry, CLI clearing, or physical selection.
- Selecting a notification dismisses it and runs the tile's statically configured action.
- Configured execute actions use an absolute executable path and argument vector; IPC events cannot submit arbitrary commands.
- Custom assets and shared artwork libraries are deferred.

## Committed v1 architecture (historical)

The owner selected a Go runtime authority with a SwiftUI menu-bar client and Unix-socket CLI API on 2026-08-24:

```text
SwiftUI menu-bar client
           |
      Unix socket
           |
 Go runtime authority
           |
  Device adapters
```

Reconnect reliability is an accepted implementation assumption, while repeated-cycle reliability remains unverified.

For the `M-01` scaffold, the SwiftUI app launches and supervises the Go runtime. Packaging work may later replace this with a separately managed process, but `launchd`, login-item installation, signing, and distribution are outside `M-01`.

The SwiftUI app uses strict, bounded IPC over an owner-only per-generation Unix socket. The supervisor attributes readiness to its launched runtime, drains bounded output tails, permits one restart, and applies deterministic TERM-to-KILL shutdown escalation. Go owns the production D200X runtime, strict TOML schema, discovery, profiles, executable press actions, execution history, transactional reload, local notification overlays, and typed source mutations. Swift owns foreground-app mappings and the profile editor UI. M-09-B lifecycle and M-10-A1 tile-label owner verification passed on 2026-10-01.

## Current Swift architecture

The v2 implementation moves runtime, strict TOML v4 configuration, source editing, D200X handling, profiles, actions, notifications, IPC, and device lifecycle into Swift. It retains the requested user-facing feature set and strict v4 contract while permitting owner-authorized implementation improvements; wholesale byte-level compatibility with v1 is not promised. The accepted I01/U01 implementation is committed as `d714dfefae7c0bae7d1592018ab857b0793c59f1` and `2418f54c6c70782936f72c23e26b8e19f00326fc`. V01 acceptance passed on `08a44f8`; its Core, app, and native simulated-app evidence is summarized in [v2-plan.md](v2-plan.md). The X01 candidate removes the Go runtime, Go CLI, and Go diagnostic wrappers. Historical v1 documents, protocol fixtures, the renderer font, and the listed spike evidence remain. The app process model assumes one app-owned process per private UUID-generation directory; owner-only permissions and identity-guarded cleanup remain, while shared explicit-directory multiprocess operation is unsupported and singleton use is not enforced. The exact v1 roadmap is preserved in [v1-roadmap.md](v1-roadmap.md).

### In-process runtime operations

V2-A01 verification (2026-10-18): 212 Core tests, 125 safe app tests, arm64 production app/CLI builds and a controlled native simulated-device app/CLI smoke passed. Decisions, evidence and the retained fixture-stall qualification are in [runtime simplification](runtime-simplification.md).

The app process owns the Core runtime session. App profile, display, and editor operations call a captured typed `RuntimeOperationsHandle` directly; the configuration watcher and optional CLI `IPCServiceBinding` share that session’s `RuntimeOperations` actor. The Swift CLI remains an external socket client. If CLI endpoint startup fails, the runtime and app can remain ready while the app reports a command-line connectivity warning; cleanup of partially started endpoint resources can remain uncertain. On retirement, the operations actor rejects new work, cancels work not yet admitted by the coordinator, and drains admitted work before the server and device coordinator stop. Configuration edits preserve distinct file-commit and runtime-reload outcomes. The app-only socket client and wire protocol implementation were removed; shared profile and UUID validation remains in `ProfileValidation.swift`. See [runtime simplification](runtime-simplification.md) for decisions and verification gates.

## Current use

Build the Swift CLI with `swift build --package-path macos/HidhoggCore --product hidhoggctl`. Each command takes `--runtime-dir <current-app-generation-directory>` before the command:

```sh
hidhoggctl --runtime-dir <runtime-dir> status
hidhoggctl --runtime-dir <runtime-dir> profiles list
hidhoggctl --runtime-dir <runtime-dir> notifications emit --source <id> --text <text> [--ttl-seconds N]
hidhoggctl --runtime-dir <runtime-dir> notifications clear <uuid>
```

Replace placeholders with real values; the directory must identify the running app's current private generation. The MVP assumes one app-owned process and does not enforce singleton use or support shared-directory multiprocess operation.

The controlled V01 gate reopened Settings with `open -a /absolute/path/to/the/temporary/Hidhogg.app`. It passed the exact temporary bundle path to avoid LaunchServices selecting another Hidhogg instance. This verified reopening an already running app, not isolated cold-launch behavior.

The first v2 configuration foundation is the standalone, dependency-free SwiftPM library at `macos/HidhoggCore`, targeting macOS 26. It strictly decodes schema v4 into immutable normalized profiles and the deterministic 14-position layout. Its vendored strict TOML engine is extended locally for TOML 1.1; the decoder preserves explicit-field presence during validation and reports safe diagnostics with complete field paths. Syntax/type and unknown-key locations use UTF-8 byte columns; semantic, missing-key, and schema-version diagnostics use `0:0`. The independent C01 unit suite passed 30/30, and the pinned current-source TOML 1.1 corpus passed with no failures or skips; detailed counts and provenance are in [v2-plan.md](v2-plan.md).

V2-C02 adds typed `keep`/`set`/`reset` position edits, profile label/clone/delete operations, and a transactional source store to the same package. Edits use the existing strict TOML engine and preserve untouched source bytes. The store uses exact-byte digests and same-directory atomic replacement, and distinguishes unchanged, committed, and uncertain file outcomes from the runtime reload result. Its independent package suite passed 59/59 tests and the refreshed TOML 1.1 corpus passed 681/681 cases; C02 is committed as `57f93a14451a3cb18b73e0dcb8d0654323649f51`. At that checkpoint the package was separate from app/CLI wiring; accepted I01/U01 now provide Swift IPC/CLI wiring and app composition.

V2-D01 adds an internal D200X codec, report assembler/input decoder, deterministic classic-ZIP page archive, and CoreText/Core Graphics/Image I/O renderer to the same package. Its typed outbound batches describe startup, redraw, brightness, and keepalive order; V2-D02 owns transport and session serialization. The renderer draws on a 16-bit premultiplied Core Graphics/CoreText working surface, then converts to 8-bit straight RGBA PNG; zero-alpha RGB is normalized to transparent black. Local synthetic checks cover exact uniform background channels at alpha 0, 1, 2, 127, 128, 254, and 255, plus an upright L glyph in separate centered and bottom-aligned regions. CoreText fallback and shaping identity are not asserted equal to Go. On 2026-10-02, the isolated C01+D01 synthetic package suite passed 47/47 tests, and the combined package on the committed C02 base passed 76/76. Independent D01 verification also passed: the frozen 11-path overlay matched its hashes, the full suite passed 76/76, the export-adapter suite passed 77/77, and the external checker validated 18 deterministic ZIP archives/56 members, 8 exact PNG8 RGBA backgrounds, labeled alpha-zero normalization, and 14,598 upload bytes reconstructed from 15 reports. The centered L bounds were `(216, 76)-(244, 121)` and bottom bounds `(216, 131)-(244, 176)`. Evidence is under `/Volumes/Data/tmp/hidhogg-v2-d01-verification/`, including `independent-zip-png-final.log` and `D01-SHA256SUMS`. CoreText fallback identity and Go-versus-Swift compression byte parity are not asserted; this gate does not establish app, runtime, simulator, native transport, or hardware integration. See [`D200XPageRenderer.swift`](../macos/HidhoggCore/Sources/HidhoggCore/D200XPageRenderer.swift), [`D200XProtocol.swift`](../macos/HidhoggCore/Sources/HidhoggCore/D200XProtocol.swift), and the qualification in [v2-plan.md](v2-plan.md).

V2-D02 adds native D200X selection/session and a protocol-faithful simulated backend to HidhoggCore. The factory selects simulation or native mode before backend construction, so simulation does not create native discovery. Complete typed report batches share one serial writer. The native backend copies and delivers input independently on a dedicated CFRunLoop; simulated input stays in the simulator backend and does not use that loop. Stop is nonblocking, and awaited teardown returns a typed `closed` or `cleanupUncertain` outcome after callback cleanup. The independent D02 gate passed 96/96 Swift package tests on the D01 base plus the exact 11-path D02 overlay; evidence and hashes are under `/Volumes/Data/tmp/hidhogg-v2-d02-verification/`. That gate did not invoke native discovery or device I/O. The later controlled U01 candidate gate exercised simulated app readiness and graceful quit; it did not use physical hardware.

V2-R01 adds a standalone profile, reload, idle, and host-display coordinator to HidhoggCore. It serializes operations across awaited session writes and publishes profile/catalog state only after required device writes succeed. Invalid reloads retain the last-known-good state; reload compares rendered archive bytes so metadata-only changes update the catalog without a HID write. Committed source edits continue through reload after caller cancellation. Input receipts are stamped before actor enqueue, the 64-event mailbox fail-stops once on overflow, and the matching release of an already-dimmed wake gesture is consumed. The absolute 50-second keepalive continues while the host display is off and skips missed intervals using the post-write monotonic time, avoiding catch-up bursts. On 2026-10-02, the independent D02-base package gate passed 125/125 tests with zero failures; its seven-path overlay hashes matched before and after testing. The gate used synthetic/fake session seams and did not open live HID, inject native input, launch the owner app, or run native app simulation. The full log is `/Volumes/Data/tmp/hidhogg-v2-r01-closure-20261002/R01-full-suite-escalated.log`.

The editor covers button appearance, actions, and notification sources. Custom assets, the proposed Go log tail, and split profile files remain deferred. V01 used synthetic configuration and a simulated D200X; it did not use a real device, selected configuration, the existing owner app, or native input injection. TaskView remains the status authority for task states.

In the committed v1 baseline, every Xcode-built app embeds the Go runtime as `Contents/MacOS/hidhogg-runtime`; it does not search `PATH` or depend on `/usr/local/bin`. That baseline's application delegate starts the runtime eagerly and coordinates asynchronous cleanup before normal termination. Accepted U01 removes the Go-child launch phase and composes the Swift runtime instead.

Device adapters expose capabilities rather than assuming every HID has displays. The D200X adapter exposes inputs, displays, and brightness. A future Flow Lite adapter would expose inputs, lighting, and on-device key mapping.

## Configuration direction (historical v1 planning)

The material below records v1 implementation and research. The current product uses the Swift schema-v4 configuration and app-owned runtime described above; historical Go commands and paths are not current operating instructions.

TOML passed the bounded `S-02` fixture suite and was selected by the owner on 2026-08-24. Required GUI edits must preserve untouched comments, whitespace, ordering, and unknown fields byte-for-byte. The tested JSONC/HuJSON fallback did not satisfy that preservation contract. No public configuration schema has been declared.

```text
~/.config/hidhogg/
├── config.toml
├── assets/
└── devices/
    └── desk-deck.toml
```

The root file owns application settings and shared library metadata. Each device file owns its adapter selection, settings, one-page layout, notification filters, and stable library references.

`M-02` introduced a milestone-private, versioned single-file schema to prove the Go runtime's first physical vertical slice. Its original format required all 14 D200X display positions and rejected unknown fields. This does not replace the planned root/device configuration model; migration to that broader model remains explicit future work.

`M-10-F01` implements compact schema v4: keyed profiles and coordinates, omitted blank tiles, strict explicit values, and a complete deterministic runtime layout. Existing selected files are preserved and require explicit conversion; earlier schema versions are deliberately rejected. Offline Go/Swift gates and independent review pass; owner physical acceptance remains pending. See [the contract and migration guide](compact-config-v4.md).

The retired Go v1 reference runtime loaded strict TOML, owned D200X display/input/brightness policy, exposed profiles and bounded executable-action history, and transactionally reloaded external edits through an immutable effective snapshot. A private lossless adapter and exact-digest store supported typed profile label/clone/delete edits; the v1 SwiftUI editor invoked those operations without owning TOML writes. Opt-in verbose diagnostics recorded decoded input events and outbound D200X packets, but never raw HID paths, serial numbers, or unrelated device identities.

`M-03` adds direct-Go discovery through one caller-owned, owner-only runtime directory. A persistent advisory lock coordinates cooperating runtimes; strict generation metadata becomes visible only after IPC binding, device initialization, and serving readiness. The controller revalidates directory, lock, metadata, socket, peer UID, and generation attribution around each discovered call. Explicit socket and instance arguments mode remains temporarily available for Swift supervision and deterministic tests.

`M-04` adds named profiles and atomic full-page activation. `M-05` adds press-only built-in profile activation and bounded asynchronous executable actions with immutable submission data and read-only execution history. `M-06` adds manual and automatic transactional reload: the runtime prepares a complete immutable candidate, serializes required writes with profile activation, applies brightness and idle settings through the existing policy owner, and publishes one atomic effective revision only after success. The watcher observes the explicit file's parent directory so direct and atomic-save edits are supported; invalid pre-write candidates retain the last-known-good runtime state.

`M-05-F01` originally introduced schema v3; its source layout is superseded by M-10-F01's [compact v4 format](compact-config-v4.md). Action `gesture = "press"` executes once on initial down and ignores release; `gesture = "release"` requires a matching prior down with an unchanged binding and is the default when omitted. Duplicate downs do not retrigger. Profile/reload transitions cancel pending actions while held-key state prevents accidental rearming; idle-wake gestures remain consumed. Earlier configuration versions are rejected rather than translated.

`M-05-F02` adds native `type_text` and Enter-only `key_press` actions through purego/CoreGraphics, with 16 waiting slots plus one active action. The native FIFO does not change executable admission. Runtime-owned permission checking/requesting, `input.status`, and read-only `doctor` use IPC; startup/status/doctor never prompt or post test input. History is metadata-only and distinguishes posting from verified delivery. The owner approved deploy migration and confirmed numpad and permission/status/doctor functionality on 2026-09-18; automatic and architecture gates pass. Scenario-specific observations and lifecycle limits are qualified in `native-input-decisions.md`; owner commands are in `native-input-runbook.md`.

`M-07` implements local `notifications.emit/clear` and discovery-aware CLI commands. Optional schema-v3 `notification_sources` select active-profile tiles; bounded text overrides their labels until replacement, optional TTL expiry, clearing or tile-local physical selection. The existing coordinator composes full-page updates over an immutable configured baseline. Changed profile/configuration transitions clear overlays; unchanged/rejected reloads preserve them. Selection authorizes only static configured actions after successful dismissal. As of 2026-09-19 implementation, independent whole-tree automatic, final architecture, and owner physical gates pass. Dimmed emission did not wake or brighten the owned D200X; manual wake retained the overlay and the next selection dismissed only its tile. See `m07-notification-plan.md` and `m07-notification-runbook.md` for limits and verification.

`M-02-F01` adds bounded owner-run diagnostics and an isolated one-frame `d200xprobe` research CLI. These surfaces measured brightness-zero input, firmware-screensaver wake packets, and captured small-window modes without broadening the experimental outbound-command surface. The selected production policy uses a fixed 50-second `0x0002` keepalive and an optional `idle_timeout_seconds` setting that defaults to 300; zero disables application dimming without disabling keepalive. On idle the runtime sets brightness to zero, then restores configured brightness and consumes the first complete known physical gesture. Automatic and bounded owner-present physical gates passed on 2026-09-03.

`M-02-F04` adds a Swift-app-only host display-power observer. Documented macOS screen sleep/wake notifications and an initial Core Graphics state query feed a generation-bound `display.host_state.set` request to Go. The Go idle-policy owner darkens on display sleep, suppresses dark-state actions, and restores the latest effective profile, notification overlay, configured brightness, and input stream on wake. A pending host-off request is serialized against reload brightness writes; a write already in flight cannot be preempted. The fixed keepalive continues. The owner must set top-level `idle_timeout_seconds = 0` in the selected TOML to disable Hidhogg's separate application dimmer. Direct Go-only launches retain the prior policy. Offline Go and Swift tests pass; physical display sleep/wake remains unverified. This follows display power, not Lock Screen alone. See [owner verification](m02-f04-host-display-runbook.md).

## Evidence policy

`UlanziDeckControl` is reference evidence only. Protocol facts may be independently reimplemented with provenance, but its product model and unverified hardware conclusions are not inherited. Automated tests, one-device observations, upstream claims, and hypotheses must be reported separately.

## Sources

- [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- [Apple NSWorkspace screen sleep notification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification)
- [Apple NSWorkspace screen wake notification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification)
- [Apple Core Graphics display sleep query](https://developer.apple.com/documentation/coregraphics/cgdisplayisasleep%28_%3A%29)
- [Apple Core Graphics alpha information](https://developer.apple.com/documentation/coregraphics/cgimagealphainfo)
- [Apple Image I/O image destinations](https://developer.apple.com/documentation/imageio/cgimagedestination)
- [go-ctap/hid](https://pkg.go.dev/github.com/go-ctap/hid)
- [go-toml](https://github.com/pelletier/go-toml)
- [Microsoft JSONC parser](https://github.com/microsoft/node-jsonc-parser)
- [Tailscale HuJSON](https://github.com/tailscale/hujson)
- [Feasibility evidence](research.md)


## Verified R02 runtime services — 2026-10-03

R02 adds bounded configured executable execution and native-input queues/history, immutable captured actions, and source-filtered notification overlays. Notification lifetimes begin after successful display commit; expiry catches newly overdue entries after slow writes. Selection revalidates captured bindings and dismisses overlays before static action admission. Owned shutdown awaits action services and the device session and preserves cleanup uncertainty. The coordinator supplies monotonic-to-wall date conversion and coherent reload views with actual display-update outcomes for IPC.

Independent verification used committed R01 `b2d3c628bedaecb5e80dc0bbd784806b64cc86e0` plus exactly thirteen frozen R02 paths: 160 XCTest cases passed, zero failures or skips, and all live/snapshot hashes matched before and after testing. Evidence: `/Volumes/Data/tmp/hidhogg-v2-r02-independent-final-20261003/final-report.txt`; overlay manifest SHA-256 `df8acfbf9b1fbaf4e5bad6da09e4a4629f10539c9fce0ecc306fee9a0835dbcb`. This gate used fake process/input adapters and synthetic rendering; actual child execution, sockets, native HID/input, permission prompts and app simulation were not exercised. At this 2026-10-03 checkpoint, app/CLI acceptance and the native simulated-app gate remained outstanding; the later accepted I01/U01 checkpoint is below.

Implementation: `macos/HidhoggCore/Sources/HidhoggCore/RuntimeActionServices.swift`, `RuntimeExecution.swift`, `RuntimePosixProcessRunner.swift`, `RuntimeNativeInput.swift`, `RuntimeNotifications.swift`, and the existing coordinator/models. Focused tests reside in `macos/HidhoggCore/Tests/HidhoggCoreTests/`.
