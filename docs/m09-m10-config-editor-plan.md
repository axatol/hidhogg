# M-09 and M-10 configuration editor plan

Status: approved for staged implementation on 2026-09-23; the owner authorized the five recommended boundaries.

Update, 2026-10-01: owner verification passed for M-09-B and M-10-A1. [M-10-F01](m10-f01-compact-schema-plan.md) replaces the source representation with keyed schema v4; its blank/default/identity rules supersede the historical v3 layout below. The typed mutation, authority, exact-digest and file/reload contracts remain unchanged.

## Outcome

Add profile lifecycle and a visual configuration editor without moving configuration authority into Swift or silently overwriting detected external edits.

```text
M-08 read/activate UI
        |
        v
M-09-A Go mutation foundation
        |
        v
M-09-B clone/create/delete profiles
        |
        v
M-10-A labels/colours/styles/actions
        |
        v
M-10-B custom assets (separate contract)
```

## Authority boundary

Swift presents typed editing controls. Go owns source mutation, strict schema validation, TOML reference analysis, atomic replacement and runtime reload coordination.

No IPC method accepts complete TOML, arbitrary JSON Patch or a generic source path. Every edit is a bounded typed command carrying the expected SHA-256 digest of the exact source bytes.

## M-09-A — Production mutation foundation

- Promote the measured `go-toml/v2/unstable/edit` capability behind a Hidhogg-owned `internal/configedit` adapter and pin its exact revision.
- Snapshot replies expose bounded structured editor data plus `source_digest`; they do not expose the configuration path.
- Under one process-local mutation gate: re-read and compare digest, apply one typed lossless edit, strictly decode and validate prospective bytes, write and sync a same-directory temporary, re-read/recheck the destination, rename, sync the parent directory, then coordinate reload.
- Report file-commit and runtime-reload outcomes separately. Never automatically restore old bytes after reload rejection or an uncertain device write.
- Preserve ordinary file permission bits and remove temporary files on all pre-rename failures; special mode bits are not part of the configuration-file contract.
- A byte-identical edit is an `unchanged` result: validate it, recheck the expected digest, and do not replace the destination inode or trigger a reload.
- Honest limit: the second digest check narrows but cannot eliminate the demonstrated check-to-rename race with a non-cooperating external writer. Do not claim filesystem compare-and-swap or absolute no-lost-update semantics.

Acceptance requires real current-schema preservation fixtures, stale refusal leaving destination unchanged, strict prospective validation, atomic visibility, sync/mode/cleanup checks, reload outcome separation, and explicit external-race evidence.

## M-09-B — Profile lifecycle

- Create only by cloning one existing complete profile; default source is the current profile.
- Owner supplies and confirms a new stable profile ID and label. ID is immutable after creation; `rename` means label edit only.
- Creation must yield exactly all 14 supported positions and remain within the 31-profile limit.
- Deletion is refused when the profile is default, current, referenced by a TOML `activate_profile` action, or referenced by a Swift foreground mapping.
- No cascade deletion, automatic fallback, reference rewriting, draft/incomplete profiles or silent ID generation.
- Go rechecks TOML dependencies at commit time; Swift supplies its current mapping-reference refusal before requesting deletion.
- The owner accepted on 2026-09-23 that the Swift mapping check is advisory rather than atomic with Go's TOML edit. A concurrent mapping change can leave a dangling Swift mapping; Swift must mark it stale on catalog refresh instead of silently rewriting or deleting it.
- Independent M-09-B architecture review found that both `clone current` and delete-current checks must run inside the profile coordinator's serialized reload callback. Reload admission alone does not serialize profile activation. The callback receives the actual current profile ID; it must perform the exact-digest store mutation and candidate construction there.
- The same review identified a post-commit cancellation boundary: a disk replacement may succeed before runtime application begins. The result must report the file and runtime outcomes separately, never imply rollback, and implement the owner's chosen cancellation policy explicitly.
- Historical v3 layout: on 2026-09-24 the owner confirmed a canonical appended `[[profiles]]` / `[[profiles.positions]]` clone block. M-10-F01 replaces this with canonical sparse keyed v4 source; wholly inline root profiles use lossless inline insertion. Existing source bytes/comments stay intact; source-profile comments are not copied to the clone. Deleting a profile removes comments attached to it while preserving unrelated bytes/comments.
- The owner chose a post-commit cancellation boundary: cancellation before the file commit may stop the edit; once the file commits, Go finishes the runtime reload and reports both file and runtime outcomes. This does not promise that a disconnected IPC caller receives the report; the runtime must still complete/reconcile the effect.
- On 2026-09-24 the owner chose to propagate Unix IPC disconnect cancellation to editor mutations before file commit. The server must not mistake a valid one-request client waiting for its response for a disconnect; post-commit reload still completes.
- Independent socket design review bounded this policy: mutation clients keep their write side open until the response; a server-read EOF/error cancels; write-half-close is unsupported for mutations; extra bytes are ignored. The watcher must not retain the initial read deadline or block the response. Cancellation is best-effort before commit: the store has a short staging interval between its last context check and rename, so a disconnect there may still commit and then reload. A stronger before-rename guarantee would require a separate context-aware store contract.
- Swift's existing profile-switch `retry()` can activate a profile, so editor mutation success needs a catalog-only refresh rather than reusing that method as a read. Editor clients must be bound to the current runtime endpoint and discarded when its socket or instance ID changes. On stale digest, refresh the editor snapshot before another edit.
- Profile edits synchronously include source staging and runtime reload, so the ordinary 1-second profile-switch IPC phase timeout is not a justified editor bound. The Swift editor integration should use an explicit bounded 10-second phase timeout; timeout/disconnect is an outcome-unknown state and must never trigger automatic mutation retry.

## M-10-A — Visual profile editor

Editable existing fields:

- profile label;
- position label and hexadecimal background colour;
- bottom/centre label alignment and size 8 through 32;
- exact notification-source list;
- add, replace or remove one strict action.

Action forms mirror existing tagged variants:

| Type | Fields |
|---|---|
| `activate_profile` | target profile, press/release |
| `execute` | absolute executable, literal arguments, timeout, press/release |
| `type_text` | text, press/release |
| `key_press` | Enter, press/release |

There is no shell-command field. Logs and diagnostics never retain executable arguments or typed text. Go validation remains authoritative.

The owner accepted on 2026-09-23 separate validated commits for execute-action fields and individual arguments. A multi-field form save is not atomic and the UI must make each committed field's outcome visible. A future milestone may add atomic whole-action commits after a bounded transport/size contract; M-10-A must not imply such atomicity. The current 16 KiB IPC frame cannot provably carry every execute action or executable path, so editor reads use per-position and per-field requests, and each encoded frame remains bounded.

Read-only M-10-A readiness review adds two implementation constraints: replacing an action must begin with a complete valid variant (type plus its required target, executable, text, or Enter key), because intermediate invalid TOML cannot be committed; optional alignment/size/source-list resets must explicitly remove the TOML field rather than writing an invalid empty or zero value. A schema-valid executable path can itself exceed one IPC frame, so the later action-editor slice needs a clear over-limit single-field contract before implementation.

The M-10-A delivery order is position-label read/edit end to end, other position fields with optional resets, notification-source set/reset, then complete-valid action initialization/removal and per-field/argument changes. New editor mutation methods must be included in the IPC server's mutation classification so the M-09-B disconnect policy continues to apply. The action slice remains blocked on the single-field executable-path/frame contract; earlier slices are not.

The first position-label slice uses three narrow methods: `config.editor.positions.list` returns 14 stable position IDs paired with physical coordinates for one profile at an exact source digest; `config.editor.position.get` returns one label for `(profile_id, position_id)` at that digest; `config.editor.position_label.set` edits only that label by stable IDs and returns the existing separate file/reload outcome. Both read results carry the runtime instance ID inside the result as well as the response envelope, matching existing editor reads. The Swift selector displays coordinates but targets stable IDs. Neither full profile content nor TOML array indices cross IPC. Tile preview and other fields remain later slices.

Preview is approximate unless it consumes output from the same Go renderer. Owner-visible verification remains necessary for wide-tile typography and device application.

## M-10-B — Custom assets

Custom images are not supported by the current source schema: `background` is a colour. Image support requires a separate schema and asset contract covering content-addressed managed storage, accepted formats, dimensions and byte limits, metadata removal, decode safety, path portability, write ordering, retention and explicit garbage collection.

Recommended boundary: exclude custom images from M-10-A. If approved later, write content-addressed assets before a TOML reference, never delete assets in the same edit transaction, and garbage-collect only through a separate explicit operation. Do not claim an atomic multi-file commit.

## Review and fix loop

Each implementation stage receives one independent review. A second review follows any material correction. A third and final review is used only if the second review finds a new correctness or security blocker.

1. Contract/source-preservation review.
2. Correction and focused verification.
3. Optional final correction/review, capped at three cycles before returning unresolved architecture to the owner.

Milestone closure additionally requires full automatic gates and owner-visible verification; review count does not substitute for acceptance evidence.

## Confirmed owner decisions

1. Accept the exact pinned untagged `go-toml/v2/unstable/edit` dependency behind a private adapter and regression corpus.
2. Create profiles only by cloning a complete profile; keep profile IDs immutable.
3. Use conservative deletion with no cascade or automatic fallback.
4. Exclude custom images from M-10-A and treat them as M-10-B under a later asset contract.
5. Accept optimistic conflict detection's documented residual race with arbitrary external editors; detected stale edits are refused, but absolute compare-and-swap cannot be claimed.
6. Keep foreground-app mappings Swift-owned and accept the non-atomic mapping/deletion check; stale mappings remain visible for explicit owner correction.
7. Use separate validated execute-field/argument commits for M-10-A; prefer atomic whole-action editing in a separately designed future change.

The owner authorized proceeding on 2026-09-23 after asking whether any open questions remained. No additional product decision blocks M-08-C01.
