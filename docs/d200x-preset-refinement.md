# Preset selection refinement — 1 November 2026

Approved scope: stable initial chooser presentation; black, centered icon-only built-in tile defaults; configurable Set Volume with 50% as its initial value; appearance customization collapsed by default. Existing saved presets remain unchanged.

- [x] Replace separate sheet visibility/content state with item-driven presentation.
- [x] Refine built-in defaults, volume naming and collapsed appearance controls.
- [x] Verify offline sizing, action configuration and rendering; rebuild signed artifacts.

Focused verification passed 70 checks, including initial chooser content size (760×580), configurable volume snapshots at 0/37/100%, default black/no-title appearances and centered icon bounds. The chooser details scroll without forcing the sheet to grow; its action-type picker is hidden, retaining action parameters. The preset editor retains its preview and collapses appearance controls.

Signed app and CLI rebuilt successfully. Build ID: `90a4f200ce3521078fd91275ffea50f0367c9862ae554ae42327a6ab9bc3c835`. Evidence: `/Volumes/Data/tmp/DX-PRESET-refinement-focused.log`, `/Volumes/Data/tmp/hidhogg-preset-refinement-release-20261101.log`.

Independent full offline gate passed: 537 XCTest and 322 reported Swift Testing tests, zero failures. `WakeConnectionTests` and `NativeWorkspaceWindowTests` remain excluded; no production app, device writes or real input actions were exercised. Evidence: `/Volumes/Data/tmp/DX-PRESET-refinement-full.log`.

The previous static offscreen rendering check did not exercise the inspector's sheet presentation. The chooser now presents directly from its captured assignment context; an absent context cannot present an empty sheet. Native first-open timing still requires owner verification.
