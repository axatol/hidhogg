# Ulanzi Studio D200X interoperability analysis

Status: bounded static and dynamic research complete; offline `0x0009` payload analysis remains
Updated: 2026-09-03

## Scope and boundaries

This record covers bounded static analysis of the owner's lawfully installed Ulanzi Studio application, repeated connection observations, and controlled trials from authorized disposable copies, solely to understand D200X interoperability. The installed application remained untouched; only disposable copies were launched. Analysis excludes unrelated application data, accounts, telemetry, assets, protection bypass, patching, and redistribution. Temporary owner-only captures are retained only for active analysis and review.

Repository evidence may contain hashes, executable offsets, symbol/import names, implementation-neutral pseudocode, byte contracts, and competing interpretations. It must not contain proprietary source, extracted assets, personal content, or substantial decompiled expression.

## Evidence taxonomy

- **Encoded fact:** a byte or control-flow property independently established from the identified specimen.
- **Observed chronology:** ordering seen in one capture or code path, without a causal claim.
- **Hypothesis:** a proposed meaning or dependency that retains alternatives.
- **Causal claim:** reserved for controlled, repeated intervention with an observable changed outcome.

## Initial bundle inventory

| Property | Observation |
|---|---|
| Installed bundle | `/Volumes/Data/Applications/Ulanzi Studio.app` |
| Bundle identifier | `ulanzi.UlanziStudio` |
| Main executable | `Contents/MacOS/UlanziDeck` |
| Executable format | Thin arm64 Mach-O |
| Build system evidence | `Info.plist` says Qt/QMake |
| HID dependency | Bundled `libhidapi` dylibs |
| Signing team identifier | `8R4USXARG4` |
| Code-signing mode | Hardened runtime flag present |
| Declared application version | Not present in the inspected `Info.plist`; unresolved |
| Main executable size | `57,231,952` bytes |
| Main executable SHA-256 | `b64e598411c0d67fc44b08b09820e0b5fea12ce26052c44098e96bbd9b2c3022` |

The bundle declares broad macOS usage descriptions. Static work therefore must not launch the application; any later dynamic analysis requires a separate decision and an isolated procedure.

## Priority questions

1. Where does the main executable construct the `7c 7c` D200X frame and call `hid_write`?
2. What payload schemas and caller preconditions exist for `0x0003`, `0x000b`, `0x000d`, and `0x0011`?
3. How are inbound `0x010b` and `0x0303` decoded or correlated?
4. Which ordering is intrinsic to a constructor, and which ordering is merely asynchronous application chronology?

## Specimen handling

The installed main executable and the analysis copy at `/private/tmp/hidhogg-ulanzi-static.4dGB6z/Ulanzi Studio.app` have the same SHA-256. Two unreadable bundled `.DS_Store` files prevented a complete `ditto` copy. A second copy excluded only `.DS_Store`; its executable bytes are verified, but `codesign --verify --deep --strict` rejects the copied bundle. The copy is suitable only for static executable analysis and must not be launched. The installed bundle was not modified or launched.

## Encoded transport findings

These facts come from arm64 disassembly of the identified executable:

- `HIDDevice::sendDataToDeck(uint8_t, uint8_t, const uint8_t *, size_t)` is present at virtual address `0x100030184`. It constructs an eight-byte logical header containing bytes `7c 7c`, the two command bytes in call-argument order, and a 32-bit native little-endian payload length, followed by a payload pointer in the in-memory `DeckFrame` object.
- `HIDDevice::writeFrame(hid_device *, DeckFrame)` is present at `0x1000302fc` and calls the imported `_hid_write` stub at `0x100030648`.
- The writer builds `header || payload || 00 00`, then zero-fills to a multiple of 1,024 protocol bytes. Its rounding expression always adds between 1 and 1,024 bytes after the eight-byte header, payload, and two NUL bytes.
- Each HID call prepends report ID `00`, copies at most 1,024 protocol bytes, and passes a maximum length of 1,025 bytes to `hid_write`. The loop advances by the successful return count minus the report-ID byte.
- The executable directly imports `hid_write`, `hid_read_timeout`, `hid_open_path`, enumeration, close, and related functions from bundled `libhidapi.0.dylib` version `0.14.0`.

These findings independently corroborate Hidhogg's magic, byte order, report ID, and packet size. They do not establish device acceptance, retry safety, or a causal command order.

## Small-window call-path finding

- `UlanziDeck::SendSmallWindowData()` at `0x1005119dc` builds a context string and dispatches a QtConcurrent task.
- That task's `runFunctor()` at `0x100546e98` calls `UlanziDeck::SendSmallWinInfoToDeck` with command bytes `00 06` and the generated string.
- `UlanziDeck::sendBackgroundBrightness()` is not the mode-`2` constructor: it obtains the configured brightness, converts it to decimal ASCII, and its task carries command bytes `00 0a`. Its name describes brightness associated with the background state, not command `0x0006` mode semantics.

This establishes constructor identity and command bytes. The QtConcurrent scheduling is observed control flow, not proof of required packet chronology.

## Display-upload call-path findings

- `UlanziDeck::SendKeyZip(...)` at `0x1005027d8` first checks that its generated file path exists, then calls `UlanziDeck::SendDataToDeck(...)` with command bytes `00 0d` at `0x100502a74`.
- `UlanziDeck::SendKeyZipFromCurrentPage(...)` resolves exactly one profile for the selected device/key, wraps it in a one-element list, calls the same archive builder, and sends command `00 0d` at `0x10053cae0`.
- `UlanziDeck::SendCurrentPageZip(...)` passes its supplied current-page profile list to that archive builder and sends command `00 01` at `0x100518024`.
- `UlanziDeck::SendSmallWindowData_Knob()` at `0x100511c6c` compares the active small-window page with decimal `100`. In mode `100`, it selects the current page's profiles with bean type `Encoder`, calls the common archive builder, and sends command `00 11` at `0x100511ef4`. Outside mode `100`, it tail-calls the ordinary `SendSmallWindowData()` path instead.
- The `0x0001`, `0x000d`, and mode-`100` `0x0011` paths all call `ItemBeanProfileManager::createZip(...)` with callbacks that delegate to `UlanziDeck::fillEncoderJson(...)`. They therefore share one ZIP/manifest format; their encoded distinction is the selected profile set and outbound command.
- `fillEncoderJson(...)` asks the plugin proxy for the profile layout. A non-empty layout is converted with `PluginLayout::toDeviceJson()` and stored as `Encoder`; an empty result follows the ordinary `ViewParam` plus `State: 0` branch.
- `createZip(...)` creates `manifest.json` and `Images/`, generates UUID image names, copies or renders PNG/GIF assets, inserts `Text`, `Font`, and optional `Icon`, and calls `JlCompress::compressDir`. It adds `SmallViewMode` only for the `com.ulanzi.ulanzideck.smallwindow.window` component or key `3_2`.
- `SendDataQueue::GenerateBufferEx` opens the generated path as `rb`, allocates exactly the file length, and reads the entire file unchanged. `SendDataQueue::sendToDeck` passes those bytes and that length directly to `HIDDevice::sendDataToDeck`.

These paths establish that `0x000d` and the mode-`100` branch of `0x0011` carry the same conventional ZIP schema observed in the connection-time `0x0001` capture. Minimal accepted fields, replacement versus additive firmware behavior, coordinate semantics, and whether either command is required outside its Studio path remain unresolved because those are device-side causal questions.

## Device-connect and inbound-frame findings

- `0x0003` is emitted with empty data/path arguments from at least `OnDeviceChanged` (`0x100510404`), `handleDeviceConnected` (`0x10051268c`), `OpenSetting` (`0x10052d4f0`), and the `CheckScreenStatus` slot path (`0x100550140`). `SendDataQueue::sendToDeck` initializes a zero pointer and zero length and only calls `GenerateBufferEx` when the supplied string is non-empty. These call paths therefore encode `0x0003` with a zero-length payload.
- `UlanziDeck::handleDeviceConnected(QString const&)` at `0x100512218` obtains `DeviceManager::fontStyler()`, serializes that `QJsonObject`, and passes the resulting string to `SendSmallWinInfoToDeck` with command bytes `00 0b` at `0x100512f5c`. This identifies the observed `0x000b` payload as font-style configuration sent during device connection. The earlier static-only inference that the serialization was compact JSON was wrong; the full-payload capture below establishes indented JSON.
- `UlanziDeck::OnDeckFrameReceived(DeckFrame, QString)` at `0x100513cbc` dispatches first on frame byte 3 and then, for the relevant branches, on frame byte 2. This is consistent with the established command-byte order.
- The `01 0b` branch obtains the current `DeviceManager::fontStyler()` object and calls `OnDefaultFontChangedEx(..., true)`. That function serializes and sends the current style as outbound `0x000b`; the inbound payload is not parsed. In Studio, `0x010b` is therefore a device-originated request that triggers font-style retransmission, not an acknowledgement whose payload is correlated with a prior request. The device-side condition that emits it remains unknown.
- The separate `01 01` branch reads the first four payload bytes as one little-endian word. Its diagnostic path separates bytes 0 through 3 as key, position, type, and status. Subsequent code uses these values to route key and encoder actions. This is encoded field extraction; the semantic labels are corroborated by the retained diagnostic format string.
- The `03 03` branch treats the payload as a NUL-terminated UTF-8 JSON string, passes it through `ParsingJson`, and invokes device-profile migration/initialization and `setDeviceInfo` paths. `ParsingJson` extracts `SerialNumber`, `Dversion`, and, when present, `HardwareVersion`; it lowercases the serial, validates its expected 17-character form before substring-based device/profile lookup, and stores the parsed firmware and hardware versions. No corresponding read of the captured `DeviceType` or `error` keys was found in this path.
- A frame whose second command byte is `03` but first command byte is not `03` calls `SendCurrentPageZip`. The expected first byte appears to be `00`, but the compiled comparison accepts every non-`03` value; no broader protocol guarantee is inferred.

These findings establish application dispatch behavior, not device-side causality. In particular, they do not prove that `0x0303` is the only possible device-information response or that a preceding outbound command is a required trigger.

## End-to-end static write boundary

The independently cross-checked native path is:

```text
UlanziDeck command path
  -> UlanziDeck::SendDataToDeck
  -> SendDataQueue::enqueue
  -> SendDataQueue::sendToDeck
  -> HIDDeviceManager::sendDataToDeck
  -> HIDDevice::sendDataToDeck
  -> HIDDevice::writeFrame
  -> hid_write
  -> bundled hidapi
  -> IOHIDDeviceSetReport
```

The main executable's imported `hid_write` stub is at `0x1007541c8`; `HIDDevice::writeFrame` calls it at `0x100030648`. The bundled `libhidapi.0.dylib` implementation reaches `IOHIDDeviceSetReport`. The corresponding read loop calls `hid_read_timeout` at `0x100031454` with a 1,024-byte buffer and a 100 ms timeout. These are application implementation details, not recommended timeout or retry requirements for Hidhogg.

## Bounded dynamic connection observation

Two connection-only trials were captured on 2026-08-30 at `HIDDevice::sendDataToDeck` and `UlanziDeck::OnDeckFrameReceived`. LLDB recorded outbound command words and lengths, inbound eight-byte headers, and at most eight stack frames. It did not read payload contents. Target stdout and stderr were discarded.

The disposable executable was identical to the installed specimen before signing. After ad-hoc signing, its whole-file SHA-256 was `b3100c522bbbf8398708579ddb8d2dd778432850fab81d7f53f54a5048181ecf`; its `__TEXT,__text` SHA-256 remained `5a07a3228e601d32c5996c758ca3558c39180f06b80438e6dc40ad2970a58e90`, identical to the installed specimen's machine-code section.

Both valid trials produced this identical initialization prefix:

| Sequence | Direction | Command | Length | Observed application origin |
|---:|---|---:|---:|---|
| 1 | outbound | `0x0003` | 0 | `SendDataQueue::sendToDeck` |
| 2 | outbound | `0x0001` | 5,633 | `SendDataQueue::sendToDeck` |
| 3 | outbound | `0x000b` | 144 | `SendSmallWinInfoToDeck::$_2` |
| 4 | inbound | `0x0303` | 1,014 | `OnDeckFrameReceived` |
| 5 | outbound | `0x000a` | 2 | `SendSmallWinInfoToDeck::$_2` |
| 6 | outbound | `0x0003` | 0 | `SendDataQueue::sendToDeck` |
| 7 | inbound | `0x0303` | 1,014 | `OnDeckFrameReceived` |
| 8 | outbound | `0x000a` | 2 | `SendSmallWinInfoToDeck::$_2` |

After that prefix, both trials repeatedly emitted outbound `0x0006` from `SendSmallWinInfoToDeck::$_1`. T01 observed five 26-byte occurrences; T02 observed six 25-byte occurrences. The count reflects unequal observation duration. The one-byte length difference is verified, but its cause is unknown because payloads were excluded; a data-dependent text or metrics field is only a hypothesis.

T01's owner-only transcript is 17,664 bytes with SHA-256 `701074ad46011e6e6baf0fc6fa99b9626731dad912a8863f68f5c96f43812005`. T02's is 17,682 bytes with SHA-256 `afcc34ae8079b195c03014614bd9df356d9ac1aae6101711b78ef2d2f3dc85f5`. They remain outside the repository under `/private/tmp/ulanzi-lldb.m4xHv3/` for owner review and may disappear after reboot.

This evidence establishes repeated application chronology only. It does not establish that network access was required, that the D200X causally required the order, or that the same sequence is stable across application state, firmware, or device profiles. Earlier launches with debugger denial, sandbox initialization failure, or faulty LLDB breakpoint-command retention are rejected harness runs and are not protocol evidence.

## Full-payload connection repeats

After the owner expanded the inspection boundary, two fresh launch-only trials, `T01P` and `T02P`, captured every non-empty D200X logical payload in the connection sequence. The application executable again matched the installed specimen before ad-hoc signing, and the signed copy retained the installed specimen's `__TEXT,__text` SHA-256. Raw captures are owner-only under `/private/tmp/ulanzi-lldb-payload.zSRQIR/` and may disappear after reboot; no packet, device identifier, profile asset, or proprietary application content was added to Git.

| Direction and command | T01P / T02P lengths | Captured content | Repeat result |
|---|---:|---|---|
| outbound `0x0003` | 0 / 0 | No payload | Stable empty payload |
| outbound `0x0001` | 5,634 / 5,632 | Conventional ZIP containing `manifest.json`, `Images/`, and four 196×196 RGBA PNG entries | Raw archives differ; normalized logical content is stable |
| outbound `0x000b` | 144 / 144 | Indented UTF-8 font-style JSON | Byte-identical |
| inbound `0x0303` | 1,014 / 1,014 | 149-byte UTF-8 JSON object followed by 865 NUL bytes | All four captures byte-identical |
| outbound `0x000a` | 2 / 2 | ASCII `44` | All four captures byte-identical |
| outbound `0x0006` | 26 / 26 | ASCII `100|CPU|RAM|HH:mm:ss|GPU|12H|` with decimal live values | Grammar stable; values vary with metrics and time |

The exact captured `0x000b` object is:

```json
{
  "Align": "bottom",
  "Color": 16777215,
  "FontName": "Source Han Sans SC",
  "ShowTitle": true,
  "Size": 10,
  "Weight": 80
}
```

Its byte-level SHA-256 is `1b1d9b3dcaf219585488071ece82f3a98b9cbb32c890149867dda51be30cbebc`. The individual field meanings are strongly suggested by their names, but allowed values, required fields, and firmware defaults have not been isolated by single-property trials.

The `0x0303` JSON contains `SerialNumber`, `Dversion`, `error`, `DeviceType`, and `HardwareVersion`. The observed non-identifier values were firmware `5.3.1`, error string `0`, device type `D200`, and hardware version `SSD210V100`. The serial value is intentionally omitted from the repository. The common full 1,014-byte payload SHA-256 is `9fc85325ef5f80e87a6a042e8cf4bf196a95360a905872ec33ef7ddc62e19a4e`. One device does not establish field optionality, maximum lengths, or other-firmware values.

The `0x0001` archive manifest is a top-level position-keyed object. Ordinary entries contain `State` and a `ViewParam` array with `Font`, optional `Icon`, and `Text`. One observed encoder entry contains two render items: a 100×100 pixmap and a text title. One small-window entry contains `SmallViewMode: 100`. The four PNG contents form the same SHA-256 multiset in both trials, including one duplicated image. After sorting JSON keys and replacing generated image UUIDs with a stable token, both manifests have SHA-256 `f35628660a902c3af7b455cfd64c1376f0ef4cb15e78134b8cc4ae276d39e260`.

The raw `0x0001` archives have SHA-256 values `8b8a1bca6b4168b51cda8a50b01fe5c1d772c0e45960788192aaa749b0c2e958` and `6bddbb0182f2e9c1f57db815d98778277c6774566aeaa422f85adf6510382abe`. The difference is explained by regenerated image UUIDs, entry order, archive timestamps, and the resulting compression stream; it is not evidence of a logical profile change.

Observed `0x0006` examples include `100|41|79|14:22:21|33|12H|` and `100|21|76|14:36:00|26|12H|`. This grammar explains why the metadata-only trials saw both 25- and 26-byte messages: unpadded decimal metrics make the payload length data-dependent. The exact values from those earlier metadata-only trials cannot be recovered.

T01P and T02P required manual stops and binary dumps at each breakpoint. That intervention measurably perturbed asynchronous ordering, so these repeats are authoritative for payload bytes and structure but not timing. The earlier auto-continue T01/T02 trials remain the stronger chronology evidence. The payload repeats do not establish device-side causality, required ordering, accepted schema variants, or whether Studio's network access affected any field.

T01P's transcript SHA-256 is `bb33adc27792dbde7450794087f3b9c3d51d5c80e532f8e835465e5cc1370c60`; T02P's is `437a27ad8bfc928b7f1cbc0fd79bcf0ac1ab39436e7ca2947de5a8b3130bfea9`. The exact disposable root was removed after both targets ended and the evidence was hashed; the installed application and owner-only evidence workspace remain.

## Controlled targeted-key upload trials

Owner-driven T05-T07 trials on 2026-08-30 used one built-in `System -> Text` action at `0_0`. Studio does not permit a text-only tile and has no save/submit boundary: display-affecting edits transmit immediately. The fixed action string did not hit either verified `0x000d` producer; assigning the action, changing its displayed title, deleting it, and moving it did. No physical tile press occurred.

| Capture | Action | Bytes | Raw SHA-256 | Normalized manifest SHA-256 |
|---|---|---:|---|---|
| `001` | Assign Text action at `0_0`, empty title | 1,667 | `b829f5d042ee700e5416022c8a6d1b77b9327ae985cf50acb86859054af992db` | `bea56ee23c560434e360b7cc320cc0745c7af1ab1d3697507457c900642d83df` |
| `002` | Set title `HIDHOGG-T05` | 1,678 | `7290ee577df63d594d07150d50864f9190ab1f3ff10c98dabcef716ef81eb639` | `ae3868662d6421c509e01f499ec505d6e4bc9da3b76bd323d321a2ff58714251` |
| `003` | Change only title to `HIDHOGG-T06` | 1,679 | `18ec79b5a9aa05de40cd885f14ea5d525f499484bf7502b477c9f2bcf6ad5b25` | `c459f1cfe6fa85894aff874a0f0134b48a9f6f44ce9c9cc3bdea67f0de4e41e1` |
| `004` | Accidental delete at `0_0` | 299 | `df645658c4fb286a49b2ff33f71c50fe5d4610023113d7ddc62b55d834f8b8b3` | `ac2163d44aad89eb03d3d15469b0e61f280a59e646bd4b04729338c3221d4008` |
| `005` | Reassign Text action at `0_0`, empty title | 1,667 | `f7f09edd61ec2dc90b01f8bca426b955a3ada35af140c61466355196eb3ebcf3` | `bea56ee23c560434e360b7cc320cc0745c7af1ab1d3697507457c900642d83df` |
| `006` | Restore title `HIDHOGG-T05` | 1,680 | `695d84efea833498c856caf46bc9a80be10be313202efae393df21be2207d550` | `ae3868662d6421c509e01f499ec505d6e4bc9da3b76bd323d321a2ff58714251` |
| `007` | Move first packet: add at `1_0` | 1,678 | `d2279efb7b7ec937cf74a853d6cf70367a6a0cbb577a21bea4a711cbd335259c` | `474b710ee0e8642f189b1117b2f11368e30bc042c592a314ba5029f81d3a4c29` |
| `008` | Move second packet: clear `0_0` | 299 | `11b5583cd4c90a8407e10e91bad5b3f3bae5e382e20c6cd6d2794671637a0489` | `ac2163d44aad89eb03d3d15469b0e61f280a59e646bd4b04729338c3221d4008` |

All non-empty-icon captures contain the same bundled PNG bytes, SHA-256 `9137b7981ab83b9e2034a892dda78ee2fa00684b7f85f1e6685f351bf5d0ef88`; Studio regenerates only the UUID filename. Captures `001`/`005` and `002`/`006` are logically identical repeats after UUID normalization. Equal-length title changes altered only `ViewParam[0].Text`; raw ZIP sizes still varied because generated filenames, timestamps, ordering, and compression are nondeterministic.

Deletion and the second move packet use an explicit position tombstone rather than omitting the key:

```json
{"0_0":{"State":0,"ViewParam":[{"Font":"","Text":""}]}}
```

The move emitted the new-position content packet before the old-position tombstone in this manually observed run. This is observed application chronology, not a required firmware ordering claim. The successful display transmissions establish Studio's emitted schema and controlled deltas; no independent device-side replacement/additive outcome was recorded.

The same tile editor visibly exposes title visibility, numeric size, color, and three alignment controls. These are verified candidate inputs for later one-property font trials; their accepted ranges and exact packet effects remain untested.

Raw captures remain owner-only under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T05-one-key-upload/`. The active disposable copy at `/private/tmp/ulanzi-lldb-runnable.zII2q5/` passed strict signature verification and retained the reviewed `__TEXT,__text` SHA-256 `5a07a3228e601d32c5996c758ca3558c39180f06b80438e6dc40ad2970a58e90`.

## T08 controlled mode-100 encoder upload

Static disassembly corrected the initial trigger assumption. Assigning or removing an encoder action does not itself invoke `SendSmallWindowData_Knob()`. `SystemSmallWindowsEditor::selectSmallWindowMode(int)` emits `SignShowSmallWindows(int)` at `0x1003776b0`; the connected `UlanziDeck::OnShowSmallWindows(int)` at `0x1005251e8` tail-branches to `SendSmallWindowData_Knob()` at `0x100511c6c`. When the stored page mode is decimal `100`, that function sends `00 11` at `0x100511ef4`. The captured stack independently followed `QButtonGroup::idClicked(int)` through `onButtonIdClicked`, `selectSmallWindowMode`, and `SignShowSmallWindows` to this callsite.

The owner established a one-action profile before the evidence interval: knob 1 contained the built-in Multimedia action, while knobs 2 and 3 were empty. With the `0x0011` breakpoint disabled, Studio was switched to the `Time` radio mode and allowed to settle. Selecting the Studio `Knob` radio then produced exactly one outbound `0x0011`. The same controlled `Time` to `Knob` transition was repeated once from the same logical profile and again produced exactly one outbound `0x0011`.

| Capture | Bytes | Raw ZIP SHA-256 | Normalized manifest SHA-256 | PNG SHA-256 |
|---|---:|---|---|---|
| `001` | 1,866 | `a6fec39aa40a0af7e09199eb0776aaac88a99b86ebfe30ab7def6bb3c8dd7c5b` | `857ae8ca6cb399c424c70e2c2d3f811888e024b39cbaa82e9cb1804aabddccf5` | `12eef5f47405971014f91b2696a8960b64a28274f4c1f8f661a93bc585bcfcee` |
| `002` | 1,866 | `51b775bef3829715093ee2cc64785c38dc99a472fde292a1deddb48b04238bef` | `857ae8ca6cb399c424c70e2c2d3f811888e024b39cbaa82e9cb1804aabddccf5` | `12eef5f47405971014f91b2696a8960b64a28274f4c1f8f661a93bc585bcfcee` |

Both ZIPs contain one 196-by-196 RGBA PNG and the same logical manifest. The generated PNG UUID and ZIP timestamps differ. The manifest establishes the encoder coordinate mapping for this device layout:

```text
2_3  knob 1  Encoder: Multimedia
3_3  knob 2  State: 0 tombstone
4_3  knob 3  State: 0 tombstone
```

Thus `0x0011` includes explicit empty entries for unassigned encoder positions rather than omitting them. The two normalized captures establish reproducible Studio emission for this controlled profile. They do not establish minimal firmware-required fields, firmware necessity, or ordering relative to periodic `0x0006`. The visible device outcome was not separately recorded during these debugger-stopped trials. Raw T08 captures remain owner-only under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T08-mode100-encoder/`.

## T03 controlled title-alignment delta

The retained action-backed tile at `1_0` had title `HIDHOGG-T05` and font state `Align: bottom`, white, size 10, weight 80, `ShowTitle: true`, and `Source Han Sans SC`. Changing only the Studio alignment control from bottom to center produced exactly one outbound `0x000d`. A second controlled bottom-to-center transition also produced exactly one.

| Capture | Bytes | Raw ZIP SHA-256 | Normalized manifest SHA-256 | PNG SHA-256 |
|---|---:|---|---|---|
| `001` | 1,680 | `adad5b593ecec9d63234f57a439084af32d171320e9d25945be03c4958c24a12` | `b7fd0901a4009dc6c85c52818b61a0376cf56b6825f1a48a165cb061b6c982e0` | `9137b7981ab83b9e2034a892dda78ee2fa00684b7f85f1e6685f351bf5d0ef88` |
| `002` | 1,680 | `34069aef43536701b7d6a75edaacd699d47e2907609e5d9002f494fb0eeae8c1` | `b7fd0901a4009dc6c85c52818b61a0376cf56b6825f1a48a165cb061b6c982e0` | `9137b7981ab83b9e2034a892dda78ee2fa00684b7f85f1e6685f351bf5d0ef88` |

After normalizing image UUIDs and deleting only `Font.Align`, each center manifest equals the retained bottom baseline; the PNG bytes are unchanged. This establishes a single-field Studio archive delta for `bottom` to `center`, not a firmware-required field or accepted-value range. Raw captures remain owner-only under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T03-font-alignment/`.

## T04 controlled title-size delta

From the restored bottom-aligned size-10 baseline, incrementing the Studio size stepper once to 11 emitted exactly one 1,678-byte `0x000d` ZIP with raw SHA-256 `528e44723128470cb6d5a8136601058df7171cb0fbdd2455f9d7f957a3f30e34`. Its UUID-normalized manifest SHA-256 is `324b1d52239ea13a30570fc0aa2f310b5d8cd9f1ce65d0e20049cad387d3429b`. Deleting only `Font.Size` makes it equal the retained size-10 baseline, and the PNG remains byte-identical with SHA-256 `9137b7981ab83b9e2034a892dda78ee2fa00684b7f85f1e6685f351bf5d0ef88`. This establishes a single-field Studio delta for size 10 to 11, not a supported range or firmware requirement. Raw evidence remains owner-only under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T04-font-size/`.

## T12 controlled wide-background image

The Studio wide tile is profile position `3_2`. A successful click on its `Background` radio entered `SystemSmallWindowsEditor::selectSmallWindowMode(int)` with argument decimal `2`, proving the UI-to-mode mapping. The device displayed a blank wide tile while no background image was configured. An exact one-shot filter observed no immediate outbound `0x0006` with payload `2|` during the following bounded interval; this does not exclude that payload on another timer or call path.

Selecting an image opens a distinct `Edit Icon` dialog with crop/preview, re-upload, Save, and Cancel controls. Unlike ordinary tile-display edits, no captured `0x000d` was emitted until the owner clicked Save. Save emitted exactly one 1,608-byte `0x000d` ZIP with raw SHA-256 `46459ca4ef76e40a12d99aaaec1a3e94b778e109885f5b842228c9e54e296041`. Its UUID-normalized manifest SHA-256 is `702b3c098adf364f3e9d2a27e8deea04cdbf081f466427f65d5516f962179418`:

```json
{
  "3_2": {
    "SmallViewMode": 2,
    "State": 0,
    "ViewParam": [{
      "Font": {
        "Align": "bottom",
        "Color": 16777215,
        "FontName": "Source Han Sans SC",
        "ShowTitle": true,
        "Size": 10,
        "Weight": 80
      },
      "Icon": "Images/<uuid>.png",
      "Text": ""
    }]
  }
}
```

The project-owned source was a 458-by-196 RGB PNG with SHA-256 `4d728692a942d2f12c91e7d488f5315c4e6dc67d98c4fb6a93d2b7c43d395094`. Studio preserved those dimensions, converted it to RGBA, and applied transparent rounded corners; the resulting 1,512-byte PNG has SHA-256 `fa6a18eda0dc3d06231c44293d21cc0b8a30d9fe83f42a9cea4d0f25be05591d`. The owner confirmed correct full-width orientation with no unexpected cropping or stretching. Intermediate colour bands were already present in the interpolated diagnostic source and are not a device-rendering defect. Raw evidence remains owner-only under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T12-background-wide/`.

## T09-T11 controlled inbound input cross-check

The owner used an unassigned square at `0_0` and the unassigned physical middle encoder, so no configured Studio action executed. A conditional breakpoint at `UlanziDeck::OnDeckFrameReceived` captured six inbound `0x0101` frames. Every declared payload was 1,014 bytes; only the first four bytes were nonzero.

| Capture | Controlled input | First four payload bytes | Payload SHA-256 |
|---|---|---|---|
| `001` | Square `0_0` pressed | `01 00 01 01` | `8d8d8158584390de642c28ea609110a4758e1a9d5e0e761ba0b0c675ca6dca74` |
| `002` | Square `0_0` released | `01 00 01 00` | `663f5c56995bb094776d27cacbcc6ebf232bbec69cb841ba7d425cd493f17379` |
| `003` | Middle encoder left | `01 12 02 02` | `0ce99ea6b7a623731653bce6b812bda0cbed3ea9b034f84045f8b0a059f71c7b` |
| `004` | Middle encoder right | `01 12 02 03` | `3911c8f36c6888ab54b1a84620864520724dd15168ce8424f63e5180449ab142` |
| `005` | Middle encoder pressed | `01 12 02 01` | `0ce65c7cb5f8634d70225faf1bdad614e203172c3eb669eaa42e9c69aafbea80` |
| `006` | Middle encoder released | `01 12 02 00` | `13679a2d8344f42dd272457f4c9d7c132fb116d6e72a50ed4ff5c382b9d82e97` |

These Studio-side captures independently confirm the direct-probe interpretation: byte 0 is `0x01` for these input events; byte 1 is the wire index (`0x00` for square `0_0`, `0x12` for the middle encoder); byte 2 is the marker (`0x01` button, `0x02` encoder); and byte 3 is the action (`0x00` release, `0x01` press, `0x02` left, `0x03` right). Within each paired comparison, the complete payload differs only at byte offset 3. This does not prove that every firmware event uses the same first-byte value or enumerate undocumented markers, actions, or wire indexes. Raw captures remain owner-only under `/private/tmp/ulanzi-lldb-interactive.jIKQFm/T09-T11-input/`.

## T13-T14 screensaver-artwork upload

The controlled Set Image boundary emitted outbound `0x0009`. Fixture A produced a 40,982-byte logical payload and fixture B produced 130,798 bytes; their recorded hashes and lengths exactly match the retained owner-only artifacts. The owner confirmed the corresponding A and B artwork visible. Opening and cancelling the editor emitted no non-periodic command and caused no visible change.

Each `0x0009` payload is a conventional one-entry ZIP using Deflate method 8. Its only member is a `1220 × 708`, 8-bit RGB PNG with a `pHYs` chunk at 2,835 pixels per metre on both axes. A's member is 47,567 bytes; B's is 138,324 bytes. Both source fixtures were opaque RGBA PNGs, so Studio performed a re-encoding step. Controlled differences include image content, selected basename, ZIP timestamp, checksums, sizes, and resulting compressed streams.

The evidence supports the clean-room semantic candidate `EncodeScreensaverArtwork(1220×708 image) -> one-entry Deflate ZIP containing one PNG -> 0x0009`. It does not establish that RGB, `pHYs`, the selected basename, timestamp behavior, compression settings, or exact PNG bytes are firmware requirements. Alpha handling is unresolved, and the waived SS-U3 restoration means deterministic same-image encoding was not tested. Architect review therefore closes this as qualified research while deferring production `0x0009` support until after the idle-policy milestone and a separately authorized clean-room physical acceptance test.

## Automated-research boundary

The final static pass on 2026-08-30 also established that `sendBackgroundBrightness()` iterates running D200X devices, reads each device's persisted value through `DeviceManager::getBrightness(serial)`, converts it to decimal ASCII, and dispatches command `00 0a` asynchronously. This explains the captured ASCII `44` as Studio model state. Static analysis does not explain why the connection chronology invokes the path twice; the only direct call found is from Studio's screen-unlocked handler for one unlock-state value, so a broader causal claim would be speculation.

No additional unattended launch can isolate the remaining variables: the repeated connection baseline is stable, and the controlled archive, font, background, input, and screensaver-artwork trials are complete to their accepted scope. Remaining device-side causal work requires explicit owner-operated physical trials:

| Priority | Owner-controlled change | Remaining question |
|---:|---|---|
| 1 | Revised brightness-zero matrix | Which input classes remain at zero before encoder rotation restores brightness to 100 |
| 2 | Project-generated mode-100 upload | Standalone `0x0011` behavior and ordering relative to mode-100 `0x0006` |

Offline T14 analysis derived the qualified `0x0009` semantic structure. The owner waived the A-restoration repeat, so deterministic re-encoding cannot be claimed from this evidence.

Cross-firmware optionality of `0x0303` fields cannot be resolved with the single owned device/firmware specimen. This is a hardware-sample limitation, not an LLDB automation gap. Architect review agreed that further launch-only captures have low information value and that the controlled trial order above is the shortest route to causal evidence.
