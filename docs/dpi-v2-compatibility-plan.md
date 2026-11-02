# DPI V2 follow-up — proposed, not implemented

2 November 2026. Owner confirms the CPU/window freeze seems resolved and still cannot set DPI. Local software checkpoint4bd7931 records the tested settings prerequisites and accepted CPU fix. Pointer speed remains deferred. This document proposes a DPI-only compatibility approach for owner approval; no new device/source mutation has been performed.

## Verified starting point

Hidhogg admits readable2201V2 state/ranges but explicitly refuses its setters. Both pinned reference3S/MX4 tables advertiseV2. The extra native setter argument dpi_level remains semantically unresolved; previous current/defaultDPI getters do not establish its original value or restoration. No live inventory or new private/runtime inspection occurred for this follow-up.

## New primary-source comparison

- [Solaar DPI setting](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/settings_templates.py#L938-L985) sends sensor0 followed by two DPI bytes through function0x30, without a version-dependent fourth argument. [FeatureRW](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/settings.py#L578-L610) forwards that payload.
- [Solaar device requests](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/device.py#L647-L695) and [report framing](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/base.py#L611-L654) may select long reports and zero-pad unused payload bytes. This produces a zero fourth parameter byte on long frames, but no fourth byte on short frames.
- [libratbag setter](https://github.com/libratbag/libratbag/blob/master/src/hidpp20.c#L1544-L1578) uses a short three-parameter setter with no version check and validates DPI echo; this does not prove level-state preservation.
- [Logitech public framing/index](https://github.com/Logitech/cpg-docs/blob/master/hidpp20/README.rst) does not provide the missingV2 level contract.
- Hidhogg currently always constructs20-byte0x11 transactions in BoltRequestIDLedger and sends0x11 on both native transports. A three-parameter call therefore still places zero padding in the fourth payload byte. Do not describe that as an absent byte or an established preserve sentinel.

These projects establish an upstream compatibility practice, not model-specific validation or the meaning of zero/padding.

## Proposed compatibility slice requiring approval

1. Keep the committed checkpoint unchanged until approval.
2. Add narrowly model/feature-gatedV2 numericDPI writes using the source-backed Solaar-compatible existing long-frame path; explicitly retain its zero-padding behavior instead of inventing another level value.
3. Require fresh selected identity, one sensor, supported positive currentDPI, advertised target range/list and fresh feature/version/state checks.
4. Verify actual DPI by readback; report refusal/unknown outcome and stop automatic retries. Preserve actual useful observations.
5. Track/restore only the verified numericDPI field under existing ownership checks. Do not claim unknown level state is read/preserved/restored.
6. Add literal dynamic-indexV2 packet/readback/refusal/ownership/cancellation tests before enabling the UI, retain3S/4 and existingV0/V1 coverage, then signed build for owner manual checks.
7. Owner changes one offered value, checks actual pointer/sensor behavior/readback, restores numeric baseline, and checks reconnect. Agent performs no live writes.

Alternative: retain the current read-only gate until an authoritativeV2 definition or controlled vendor trace establishes level semantics/readback/restoration. No claim that the compatibility proposal is fullV2 protocol parity.

## State

Compatibility implementation awaits approval. DPI remains unfinished in build4013fd4. This is independent of deferred host pointer speed and the queued interactive mouse-model layout.
