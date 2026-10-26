# Compact settings permissions

Approved2026-10-23 after local checkpoint e2744ad on next/d200x-slice.

## Scope

One native grouped Permissions section with Accessibility Required and Notifications Optional rows: icon, name, concise purpose, compact status or Allow. Accessibility is Allowed only when accessibility trust and event posting both permit operation; disagreement/errors remain inline. Allow uses the existing system request APIs and opens the corresponding Settings page. macOS controls whether a prompt is shown; notification denial cannot force a repeat prompt. Shared footer retains current-app drag icon, Refresh and Restart. General, Configuration and Diagnostics remain on the existing single scrollable page.

Notification authorization must be independent of the per-device low-battery checkbox: requesting permission never enables alerts, changes latch/config or enqueues a notification. Existing setEnabled race/coalescing semantics remain. Refresh and view activation never prompt. No new runtime/device/schema permission requirement or live testing.

## Checklist

- [x] compact native rows and adaptive footer
- [x] independent notification authorization with shared in-flight guard
- [x] fake-service permission regressions
- [x] background native minimum/default navigation/render gate
- [x] signed fixed bundle and provenance
- [ ] owner Allow/deep-link/drag/Restart review

## Decisions

Keep two permissions rather than exposing low-level event-post authorization as an independent macOS pane. Show mismatch as Needs attention under Accessibility. Preserve operational diagnostics, omit permanently visible redundant permission action rows. Use existing system deep links with existing failure messages; no new dependency or custom permission prompt.


Compact permissions checkpoint2026-10-23: baseline D200X/UI committed locallye2744ad on next/d200x-slice, no push. New approved settings edits remain uncommitted for owner acceptance. Single native Permissions section: Accessibility Required and Notifications Optional, compact status/actions, mismatch immediately below Access, notification errors local. Shared adaptive footer real app drag icon/current bundle URL, Refresh, Restart; single-page sections/anchors retained. Allow requests then opens existing relevant Settings deep link; denied/unknown notification states offer Open Settings (macOS prompt policy unchanged). Independent controller requestAuthorization() shares in-flight guard without enabling battery alerts or enqueue/latch mutation; setEnabled guarded behavior retained. Focused27/27 (18notificationcontroller+9UIAlignment) includes4newfake regressions; background minimum820/default1280 native2/2, fake automatic prompt count0. Parent reviewed /Volumes/Data/tmp/hidhogg-permissions-settings-1280x800.png; native runner displays fallback folder icon, production uses existing AppAppearance.icon. Signature strict passed. Build 2780fbd0a98f252378c770b78decd77cd37003153b5a9f5e99667d40b23b7485,137-input provenance refreshed. No real permission prompts/settings opening/drag/restart/HID tested. Owner verify Allow/OpenSettings, grant-and-return refresh, drag real app icon, Restart. Logs /Volumes/Data/tmp/hidhogg-compact-permissions-{focused,native,release}.log. Plan docs/settings-permissions-plan.md.
