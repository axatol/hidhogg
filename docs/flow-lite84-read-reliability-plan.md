# FL-01 late-reply and bounded logical-read recovery proposal

## 28 October 2026 approval update

The owner reported an intermittent idle `unexpected command 4 reply` after successful activity-driven refreshes. The owner explicitly preferred accepting useful data and approved a revised Part A: identity-confirmed, validated battery updates may update battery independently of pending reads; ordinary globally valid replies that cannot match the current query are ignored. Battery updates must not complete or extend unrelated reads, bypass matching-request validation/write completion, or allow batch completion to overwrite a newer observation. Battery timestamps mean received-at, not proven device sample time. Invalid unsolicited battery fields/rejections do not become useful updates; checksum, global scope, identity and generation protections remain.

Implementation and fake regressions are complete; 69 independent focused checks pass and the signed app/CLI pass strict signature verification. Owner physical acceptance remains pending. Part B (read retransmission) remains unapproved and must not be implemented. The dated proposal below is historical: its statement that neither part is approved, and its blanket discard policy for battery replies, are superseded by this update.

Unsolicited battery admission is deliberately all-or-nothing: the existing decoder must produce a level in 0–100, a charging flag of 0/1 and a voltage other than the existing 0/65535 sentinel values. No new voltage range is guessed. A rejected or partial unsolicited frame leaves the last useful value and its timestamp unchanged. Accepting individual valid fields was considered but deferred because one shared battery timestamp would otherwise obscure mixed field freshness. Solicited battery responses retain their existing partial/unavailable-field behaviour.

27 October 2026. Status: revised plan awaiting owner confirmation; neither general reply routing nor retries is implemented yet. The validated identity-only filter and typed diagnostics are already implemented, tested and locally signed separately. No device settings writes are proposed. A new owner screenshot shows expected battery command4 but received firmware command18 after Connect succeeded and Refresh failed; the identity-only exception is insufficient. The screenshot is not approval of the earlier retry proposal. Independent review found a simpler correlation matcher than the initially considered response-history cache; the current proposal below supersedes that cache design.

## Revised scope

| Part | Proposed correction | Additional device traffic |
| --- | --- | --- |
| A: reply correlation | After existing frame/scope/checksum checks, ignore ordinary read replies that cannot match the pending query; never use them to satisfy another request | None |
| B: unanswered reads | Retry the identical encoded request once inside its existing logical exchange, preserving validation and bounded deadlines | At most one extra identical read transmission |

The owner may approve both parts, or Part A only. No dependent code changes before confirmation.

Part A needs no response-history cache. This matches the reference reader's filtering at /Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/probe.swift:534: only the requested command and, for command8, matching address/normalized count can satisfy a pending read. Existing production projection, schema/scope and global packet-checksum checks remain before this routing. Current matching responses still pass all existing status/model/payload checks. An ordinary off-current or idle response is discarded without state, freshness, deadline or traffic changes; its data is never accepted as current.

Preserve the model-binding exception: exact successful repeats of the confirmed identity remain benign, but wrong/rejected identification replies retain the existing failure behaviour. Command10 notification handling is unchanged. An identical fully validated positive response already buffered while its write is incomplete may also be ignored, without releasing that write barrier or advancing the request. Changed buffered data still fails. Unknown schema, out-of-scope read headers and global packet-checksum failures remain fatal through the existing sanitizer. A different field's inner checksum or an unrelated query's rejection is not used to judge the current query; a matching rejection retains existing required/optional handling.

Essential Part A regressions: complete firmwarev1.61, hold battery4, inject firmware18 then genuine battery4 (old code red expected4/18, new code completes once); idle/off-current ordinary replies cause no fresh state or deadline extension; current changed values and current rejections remain observable; matched bad payloads, unknown/global-invalid input and wrong/rejected identities fail; buffered duplicates cannot bypass write completion and changed buffered data fails. Cancellation/generation guards remain effective.

## Evidence and uncertainty

The owner confirms2.4GHz, awake and available throughout. Immediately after that report, the diagnostic completed an initial online snapshot; Refresh then completed online, keyboard-version and battery exchanges, but timed out after the lighting-mode read send completed. /Volumes/Data/tmp/hidhogg-flowlite-user-active-live-20261027.json. Treat this as an unanswered read, not evidence of sleep or normal macOS disconnection. Radio loss, firmware timing and host delivery remain unseparated.

The previously successful public native investigation probe uses two attempts of the same encoded request,250ms per attempt: /Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/probe.swift:479. That is precedent, not a firmware timing guarantee. Current native session performs one attempt; the proposed default retains its one-second per-attempt deadline and caps transmission at two attempts for one logical read.

## Proposed transaction

~~~text
One pending logical read; same generation and request key
  send #1 ── valid correlated reply + confirmed send ── complete once
     |
     +── send confirmed, no reply by deadline
           send #2: identical encoded bytes
             ├─ valid reply + all issued sends complete ── complete once
             └─ final timeout ── close handle and fail truthfully
~~~

| Invariant | Required behaviour |
| --- | --- |
| Retry eligibility | First send completed successfully, no result, attempt deadline elapsed; at most one resend |
| Same logical read | Do not change command, address, count, identity challenge or encoded bytes; do not advance to another request |
| Send barrier | Reset completion for the new attempt; buffer a late first reply until the second issued write completes |
| Callback safety | Check generation, exchange and attempt tags; cancelled/stale timers cannot terminate another attempt |
| Non-retry errors | Write/transport errors, malformed replies and valid rejections follow existing handling; no new retries |
| Terminal bound | Second unanswered attempt closes once; no third send or unbounded loop |
| Retry duplicates | Off-current duplicates are discarded by Part A; an identical buffered positive duplicate cannot advance the request or extend its deadline |
| No reply history | No response cache or undefined rejection body is retained |
| Current request first | A packet whose header can satisfy the current pending request must go through normal validation; differing buffered data remains an error |
| Existing boundaries | Keep validated identity-repeat filter, checksum/header/model checks, command allowlist and receiver-version omission |

The protocol has no established transaction nonce. A late reply to the first transmission can legitimately satisfy this same logical read; an old identical response matching a later identical request cannot be distinguished from fresh data. Receipt is an observation within the bounded logical-read window, not proof of the device's exact sample time. Do not claim otherwise.

## Historical proposed verification — includes deferred Part B

The retransmission-specific cases below apply only if Part B is approved later; they are not gates for the current Part A release. Current Part A verification passed 56 Lofree module and 13 model checks, including telemetry ordering, read deadlines, scope/identity/generation validation and send barriers. Live acceptance remains open.

- Red/green dropped-first-response case: exact-byte retry succeeds with two sends and one snapshot.
- Late first response while retry send is paused: no query advancement before the issued retry completes; retry-send failure stays fatal.
- Two unanswered sends terminate once; incomplete write, rejection, bad checksum and transport failure do not trigger a prohibited retry.
- Off-current ordinary responses at idle/during a different request are ignored without deadline/freshness changes; same-header current responses remain eligible; changed buffered data still fails.
- Stale attempt timer, cancellation/reconnect and existing identity/notification regressions pass.
- Independent full/native gates, bounded real Connect/wait/Refresh, signed app/CLI and provenance refresh.

## Alternatives considered

| Alternative | Reason not selected |
| --- | --- |
| Longer single deadline | Can help a delayed reply, but cannot recover an unanswered/dropped read |
| Skip lighting/OS reads entirely | Removes requested status rather than addressing transaction reliability |
| Continue to the next request after timeout | Risks miscorrelating a late response with another read |
| Completed-response history/LRU | Unneeded state: an off-current ordinary reply cannot update state or satisfy the request; history cannot resolve the same-header nonce ambiguity |
| Accept the next incoming frame as the reply | The observed late18/expected4 case shows why matching must precede acceptance |
| Driver-online/power/setting commands | Outside the approved read-only boundary |
