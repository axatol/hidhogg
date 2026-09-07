# M-02-F01 decision review

Updated: 2026-08-31

This file records consequential idle-policy decisions for later owner review. It separates measured facts, approved experiments, and unresolved production choices.

## Verified evidence

- S0: passive device open sent zero frames, did not dismiss the visible native screensaver, and one `0_0` press/release emitted no input.
- S1: from a fresh native-screensaver generation, exactly one `enable-input-stream` (`0x0002`) frame dismissed the visible screensaver and restored the canonical `0_0` press/release pair.
- S1 establishes one-device wake sufficiency. It does not establish prevention, interval, command ordering, or cross-firmware behavior.
- C0: after one input-enable reset and immediate confirmation that the configured display was visible, the owner reported native screensaver onset 64 seconds later. A subsequent `0_0` press/release neither dismissed it nor emitted an input frame. The 64-second interval includes human reporting latency; it is the conservative observed value used for K1, not a firmware-precise transition.

## Approved diagnostic decision

The owner approved a diagnostic-only keepalive-prevention implementation on 2026-08-31 after architect review.

```text
C0: measure one no-write visible-screensaver onset T0
K1: interval I = T0 / 2
    duration D = 2 * T0
    send only 0x0002 at each monotonic I boundary
    pass only if the display remains active and final input works
```

The diagnostic must not retry, catch up after a missed boundary, or mutate production runtime behavior. A 30-minute C0 ceiling is predeclared unless new verified evidence justifies another bound.

Architect review on 2026-08-31 resolved the implementation boundary as a closed experiment rather than a general scheduler:

```text
D = 4I
D <= 60m
scheduled experimental writes = 4
```

The Go core and owner wrapper enforce these conditions before archive creation, confirmation, or HID activity. Changing the ceiling or ratio requires reviewed evidence and a new code-and-decision revision; there is no runtime override. The retained 48-boundary guard is defense-in-depth and is unreachable for a valid K1 run.

## Verified diagnostic implementation

`M-02-F01-K01` completed on 2026-08-31. The diagnostic retains one normal startup and HID session, schedules four `enable-input-stream` frames at absolute interval boundaries, never retries or catches up, and requires one final canonical wire-0 square press/release pair. A successful archive is exactly 11 ordered redacted JSONL records.

The full cgo-free Go suite, focused race tests, vet, zsh syntax, jq/Python/Ruby archive regressions, formatting, diff checks, and independent tester review passed. No physical HID result is claimed by these gates. The scheduler accepts wake jitter that remains before the next interval boundary; K1 must therefore retain actual timing evidence.

The completed owner-observed C0 derives `I = 32s` and `D = 128s` for the single K1 run.

The first K1 invocation completed all four scheduled writes, but the final at-`D` owner check was not performed promptly. The owner reported the screensaver approximately one C0 interval after the nominal final write; a subsequent `0_0` press/release neither woke the display nor produced input. The checksum-matching archive correctly records `class-failure`. It must not be reclassified as a prevention pass; architect review is required before any second invocation.

Architect review classifies the first invocation as scheduler-valid but endpoint-inconclusive. It permits exactly one clearly labeled replacement with unchanged `I = 32s`, `D = 128s`; this is replacement of an unobserved primary endpoint, not retry of a negative result. The first archive remains retained and reported.

The replacement protocol requires continuous owner observation, no interaction before `D`, a local non-chat cue, visual classification within five seconds, and—only if active—one canonical `0_0` press/release within the next five seconds. Screensaver appearance at or before `D`, uncertainty, distraction, unrelated interaction, late or failed write, missed window, or missing pair prevents a pass. No third invocation is permitted without a revised protocol decision.

The replacement completed four scheduled writes. The owner reported the display active at the spoken cue, then screensaver onset before there was enough time to press; no pair was captured. The agent-mediated cue could not be proven within five seconds of the diagnostic endpoint. The archive correctly records `class-failure`, but the replacement remains endpoint-inconclusive under the predeclared protocol. K02 is blocked; a third invocation requires an explicit revised protocol decision, not another retry.

## Approved endpoint-instrumentation revision

The owner approved the architect-reviewed `M-02-F01-K02-R01` revision on 2026-08-31. One final physical invocation is authorized only after its automatic and independent gates pass.

The diagnostic will invoke fixed absolute `/usr/bin/say` with fixed text directly from the scheduler after the fourth successful write. It exposes no command, path, text, environment, or shell configuration. Continuous capture begins before the idle schedule; a fresh caller-side boundary immediately before cue invocation starts endpoint input eligibility. Records after the completed idle interval but before that boundary are archived as `pre-cue` and affect neither idle nor endpoint classification. The logical evidence window ends exactly five seconds after successful cue completion; cue execution must finish within 12 seconds or the run is invalidated. The actual timer wake and capture stop may be at most 250 milliseconds late. Earlier closure, greater lateness, or missing timing invalidates the run. The archive must retain distinct monotonic elapsed values for cue start, cue completion, planned logical close, actual timer wake, actual capture stop, and each input. It must not substitute the planned close for an actual timestamp.

After the timed window, the owner supplies exactly one visual token: `ACTIVE_AT_CUE`, `SCREENSAVER_AT_CUE`, or `UNCERTAIN`. Only active attestation plus exactly one canonical `0_0` pair within the logical window can pass. Active with missing, wrong, reversed, duplicate, malformed, non-input, or extra evidence is `class-failure`; screensaver attestation is `class-failure` with or without input; uncertainty and missing or malformed attestation are `indeterminate`; capture or decoder failure is `indeterminate`; cue or timing failure is `invalidated`. Timing invalidation takes precedence. Records after the planned logical close remain archived but are outside endpoint classification. Every confirmed physical CLI invocation performs the same fixed cue and requires exact `CUE_HEARD` in that process before runner construction or HID activity; the wrapper records the resulting gate in metadata. Production behavior and packet bytes remain protected.

The 250-millisecond allowance is an experimental policy bound equal to 5% of the post-cue tail, not a macOS or Go timer guarantee. It may be revisited only through another reviewed decision. Exactly one further physical K1 run remains authorized with `I = 32s` and `D = 128s`, and only after revised automatic gates, independent verification, architect review, and the same-cue owner preflight pass.

Independent verification `M-02-F01-K02-R01-V01` failed because terminal input-capture failure did not stop later scheduled writes or the cue. Architect decision `M-02-F01-K02-R01-A03` therefore adds these fail-closed requirements:

- capture health is checked immediately before and after every experimental write and immediately before the cue; terminal failure or capacity exhaustion stops further frames and the cue, records redacted health, and makes the run `indeterminate` with final verification not run;
- every physical keepalive CLI invocation performs the fixed cue and requires exact `CUE_HEARD` input in that same process before runner construction or HID activity; wrapper-only preflight is insufficient;
- invalid endpoint timing stops without an owner-attestation prompt, because testimony cannot repair invalid timing;
- cue success is rejected when the derived timeout context has expired, including an injected cue that ignores cancellation;
- only errors proven to arise from malformed inbound bytes are class evidence; transport, session, impossible read-count, unknown, and otherwise ambiguous errors are terminal capture failures;
- cancellation observable before terminal endpoint and result observations are committed prevents a pass;
- continuous capture begins before the idle schedule by design, while endpoint input eligibility begins at cue invocation;
- zero-duration injected cues are valid when completion is not earlier than start; negative, missing, expired, or over-12-second timing invalidates;
- required diagnostic observations cannot be silently dropped or ignored. Any required observation failure makes the result `indeterminate`; archive validation remains defense-in-depth.

Corrections `R05` through `R08` now pass the unrestricted full Go suite, focused race and vet, shell syntax, strict jq/Python/Ruby archive regressions, independent verification `V04`, and final architect review `A06`. The archive order is fixed records, cue, zero or more strictly validated `pre-cue` records, exactly one adjacent canonical press/release pair, zero or more post-window records, endpoint, and result. All backends enforce pair adjacency and nondecreasing elapsed time.

Exactly one further `I = 32s`, `D = 128s` physical run is authorized while the owner is present and continuously observing. Audible same-process preflight and exact `CUE_HEARD` are mandatory. Once HID scheduling begins, every outcome consumes the authorization; there is no retry. The run does not authorize a production keepalive policy.

## Final scheduler-coupled physical result

The one authorized physical invocation produced checksum-valid archive `20260831T064118Z-keepalive-prevention`. Its internal diagnostic result is `pass`: same-process preflight and owner-heard gates were accepted; four ordered `enable-input-stream` boundary records passed; capture remained healthy; cue duration was 2.565405084 seconds; one adjacent canonical wire-0 press/release pair occurred 1.518074708 and 1.653927083 seconds after cue completion; the owner attested `ACTIVE_AT_CUE`; timer wake and capture stop were 1.073666 and 1.160541 milliseconds late, within the 250-millisecond tolerance; and metadata/stdout/stderr hashes match the manifest.

The four scheduler records contain ordinal boundary numbers but omit actual monotonic wake/write timestamps. Because the implementation accepts wake jitter until the next 32-second boundary, those records prove ordered writes in bounded scheduler windows, not exact actual delivery timing. Architect `A07` therefore rejected prospective K02 contract acceptance; independent archive verifier `V01` classified the physical result as endpoint-valid but K02-inconclusive.

On 2026-09-01, after reviewing the favourable endpoint outcome, the owner explicitly waived the serialized actual-timing requirement and accepted the archive under the categorical scheduler-window contract. Architect `A08` therefore classifies K02 as **bounded pass by retrospective waiver**. This is a post-outcome protocol revision and must not be presented as prospective compliance with the original timing-evidence requirement.

Permitted inference is narrow: on this owned specimen, one 128-second invocation with four ordered bounded-jitter input-enable writes remained visibly active and produced valid canonical input at the coupled endpoint. Exact 32-second delivery, a maximal safe interval, long-term reliability, cross-device or cross-firmware behavior, and production policy are not established. The physical authorization is consumed; no further K1 is authorized.

The owner also proposed reducing the scheduler window to reduce risk. A 16-second cadence is the conservative analytical candidate: with the same categorical acceptance contract, worst admitted spacing approaches 32 seconds, preserving the intended `T0 / 2` margin against observed `T0 = 64s`. This is not the five-second endpoint window, which remains unchanged. The 16-second cadence is physically unverified and is not selected for production by this waiver alone.

## Prospective K1-50 revision

The owner subsequently clarified that the intended optimization is a cadence nearer `T` with a small buffer and explicitly confirmed one new prospective `I = 50s`, `D = 200s`, four-write experiment. This is K03, not a K02 retry and not a production-policy selection.

Architect `K03-A01` requires every successful boundary to identify `timing_contract = k1-50-v1` and serialize planned boundary, actual timer wake, write invocation start, and successful write completion as monotonic nanoseconds from one schedule origin. For every boundary:

```text
planned <= wake <= write start <= write completion <= planned + 250ms
```

The bound is inclusive. Zero and exactly 250 milliseconds late pass; early, reordered, missing, clock-regressed, or 250 milliseconds plus 1 nanosecond timing invalidates the schedule and prohibits later writes and the cue. Write failure or uncertain completion is indeterminate and has no synthesized completion timestamp. There is no retry or catch-up. The fourth successful completion must precede the fresh endpoint cue boundary.

Legacy K01/K02 archives remain governed by their historical schema. Absence of `timing_contract` selects only the legacy validator; `k1-50-v1` selects the prospective validator; unknown or partial timing contracts are rejected. One owner-present physical K1-50 is authorized only after full automatic, independent, and final architect gates pass. Any outcome after HID scheduling begins consumes that authorization.

On 2026-09-01, implementation corrections `K03-R01` and `K03-R02`, independent verification `K03-V02`, and final architect review `K03-A02` passed. The validators require nondecreasing pre-cue elapsed time and agree across jq, Python, and Ruby on strict integer nanosecond representations. The exact next permitted action is preparation of one owner-present `I = 50s`, `D = 200s` invocation after the mandatory same-process cue preflight and exact `CUE_HEARD`. No retry or replacement is authorized after HID scheduling begins.

The one K03 physical invocation began on 2026-09-01 and is retained at `deploy/diagnostics/20260901T063506Z-keepalive-prevention`. All four scheduled writes passed `k1-50-v1`, with successful completion 1.326333–1.988541 milliseconds after the respective planned boundaries; capture remained healthy and the fourth completion preceded cue start. The endpoint is indeterminate: `CUE_HEARD` was submitted at the later visual-attestation prompt instead of one of the closed attestation tokens, and no canonical input pair was retained. This establishes prospective scheduler conformance for the invocation but does not establish that a 50-second cadence prevented the screensaver. The authorization is consumed and no retry is permitted under K03.

After completing the procedure directly rather than through the latency-prone agent relay, the owner produced `deploy/diagnostics/20260901T065715Z-keepalive-prevention`. The archive passes strict validation and checksum verification: all four boundaries satisfy `k1-50-v1`, capture is healthy, the fourth completion precedes the cue, `ACTIVE_AT_CUE` is recorded, and one canonical wire-0 square press/release pair occurs in-window. On 2026-09-01 the owner explicitly designated this independently operated passing archive as the authoritative and sufficient K03 source of truth. The earlier archives are retained as procedural-interaction history, not as the controlling K03 outcome. This owner ruling closes K03 but does not waive B01 or select a production policy.

## Retained acceptance requirement

The revised archived brightness-zero matrix remains required. Informal probe observations and S0/S1 do not substitute for its classification of wide, physical-button, and square input while brightness persists at zero, the separately attested encoder-triggered transition to brightness 100, and configured-brightness recovery. Encoder rotation cannot establish persistent-zero encoder behavior because the act ends that state on the owned specimen.

On 2026-09-03, B01 R01-R05 automatic corrections passed independent verification and final architect review without HID access. The archive now requires a dedicated structured `brightness_attestation`, accepts only `BRIGHTNESS_100_OBSERVED` for a passing transition, includes all captured input through shutdown in the terminal verdict, and is validated consistently by jq, Python, and Ruby. Exactly one owner-present, no-retry physical B01 run is authorized before P01.

The resulting archive, `deploy/diagnostics/20260902T235304Z-brightness-zero`, is checksum-consistent and correctly records `class-failure`: wide 13 and buttons 15/16 passed while zero persisted, but the required square `0_0` pair was absent before encoder 17 left ended the zero window. Structured brightness-100 attestation, configured restore, and recovery passed. The authorization is consumed, B01 remains incomplete, and P01 cannot use this archive as a passing matrix.

The owner subsequently initiated `deploy/diagnostics/20260903T032301Z-brightness-zero` outside that no-retry authorization. The replacement independently passes hash and strict archive validation and contains the complete required sequence with no contrary or trailing records. On 2026-09-03 the owner explicitly accepted it retrospectively as authoritative and sufficient for the bounded one-device B01 decision. The first class-failure remains valid historical evidence; the second does not correct or invalidate it. The procedural deviation and retry-selection risk are accepted and do not support repeatability or cross-firmware claims. B01 is closed and P01 may proceed to owner policy selection; no third B01 run is justified.

## Deferred production decision

On 2026-09-03 the owner selected the P01 production contract: fixed absolute 50-second `0x0002` keepalive while connected; optional integer `idle_timeout_seconds` defaulting to 300, with 0 disabling application dimming and 86,400 as the maximum; one brightness-zero write on application idle; and configured-brightness restoration on the first known physical gesture. A wake press and its matching release are both consumed to avoid orphan release delivery; one rotation is consumed; unknown decoded values do not wake. Uncertain keepalive, dim, or restore writes fail-stop the runtime without retry. IPC, supervisor restart behavior, Swift, and `0x0009` remain outside P01.
