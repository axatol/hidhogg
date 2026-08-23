# M-01 decision review register

Updated: 2026-08-24

This file collects consequential `M-01` decisions for later owner review. Work continues under the owner's authorization; changing a decision later may require migration or rework.

| ID | Status | Decision | Basis | Rejected alternatives | Residual uncertainty |
|---|---|---|---|---|---|
| M01-D01 | Accepted for implementation | Use one UTF-8 JSON request and response per Unix stream connection, each terminated by LF; the server closes after its response. | Architect consensus: explicit framing and bounded connection state suit health/status traffic. | Persistent NDJSON; EOF-delimited request; binary length prefix. | None material. |
| M01-D02 | Accepted for implementation | Protocol v1 uses strict envelopes, canonical lowercase UUID request/instance IDs, stable error codes, rejected unknown/duplicate fields, and shared byte fixtures. | Cross-language determinism; avoids repeating the spike's self-comparison defect. | Permissive decoding; numeric IDs; language-specific fixtures. | Duplicate-key validation requires deliberate parsers in both languages. |
| M01-D03 | Accepted for implementation | Frames are at most 16,384 bytes including LF; phase deadlines are one second; at most eight connections are handled concurrently. | Bounded resources with ample capacity for scaffold messages. | Default scanner limits; unlimited goroutines; configuration knobs. | Test policies may inject longer deadlines on loaded systems without changing production defaults. |
| M01-D04 | Accepted for implementation | Swift creates a new 0700 temporary directory and socket path for every process generation. The runtime refuses any pre-existing entry, binds, applies 0600, and removes only the inode it bound if identity still matches. | Eliminates stale/live ambiguity and permits multiple app instances. | Fixed socket path; stale probing and unlinking; PID-derived paths. | Cleanup identity implementation must be verified under replacement races. |
| M01-D05 | Accepted for implementation | Both sides verify effective peer ownership where supported; directory and socket ownership/modes remain mandatory. | Apple documents `getpeereid` as reliable for connected Unix stream peers; the installed SDK and Swift expose it. Go can use Darwin `LOCAL_PEERCRED` through `x/sys/unix`. | File modes alone; unauthenticated endpoint discovery. | Go and Swift wrappers require local tests; this is peer identity, not application authentication. |
| M01-D06 | Accepted for implementation | Swift passes an injected socket path and per-generation UUID instance ID. Ready requires a matching health response, not socket existence or process survival. | Attributes readiness to the launched process without secret storage. | PID matching; environment token; socket-exists readiness. | Instance ID is an attribution nonce, not a credential. |
| M01-D07 | Accepted for implementation | Supervision allows one restart after 500 ms per app launch. Shutdown sends SIGTERM, waits two seconds, sends SIGKILL if needed, then waits one second. Stdout/stderr are drained concurrently into separate 64 KiB tails. | Deterministic tests; prevents restart storms and pipe deadlock. | Unlimited/exponential retries; IPC shutdown command; unbounded or merged output. | Installed Swift `Process` termination and pipe ordering need integration tests. |
| M01-D08 | Accepted for implementation | `M-01` creates only exercised runtime/IPC/command boundaries and shared protocol artifacts. No action, notification, D200X, HID, or TOML implementation package is created. | Independent review found speculative packages contradicted scaffold exclusions. | Mirroring the future domain tree; copying spike code. | Consumer-owned config/device ports may be added only if an exercised fake requires them. |
| M01-D09 | Accepted for implementation | Go language baseline is 1.26; local verification uses Go 1.26.4. Swift verification uses Swift 6.3.3 and Xcode 26.6. | Installed toolchain facts recorded on 2026-08-24. | Claiming an unrun Go 1.27 gate. | Go 1.27 verification is optional and must be reported as not run unless an explicit toolchain is obtained. |

## Primary sources

- Apple, [`getpeereid(3)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getpeereid.3.html): effective credentials for connected Unix-domain stream peers.
- Apple, [`Process`](https://developer.apple.com/documentation/foundation/process): child launch, monitoring, standard streams, termination, and sandbox inheritance.
- Apple, [`Pipe`](https://developer.apple.com/documentation/foundation/pipe): bounded operating-system pipes require active draining to avoid blocking writers.
- Apple, [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra): persistent SwiftUI menu-bar scene.
- Go, [release history](https://go.dev/doc/devel/release): upstream release and support history.

## Local verification facts

- `/usr/include/sys/un.h` in the Xcode 26.6 macOS SDK declares `sun_path[104]`; the complete encoded path must fit with its terminator.
- Swift 6.3.3 imports Darwin `getpeereid` and reports `sockaddr_un` size 106 with a 104-byte path field.
- `golang.org/x/sys/unix` documents `GetsockoptXucred(fd, SOL_LOCAL, LOCAL_PEERCRED)` on Darwin.
