# 4994: refresh prose exposed by a completed content layout

Base: clean `6be96c9caf47463931cbe1c60343f9dbc12e4047`, installed migration build 4993. The user confirmed no blank-region scrolling regression, then supplied a recording in which prose below a collapsed code block stayed invisible until a small scroll.

## Change

The existing shared replacement handoff now asks native prose hosts in the current chat scroll view to recheck viewport drawing coverage after the final row, code, bottom-sentinel, container and offset checks succeed. This covers a prose host moving onscreen without changing its text, size or outer scroll offset. The same completion boundary handles code disclosure, message deletion and reply-version replacement.

The traversal stops at each native prose view. It reuses the existing non-forced coverage check, so already covered text and still-offscreen text do not redraw. The original 720-point overscan, full text height, measurement caches and glyph renderer are unchanged. No observer, timer, per-frame work, additional scroll command or layout measurement is introduced. An unused private `viewportDrawingRect()` calculation is replaced by this refresh entry point; it had no callers.

Two product Swift files change: 18 added and 7 removed lines, net +11. Four project configurations advance app and extension to 4994. The code fade, fold state, stream-display suspension and provider/model/storage code are unchanged.

## Verification

- `check_prose_viewport_refresh.py`: 15 checks pass using extracted production traversal, clipping and invalidation functions with CoreGraphics and a translation-only UIKit hierarchy double. Covers unchanged-size/offscreen-to-onscreen collapse, bounded overscan, duplicate acknowledgements, covered movement, expansion/re-collapse, detached hosts, full-height retention and current-chat traversal scope.
- `check_deletion_handoff.py`: 157 behavior checks pass, including 24576 deletion-selector combinations. Added checks establish no premature paint refresh and one refresh for accepted header/footer landings. This mocks UIKit and SwiftUI scheduling.
- Swift parsing and whitespace checks pass.
- Generic signed Release passes at source commit `48718c7e55c3740c206bab57313eb1de5ed232bd`; all 42 recorded build inputs match. Main app and extension are 0.1.0 (4994), arm64, with strict signatures, matching dSYM UUIDs and valid device profiles.
- Same-bundle installation, installed-version readback and normal launch/process readback pass on iPhone 17 Pro (main PID 1056). The independent formal bundle remains 4957. No diagnostic arguments, uninstall, data clear or chat copy were used. Artifact and deployment records are in ignored `work/verification/`.

## Physical acceptance

Pending. Check the recorded path on iPhone 17 Pro: collapse long code near its header while prose follows, then leave the screen still. The prose should appear without a scroll. Also retain footer positioning, generation-time disclosure/following and local feedback. Offline checks cannot establish actual UIKit paint timing or phone responsiveness.

4993 source and signed artifact remain in `mocca-code-fold-stream-feedback-4993-a`; the separately accepted no-backroom 4992 source/artifact are also retained. No chat data is copied or altered by the validation procedure.
