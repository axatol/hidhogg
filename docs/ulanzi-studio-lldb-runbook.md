# Ulanzi Studio LLDB interoperability runbook

Status: T03-T13 interaction complete; retained as a reproducibility and evidence-handling runbook
Updated: 2026-09-03

## Purpose

Use LLDB to observe only the D200X HID boundary of a lawfully installed Ulanzi Studio application. The intended outputs are exact command payloads, bounded inbound responses, call origins, and trial chronology for clean-room interoperability work.

This runbook does not authorize launching or attaching to the application. It does not authorize bypassing hardened runtime, signing, debugger restrictions, authentication, DRM, or macOS security controls.

## Expected outcomes

| Trial family | Primary outcome | Evidence limit |
|---|---|---|
| Connect | Exact `0x0003`, `0x000b`, `0x0303`, and any `0x010b` bytes and chronology | One observed order is not a required order |
| Font style | Exact `0x000b` JSON and single-property deltas | Successful fields are not necessarily required fields |
| Key upload | Exact `0x000d` ZIP manifest from an owner-created test profile | One archive does not establish every accepted schema variant |
| Mode-100 upload | Exact `0x0011` ZIP manifest and its delta from `0x000d` | Application behavior does not prove firmware necessity |
| Input | Exact `0x0101` bytes for controlled presses and rotations | Does not enumerate undocumented firmware events |
| Screensaver | Packet/response chronology for one wake action per fresh trial | Causality requires repeated controlled comparisons |

## Current gate

T01/T02, full-payload repeats T01P/T02P, and controlled T03-T12 are complete. T13 preparation now targets Studio's screensaver-artwork uploader, which is distinct from timeout or wake causality. The Device preferences button opens an editor; `Stored Image` opens the macOS picker and `Set Image` is the explicit commit control. No T13 dynamic action is authorized until its non-launching utilities pass review.

No further launch-only capture is planned. The T09-T11 LLDB target was terminated after its input breakpoint was disabled and evidence was recorded. Retain the verified disposable copy through any later Studio-chronology work and remove it only when the owner ends or abandons that phase.

## Non-negotiable boundaries

- Use a new local macOS standard account with no existing Ulanzi Studio state, account, profile, or cloud session.
- Disconnect networking before launch where practical.
- Connect only the owner's D200X and remove unrelated HID devices where practical.
- Create only synthetic profiles and owned test images. Do not inspect existing profiles, application data, preferences, logs, accounts, telemetry, or unrelated memory.
- Keep raw captures outside the repository. Store only hashes, decoded protocol fields, bounded implementation-neutral fixtures, and conclusions in Hidhogg.
- Do not launch the static copy at `/private/tmp/hidhogg-ulanzi-static.4dGB6z`; its bundle seal is invalid.
- Stop if ordinary LLDB launch is denied. Do not patch, resign, inject libraries, disable SIP, change AMFI settings, modify entitlements, or otherwise weaken platform protections.
- Exception authorized by the owner on 2026-08-30: a new owner-only temporary copy may be ad-hoc signed solely to reproduce the previously documented Ulanzi Studio 3.1.9 LLDB capture procedure. Do not modify or sign the installed bundle or either static specimen. Verify the whole executable is identical before signing and its `__TEXT,__text` machine-code section remains identical afterward; whole-file identity cannot survive embedded-signature replacement. Deny networking for the traced process, exclude payload contents, and stop after T01/T02 for review. This exception does not authorize SIP, AMFI, debugger-authorization, entitlement, or other system-security changes.
- Follow-up authorized by the owner on 2026-08-30: after the network-deny enclosure caused target sandbox initialization failure with zero HID-boundary hits, T01/T02 may run with Ulanzi Studio's normal network access. Discard target stdout/stderr, do not inspect network traffic or application state, retain the no-login and metadata-only capture boundary, and do not infer network necessity from this operational workaround.
- Stop if the application requests login, existing user content, unexpected permissions, or network-only initialization.

## Capture model

```text
controlled UI action
        |
        v
HIDDevice::sendDataToDeck        logical command and payload
        |
        v
hid_write                       exact HID report and return value
        |
        v
D200X
        |
        v
hid_read_timeout                exact inbound report
        |
        v
OnDeckFrameReceived             decoded application dispatch
```

Prefer the two application-level breakpoints for initial trials. Add the hidapi breakpoints only when report boundaries or read return values are necessary; stepping through hidapi can perturb timing.

## Before each session

1. Confirm that the active macOS account has no prior Ulanzi Studio state.
2. Disconnect networking.
3. Quit software that could open the D200X.
4. Run the static-only preflight. It verifies the reviewed executable hash, architecture, symbol addresses, and breakpoint resolution without launching a process:

```sh
./scripts/diagnostics/ulanzi-lldb/preflight.zsh \
  --app-bundle '/Volumes/Data/Applications/Ulanzi Studio.app'
```

5. Prepare owner-only T01 and T02 directories under a unique `/private/tmp` root, then copy the printed paths:

```sh
./scripts/diagnostics/ulanzi-lldb/prepare-workspace.zsh
```

6. Complete the generated metadata without including a username, device serial, account identifier, or unrelated path:

```text
trial_id:
absolute_date_time:
application_sha256: b64e598411c0d67fc44b08b09820e0b5fea12ce26052c44098e96bbd9b2c3022
device_model: D200X
firmware_version: unknown or displayed value
initial_device_state:
single_variable_changed:
expected_command:
```

7. Start from a fresh application process for every baseline or causal comparison.

Do not record the entire terminal session by default. Ulanzi Studio may print unrelated application paths or state. Capture only the bounded registers, backtraces, protocol buffers, hashes, and worksheet fields specified here.

## Ordinary LLDB launch gate

Start LLDB against the signed installed executable:

```sh
/Volumes/Data/Applications/Xcode.app/Contents/Developer/usr/bin/lldb \
  --file '/Volumes/Data/Applications/Ulanzi Studio.app/Contents/MacOS/UlanziDeck' \
  --source ./scripts/diagnostics/ulanzi-lldb/breakpoints.lldb
```

In LLDB, verify that the known application file addresses and hidapi symbols resolve before launch:

```text
target modules lookup --address 0x100030184
target modules lookup --address 0x100513cbc
target modules lookup --name hid_write
target modules lookup --name hid_read_timeout
```

The sourced command file sets the application breakpoints at their verified function-entry file addresses. LLDB converts these file addresses to live addresses after applying the image slide, so ASLR does not require manual arithmetic. The equivalent commands are:

```text
breakpoint set --address 0x100030184 --shlib UlanziDeck --breakpoint-name d200x_outbound
breakpoint set --address 0x100513cbc --shlib UlanziDeck --breakpoint-name d200x_dispatch
breakpoint list
process launch
```

Proceed only if ordinary launch succeeds and both breakpoints resolve. A debugger or code-signing denial is a stop result to record verbatim, not a condition to circumvent.

## First-session walkthrough: T01 and T02

For T01:

1. Start from the isolated account, disconnected network, stopped application, and connected D200X.
2. Create the target and two application breakpoints as shown above.
3. Run `process launch`.
4. At every `d200x_outbound` stop, record `w1`, `w2`, `x4`, and the bounded backtrace. Dump the payload only when its command is in scope and its length is nonzero.
5. At every `d200x_dispatch` stop, record the eight-byte header, decoded length, bounded backtrace, and only the protocol payload addressed by the `DeckFrame`.
6. Run `continue` after each recorded stop. Do not interact with the UI during the connection baseline.
7. Once no immediate connection breakpoint recurs, wait ten seconds without interaction, interrupt LLDB with Control-C, record `process status`, then end the session.
8. Hash every captured buffer and complete the trial worksheet.

For T02, repeat the exact procedure from a fresh application process without changing the device, profile, UI, or breakpoint set. Compare commands, payload hashes, and order. Variable fields such as timestamps or generated identifiers must be classified before treating unequal hashes as instability.

Stop after T02 and review the evidence before performing any later trial.

## Capturing an outbound logical payload

At `d200x_outbound`, the verified arm64 entry convention is:

```text
x0     HIDDevice this pointer
w1     first command byte
w2     second command byte
x3     payload pointer
x4     payload length
```

Inspect bounded values:

```text
register read w1 w2 x3 x4
thread backtrace --count 12
memory read --format x --size 1 --count <preview-count-no-greater-than-64-or-payload-length> -- $x3
```

Do not run `memory read` when `x4` is zero. Do not request more bytes than the reported payload length. The 64-byte preview is only for identification.

For a full capture, manually copy the reported decimal length and payload address into an explicit command:

```text
memory read --binary --outfile /private/tmp/ulanzi-lldb/<trial-id>/outbound-<command>.bin --size 1 --count <payload-length> -- <payload-address>
```

Then continue:

```text
continue
```

For `0x000d` and `0x0011`, the payload may be large. Confirm the command bytes and length before dumping it. Capture only archives generated from the synthetic trial profile.

## Capturing inbound application dispatch

At `d200x_dispatch`, `x1` points to the in-memory `DeckFrame` used by the application:

```text
offset 0..1   magic
offset 2      first command byte
offset 3      second command byte
offset 4..7   little-endian payload length
offset 8..15  payload pointer
```

Inspect the header, length, pointer, and call origin:

```text
register read x1 x2
memory read --format x --size 1 --count 8 -- $x1
memory read --format unsigned --size 4 --count 1 -- '$x1 + 4'
memory read --format address --size 8 --count 1 -- '$x1 + 8'
thread backtrace --count 12
```

Use the displayed payload length and dereferenced payload address in an explicit bounded dump:

```text
memory read --binary --outfile /private/tmp/ulanzi-lldb/<trial-id>/inbound-<command>.bin --size 1 --count <payload-length> -- <payload-address>
```

Do not dump `x2`; it is application context, not the protocol payload.

## Optional hidapi report boundary

Enable this only after the application-level capture works:

```text
breakpoint set --name hid_write --skip-prologue false --breakpoint-name hid_write_boundary
breakpoint set --name hid_read_timeout --skip-prologue false --breakpoint-name hid_read_boundary
breakpoint list
```

At `hid_write_boundary`, arm64 arguments are:

```text
x0     hid_device pointer
x1     report buffer
x2     report length
```

Capture the exact report, including report ID byte zero:

```text
register read x1 x2
memory read --format x --size 1 --count 32 -- $x1
memory read --binary --outfile /private/tmp/ulanzi-lldb/<trial-id>/hid-write-<sequence>.bin --size 1 --count <report-length> -- <report-address>
thread backtrace --count 12
continue
```

At `hid_read_boundary`, record `x1` as the buffer address, `x2` as capacity, and `w3` as timeout. `thread step-out` returns after the read; signed `x0` is then the byte count or error. Dump only a positive returned byte count from the previously recorded buffer address.

```text
register read x1 x2 w3
thread step-out
register read x0
memory read --binary --outfile /private/tmp/ulanzi-lldb/<trial-id>/hid-read-<sequence>.bin --size 1 --count <positive-return-count> -- <recorded-buffer-address>
```

If stepping changes timing, produces re-entrant stops, or destabilizes the application, note the numeric IDs shown by `breakpoint list`, disable those hidapi breakpoints, and rely on `OnDeckFrameReceived`. For example, if they are breakpoints 3 and 4:

```text
breakpoint disable 3 4
continue
```

## Trial matrix

Run one row per fresh process. Change exactly one variable after reaching a recorded baseline.

| ID | Initial state | Single action | Capture | Comparison question |
|---|---|---|---|---|
| T01 | App stopped; D200X connected | Launch only | All bounded logical writes and dispatches until idle | Which commands occur on connection? |
| T02 | Same as T01 | Repeat launch | Same as T01 | Which ordering and bytes are stable across runs? |
| T03 | Connected synthetic default profile | Change one font property | `0x000b`, subsequent `0x010b`, if any | Which JSON field changes? |
| T04 | Same baseline as T03 | Change a different font property | Same as T03 | Are fields independent or coupled? |
| T05 | Built-in System -> Text action at `0_0`, empty title | Assign that action; repeat once | `0x000d` ZIP | What is the minimal Studio-permitted action-backed tile manifest? |
| T06 | Exact T05 action/icon/font baseline | Change only displayed text between equal-length synthetic values | `0x000d` ZIP | Which manifest value or file changes? |
| T07 | Exact titled T05 baseline | Move the same tile from `0_0` to `1_0` | Every resulting `0x000d` ZIP | How are add/clear coordinates and packet order encoded? |
| T08 | One Multimedia action on knob 1; knobs 2-3 empty; settled Time mode | Select the Studio Knob radio once; repeat from the same Time baseline | `0x0011` ZIP | Reproducible current-page encoder archive and physical knob coordinates |
| T09 | Connected and idle | One square press and release | Inbound `0x0101` | Confirm key, position, type, and status bytes |
| T10 | Connected and idle | One encoder detent left | Inbound `0x0101` | Confirm encoder action encoding |
| T11 | Connected and idle | One encoder detent right | Inbound `0x0101` | Confirm the opposite action encoding |
| T12 | Wide tile in Background mode with no image | Select one project-owned 458-by-196 PNG and Save | `0x000d` ZIP | Map `3_2`, `SmallViewMode: 2`, and Studio's image transformation |
| SS-U0 | Fresh process; settled active device | Open Screensaver editor, then Cancel without choosing a file | Application-boundary chronology | Detect click-time writes |
| SS-U1 | Fresh process; settled active device | Select synthetic 1220-by-708 image A; keep default transform; Set Image | Application-boundary chronology and attributable payload | Establish baseline upload |
| SS-U2 | Fresh process with A established | Select same-size synthetic image B; keep identical defaults; Set Image | Same as U1 | Isolate image-content delta |
| SS-U3 | Fresh process with B established | Re-select A with identical defaults; Set Image | Same as U1 | Test normalized restoration of baseline |

For SS-U0 through SS-U3, record `CLICK_SCREEN_SAVER`, `PICKER_VISIBLE`, `FILE_SELECTED`, `EDITOR_VISIBLE`, `SET_IMAGE_CLICKED` or `CANCEL_CLICKED`, `EDITOR_CLOSED`, and `DEVICE_OUTCOME_OBSERVED`. Capture begins 15 seconds before the first UI action and ends 30 seconds after commit or cancel. Do not adjust crop, zoom, pan, rotation, brightness, another preference, or any physical device control.

Do not begin screensaver trials until T01–T11 are reviewed. Screensaver testing should use one outbound candidate per fresh native-screensaver state and retain the existing no-retry boundary.

## ZIP and JSON examination

Only inspect captures derived from synthetic trial content.

List a ZIP without extracting images:

```sh
unzip -l /private/tmp/ulanzi-lldb/<trial-id>/outbound-000d.bin
```

Print only the controlled manifest:

```sh
unzip -p /private/tmp/ulanzi-lldb/<trial-id>/outbound-000d.bin manifest.json | jq .
```

For JSON commands or responses, first verify that the capture belongs to `0x000b` or `0x0303`, then inspect the bounded file:

```sh
jq . /private/tmp/ulanzi-lldb/<trial-id>/outbound-000b.bin
jq . /private/tmp/ulanzi-lldb/<trial-id>/inbound-0303.bin
```

If a payload contains identifiers, paths, account data, telemetry, or content not created for the trial, stop inspection and do not copy it into the repository.

For the owner-authorized `T01P` and `T02P` connection repeats on 2026-08-30, complete D200X logical payloads and their derived contents may be inspected even when they contain existing Studio profile or device metadata. This exception does not authorize inspection of unrelated application memory or network traffic. Raw captures remain owner-only outside Git; repository findings must remain implementation-neutral.

## Integrity and evidence record

Hash each capture individually:

```sh
shasum --algorithm 256 /private/tmp/ulanzi-lldb/<trial-id>/<capture-file>
```

After a trial, create its bounded manifest with:

```sh
./scripts/diagnostics/ulanzi-lldb/hash-trial.zsh \
  --trial-dir '<absolute-trial-directory>'
```

Immediately before comparing T01 and T02, rerun that helper for both trials, then compare only their digest/size/name manifests:

```sh
./scripts/diagnostics/ulanzi-lldb/compare-trials.zsh \
  --left-trial '<absolute-T01-directory>' \
  --right-trial '<absolute-T02-directory>'
```

For each observation, record:

```text
trial_id:
command:
direction: inbound | outbound
payload_length:
capture_sha256:
call_origin:
action_performed:
prior_commands:
subsequent_commands:
device_response:
classification: captured-bytes | observed-chronology | hypothesis | causal-claim
uncertainties:
```

A causal claim requires repeated intervention and a comparison trial. For example:

```text
same baseline + property A unchanged -> payload X
same baseline + only property A changed -> payload X'
repeat both conditions             -> same reproducible delta
```

## Ending a session

In LLDB:

```text
process status
process kill
quit
```

Confirm that Ulanzi Studio is no longer running and that no debugger process retains the device. Do not delete raw captures until their hashes and bounded derived findings have been reviewed. Raw captures remain temporary evidence and should not be committed by default.

## Completed targeted-key gate and next interaction

The connection gate has passed. Its review established:

- Ordinary installed-app LLDB launch was denied; a separately authorized ad-hoc-signed disposable copy worked without SIP, AMFI, entitlement, or debugger-policy changes.
- The selected existing account, normal network access, no-login state, and sole owned D200X boundary were recorded.
- Application breakpoints captured the intended HID boundary. Manual payload dumps perturb asynchronous chronology, so automatic trials and interactive payload trials serve different evidence roles.
- Repeated connection commands and payloads are stable after normalization. Additional unattended launches have low information value.
- T03-T08 and T12 are complete. Ordinary display edits transmit immediately, but background artwork opens a crop/preview dialog and commits on Save.
- T09-T11 captured exact square and middle-encoder `0x0101` frames; only screensaver trials still require physical device-state changes.

Start a new verified LLDB session from the retained disposable copy only if later work needs Studio chronology. Use `d200xprobe`, not Studio, for one-frame screensaver causality. Preserve `/private/tmp/ulanzi-lldb-interactive.jIKQFm/` until hashes and bounded derived findings are reviewed.

The canonical static baseline and specimen evidence are in `docs/ulanzi-studio-analysis.md`.
