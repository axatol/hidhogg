# cgo-free macOS keyboard input spike

> Historical Go spike retained as research evidence (2026-10-18). Its examples describe the retired implementation and are not current product commands. The current Swift architecture is documented in [docs/v2-plan.md](../../docs/v2-plan.md).


This isolated Go module probes Core Graphics keyboard and Unicode event
injection through `github.com/ebitengine/purego` v0.10.2. It is not integrated
with Hidhogg and does not use cgo, a native shim, a helper process, or a
subprocess per event.

Build and run it from this directory:

```sh
go test -race -count=1 ./...
go vet ./...
go run ./cmd/native-input --check
go run ./cmd/native-input --benchmark 1000
go run ./cmd/native-input --inspect --text 'hello'
go run ./cmd/native-input --inspect --key enter --source combined --tap session
```

`--check` calls `CGPreflightPostEventAccess` only. It never requests access,
prompts, allocates an event, or posts one. `--benchmark N` performs one
unmeasured warm-up followed by N measured one-character Unicode-event
construction and release iterations. It reports allocation distribution only; it is not UI or
application delivery latency.

`--inspect` constructs one down/up pair, reads each event back, and releases
the events before returning. It never checks permission, prompts, waits for
focus, or posts an event. Each record reports the Core Graphics event type
(key down is 10 and key up is 11), virtual keycode (field 9), flags, and
UTF-16 Unicode readback. Text records include `unicode_match=true|false` for
the constructed string; Enter is a physical key action, so its Unicode field
is reported but the match is `n/a`. A mismatch diagnoses construction only;
it does not establish delivery to an application.

The optional `--source` selector applies to construction and posting. Its
values map to Core Graphics event-source states as follows:

```text
default  -> NULL source
private  -> -1
combined ->  0
hid      ->  1
```

The optional `--tap` selector applies to posting and is included in inspect
output for comparison:

```text
hid       -> 0
session   -> 1
annotated -> 2
```

For a controlled owner comparison after the default probe, try
`--inspect --text 'hello' --source combined --tap session`; this is still a
no-post diagnostic and is not evidence that either selector fixes delivery.

Owner-only posting commands are:

```sh
go run ./cmd/native-input --text 'hello' --delay 500ms
go run ./cmd/native-input --key enter --delay 500ms
go run ./cmd/native-input --text 'hello' --source combined --tap session --delay 500ms
```

These commands require event-synthesizing permission and post exactly one
down/up pair to the selected event tap (`hid` by default). The delay is an
optional focus hand-off window. Text is limited to 64 UTF-16 code units; Enter
is a physical key action, not Unicode text. Do not run posting commands against
an unintended focused application.

Apple documents that application frameworks may ignore a Unicode string on a
keyboard event and perform their own virtual-key translation. A returned
`CGEventPost` call therefore establishes only that the host API call returned;
it does not establish application receipt, text insertion, or visible output.
The automated tests use fakes and never post native events. Validate any
owner-run behavior manually and treat the result as experimental.
