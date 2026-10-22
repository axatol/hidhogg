## Revision08 — photo-derived geometry checkpoint, 2026-10-22

Owner rejected revision07 as not close. The freehand approximations are discarded for integration. [Photo/trace comparison](08-photo-contour-review.png), [comparison SVG](08-photo-contour-review.svg), [transparent trace](08-photo-contour-mouse.svg). VectorCraft Image Trace derives contour regions directly from the supplied photo; selected neutral regions and a photo-derived body mask remove the background. No labels or interaction outlines. This remains a rough geometry study: lighting boundaries and small edge irregularities need manual path cleanup before use. It is not an approved final simplified vector.

Parent rendered and inspected the checkpoint; VectorCraft import/export warnings none. No app/source/bundle changes. Next: review actual silhouette/panel geometry, then clean paths without changing those proportions; only restore labels after shape approval.

## Revision07 — straight leaders and revised shapes, 2026-10-22

Owner rejected revision06 leader routing and shape fidelity. [Review PNG](07-angled-controls-review.png), [review SVG](07-angled-controls-review.svg), [standalone SVG](07-angled-mouse.svg). Each label now has one straight line with no elbows. Revised front panel/seams, curved thumbrest, wider rounded wheel bodies, smaller14×4 side buttons. Reference photo retained only on the board. Parent reviewed geometry, adjusted label rows to avoid unrelated controls, and rendered/exported through VectorCraft without warnings. Owner review pending; no app integration/bundle changes.

## Revision06 — angled vector preview, 2026-10-22

Owner supplied a side-angle photo so both wheels and both side buttons can appear in one drawing without an inset. [Rendered review PNG](06-angled-controls-review.png), [review SVG](06-angled-controls-review.svg), [standalone transparent vector](06-angled-mouse.svg). Photo is embedded only in the review board. Standalone has no raster content or rendered text. Labels sit on the left; Back demonstrates richer gold. Surface detail is deliberately reduced.

Main rejected the initial wedge-like trace and incorrect wheel placement, then aligned silhouette/control coordinates against the supplied photo. Final pass uses elongated side-button regions and shorter overlaid leader lines. VectorCraft import reported no warnings; parent rendered and visually checked the final preview. Owner review pending; no app integration or bundle changes.

Mapping reference: [Logitech official default-control diagram](https://secure.logitech.com/en-gb/software/mx-software), labels4Forward/5Back; orientation follows the supplied photo. This is illustration geometry, not a mechanical drawing or a working control surface.

Other requested app refinements remain pending: save-status simplification/settings link, richer accent, sidebar status text alignment/vertically centered icon. Current approval is the vector preview before integration.

## Native integration checkpoint — 2026-10-22

Owner-approved revision03 artwork and revision04 interaction design are integrated as native SwiftUI paths and buttons. Nine artwork paths match the approved SVG; both labels and physical regions call the same selection action for each of four targets. Text stays at native size; narrow layouts stack controls. Native automatic sidebar/inspector sizing remains unchanged.

- [Narrow native canvas](05-native-canvas-narrow.png): synthetic240pt-wide fixture.
- [Wide native canvas](05-native-canvas-wide.png): synthetic600pt-wide fixture.

Both images were captured from isolated test-owned SwiftUI hosts and visually inspected. They are fixture widths, not measured workspace detail widths. Native window lifecycle passes at820×560 and980×680. The in-process host/window accessibility tree was empty, so automated button presses were not established; clicks and keyboard access remain owner validation items. No live device/configuration operations were performed.

# MX Master 3S canvas review — 2026-10-22

## Approved angled artwork: revision15

Owner approved [15-smooth-band.svg](15-smooth-band.svg) and its rendered PNG on 2026-10-22. Revisions09–15 record generated-reference tracing, removal of tracing artifacts, manually rebuilt smooth curves, restoration of the broad thumb-wheel recess band and removal of its pointed join. Revision10 flattened too much distinction; revision11 introduced angular contours; neither is the integration source.

Native integration is in progress. The approved SVG uses20 path elements, solid fills and round strokes, no embedded bitmap. Preserve its curves and layering; compile the geometry into cached SwiftUI paths rather than loading SVG at runtime. Further automatic path merging is deferred because overlapping colour blocks establish the approved appearance. Labels and hit regions remain native, separate from the decorative artwork.

Native integration is now verified and packaged in signed build5a564e91901e, pending owner interaction acceptance. [Narrow native preview](16-native-angled-narrow.png) and [wide native preview](16-native-angled-wide.png) show native outlined regions and labels. The narrow preview uses full-width labels; wide leaders are straight, visible above the artwork and end with dots. Exact20-path static audit passed. Test harness windows now remain behind other apps and non-key; no real pointer clicks were asserted. [Full verification boundaries](../../../ui-alignment-validation.md).

## Current revision04: linked control selection

Owner agreed to combine outlined diagram regions with labelled callouts selecting the same target. [Review SVG](04-linked-controls-review.svg) and [VectorCraft PNG](04-linked-controls-review.png) retain revision03's simplified silhouette. Wheels are outlined on the main drawing. A schematic enlarged thumb-side inset distinguishes Forward and Back without inventing top-facing buttons; Back shows the selected gold styling. The dashed inset connector is decorative.

This is a static interaction-design preview, not a working click prototype. On integration, labels and corresponding shapes must call the same native selection action; labels provide larger keyboard-accessible targets. All four controls retain neutral outlines when unselected. VectorCraft import/export reported no warnings and the render was visually checked. **Owner approved revision04 and integration on 2026-10-22. Native SwiftUI implementation is source-frozen. Independent static review confirms the nine artwork paths match revision03 and all four targets map correctly. Release compilation and strict signing passed; native interaction/layout verification is in progress.**

## Current revision03: simplified approved shape

Owner accepted revision02's shape and requested less detail. Revision03 retains the exact outer silhouette path and removes palm contours, texture, wheel grooves and layered button/palm shading. Nine paths remain, using flat body tones and plain wheels.

- [Simplified mouse SVG](03-simplified-mouse.svg)
- [Before/after PNG](03-simplified-comparison.png) rendered through VectorCraft; [comparison SVG](03-simplified-comparison.svg)

VectorCraft import/export had no warnings; the render was visually checked. The silhouette path was compared programmatically and is unchanged. Owner accepted the reduced-detail artwork and linked-control revision04 on 2026-10-22. Native integration is in progress.

## Current revision: supplied photo reference

The owner rejected revision01 as unrecognizable and supplied a top-view mouse photograph. Revision02 follows that reference's silhouette and proportions: sloped narrow front, inset main-button seams, small central wheel and flared left thumb rest.

- [Pure vector mouse](02-reference-aligned-mouse.svg): transparent background; no embedded photograph.
- [Rendered comparison](02-reference-comparison.png) and [comparison SVG](02-reference-comparison.svg): supplied photo on the left, revised vector on the right. The comparison board embeds the photo only for review.
- Opened and rendered through VectorCraft without warnings; output visually checked side by side.
- Back/Forward are not visibly exposed in this photo's angle. They have not been invented as large top-facing buttons. Final interaction callouts/possible side detail follow silhouette approval.

**Revision02 review pending. No app integration. Revision01 below is rejected history.**

## Revision01 — rejected

Owner requested a recognizable, simple vector mouse with physical control-shaped targets or linked labels, and a rendered SVG review before integration. The previous rounded box/grid did not meet that expectation.

- [Review SVG](01-mouse-review.svg) and [VectorCraft PNG render](01-mouse-review.png): thumb-side three-quarter concept, Back selected in gold; other editable controls outlined neutrally. External labels connect to their physical locations.
- [Neutral mouse artwork](mouse-artwork.svg): transparent background, no labels or baked selected state. Target IDs identify `back-button-target`, `forward-button-target`, `vertical-wheel-target` and `thumb-wheel-target`.
- Shape and placement are deliberately simplified, not a mechanical drawing. Reference: [Logitech product/control overview](https://support.logi.com/hc/en-za/articles/5218056588311-Getting-Started-MX-Master-3S), plus a viewed product photo for silhouette.
- SVG imported into VectorCraft without warnings and PNG exported there. No raster photo is embedded. The photo reference is not bundled or integrated.
- Callout labels are part of this review board. Integration should use native accessible controls and semantic selection styling, not clickable text baked into a bitmap. Other mouse details remain decorative; no new supported controls implied.

**Review pending. No app integration or production source/bundle changes.** Native layout behavior and small-canvas readability must be verified during the separately approved integration.

## Connection diagnosis checkpoint

Owner approved relevant diagnostic events. A filtered last-hour query found external-state failures in builds17e2cfd76146 and97d79d553024, each with `code=bolt.state.external-change` and `source=LogitechBolt/BoltController.swift:511`. That narrows the error to `performEnable`'s catch boundary. It does not identify the exact throwing guard: enable verifies capabilities, existing wheel/thumb-wheel ownership and button baseline/diverted readback before enabling delivery. It does not prove another app changed reporting. No live HID requests, configuration changes or production fixes were performed.
