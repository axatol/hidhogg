# Milestone index

Updated 2026-10-19. TaskView Personal / HIDhogg project 5, list 65 **Next — Logitech vertical slice** owns task status, criteria and dependencies. Historical list 49 and its pending v2 acceptance records are not closed by this reset. No new project created.

## NX-M1 — MX Master 3S Back and Forward bindings

User deliverable: discover already-paired mouse over Bolt, configure Back and Forward shortcut bindings using native UI, save defaults/one application override, execute once per press, recover saved configuration after reopen and stop cleanly.

| Stable ID | TaskView | Deliverable | Status |
|---|---|---|---|
| NX-01 | 417 | Recoverable reset, native app/build foundation at dist/Hidhogg.app | Complete — compile/package/audit gates; no GUI/hardware claim |
| NX-02 | 418 | Device-neutral Back/Forward configuration and persistence | TODO |
| NX-03 | 419 | Bolt session, control discovery and action integration | TODO |
| NX-04 | 420 | Native editor, owner acceptance and resource gate | TODO |

NX-01 blocks NX-02, which blocks NX-03; NX-02 and NX-03 block NX-04. Detailed roles, boundaries and gates are in TaskView. The foundation does not establish a completed vertical slice. Existing LogiBridge research tasks remain separate and are not closed or duplicated by these production tasks.

## Checklist

- [x] Owner approved Bolt-only scope and Back plus Forward.
- [x] Owner approved new branch and old production-source retirement.
- [x] Recoverable v2 checkpoint `4b3248d` and `next/logitech-slice` branch.
- [x] Old compiled dist app removed with owner approval.
- [x] Native app and fixed-path signed packaging independently verified.
- [x] Preservation/reset audit complete: 147 preserved files match checkpoint.
- [ ] NX-M1 physical user deliverable accepted.
