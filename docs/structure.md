# Structure

Updated 2026-10-19. Current implementation boundaries:

```text
app/                     new Swift package and native SwiftUI application
scripts/build-app.sh     fixed-path arm64 Release packaging and signing
dist/Hidhogg.app          ignored local build product
docs/                    current overview, decisions and milestone index
docs/product-redesign/   preserved mock-ups, accepted logo and design history
docs/archive/v2/         prior docs, protocol/schema/examples and legal artifacts
spikes/                  preserved historical experiments
scripts/diagnostics/     preserved research tooling, not app dependencies
.agents/                 main-agent session log and handoff
```

Only the main agent updates `.agents/log.md` and `.agents/handoff.md`. Frozen Logitech experiments remain in the external LogiBridge checkout; the new app must not depend on their executable artifacts. Existing local Xcode metadata left under `macos/` is outside the active build and is not production source.
