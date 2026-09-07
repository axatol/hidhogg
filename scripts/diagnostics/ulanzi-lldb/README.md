# Ulanzi Studio LLDB preparation utilities

These utilities prepare and validate bounded LLDB evidence collection. None launches or attaches to Ulanzi Studio. The dynamic phase remains separately authorized.

## Static preflight

```sh
./scripts/diagnostics/ulanzi-lldb/preflight.zsh \
  --app-bundle '/Volumes/Data/Applications/Ulanzi Studio.app'
```

The preflight requires the reviewed executable SHA-256 and arm64 format, creates an LLDB target, resolves the reviewed file addresses and hidapi symbols, and loads the breakpoint command file in batch mode. It contains no `process launch` command.

## Prepare T01 and T02

```sh
./scripts/diagnostics/ulanzi-lldb/prepare-workspace.zsh
```

Copy the printed workspace and trial paths. The workspace is created with owner-only permissions under `/private/tmp`; raw captures must remain there by default.

When the dynamic phase is explicitly authorized, start interactive LLDB with the reviewed breakpoint file:

```sh
/Volumes/Data/Applications/Xcode.app/Contents/Developer/usr/bin/lldb \
  --file '/Volumes/Data/Applications/Ulanzi Studio.app/Contents/MacOS/UlanziDeck' \
  --source ./scripts/diagnostics/ulanzi-lldb/breakpoints.lldb
```

This command creates the target and breakpoints but still does not launch it. Launch occurs only if `process launch` is entered interactively.

## Hash one completed trial

```sh
./scripts/diagnostics/ulanzi-lldb/hash-trial.zsh \
  --trial-dir '<absolute-trial-directory>'
```

The helper hashes regular top-level `.bin` captures and records digest, byte count, and basename in `captures.sha256`. It refuses directories outside a workspace created by `prepare-workspace.zsh`.

## Compare repeat trials

Run `hash-trial.zsh` for both trials immediately before comparison so each manifest represents the current capture files.

```sh
./scripts/diagnostics/ulanzi-lldb/compare-trials.zsh \
  --left-trial '<absolute-T01-directory>' \
  --right-trial '<absolute-T02-directory>'
```

The comparison prints only capture manifests and whether they are identical or different; it does not print payload contents. Different hashes require classification and are not automatically failures.

Follow the capture procedure and stop conditions in `docs/ulanzi-studio-lldb-runbook.md`.

## Screensaver-artwork preparation (SS-U0..SS-U3)

The screensaver helpers create a fresh owner-only workspace under `/private/tmp`
and generate two project-owned, metadata-free `1220x708` PNG specimens. They
do not start or attach to Studio and do not perform device, transport, or
network I/O:

```sh
./scripts/diagnostics/ulanzi-lldb/prepare-screensaver-workspace.zsh
```

Prepare one trial from the printed workspace path. `SS-U0` is the click/cancel
control; the upload trials require their predeclared specimen (`SS-U1=A`,
`SS-U2=B`, `SS-U3=A`):

```sh
./scripts/diagnostics/ulanzi-lldb/prepare-screensaver-capture.zsh \
  --trial-dir '<absolute-workspace>/SS-U1' --specimen A
```

The trial contains separate `chronology.lldb` and `payload.lldb` command
files. The former records bounded metadata at `sendDataToDeck` and
`OnDeckFrameReceived` with automatic continuation. The latter is stopped-only
and refuses payload bytes until the owner marks `FILE_SELECTED` with the
matching specimen and explicitly arms payload capture. A payload is still
gated on `SET_IMAGE_CLICKED`. Source either command file from the repository
root so its relative callback-module import resolves.

Record the closed UI workflow with `mark-screensaver-action.zsh`. The accepted
flows are `CLICK_SCREEN_SAVER -> EDITOR_VISIBLE -> CANCEL_CLICKED ->
EDITOR_CLOSED -> DEVICE_OUTCOME_OBSERVED` for U0, and the picker/set-image
variant for U1-U3. For an upload, arm at file selection:

```sh
./scripts/diagnostics/ulanzi-lldb/mark-screensaver-action.zsh \
  --trial-dir '<absolute-workspace>/SS-U1' \
  --marker FILE_SELECTED --specimen A --arm-payload
```

The generated fixture manifest records dimensions and SHA-256 values; all
paths, trial IDs, identifiers, lengths, and capture names are validated and
overwrites are refused. Payload authorization is bound to the current
`FILE_SELECTED` specimen, sequence, timestamp, and record digest; every
payload-log row is reconciled with its owner-only `.bin` artifact, including
filename, size, and SHA-256. Recheck an existing workspace with
`verify-screensaver-fixtures.zsh`; raw payload files remain in the temporary
workspace.

Run the non-launching regression gate with:

```sh
./scripts/diagnostics/ulanzi-lldb/screensaver_validation_test.zsh
```
