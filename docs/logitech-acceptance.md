# NX-M1 owner check

Prepared 2026-10-19. Compilation and synthetic tests cannot establish physical mouse or macOS permission behavior. Use the signed `dist/Hidhogg.app`; no Xcode session is required. Quit older Hidhogg instances and competing mouse software first.

1. Open the app. In Devices, select Back, choose Shortcut and record a combination. Repeat for Forward, then Save. Add one application override if desired. In-app toolbar Back/Forward should retain the selected application/control and draft. Settings shows the exact configuration path.
2. Open Settings and request keyboard permission. If macOS requires enabling the app in Privacy & Security, do so, then refresh/reopen the app as required by macOS. Return to Devices. Save the initial defaults even if both controls are disabled; a missing file cannot enable bindings.
3. With the intended MX Master 3S paired over Bolt, Connect. Confirm the candidate is your intended mouse, then Enable Back and Forward. Release both buttons. Each deliberate press should execute its saved shortcut once in the frontmost application; holding a button should not repeat it. Verify the application override and an application using the default.
4. Stop. Both buttons should return to native behavior. Connect and enable again, then unplug/reconnect the receiver or sleep/wake. Delivery should stop and require explicit Connect/Enable. Quit while enabled and check native button behavior afterward.
5. Reopen and check saved bindings. Reload should retain the last valid document on invalid TOML, warn before discarding a draft, and detect an external edit before Save. Observe idle memory/CPU over a representative session; no physical resource measurement is claimed yet.

If discovery fails, preserve the visible message rather than retrying with another device or transport. This slice rejects ambiguous receivers/devices and unsupported capability versions. A cleanup-unverified state blocks rearming; resolve receiver state before restarting. Abrupt crash cleanup and coexistence with other diversion clients are not acceptance claims.

## Configuration behavior

The new schema is unrelated to legacy D200X TOML. The app creates `config.toml` only after Save, under absolute `XDG_CONFIG_HOME/hidhogg/` or `~/.config/hidhogg/`. GUI launches inherit their launch environment; the displayed Settings path is authoritative for that instance. No watcher runs. Successful Save or explicit Reload updates memory and stops active bindings; reconnect/enable is deliberate.

Use the editor to generate valid shortcuts. Keys are physical macOS key codes with semantic modifier names. Missing per-application control overrides inherit All apps; Disabled intentionally suppresses the control while diversion is active. Saves rewrite comments/formatting. Unsupported or malformed existing files are preserved rather than replaced.
