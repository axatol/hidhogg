# Hidhogg roadmap

Updated: 2026-10-02

TaskView is the authoritative source for task status. This file records scope and stable TaskView identifiers; it does not maintain a parallel status checklist.

## Legacy v1

The original roadmap and its detailed contracts are preserved in [v1-roadmap.md](v1-roadmap.md). The verified legacy records are in TaskView project 5, list 48. TaskView task #120 is the single historical migration manifest; its completion means the archive was imported, not that every underlying gate passed. The exact stable-code map and status qualifications are in [v2-plan.md](v2-plan.md) and the manifest note.

TaskView's list endpoint omits known records. Use the direct task IDs in the plan and manifest rather than treating list results as a complete inventory.

## Approved v2 migration

The target is a pure Swift macOS application that owns the runtime and device, plus a Swift CLI for status and notifications. Preserve strict TOML v4 and current product behavior. Acceptance runs the native macOS app with a simulated D200X; no Apple Simulator target is assumed.

| Functional slice | TaskView code and ID |
|---|---|
| Review, v1 checkpoint, v2 branch | V2-P01 #121 |
| Strict configuration and lossless transactional editing | V2-C01 #122, V2-C02 #123 |
| D200X protocol and simulated/native transport | V2-D01 #124, V2-D02 #125 |
| Profiles, reload, idle/display policy, actions, input, notifications and history | V2-R01 #126, V2-R02 #128 |
| Swift IPC, discovery and CLI parity | V2-I01 #130 |
| Swift app ownership and full button editor | V2-U01 #132, V2-U02 #134 |
| Comprehensive unit, edge and simulator acceptance | V2-V01 #136 |
| Remove Go dependencies and audit final build/docs | V2-X01 #138 |

TaskView project 5 list 49 owns the V2 tasks and dependency graph. See [v2-plan.md](v2-plan.md) for the task map, dependencies, constraints and verification gates. V2-X01 follows V2-V01; Go removal waits until Swift parity is accepted.

Custom assets, the proposed Go log tail and split profile files are deferred. Historical requirements remain in [v1-roadmap.md](v1-roadmap.md).
