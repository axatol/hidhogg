# Native input acceptance

Updated: 2026-09-18. Owner-run only; use an empty TextEdit document, then an empty VS Code editor. Do not use a terminal, password field, or production document.

Known limit: native initialization is synchronous before IPC. A hung macOS initialization call can delay both readiness and normal runtime close; the worker's bounded close does not guarantee universally bounded runtime shutdown. Report a startup hang rather than repeatedly launching replacements.

## Prepare

Stop any existing Hidhogg runtime normally. Build stable executable paths from the repository root:

```sh
go build -o ./deploy/hidhogg ./cmd/hidhogg
go build -o ./deploy/hidhoggctl ./cmd/hidhoggctl
cp ./deploy/hidhogg.toml ./deploy/native-input-test.toml
```

In the copied configuration only, replace two existing position action tables in the profile you will activate. Remove the old action's foreign fields, including executable, arguments, and profile_id.

Text position:

```toml
[profiles.positions.action]
type = "type_text"
gesture = "press"
text = "123.*+"
```

Enter position:

```toml
[profiles.positions.action]
type = "key_press"
gesture = "press"
key = "enter"
```

The surrounding complete profiles/positions and schema version 3 remain unchanged. Start the test runtime in one terminal:

```sh
./deploy/hidhogg --runtime-dir "$(pwd)/deploy" --config-path "$(pwd)/deploy/native-input-test.toml" --verbose
```

Activate the modified profile if it is not the initial profile:

```sh
./deploy/hidhoggctl --runtime-dir "$(pwd)/deploy" profiles activate numpad
```

Substitute its actual profile ID if different.

## Permission and doctor

In another terminal:

```sh
./deploy/hidhoggctl --runtime-dir "$(pwd)/deploy" --method input.status
./deploy/hidhoggctl --runtime-dir "$(pwd)/deploy" --method doctor
```

Neither command prompts or posts input. If permission is not granted, explicitly request it:

```sh
./deploy/hidhoggctl --runtime-dir "$(pwd)/deploy" --method input.request_permission
```

Follow any macOS Accessibility instructions for the posting runtime's identity. A request does not guarantee a prompt or grant. If it times out, do not retry automatically: complete the OS UI, then check status. If macOS requires restart, stop/start the same runtime binary. Admission during the request is rejected; canceled input must not replay after approval.

## Input

Focus the empty editor after running CLI commands; input targets the foreground application at posting time.

- Press/release the text position once: exactly `123.*+`, with no extra release-triggered text.
- Press/release Enter once: one newline.
- Repeat in VS Code. Record each application result separately.
- Press the text position rapidly five times: five ordered copies, without busy-slot loss. A burst exceeding 16 waiting actions can explicitly reject queue-full; that is not a delivery guarantee.
- In the harmless editor, repeat once while holding Cmd and once while holding Control; record text delivery versus shortcut/other behaviour. Zero event flags do not establish how every application handles physically held modifiers.

Inspect metadata history after refocusing the terminal:

```sh
./deploy/hidhoggctl --runtime-dir "$(pwd)/deploy" --method executions.list --limit 16
```

Native rows must identify their action type and outcome, without typed text, process output, or exit metadata. `posted` means both native posting calls completed; visible delivery is verified by you, not the API.

## Shutdown and report

Stop with Ctrl-C in the runtime terminal. Confirm normal cleanup of runtime socket/generation metadata; the persistent lock is expected. Report permission/status/doctor, TextEdit text/Enter, VS Code text/Enter, rapid typing, held-modifier observations, and shutdown separately. The owner explicitly approved native numpad migration before manual acceptance on 2026-09-18; `deploy/hidhogg.toml` is now migrated, but this does not establish physical acceptance.
