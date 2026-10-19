# Hidhogg scaffold protocol v1

Status: internal scaffold contract
Frozen: 2026-09-06

This protocol is an internal scaffold contract for the Go/Swift boundary and profile-control clients. It is not a public compatibility promise.

## Transport and framing

- Transport is a local Unix `SOCK_STREAM` socket.
- A connection carries exactly one request and one response.
- Each frame is one UTF-8 JSON object followed by LF (`0x0a`).
- A frame is at most 16,384 bytes including LF.
- The client must not reuse a connection. The server closes after its response.
- A raw LF cannot occur inside a JSON string; embedded newlines use JSON escaping.
- Invalid UTF-8 and missing LF are invalid. If LF is absent when the request-read deadline expires, the server closes without a response because no complete frame exists. The first LF terminates the request; the server does not wait for client EOF. It processes only the first record, discards later bytes, writes one response, and closes. JSON whitespace between the closing object delimiter and LF is permitted.
- Connect, complete write, server request-read, and server response-write phases each have a one-second deadline. Notification clients use a seven-second default read allowance; an explicitly configured read deadline or tighter caller context deadline still wins. Other client methods retain the one-second read allowance.
- The server handles at most eight accepted connections concurrently. It accepts and immediately closes an excess connection without reading or writing protocol bytes.

Production deadlines are fixed. Tests may inject a policy with longer deadlines without changing the contract.

## Request

```json
{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"health","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}
```

All fields are required. No other fields are permitted.

| Field | Rule |
|---|---|
| `protocol_version` | JSON integer exactly `1`; `1.0` is invalid |
| `request_id` | canonical lowercase hyphenated UUID |
| `method` | case-sensitive `health`, `status`, `profiles.list`, `profiles.activate`, `executions.list`, `executions.get`, `config.reload`, `config.status`, `display.host_state.set`, `input.status`, `input.request_permission`, `notifications.emit`, `notifications.clear`, or `doctor` |
| `params` | object containing `instance_id`; `profiles.activate` additionally requires `profile_id`; `display.host_state.set` additionally requires boolean `display_awake`; `executions.list` optionally accepts integer `limit` (1 through 32, default 20); `executions.get` requires non-empty exact `execution_id`; `notifications.emit` additionally requires `source` and `text` and optionally accepts integer `ttl_seconds` (1 through 86400); `notifications.clear` additionally requires `notification_id` |
| `params.instance_id` | canonical lowercase UUID matching the launched generation |
| `params.profile_id` | non-empty case-sensitive profile identifier; no case normalization is performed |

Unknown fields, duplicate keys at any object depth, missing fields, `null`, and wrong JSON types are rejected. UUID version is not restricted, but canonical syntax and lowercase encoding are required.

## Response

Success:

```json
{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","state":"ready"},"error":null}
```

Failure:

```json
{"protocol_version":1,"request_id":null,"result":null,"error":{"code":"invalid_json","message":"request is not valid JSON"}}
```

Exactly one of `result` and `error` is non-null. A safely decoded and valid request ID is echoed even when another field fails; otherwise `request_id` is null. Error messages are static, never contain request bytes, and are at most 256 UTF-8 bytes.

`health` returns `instance_id` and `state`. `status` additionally returns `protocol_version`. These two result shapes are unchanged by the profile methods. The scaffold state is `ready`; process identifiers, device state, configuration, layouts, actions, and logs are not exposed.

`profiles.list` returns a result containing the requested `instance_id` and `profiles`, an array in normalized catalog order: the configured default first, then remaining profile IDs lexicographically. Each summary contains exactly `id`, `label`, `is_default`, and `is_current`:

```json
{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","profiles":[{"id":"default","label":"Default","is_default":true,"is_current":true}]},"error":null}
```

`profiles.activate` returns a result containing exactly `profile_id` and `changed`. A request for the current profile succeeds with `changed:false`; a successful transition reports `changed:true` only after the runtime commits the complete page write:

```json
{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"profile_id":"work","changed":true},"error":null}
```

`display.host_state.set` carries the app-observed macOS display power state. Its result contains exactly `instance_id`, `display_awake`, and `changed`. Repeating the committed state is an idempotent success with `changed:false`. The generation-specific `instance_id` prevents a request for a replaced runtime from being accepted by the newer generation.

```json
{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"display.host_state.set","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","display_awake":false}}
```

```json
{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","display_awake":false,"changed":true},"error":null}
```

`notifications.emit` and `notifications.clear` preserve the nested `params` envelope. Emission source matching is case-sensitive and uses the configured source identifier without normalization. Text is nonblank, single-line UTF-8 of at most 64 runes and 256 bytes. An omitted `ttl_seconds` leaves the overlay until replacement, clearing, selection, or a profile/reload transition; a supplied value starts at successful commit and expires after the requested number of seconds.

```json
{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"notifications.emit","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","source":"alerts.v2","text":"Hello","ttl_seconds":30}}
```

The emit result contains exactly `instance_id`, `notification_id`, and `matched_count`. The clear request contains exactly `instance_id` and `notification_id`, and its result contains exactly `instance_id` and `cleared_count`:

```json
{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","notification_id":"22222222-2222-4222-8222-222222222222","matched_count":0},"error":null}
```

Counts are explicit integers from 0 through 14, including zero. A source with no matching tile succeeds without storage or a device write. Notification text is never echoed in a result, error, execution record, or routine diagnostic. A client timeout or disconnect leaves the outcome unknown: clients must not retry automatically because a write may have committed without its reply.

Configuration accepts at most 31 profiles. The encoder checks the complete LF-terminated response frame, including the newline; a 31-summary worst-case response is 15,880 bytes and fits the 16,384-byte bound. A corresponding 32-summary boundary fixture is exactly 16,387 bytes and is rejected before transmission.

`executions.list` is read-only and returns a result containing exactly `instance_id` and `executions`. The array merges both workers, sorts by descending submission time and ascending ID on ties, and is bounded by the requested limit (maximum 32). Each summary contains only `action_type`, `execution_id`, `profile_id`, `position_id`, `state`, `submitted_at`, `started_at`, `finished_at`, `duration_ns`, `exit_code`, `signal`, and `supervision_error`. `action_type` is `execute`, `type_text`, or `key_press`; it never includes an action payload. Execution IDs are stable ASCII identifiers of at most 36 bytes. Encoded timestamps are UTC RFC3339Nano strings or `null`; decoders also accept RFC3339Nano offsets. `duration_ns` is non-negative. Exit code and signal are mutually exclusive integers or `null`. Native records have neither, no output, and no supervision error. No executable path, command, argument, environment, working directory, text, or configured key is present in a summary.

The required `action_type` field and 36-byte execution-ID bound strengthen the strict history contract. Older strict history clients must update; health, status, and profile result shapes remain unchanged.

Command states remain `running`, `exited`, `signaled`, `timed_out`, `canceled`, `start_failed`, and `rejected_busy`. Native states are `queued`, `running`, `posted`, `permission_denied`, `failed`, `canceled`, `rejected_queue_full`, and `rejected_busy`. Queued native records have no start or finish; running records have a start but no finish; all native terminal records have a finish. Rejections have no start and zero duration. Wall-clock ordering and equality with duration are not required because system time can adjust independently of monotonic duration measurement.

`input.status`, `input.request_permission`, and `doctor` accept only `instance_id` in `params`. The first two return exactly `instance_id` and `input`. Input contains `backend_state` (`ready`, `unsupported`, `initialization_failed`, `closed`), `permission` (`granted`, `not_granted`, `check_failed`), `ready`, integer `queue_depth` and `queue_capacity` (bounded by 16), `request_in_progress`, and bounded static remediation `detail`. Only explicit `input.request_permission` can invoke the runtime-process permission request. Status and doctor do not prompt or post input.

`doctor` returns exactly `instance_id` and `doctor`. Doctor contains `input` and four ordered `checks`: `runtime`, `config`, `device`, `input`. Each check has exactly `name`, `state` (`ready`, `attention`, `closed`), and static actionable `detail`. Configuration contents, paths, environment, and application data are not exposed.

A client timeout or disconnect does not cancel an OS permission request that has already started. Do not automatically retry a timed-out permission request; inspect `input.status` and complete the system permission UI explicitly.

`executions.get` is read-only and returns a result containing exactly `instance_id` and `execution`. The record has the summary fields plus `stdout`, `stdout_total_bytes`, `stdout_truncated`, `stderr`, `stderr_total_bytes`, and `stderr_truncated`. `stdout` and `stderr` are canonical standard base64 strings containing the bounded output tails. Total-byte counters include discarded bytes and are never smaller than the decoded tail length. The record contains no executable path, command, argument, environment, working directory, or trigger controls. Valid list and get responses, including their LF terminator, remain below 16,384 bytes under the execution worker's 32-entry and 4,096-byte tail bounds.

Stable error codes:

| Code | Meaning |
|---|---|
| `invalid_json` | invalid UTF-8 or JSON syntax |
| `invalid_envelope` | fields, structural types, duplicates, or identifier syntax are invalid |
| `invalid_notification` | notification parameters or service admission are invalid |
| `unsupported_version` | `protocol_version` is not integer `1` |
| `unknown_method` | method is not in the protocol method allowlist |
| `instance_mismatch` | request instance does not match the runtime generation |
| `message_too_large` | frame exceeds 16,384 bytes including LF |
| `profile_not_found` | requested profile ID is not configured |
| `activation_failed` | profile activation failed before a device write was classified as uncertain |
| `device_write_failed` | a profile page write failed or left device state uncertain |
| `shutting_down` | the runtime is stopping or no longer accepts activation work |
| `busy` | bounded activation work is unavailable before the request deadline |
| `execution_not_found` | the exact requested execution ID is not retained in generation-local history |
| `history_unavailable` | the execution history adapter is unavailable or failed a read-only query |
| `internal` | bounded unexpected server failure |

Validation precedence is normative:

1. frame size;
2. LF framing and read deadline;
3. UTF-8 and JSON syntax;
4. duplicate keys at any object depth;
5. top-level object, exact field set, canonical request ID, and structural field types except `protocol_version`;
6. protocol version;
7. method allowlist;
8. exact params shape, canonical instance ID, and profile ID presence;
9. instance match; and
10. handler/internal failure.

The request ID is echoed only after duplicate-key validation and canonical request-ID validation succeed. It is null for all earlier failures and for any duplicate key, including a duplicate unrelated field.

Clients reject any response schema deviation. Every response has exactly four required top-level fields with no duplicates or extras: integer `protocol_version` equal to `1`, canonical `request_id` or null as allowed by the failure, and exactly one non-null value among `result` and `error`. A `health`, `status`, `profiles.list`, or execution-history result uses the requested instance ID; health/status state is exactly `ready`, profiles.list contains only the ordered summaries besides that ID, execution results contain only their documented bounded history fields, and a `profiles.activate` result has only `profile_id` and `changed`. An error object has exactly string fields `code` and `message`; the code is from the stable allowlist and the message is at most 256 UTF-8 bytes.

## Endpoint lifecycle and security

1. On macOS, the production supervisor uses the literal, non-resolved root `/private/tmp`. Before creation it requires by `lstat` that the root is a real UID-0 directory with mode exactly `01777`. It constructs `hidhogg-<decimal-effective-uid>-<canonical-lowercase-random-UUID>`, validates the complete `<root>/<generation>/runtime.sock` encoded byte length including NUL, and atomically creates the generation directory with `mkdir(0700)`. Creation fails on collision and never adopts or deletes an existing path. Tests may inject another root; production does not use `TMPDIR` or Foundation's temporary-directory URL.
2. The endpoint is `<generation-directory>/runtime.sock`. Its encoded path, including the terminating NUL, must fit the 104-byte Darwin `sun_path` field before launch.
3. Swift passes the exact endpoint with `--socket-path`; the runtime never searches for an endpoint. `hidhoggctl` supports the same legacy `--socket-path` plus `--instance-id` mode and a discovery `--runtime-dir` mode that reads the published generation metadata.
4. Before binding, the runtime uses `lstat` to require that the generation directory is a real directory, owned by its effective UID, with mode exactly `0700`. If any endpoint entry exists, including a symlink, file, or socket, startup fails without deletion.
5. After bind and before readiness, the runtime applies mode `0600` and starts listening.
6. Immediately after accept/connect and before protocol bytes, both peers must verify the other's effective UID equals their own. Failure closes silently. Clients also validate the generation directory as above and use `lstat` to require a non-symlink socket owned by their effective UID. Failure to obtain Darwin peer credentials is fatal for this macOS-only scaffold.
7. The runtime records the socket identity it bound. The supervisor records the first valid socket identity observed for a generation and never replaces it; later identity drift is a security failure that terminates the child and prevents readiness.
8. Runtime and supervisor cleanup is best-effort and identity-guarded. Immediately before unlinking, the cleaner requires the recorded generation-directory and socket device/inode identities, types, owners, and modes still match. Any mismatch leaves the endpoint and directory untouched. Before any socket identity was recorded, the supervisor removes only an already-empty matching generation directory. Cleanup never recursively deletes.
9. Every restart uses a new directory and endpoint. Multiple app instances therefore coexist.

No component probes and unlinks a supposedly stale endpoint. The final pathname unlink is not an atomic compare-and-unlink operation on macOS; a malicious process with the same effective UID can substitute the name between validation and unlink. This scaffold trusts same-effective-UID processes. The owner-only directory, unpredictable generation name, peer credentials, and instance attribution exclude other users and prevent accidental or stale cleanup, but are not a sandbox against code already running as the owner. Normal exit, forced exit after readiness, exit before readiness, observable substitution, and unexpected-entry behavior are tested.

## Instance attribution and readiness

The supervisor creates a canonical lowercase UUID `instance_id` for each generation and passes it with `--instance-id`. Every request contains it. It attributes readiness only after all of these hold:

1. the child remains alive;
2. the endpoint accepts a connection;
3. a v1 health response is valid;
4. request and instance IDs match; and
5. state is `ready`.

The supervisor polls every 100 ms for at most five seconds. Socket existence and process survival alone do not establish readiness. The instance ID prevents generation confusion; it is not a secret or authentication credential.

## Supervision

Lifecycle states are `idle`, `starting`, `ready`, `stopping`, `stopped`, and terminal `failed(reason)`.

- One unexpected exit or readiness failure permits one automatic restart after 500 ms.
- The restart budget does not reset until the app is relaunched.
- User quit cancels a pending restart.
- Shutdown sends `SIGTERM`, waits two seconds, sends `SIGKILL` if the child remains alive, then waits one second.
- Stdout and stderr are drained concurrently from launch into separate 65,536-byte tail buffers.
- UI failure categories are bounded and may contain exit status or signal, but never raw process output.

## Dependency direction

```text
SwiftUI client ───────────────► protocol spec and fixtures

cmd/hidhogg ─► internal/ipc server ─► runtime status query
cmd/hidhoggctl ───────────────► internal/ipc client
```

Interfaces are declared at their consumer. No production package imports spike modules. The protocol package does not link HID, TOML editing, action, notification, or D200X production dependencies.

## Shared fixtures

Schema-v4 source keys identify profiles and physical positions. Runtime editor/notification/history position IDs are canonical D200X coordinates such as `0_0`; the wire envelope remains protocol v1. `config.editor.position_label.set` and position-label reads allow an explicit empty `label` string. Missing `label`, wrong types, and invalid nonempty labels remain invalid; profile labels still require visible text. Encoders must include `"label":""` when clearing a tile rather than omitting the field.

Editor position read/set requests and read responses require a supported coordinate as `position_id`. Position-list entries require `position_id == position`; arbitrary stable IDs, mismatched pairs and unsupported coordinates are rejected. Profile IDs remain case-sensitive stable keys rather than coordinates.

[`cases.json`](cases.json) is the authoritative fixture manifest. Static cases reference shared request and response bytes. Generated cases define their base bytes or mutation, direction, and expected semantic behavior. Go and Swift tests consume the same manifest. Live response key order is not significant; fixture comparison is semantic except where a case explicitly tests framing bytes.
