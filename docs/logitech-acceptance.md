# Current acceptance and remaining limits

Updated 2026-10-21. The owner accepted the latest signed build **9e322504174b** and requested check-in; source checkpoint is **6ce6b23**. The final frozen suite passed **316 tests**, zero failures. [Verification](workspace-presentation-verification.md).

## Owner-confirmed behavior

- Back/Forward bindings and native navigation work.
- Vertical amount, thumb-wheel direction and thumb-wheel amount work.
- Single-instance Restart works; current sleep/wake recovery is acceptable.
- Menu status styling and workspace-dependent Dock/native ⌘Tab behavior look good.
- Launch at login now shows Enabled without error; no actual login launch was observed by the agent.

Startup is menu-only. Opening the workspace supplies Dock/app-switcher presence; minimizing or switching apps retains it. Closing the workspace restores menu-only presence while the same app/device session continues.

No repeat acceptance campaign is required before UI planning. The [roadmap](roadmap.md) distinguishes delivered behavior from residual evidence limits.

## Remaining evidence limits

Automated fixtures do not prove hardware or native AppKit behavior. Owner acceptance is recorded separately from agent testing. Low/High physical comparison, optional restoration, abrupt receiver removal/crash cleanup, other-mouse isolation, contention, overnight CPU/memory, exceptional native recovery and actual launch after login are not all established. Keep these explicit; agree any targeted follow-up before testing.

The single candidate/capability gates, release arming and lack of a native-passthrough binding remain deliberate behavior. Once any shortcut is configured, the session diverts both controls; Disabled suppresses its action. First press/release can arm a control when no initial-up state was observed. Successful HID++ requests reuse IDs; ambiguous requests retire IDs and can still stop a session safely.

## Configuration and diagnostics

Configuration uses `config.toml` under absolute `XDG_CONFIG_HOME/hidhogg/`, otherwise `~/.config/hidhogg/`. Valid edits apply immediately and save after one second of inactivity. Quit/Restart flush pending changes; save failure keeps the app open. Manual Reload remains; no hot reload. Atomic saves detect byte-revision conflicts and preserve malformed/conflicting files; rewriting does not preserve comments/formatting.

Settings exposes permission checks, app drag/restart affordances and startup controls. Recent Activity has event IDs/codes/build/source correlation; persistent events use the Console subsystem `com.hidhogg.app`. [Diagnostics](diagnostics.md). Owner configuration was not inspected for checkpoint verification.
