# Current selection — head-only eye status

On 2026-10-21 the owner selected the head-only design. Production uses unchanged `head-clean.png`; the renderer overlays a 3.5-point status circle inside a 5.5-point transparent eye opening. The trial selector and external dot are removed. Only the head source is packaged and included in build identity. Other assets and the descriptions below are historical. [Current verification](../../../head-eye-status-verification.md).

---

# Current comparison — NX19 head and tail

Owner approved trying both2026-10-21. `head-clean.png` and `tail-swirl.png` are standalone transparent assets generated with built-in imagegen from `head-vs-swirl-refinement.png`. Old selected-a1 and prior boards remain historical. Current native size/gate: [dual-icon verification](../../../dual-menu-icon-verification.md).

Final prompt set:

- Head: extract/reproduce only leftA as a pureblack transparent silhouette, preserve twohorns/broadmuzzle/shortneck, exactly onecrescenteye; fill the separate ear/leaf/scale cutout, no nostrils/mouth/texture/shadow/statusdot/labels/previews. Keep complete shape for tight22x18pt fitting.
- Tail: extract/reproduce only rightB as a pureblack transparent silhouette, large friendlyhead/twohorns/thickcoiledbody/one cleanbroadspiral, singlecrescenteye; no extraear/scalehole or otherdetail, no statusdot/labels/previews/gradients/shadows. Keep complete shape/aspectratio for tiny menu use.

Menu Icon style selects A·Head or B·Tail in memory, resetting on relaunch. Renderer crops visiblealpha once, caches tiny masks and at most16style/status/light-dark composites. A SINGLE original-color image combines glyph anddot, addressing the missing second image inNX18. Main app icon remains unchanged. Native harness visibility was ownerconfirmed; highlighted/highcontrast/alltheme transitions remain unverified.

---

NX18 supersedes the18pt rendering below: selected glyph now fills24x20pt (48x40raster), exact visible-artwork crop without added margin; separate status dot. Native menu readability/colors remain owner checks. See [current verification](../../../menu-bar-status-verification.md).

# Menu-bar icon — selected A1 variation1

Owner selected on2026-10-21. `a1-variations.png` is the comparison board; `selected-a1.png` is the preserved standalone transparent source. Both were generated using the built-in imagegen tool. These are distinct from the full-color app icon.

Standalone generation prompt:

> Extract and faithfully reproduce ONLY icon variation1 (upper-left large dragon head) from the reference contact sheet as a SINGLE standalone monochrome menu-bar icon. Preserve this exact silhouette and proportions: friendly right-facing dragon profile, two swept horns with separated gap, swept cheek spikes, short neck, broad round muzzle, large crescent eye cutout and simple ear cutout. Solid pure black shape with genuinely transparent background; eye and ear holes transparent. No white fill, no labels, no presentation board, no previews, no gradients, no shadows, no extra details, no border. Center complete icon with generous12% transparent padding on all sides. Clean sharp smooth contour, silhouette should remain readable at18pt. This is extracting selected design1, not inventing a new dragon.

Reference: variation1 in `a1-variations.png`. Production `MenuBarIcon.swift` uses a fixed crop of the visible source geometry plus30px margin, fitting proportionally within16pt in an18pt canvas. Rasterized once to36px at2x, then marked as a template for native appearance. A separate system mouse symbol is used if loading fails. The build script includes the source PNG digest in build identity and stages it as `Contents/Resources/MenuBarIcon.png`.

Isolated AppKit rendering verified one36x36 representation with18x18pt logical size; alpha>=8 bounds x2–34/y5–31. Native menu-bar light/dark appearance remains owner verification. No normal app launched for this render.
