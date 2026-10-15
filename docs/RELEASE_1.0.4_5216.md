# Mocca 1.0.4 (5216)

Selecting Calendar or another assistant page could reset the horizontal tab strip to its leading edge even though the selected page was correct. The top bar now belongs to a stable outer container while the page content changes inside it. Typography, colors, spacing, navigation controls and the native soft scroll edge are retained, along with the 5215 settings-popover repair.

The 5215 baseline reproduced the defect: the Calendar button midpoint moved from 357.0 to 584.33 points. After the fix, it stayed at 357.0 points in both light and dark appearance. Six focused simulator cases passed, covering tab position, subsequent Calendar/MCP/Tools switches, header occlusion and memory popover reopening/navigation. Screenshots were inspected. A zero-test runner invocation was discarded; only the run that actually executed all six cases counts as verification.

Only `Mocca/AssistantViews.swift` and project build metadata change among portable product inputs from 5215. Existing public signing, disabled sponsorship and reviewed assets remain configured for the portable edition. The signed 5216 phone build was installed in place, launched and read back; the user confirmed the horizontal-position issue was resolved. Distribution-build verification is recorded separately in the accompanying manifest. Simulator checks do not establish phone FPS or temperature.

Use the explicitly linked 5216 source commit/archive, `BUILD-INFO-5216.json` and `SHA256SUMS-5216.txt`. The historical v1.0.4 tag still references the original 5206 snapshot. The unsigned GitHub IPA requires your own signing. App Store review is separate, with manual release after approval.
