# Native input integration decisions

Updated: 2026-09-18

Scope: M-05-F02. The owner approved native actions, a bounded native-only FIFO, explicit permission requesting, status, and doctor. This file separates accepted design decisions from unverified physical behaviour.

| ID | Decision | Basis / limit |
|---|---|---|
| NI-01 | Bind system CoreGraphics through the existing purego dependency; no subprocess per native action. | Approved integration boundary; standalone construction ABI and fake gates passed. |
| NI-02 | Persistent combined-session source and session posting location. | Owner TextEdit comparison delivered `1` only with this pair; no explanation or cross-app claim established. |
| NI-03 | Separate `type_text` from plain `key_press`; initially only Enter is supported as a key. | Text payload and physical-key semantics differ; owner approved both variants and subsequently reported the migrated native numpad working as expected. |
| NI-04 | Native FIFO has 16 waiting slots plus at most one active action; existing execute admission is unchanged. | Architecture review supports bounded ordered admission without a broad async-execution rewrite. Queue-full attempts are recorded explicitly, never retried. |
| NI-05 | Native history is metadata-only, with an action-type discriminator and factual posting states. | Reuse the execution-history projection through a runtime adapter; never include input text, native pointers, raw errors, or claim delivery. |
| NI-06 | Availability and permission are distinct. | Initialization failure is not permission denial; ordinary native failure must leave the D200X runtime functional. |
| NI-07 | Startup, status, and doctor never prompt or post. Only explicit `input.request_permission` invokes the OS request API from the runtime. | Approved permission boundary; the controller process is not the process that posts input. |
| NI-08 | Starting a permission request cancels waiting native actions and rejects new admission until the request finishes. | Architecture safety requirement: approval must not replay physical actions collected during the prompt. |
| NI-09 | Shutdown and permission requests cancel queued and preparing actions; cancellation is checked immediately before posting down. Once down begins, up must follow before source release. | Cancellation is best effort before the final check/down commit boundary: its narrow race can still post a complete pair. A blocked native allocation cannot be interrupted; deferred release retains ownership until it returns. |
| NI-10 | Admitted actions keep their submission snapshot and target the foreground application at posting time. | Existing executable submissions are independent of later reload/profile changes. No foreground-app inspection or app-specific routing is added here. |
| NI-11 | Preserve the 16 KiB frame and 32-summary bounds; history IDs are capped at the producers' 36-byte UUID format, timestamps use existing UTC encoding, and exit code/signal are mutually exclusive. | Adding the discriminator exceeds the old impossible fixture with both maximum exit/signal integers. Bounds must be checked against valid records, not fixed by silent clipping or wall-clock ordering assumptions. |
| NI-12 | Set both plain-text and Enter event flags to zero; do not synthesize modifier releases. | Architecture review found no required keypad, function, or mouse flags for these actions. Event flags do not prove application behaviour while physical modifiers remain held; owner acceptance must include held Cmd/Control. |
| NI-13 | Native initialization remains synchronous; do not claim globally bounded runtime startup/close. | Final architecture review closed correctness blockers but identified an unbounded OS source-creation/preflight call before IPC/device startup. A hung initializer can hold startup serialization and delay Runtime.Close. Ordinary returned failures are isolated; asynchronous initialization with late-result disposal is separate work if a stronger guarantee is required. |

## Public status contract

Backend state is `ready`, `unsupported`, `initialization_failed`, or `closed`. Permission is `granted`, `not_granted`, or `check_failed`; these labels do not distinguish never-requested from user-denied access. Queue depth/capacity, request-in-progress, readiness, and static remediation explain the state without exposing configuration contents or paths.

`CGRequestPostEventAccess` returns a boolean. Calling it is not a promise that a dialog appears, access is granted, or existing settings update without a restart. These behaviours and the identity shown in System Settings require owner acceptance. [Apple request API](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()), [Apple source states](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid).

## Acceptance and evidence limits

- [x] Plain event modifier policy reviewed and frozen.
- [x] Strict config/schema, worker, runtime/history, and IPC/CLI automatic gates; full uncached test/race suites passed on 2026-09-18.
- [x] Independent architecture/verification closure; synchronous initialization risk qualified in NI-13.
- [x] Owner reports migrated native numpad working as expected on 2026-09-18.
- [x] Owner explicitly confirms permission request, input status and doctor functionality on 2026-09-18.
- [x] Deploy numpad migration explicitly approved on 2026-09-18; subsequent owner report confirms expected numpad behaviour, without establishing unreported scenarios.

M-05-F02 is closed on the automatic/architecture gates and owner functional acceptance. Specific cross-app, rapid-ordering, held-modifier, revocation/regrant and shutdown observations were not individually supplied. Do not convert this functional report into invented scenario results or universal delivery guarantees. NI-13 remains an accepted lifecycle limitation.

No agent-run typing, permission prompts, clipboard/application-data reads, or automatic osascript fallback is authorized by this implementation task.
