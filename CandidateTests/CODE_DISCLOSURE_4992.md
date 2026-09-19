# 4992: code disclosure through the shared message layout handoff

Base: the phone's migration build 4991, clean source `3c641a0cd2fc804dc7e92b35e14cff374624b4ff`. Candidate branch: `codex/code-fold-shared-layout-4992`. The independent formal bundle remains 4957.

## Captured failure

On iPhone 17 Pro, a fresh conversation's first footer collapse after generation entered a blank region. The 4991 trace reported `concreteEntry=false`, 26 `concreteLatestTailMissing` events, and a completed fold at `contentH=3298.7`, `offsetY=2458.7`, mathematically at bottom. Switching away and back changed entry to concrete layout. The same code repeatedly expanded/collapsed without the reported blank region; settled collapsed content height was about 1297.7, with zero tail-missing events. These are geometry diagnostics and user-reported visual outcomes, not CPU measurements. The original capture and phase summaries are in the 4991 candidate's ignored `work/diagnostics/fold-4991-20260910-132921` directory.

## Change

Code disclosure now uses the existing deletion/version native-release, bounded concrete window, measured landing and acknowledgement lifecycle. A typed edit distinguishes deletion, reply replacement, and display-only code disclosure. Folding never calls model deletion, version selection, import or persistence.

The clicked code header/footer is the reading anchor; a genuine bottom source retains the shared bottom policy. Disclosure state belongs to the current loaded message window rather than a particular SwiftUI lazy/concrete host. Independent message, text/reasoning region and block IDs prevent collisions. Paging releases states outside the loaded window; empty conversations clear them. A superseding same-block request inherits the original reading edge and bottom/follow intent.

Folding keeps the message ID, so a request-specific code-layout preference must acknowledge the committed display state before the shared row/sentinel/container geometry gate can pass. Existing message and bottom preferences carry that same request UUID; old and new layout epochs cannot be merged or accepted together. The native code anchor size must also match the acknowledged SwiftUI code size. The preference exists only for the active disclosure; the native anchor is weak and publishes no idle frame state. User interruption can cancel an uncommitted display change without changing height in an unprepared lazy host. Committed display state remains selected when positioning is interrupted. Pending model edits retain the original exactly-once cancellation behavior.

The code height changes without an interpolated height animation. The old display-link coordinator, separate root lease, direct release observer, presentation-frame sampling, full-text retention/completion cycle, and separate render/height measurement path are removed. Collapsed previews scan only as far as the requested LF boundary and preserve the previous preview bytes, including CRLF and Unicode. Copy, HTML preview, colors, text font and selection remain on their existing paths. Whole-message streaming rejects manual disclosure; it cannot silently change height after viewport admission fails.

## Verification

- `check_deletion_handoff.py`: 129 production-extracted behavior checks, retaining the deletion/version cases and 24576 deletion-selector combinations. New cases cover same-ID old geometry, mismatched extent from the captured failure, stale UUIDs, header/footer, history, bottom, single correction, cancelled/reversed requests, independent display state, paging release, and preview equivalence. Geometry and UIKit services are mocks, not SwiftUI pixels.
- `check_layout_snapshot_epochs.py`: 9 checks against the production preference reducers and frame structures pass, including unchanged-size frames with a new request UUID.
- `check_conversation_entry.py`: 24 existing entry/window lifecycle checks pass.
- `check_drawer_content_cleanup.py`: 1524 existing drawer/text equivalence checks pass.
- `check_unclassified_assistant.py`: 52 ownership/import/delete lifecycle checks and source integration checks pass.
- Product audit: 37 other Swift source files are byte-identical to 4991. AppModel, storage/import, code colors and HTML renderer are unchanged. Removed fold symbols have no remaining product references.
- Swift parse and whitespace checks pass. The three changed product Swift files have 360 inserted and 858 removed lines: net 498 lines removed.
- Final Generic iOS Release build succeeds. All 41 build-input hashes match the recorded final manifest. Main app and extension are 0.1.0 (4992), the existing migration bundle identifiers, and arm64; strict signatures, device provisioning, and binary/dSYM UUIDs pass. The verified 4991 rollback artifact remains available.
- Same-bundle 4992 installation and installed-version readback succeed. The separate formal bundle remains 4957. No uninstall, data clear, chat copy or restore was performed. Initial diagnostic launch was rejected because the phone was locked; this is not an app launch or interaction pass.

Two preliminary Release builds were interrupted for source review before an artifact was accepted or installed. Only the final source manifest may qualify the deployment artifact.

## Physical acceptance still required

New-chat generation followed by first collapse without switching; re-entry collapse/expand; historical code with later messages; header/footer and middle/bottom positions; repeated reversals; interruption by drag, drawer, keyboard or conversation switch; long-code first/warm expansion responsiveness; copy, selection, horizontal scrolling and HTML preview. Existing deletion/version behavior must remain intact. This source/test record does not claim those device gates passed.
