# D200X workspace owner checks

## 28 October 2026 — wide modes, screensaver and app icons

Restart the signed `dist/Hidhogg.app` (build `fec36149ac455d36e8187bc8c9b878a5d06e8bce140f76ca21218cbf20f2a66d`). The earlier display/icon baseline passed206 independent fake-only checks; the current mode-switch/retained-preview follow-up passed38 focused checks on frozen source. Physical appearance and persistence are still open. The agent has not launched the app or changed the deck.

| Check | Steps | Expected |
|---|---|---|
| Wide modes | In D200X → Device settings choose clock/date variants, background, then Custom tile; compare12/24-hour selection | Physical wide display follows selection; custom content and button assignment remain available. |
| System status | Choose CPU/RAM/GPU and allow initial samples | Valid available counters are sent; if any source is unavailable the app reports it and uses custom content, without inventing GPU0. Values are not an Activity Monitor calibration. |
| Wide notification restore | Subscribe Key14 to `demo.build`, select a clock mode, then emit the icon example below | Icon temporarily replaces the wide clock; after TTL expiry the selected clock mode returns. |
| Icon fallback | Emit an installed app ID; then use `com.example.NotInstalled` with fallback text | Installed icon is shown; missing icon shows the supplied text (or bundle ID when no text was supplied). |
| Icon actions/presets | Create Send Deck Notification with an app ID and optional fallback text; export/import a preset including it | Editor, review summary and imported action retain the app ID; appearance-only import still avoids importing actions. |
| Crop preview | Choose a PNG/JPEG and adjust zoom/position repeatedly | Before first confirmation, only the latest local crop is published and nothing is sent to the device. After confirmation, crop edits update the saved image and restart the temporary deck preview. |
| Explicit screensaver image | Review the crop, click Apply, then confirm replacement | Exactly this image is sent and a five-second deck preview is requested, then current tiles/mode restore. There is no automatic screensaver reapply on reconnect; the original device image cannot be restored by HidHogg. |
| Screensaver visibility | Confirm an image or use Preview on Deck; also observe the normal screensaver after quitting HidHogg | Check crop placement across screen gaps and the approximately five-second return to active tiles. Immediate activation and physical timing need owner verification; the five-second preview is not a firmware inactivity-timeout setting. Power-cycle persistence remains unverified. |
| Lifecycle | Reconnect and sleep/wake after selecting a wide mode; repeat with an active notification | Selected mode returns; notification expiry/clear/profile changes restore ordinary content; existing retained-connection sleep/brightness policy is preserved. |

With the app running, deck connected and the chosen tile subscribed to `demo.build`:

```sh
./dist/hidhoggctl notifications emit --topic demo.build --app-id com.apple.Terminal --ttl-seconds 5
./dist/hidhoggctl notifications emit --topic demo.build --app-id com.example.NotInstalled --text "Build finished" --ttl-seconds 5
```

The agent did not execute these live examples. CLI validation was smoke-tested only using an explicitly nonexistent socket path. No flashing effect is implemented. [Now Playing report/prototype](d200x-now-playing-spike.md) is synthetic research, not a live player feature in this build.

## Earlier owner checks

2026-10-23. Agents verified software with fake devices/process runners and isolated temporary Unix endpoints. The real app, deck writes, configured child execution and permission prompts were not exercised. Reopen the signed `dist/Hidhogg.app` before checking. Run CLI examples from the repository root; the CLI does not start Hidhogg automatically.

| Check | Steps | Expected |
|---|---|---|
| Brightness | Device settings below deck: try 1, 25, 60, 100; reconnect | Visible levels change and saved preference reapplies. Sent means transport completion, not readback. Unset stops overriding; it does not restore old brightness. |
| Images/titles | Normal and wide key: import image; change size 15→24→20, colour, vertical placement and Left/Center/Right alignment | Only title changes size; grid stays fixed. Preview and deck agree. Saved styles persist after reopening. |
| Button scripts | Add `demo.true`, executable `/usr/bin/true`, no arguments; bind a key to it and press | Recent automation shows execution ID, success and exit 0. Direct execution does not need keyboard permission. |
| External trigger | Run `./dist/hidhoggctl actions invoke demo.true`, then `actions history` | Response includes execution ID; history reports outcome. No automatic retries. |
| Notifications | Inspector: subscribe to `demo.*`. Notifications page: enable listener; publish `demo.build`, then use CLI below | Temporary title appears in app/deck; live feed shows text, profile, controls and outcome. Metadata history omits text. `*` matches across dots. Disabling listener clears live text. |
| App profiles | Add an app; set a different tile appearance and action; switch between that app and an unmapped app | Both appearance and actions switch automatically. Editing a different profile does not change the runtime profile. Unmapped apps use defaults. |
| Tile presets | Save selected tile with/without action; apply to another tile; change the original; Copy/Paste and Export/Import | Applied tiles are independent copies. Shared images survive import. Optional actions require review; importing never runs them. Existing IDs cannot be silently overwritten. |
| Management pages | Open Actions, Tile presets, Notifications and Settings; resize and return to devices | Pages remain readable; inspector stays specific to selected device control. Device-wide settings remain below the deck. |
| Script editor | Select scripts in the inner left list; use + twice while drafting; save/remove a disposable script | Right editor loads the selected script; + always starts a clean draft. |
| Script history | Invoke via CLI and physical control; expand history; follow a device origin; clear history while a harmless action runs | Trigger profile/control or CLI/API is shown; device link opens its editor. Clear removes records without deleting scripts or stopping work. |
| Compact notification rows | Copy a topic; follow profile/control links; dismiss one notification, then Clear Active Notifications | Topic/text and profile/controls are compact single rows; copy retains full topic; clearing restores tile content. |
| Shared appearance | Choose Apply Appearance to Other Tiles and select font/background only, including an app profile | Other 13 tiles receive only chosen style properties in that profile. Labels, images and actions remain unchanged. |
| Notification text | Send several words to square/wide tiles at a large configured font size; try one very long word | Size shrinks to fit and wraps between words. Overlong words/overflow use ellipsis rather than character wrapping. |
| Independent presets | Without selecting a device tile, use New Preset; set text/colors/image/style and an optional action; save/edit twice | Draft changes stay local until Save. Preset edits do not alter already-applied tiles. Native/executable action snapshots remain fixed until explicitly replaced. |
| Compact Notifications | Open Notifications and leave Test closed; toggle Listen; open/close Test | History is visible by default and fills the main pane. Test publishing stays in a popover. Turning Listen off removes text, retaining metadata. |
| Native media/volume | Create Play/Pause, Next/Previous, Volume Up/Down/Mute and Set Volume actions from New; bind controls or invoke via CLI | macOS handles the paired media keys. Relative volume uses system steps; Set Volume targets the current output. Unsupported outputs show a real action failure. Check your actual media apps/output devices. |
| Bell/sound/openers | Create Bell and Play Sound, Open Application/File/URL actions; choose disposable targets; invoke explicitly | No effect when selecting a template or saving. Invoking performs the selected operation. A new app-owned sound replaces the previous one; cleanup stops it. |
| Deck notification/shortcut templates | Create a static notification with a subscribed topic and a named shortcut; invoke from a control and CLI | Notification routes through the same topic/history lifecycle. Shortcut uses existing input permissions. No notification content is interpolated into either action. |
| Knob gesture buttons | Select a knob; select Press, Rotate Left and Rotate Right at narrow/wide inspector widths | All three choices are visible directly with a gold selected state. Hold+Rotate is absent from the inspector; existing saved held bindings are preserved. |
| Direct assignment | Press Record Shortcut and cancel/record; open Choose Action, search, cancel/select; clear an assigned value | Opening/cancelling preserves the old binding. Record starts capture immediately; selecting assigns without running. Clear appears only for an assigned binding. Labels stay readable at the initial inspector width. |
| App-specific clearing | In an app profile with an inherited action, Clear; then Use All Apps Default | Clear creates a disabled override only for that app. Use All Apps Default removes the override and restores inheritance. |
| Notification lifecycle | Wait for TTL; emit twice and clear the earlier ID; press a notified key | TTL restores the configured image/title. Stale clear preserves replacement. Press dismisses the captured instance before its static action. |
| Lifecycle | Quit/reopen; try status/history; check mouse bindings | One app instance, working endpoint, no replayed notifications or queued scripts after termination. |

```sh
./dist/hidhoggctl status
./dist/hidhoggctl notifications emit --topic demo.build --text "Build finished" --ttl-seconds 5
./dist/hidhoggctl notifications history
./dist/hidhoggctl actions history
```

To clear, copy `notification_id` from emit and run `./dist/hidhoggctl notifications clear UUID_FROM_RESPONSE`. For a timeout check, create a disposable action with executable `/bin/sleep`, one argument `10`, timeout 1; its owned child should time out. Use a harmless action for initial checks.

## Execution and endpoint decisions

Executables use absolute paths and literal arguments, without implicit shell expansion. Their environment is deliberately empty: scripts needing PATH, HOME or custom variables must establish them explicitly or use absolute paths/interpreters. Output is discarded; histories retain IDs/status/exit codes, not arguments or notification text. Timeout/cancellation targets the direct child; descendant cleanup is not promised.

The API is a private same-user Unix socket, not a network listener. Existing or crash-stale endpoints are rejected rather than deleted automatically; report the app automation status if startup fails. After a CLI timeout/disconnect, outcome may be unknown; inspect history instead of automatically retrying a consequential action. Assets are stored beside the active TOML. New binaries read old configurations; old binaries are not promised to accept the added strict fields.

## Earlier appearance/automation verification record

- Focused integration: 69 XCTest + 15 Swift Testing passed, including configuration compatibility, routing/clear, held writes, fake action dispatch and wire/store/queue checks.
- Full pre-preview baseline: 279 XCTest executed, 2 intentional native skips, 0 failures; 201 Swift Testing passed (478 ordinary passes).
- Preview/UI follow-up: 14 focused tests and both native window tests passed at 820×560 and 1280×800.
- Final stored-image bound: 9 appearance tests passed, including oversized stored-PNG rejection. Full/native not repeated for that targeted safety change.
- Strict app/CLI signatures and CLI help checked. Physical/process acceptance remains this checklist.

[Implementation decisions and review corrections](d200x-parity-implementation.md).

Current DX-08 verification and decisions are tracked in [workspace evolution](d200x-workspace-evolution-plan.md). The topic-only contract deliberately has no `source`/`--source`/`notification_sources` compatibility alias; use the current CLI examples.

Owner confirmed existing notifications and script actions functional on 2026-10-23. This is partial acceptance of that baseline; the new usability/history checks above remain separate. Notification payload interpolation into actions is deferred to DX-09 / TaskView475.

## Owner confirmations and follow-up — 24 October 2026

Owner confirmed inline action search and native media controls working. Other catalog effects are not implied by media acceptance.

| New check | Expected |
|---|---|
| Wide title size | Same font setting gives comparable apparent text size on square and wide tiles, including notification text; images retain previous sizing. |
| Dial brightness | With explicit brightness below100%, turn each dial, including an unassigned one. Saved brightness reapplies after activity settles; rapid rotation is coalesced. No override means no automatic brightness writes. Brief device-side brightening may still occur. |
| Reconnect | Saved brightness applies on connection; disconnect during rotation does not send delayed writes to a disconnected session. |

## Retained sleep trial — 26 October 2026

1. Reopen the trial build and set an easily visible saved brightness. Put the Mac to sleep; check whether the deck stays black immediately and after its usual screensaver delay.
2. Wake the Mac; check that the page and saved brightness return, then repeat sleep/wake quickly. No deliberate HID disconnect is expected, but OS USB removal/read failure can still require recovery.

This trial pauses GETBASE and sends transient brightness0 without persisting0 in configuration. It does not yet implement lock/screensaver switching, the proposed100/10/10s idle policy, or physical wide-tile calibration. Firmware behavior at0 and host sleep-notification timing are physical acceptance gates; fake tests cannot establish them.

Wide horizontal calibration trial26October: afterreopening build03ca0bb45c48, compare physical wide text width with squaretitles. Devicewide text is20%narrower; height/alignment/app-preview unchanged. Check both ordinarylabel and notificationtext. Report whether it remains too wide or is now too narrow;0.8factoris an initial empirical trial.

458×196wide trial26October: reopenbuild3a7adfa11f7b; compare ordinary andnotification textedges on thephysicalwide tile. Confirm acceptedheight/width/alignment remain and whether anti-aliasing improves; report cropping/blur/different proportions. Preview deliberately stays unchanged. Firmware1:1mapping is not established by offlinechecks.


## Temporary screensaver preview — 28 October 2026

1. Select the revised `docs/product-redesign/screensavers/hidhogg-default.jpg` at default crop. The logo should sit entirely inside the bottom-right wide screen; the app guide should not appear on hardware.
2. Confirm replacement. The large app image should disappear; the deck should show the screensaver for approximately five seconds after transfer, then return to current tiles and selected wide mode.
3. Change crop/zoom after confirmation. The updated image should appear on the deck, with a fresh five-second interval after each completed transfer. Use Preview on Deck to repeat an unchanged crop.
4. During preview, lock/sleep/disconnect. No delayed restoration should wake the deck. Unlock/wake/reconnect should restore the appropriate current active layout without automatically uploading the screensaver again.
5. Check notification/profile changes during preview are reflected when the current active layout returns. A different selected image should require its own confirmation.

These are owner-run acceptance checks; no agent-operated physical writes establish them. Restoring tiles does not restore the previous saved screensaver image.


## Mode-switch correction and retained image — 28 October 2026

- Select CPU/RAM/GPU, then Clock face, then Custom tile, then another clock/date mode. Each selection should replace the previous wide layout, not leave telemetry with zero counters. Repeat after reconnect.
- Send a screensaver image, expand Screensaver preview, navigate away/back, then restart the app. The same last-sent image should remain available in the collapsed accordion without sending it again. Images sent before this build were not cached; send once to retain a preview.

The accepted protocol probe requires numeric fields for ignored counters in nontelemetry modes. Empty-field parsing is the leading explanation for the reported hardware symptom; physical correction is not proven by offline tests.
