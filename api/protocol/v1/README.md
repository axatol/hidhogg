# Hidhogg scaffold protocol v1

Status: internal scaffold contract
Frozen: 2026-08-24

This protocol exists only to verify the `M-01` Go/Swift boundary. It is not a public compatibility promise.

## Transport and framing

- Transport is a local Unix `SOCK_STREAM` socket.
- A connection carries exactly one request and one response.
- Each frame is one UTF-8 JSON object followed by LF (`0x0a`).
- A frame is at most 16,384 bytes including LF.
- The client must not reuse a connection. The server closes after its response.
- A raw LF cannot occur inside a JSON string; embedded newlines use JSON escaping.
- Invalid UTF-8 and missing LF are invalid. If LF is absent when the request-read deadline expires, the server closes without a response because no complete frame exists. The first LF terminates the request; the server does not wait for client EOF. It processes only the first record, discards later bytes, writes one response, and closes. JSON whitespace between the closing object delimiter and LF is permitted.
- Connect, complete write, complete read, server request-read, and server response-write phases each have a one-second deadline.
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
| `method` | case-sensitive `health` or `status` |
| `params` | object containing only `instance_id` |
| `params.instance_id` | canonical lowercase UUID matching the launched generation |

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

`health` returns `instance_id` and `state`. `status` additionally returns `protocol_version`. The scaffold state is `ready`; process identifiers, device state, configuration, and logs are not exposed.

Stable error codes:

| Code | Meaning |
|---|---|
| `invalid_json` | invalid UTF-8 or JSON syntax |
| `invalid_envelope` | fields, structural types, duplicates, or identifier syntax are invalid |
| `unsupported_version` | `protocol_version` is not integer `1` |
| `unknown_method` | method is not `health` or `status` |
| `instance_mismatch` | request instance does not match the runtime generation |
| `message_too_large` | frame exceeds 16,384 bytes including LF |
| `internal` | bounded unexpected server failure |

Validation precedence is normative:

1. frame size;
2. LF framing and read deadline;
3. UTF-8 and JSON syntax;
4. duplicate keys at any object depth;
5. top-level object, exact field set, canonical request ID, and structural field types except `protocol_version`;
6. protocol version;
7. method allowlist;
8. exact params shape and canonical instance ID;
9. instance match; and
10. handler/internal failure.

The request ID is echoed only after duplicate-key validation and canonical request-ID validation succeed. It is null for all earlier failures and for any duplicate key, including a duplicate unrelated field.

Clients reject any response schema deviation. Every response has exactly four required top-level fields with no duplicates or extras: integer `protocol_version` equal to `1`, canonical `request_id` or null as allowed by the failure, and exactly one non-null value among `result` and `error`. A success result has only the fields specified for its method, uses the requested instance ID, and has state exactly `ready`. An error object has exactly string fields `code` and `message`; the code is from the stable allowlist and the message is at most 256 UTF-8 bytes.

## Endpoint lifecycle and security

1. On macOS, the production supervisor uses the literal, non-resolved root `/private/tmp`. Before creation it requires by `lstat` that the root is a real UID-0 directory with mode exactly `01777`. It constructs `hidhogg-<decimal-effective-uid>-<canonical-lowercase-random-UUID>`, validates the complete `<root>/<generation>/runtime.sock` encoded byte length including NUL, and atomically creates the generation directory with `mkdir(0700)`. Creation fails on collision and never adopts or deletes an existing path. Tests may inject another root; production does not use `TMPDIR` or Foundation's temporary-directory URL.
2. The endpoint is `<generation-directory>/runtime.sock`. Its encoded path, including the terminating NUL, must fit the 104-byte Darwin `sun_path` field before launch.
3. Swift passes the exact endpoint with `--socket-path`; the runtime never searches for an endpoint. `hidhoggctl` also requires an explicit path during `M-01`.
4. Before binding, the runtime uses `lstat` to require that the generation directory is a real directory, owned by its effective UID, with mode exactly `0700`. If any endpoint entry exists, including a symlink, file, or socket, startup fails without deletion.
5. After bind and before readiness, the runtime applies mode `0600` and starts listening.
6. Immediately after accept/connect and before protocol bytes, both peers must verify the other's effective UID equals their own. Failure closes silently. Clients also validate the generation directory as above and use `lstat` to require a non-symlink socket owned by their effective UID. Failure to obtain Darwin peer credentials is fatal for this macOS-only scaffold.
7. The runtime records the socket identity it bound. The supervisor records the first valid socket identity observed for a generation and never replaces it; later identity drift is a security failure that terminates the child and prevents readiness.
8. Runtime and supervisor cleanup is best-effort and identity-guarded. Immediately before unlinking, the cleaner requires the recorded generation-directory and socket device/inode identities, types, owners, and modes still match. Any mismatch leaves the endpoint and directory untouched. Before any socket identity was recorded, the supervisor removes only an already-empty matching generation directory. Cleanup never recursively deletes.
9. Every restart uses a new directory and endpoint. Multiple app instances therefore coexist.

No component probes and unlinks a supposedly stale endpoint. The final pathname unlink is not an atomic compare-and-unlink operation on macOS; a malicious process with the same effective UID can substitute the name between validation and unlink. `M-01` trusts same-effective-UID processes. The owner-only directory, unpredictable generation name, peer credentials, and instance attribution exclude other users and prevent accidental or stale cleanup, but are not a sandbox against code already running as the owner. Normal exit, forced exit after readiness, exit before readiness, observable substitution, and unexpected-entry behavior are tested.

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

Interfaces are declared at their consumer. No production package imports spike modules. `M-01` does not link HID, TOML editing, action, notification, or D200X production dependencies.

## Shared fixtures

[`cases.json`](cases.json) is the authoritative fixture manifest. Static cases reference shared request and response bytes. Generated cases define their base bytes or mutation, direction, and expected semantic behavior. Go and Swift tests consume the same manifest. Live response key order is not significant; fixture comparison is semantic except where a case explicitly tests framing bytes.
