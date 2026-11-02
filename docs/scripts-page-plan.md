# Scripts page — 1 November 2026

Approved scope: rename the Actions page to Scripts, restrict its list and creation flow to configured executables, and preserve existing definitions, assignments and run history. Built-in action creation remains available through Tile Presets. No configuration migration or deletion is required.

- [x] Replace the mixed action list/template menu with a scripts-only list and New Script button.
- [x] Update executable editor labels to script terminology.
- [x] Verify offline rendering and configuration behavior; rebuild signed artifacts.

Internal route and configuration action identifiers remain unchanged for compatibility. The underlying shared action-count limit and runtime execution behavior remain unchanged.

Verification: 14 focused offline checks passed, zero failures. The never-shown fixture includes executable and native definitions and verifies configuration equality, zero edits and no action history. Rendered Scripts page was inspected. Initial sandbox cache-write failure was resolved by retrying with the required test-runner permission. Logs: `/Volumes/Data/tmp/hidhogg-scripts-focused.log` and `/Volumes/Data/tmp/hidhogg-scripts-release-20261101.log`. Signed app/CLI build `5cc8d353d36de074bf427283976fec99ee7c5d55638a24e8078df27a8ff4c655` passed signature verification. No production app launch or real actions; source remains uncommitted.
