# M-07 — Local notification vertical slice

Date: 2026-09-19. Status: complete; P01/C01/R01/I01/A01 and V01 automatic, architecture, and owner physical gates pass.

## Outcome

A local CLI publishes text for a configured source. Matching tiles in the active profile display that text. Replacement, expiry, explicit clearing, or physical selection restores the current configured label. Selection may run the tile's static configured action; notification data never supplies executable instructions.

The existing Go runtime remains authoritative. Swift UI and foreground-app mapping are deferred. This slice excludes network ingestion, persistence, replay, artwork generation, pages, action expansion, and an unbounded notification queue.

## Proposed owner-visible contract

| Concern | Proposed decision |
| --- | --- |
| Routing | Optional `notification_sources` on a configured position; exact, case-sensitive source matching. Absent means no subscription. Broadcast to every matching tile in the active profile, including wide `3_2`. |
| Configuration | Retain schema version 3 with an optional field. Older strict binaries reject the new field; no backward compatibility promise. |
| Source | `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; no normalization or wildcards. When supplied, a filter list contains 1–16 distinct identifiers. Empty lists are rejected; omit the field for no subscription. |
| Text | Nonblank single-line UTF-8, at most 64 runes and 256 bytes; reject unsupported control/directional characters. Preserve configured style and background, overriding only the label. Limits do not guarantee visual fit. |
| Lifetime | Optional `ttl_seconds`; absent means until replacement, clear, selection, or transition. When present, integer 1–86400; zero rejected. |
| Replacement | Latest successfully committed emission wins per tile. Superseded IDs cannot clear or expire replacements. No retention or replay for unmatched sources. |
| Emission reply | Runtime-generated notification ID and matched tile count, without echoing text. Zero matches succeeds without storage or device writes. |
| CLI clear | Required notification ID; remove all remaining matching instances of that ID. Repeated/stale clearing succeeds with count zero. |
| Physical selection | Dismiss only the selected tile's captured notification instance, then submit its static action. Actionless tiles can dismiss too. Action admission failure does not restore the dismissed notification. |
| Profile/reload | A successful different-profile activation or changed configuration reload clears overlays. Same-profile activation and unchanged/rejected reload preserve them. Action-only changed reload still restores the baseline when necessary. |
| Idle | Notification operations do not intentionally wake, alter brightness, or reset activity. Firmware behaviour during dimmed page uploads requires physical verification. |

Methods: `notifications.emit` and `notifications.clear`, exposed through discovery-aware `hidhoggctl`. Preserve the existing wire envelope: top-level `protocol_version`, `request_id`, `method`, and nested `params`. The Go Request DTO is flat, but [the explicit codec](../internal/ipc/protocol.go) projects it onto this nested wire shape.

```text
hidhoggctl --runtime-dir ABSOLUTE_DIR notifications emit --source ID --text TEXT [--ttl-seconds N]
hidhoggctl --runtime-dir ABSOLUTE_DIR notifications clear --notification-id UUID
```

Emit params contain exactly `instance_id`, `source`, `text`, optional `ttl_seconds`. Clear params contain exactly `instance_id`, `notification_id`. Reject explicit null, unknown or duplicate fields, noninteger/out-of-range TTL, duplicate CLI flags, extra positional arguments, and method-inappropriate arguments. Emit results contain exactly `instance_id`, `notification_id`, `matched_count`; clear results exactly `instance_id`, `cleared_count`. Counts are explicit integers 0–14. Notification IDs are canonical runtime-generated UUIDs, meaningful only within their runtime generation.

Use static bounded errors for invalid parameters, busy admission, unavailable/shutting-down service, and internal/uncertain failure; never echo payloads or raw causes. Correlation request IDs are not deduplication tokens.

## Architecture consensus and limits

Architect review supports keeping immutable configured render snapshots separate from ephemeral overlays and extending the existing profile/reload coordinator. A new independent device writer or general-purpose device actor is unnecessary. See [runtime profile coordination](../internal/runtime/profiles.go), [baseline reload comparison](../internal/runtime/reload.go), and [existing page rendering](../internal/d200x/page.go).

```text
CLI / physical selection / expiry
                 |
       profile/reload coordinator
                 |
 configured baseline + bounded overlays
                 |
 one composed content-addressed 0x0001
```

- Use the existing typed full-page sender, not a 14-command targeted batch. Prior owner observation establishes simultaneous-looking updates on the owned device, not firmware atomicity.
- At most 14 live tile overlays; admission bound is eight waiting requests. Reject saturation without blocking input or allocating an unbounded queue.
- Use one coalesced expiry signal and monotonic deadlines. TTL begins on successful commit; expiry is due at equality. Recheck deadlines and instance identities inside the coordinator. Physical restoration may lag the deadline while another operation is running.
- Validate and prebuild before writes. A write failure leaves device state uncertain and follows existing terminal failure policy; no automatic retry or claimed rollback.
- Reuse transition gating for redraws. This can cancel pending gesture candidates on unrelated tiles; preserve held-input latches and wake/duplicate suppression. Never wait for coordinator work while holding a transition read lock.
- Capture notification identity with gesture attribution. A replacement between press and release must survive selection of the older instance. Revalidate captured identity and binding in the coordinator; stale selections skip both dismissal and action. Submit actions only after successful dismissal commit. Saturated selection admission skips both without blocking for queue capacity; awaiting an admitted selection can still pause existing input/idle processing.
- Shutdown stops admission and the expiry timer and resolves queued requests under the existing lifecycle policy.
- Keep notification text out of execution history and routine diagnostic logs. Replies and errors remain strictly bounded under the existing 16-KiB IPC limit.

Architect consultation on 2026-09-19 settled a five-second runtime-owned cooperative operation budget beginning immediately before admission, including queueing and execution. Before the first write, cancellation prevents committing that mutation; after a write attempt, failures follow terminal uncertainty policy. This is not a hard OS/HID call bound. Notification calls receive a seven-second default client read allowance, retaining existing one-second connect/write allowances. Preserve explicit tighter client deadlines and caller context deadlines; other methods keep their existing defaults.

R01 draft review established these implementation decisions (not a verification result): publish separate ephemeral notification state within the same immutable atomic effective snapshot for coherent gesture reads, but exclude it from the configuration-only candidate and baseline render/revision comparison. Transition gating must cover both the write and state publication. Link the maximum five-second operation budget to direct caller cancellation; IPC transport disconnect does not itself cancel server-side work. Preparation/invariant failures before writes are internal faults, not evidence of uncertain device state; halt scheduling without retries or self-waiting closure. Selection authorization must reject expired instances even when physical restoration is delayed.

A01 architect review requires rechecking the captured deadline after rendering, under the transition gate immediately before the write or identical-render commit. Equality is expired and skips both mutation and action. Once authorized and a write begins, successful completion publishes and authorizes the static captured action even if cancellation/TTL changes during transport; a subsequent reload does not retroactively cancel that authorization. This is a narrow commit ordering, not a new action coordinator.

A timeout/disconnect means outcome unknown: emission may have committed without the client receiving its ID. Never retry automatically. Recovery is physical selection, a new same-source emission whose returned ID can then be cleared, a successful changed reload, different-profile activation, or runtime restart. A finite optional TTL limits orphan duration; there is no implicit expiry, list API, or idempotency ledger in this slice.

Routine notification logs may contain IDs/counts/status, not source text. Existing opt-in packet diagnostics include a bounded hexadecimal report prefix and digest, not a full payload dump ([diagnostics.go](../internal/d200x/diagnostics.go)); do not advertise that surface as providing content confidentiality. Packet fragments and content-derived fingerprints remain possible. This slice does not require a new diagnostic device API.

## Tasks and verification gates

The owner approved the proposed defaults on 2026-09-19. P01/C01/R01/I01/A01 are complete. V01 independent whole-tree test/race/vet/build and final architect review pass; main fresh tests/vet, Darwin arm64/amd64 command builds and deterministic schema regeneration pass. The normal independent suite required one rerun for the known separate discovery helper race; its full race suite passed. Owner physical acceptance passed: dimmed emission remained dark, manual wake retained the notification, the next selection restored only the selected tile, and all remaining runbook checks were confirmed. No M-07 commit has been requested. Main owns decisions, integration, and `.agents` records.

| Stable ID | Goal and scope | Dependencies | Acceptance / gate | Roles and ownership |
| --- | --- | --- | --- | --- |
| M-07-P01 | Approve behaviour and freeze strict config, wire, CLI, deadline, and failure contracts. | Completed Go checkpoint `78732e5` | Owner approval; architect consultation closes unresolved concurrency/lifecycle decisions. | Main + architect; planning documents only. |
| M-07-C01 | Add optional exact source filters and generated schema validation. | P01 | Absent-field behaviour unchanged; invalid/duplicate/boundary cases; deterministic schema. | Executor light; config/schema/examples. |
| M-07-R01 | Implement bounded overlay state, composed rendering, expiry, transition clearing, and lifecycle in the existing coordinator. | C01 | Fake-clock replacement/expiry tests; baseline diffs unaffected; failure/shutdown/concurrency gates. | Executor light; runtime/coordinator and focused tests. |
| M-07-I01 | Strict IPC and discovery-aware CLI emission/clear. | P01; runtime interface frozen | Invalid requests cause no writes; size/admission limits; no payload echo; timeout semantics documented. | Executor light; IPC, CLI, protocol documentation. Runtime adapters remain R01-owned. |
| M-07-A01 | Physical tile-local dismissal and static action submission. | R01 | Press/release attribution, actionless dismissal, replacement race, idle-wake consumption, action rejection. | Executor light; runtime action integration. Sequential with R01 because files overlap. |
| M-07-V01 | Independent automatic verification and owner-run physical acceptance. | C01, R01, I01, A01 | Full test/race/vet/build/schema gates and the physical sequence below pass; durable handoff records actual evidence. | Tester + owner; main closes documentation and milestone. |

I01 can run alongside R01 only after interface ownership is frozen. No parallel changes to shared runtime files. Source filters and runtime overlays must remain independently testable without HID access.

Owner acceptance sequence: emit to square and wide subscribers; replace; clear stale/current IDs; expire; dismiss on configured gesture and verify static action; dismiss an actionless tile; verify profile/reload retention rules. Separately emit/replace/expire/clear while dimmed and check that the first wake gesture is still consumed. If uploads brighten the device, revise the idle policy before accepting this milestone. No repeated protocol research is required unless this sequence exposes new behaviour.

## M-03-F01 — Separate lock-test hardening follow-up

On 2026-09-18 a fresh full-suite run failed `TestLockReleasedOnProcessExit`; ten isolated repetitions and the full-suite rerun passed. The helper prints its readiness marker then exits immediately, allowing lock release before the parent's contention assertion. Plan a parent-controlled release handshake as a test-only follow-up; this observation does not establish a production discovery defect. See [discovery test](../internal/discovery/discovery_test.go). No test fix is included in this planning checkpoint.

Status: planned, outside M-07 implementation. Scope/ownership: discovery tests only, executor light and independent reviewer. Acceptance: parent observes contention while the helper deliberately retains ownership, explicitly permits helper exit, then observes release; repeated race tests pass without sleeps. Dependency: a separately approved implementation step. Production locking remains untouched.
