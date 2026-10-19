# HIDHogg

Native Swift macOS application for configuring input devices. The approved rebuild starts with Logitech MX Master 3S over Bolt, Back and Forward shortcut bindings, All apps defaults and application overrides.

**Current build is the native application foundation only.** It does not yet discover or configure hardware. The UI reports this explicitly.

- [Build and fixed-path app packaging](docs/build.md)
- [Architecture and scope](docs/overview.md)
- [TaskView milestone index](docs/roadmap.md)
- [Decisions and alternatives](docs/rebuild-decisions.md)
- [Design mock-ups and selected logo](docs/product-redesign/brief.md)
- [Historical D200X/v2 documents](docs/archive/v2/README.md)

The previous implementation is recoverable at checkpoint `4b3248d` on `v2`. New work is on `next/logitech-slice`; the ignored build product remains `dist/Hidhogg.app`.
