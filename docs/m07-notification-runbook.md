Retired v1 procedure (2026-10-18): the Go runtime and CLI instructions below are archived history, not current operating steps. Current Swift architecture and verification limits are in [v2-plan.md](v2-plan.md).

# M-07 owner verification

Status on 2026-09-19: completed. Implementation, independent automatic gates, final architecture review, and owner-run physical acceptance pass.

Observed acceptance: active-display checks passed. While dimmed, emitting `WAKE` did not wake or brighten the display. A manual wake restored visibility and retained `WAKE`; the next selection restored only that tile to its configured `status` label. The owner confirmed all other checks in this runbook passed.

## Setup

In the active profile, add this field to two positions, preferably a square and wide `3_2`:

```toml
notification_sources = ["debug"]
```

For the tile-local dismissal check, the selected tile must have no action that switches profile. An actionless tile is suitable. Later check a statically configured harmless action separately. Preserve the original configuration; do not change labels/styles just for notification testing.

Build and start from the repository root, with no other runtime using the directory:

```sh
go build -o ./deploy/hidhogg ./cmd/hidhogg
go build -o ./deploy/hidhoggctl ./cmd/hidhoggctl
./deploy/hidhogg --runtime-dir "$(pwd)/deploy" --config-path "$(pwd)/deploy/hidhogg.toml" --verbose
```

Use a second terminal for controller commands. Focus a harmless text field before selecting a tile that types text or Enter; do not focus a shell prompt for that check.

## One active-display sequence

```sh
./deploy/hidhoggctl --runtime-dir "$(pwd)/deploy" notifications emit --source debug --text N1
./deploy/hidhoggctl --runtime-dir "$(pwd)/deploy" notifications emit --source debug --text N2 --ttl-seconds 3
```

- Both subscribers show N1, then N2, retaining their configured style/background. Replies report two matches and distinct IDs.
- After expiry, both return to their configured labels, not N1. Copy returned IDs when needed; responses do not echo notification text.
- Emit again without TTL. Select the actionless subscriber with one down/up pair: only that tile returns to baseline; the other retains the notification.
- Clear the returned ID with the command below: the remaining subscriber returns to baseline and `cleared_count` is one. Repeat the clear: count zero and no redraw.

```sh
./deploy/hidhoggctl --runtime-dir "$(pwd)/deploy" notifications clear --notification-id "PASTE_RETURNED_ID"
```

Also confirm: a configured press/release action runs once after successful dismissal; an unmatched source returns count zero without changing the display; a superseded ID cannot clear its replacement. Same-profile activation and unchanged/rejected reload retain a live notification; a different-profile activation or changed reload restores configured content and clears overlays.

## Required idle check

Use a short temporary `idle_timeout_seconds` if desired, restoring it afterward. Once the application has blanked the display, emit, replace, clear, and allow a finite-TTL notification to expire. The display must remain blank throughout. Then emit an indefinite notification while still dimmed:

```sh
./deploy/hidhoggctl --runtime-dir "$(pwd)/deploy" notifications emit --source debug --text WAKE
```

The first physical wake gesture must restore configured brightness without dismissing WAKE or executing an action; the next configured gesture may select it. Confirm only that selected tile returns to baseline.

If any software update brightens the device, stop and report the exact operation. That is a firmware-policy gap, not a passed acceptance test.

Finish with Ctrl-C in the runtime terminal. Socket/metadata should disappear; `runtime.lock` remains. Report which checks passed, any unexpected behaviour, and the runtime's error/log output. A timeout/disconnect means outcome unknown; do not automatically retry emission. Physical dismissal, same-source replacement followed by clear, changed reload, profile switch, or restart can recover an orphan.
