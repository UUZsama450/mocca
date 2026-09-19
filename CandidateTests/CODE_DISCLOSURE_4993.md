# 4993: streaming code disclosure and local feedback

Base: clean `e4fdba2136d805a32f19dcd41244cbf3b14ba7ad`, migration build 4992. The user confirmed that their folding test no longer entered the blank region and then reported the generation-time disclosure restriction. Phone readback before this candidate was migration 4992 and the independent formal bundle 4957.

## Behavior

Manual code expansion/collapse can enter the existing shared layout handoff while the conversation is generating. This also permits an earlier completed code block while the same reply or conversation continues. Genuine-bottom following is restored through the existing measured policy; an interrupted or off-bottom reader is not automatically reattached.

The request obtains a UUID-scoped owner in the existing streaming-display suspension ledger. Provider delivery and the authoritative model continue unchanged. One optional `ChatMessage` value belongs to that same request, keeping the visible row and its reasoning/updatedAt observations consistent even if completion or a non-text event bypasses text cadence. Idle rendering returns the ordinary message array directly. Canonical message IDs remain authoritative, so the held value cannot resurrect a removed message.

Successful landing releases the request and restores following before resuming the existing text cadence. Cancellation, failed release, missing target and supersession release the same owner. The existing ledger keeps drawer, detached-tail and newer-fold ownership independent. Completion cleanup can remove the stream's ledger without restarting it when an older fold releases.

An acknowledged manual disclosure advances one feedback generation. Code body and button labels use the same small opacity modifier: an immediate dip to 0.72 followed by 0.14 seconds back to full opacity. Reduce Motion leaves opacity at 1. Ordinary stream batches, pre-commit cancellation and stale callbacks do not advance this generation. Geometry has no height interpolation; feedback never gates stream release and does not duplicate the native code text view.

## Scope and verification

- Four product Swift files: 63 added and 19 removed lines, net +44 against 4992. Including the earlier cleanup, product Swift remains net -454 against 4991.
- AppModel, provider delivery, persistence, display cadence and text measurement are byte-identical to 4992. No new scroll coordinator, offset writer, timer, retry loop, full-code copy for animation or new cache is introduced.
- `check_deletion_handoff.py`: 153 checks pass, including the existing deletion/version cases and 24576 selector combinations. It extracts the production handoff, display-state, display projection and AppModel suspension method. Added checks cover streaming admission, completion without a later token, held final/non-text updates, release ordering, pre/post-commit interruption, rapid requests, independent drawer ownership and one-time feedback. UIKit geometry and provider/display scheduling are mocked.
- Existing checks pass: 9 layout-epoch checks, 24 entry lifecycle checks, 1524 drawer/text equivalence checks and 13 offscreen-display policy/owner checks.
- Swift parsing and diff whitespace checks pass.
- Generic signed Release build passes at source commit `9602c7bab4d39db7f6998b419e663380e9efe4fe`. All 42 recorded inputs match the signed artifact verification. Main app and extension are 0.1.0 (4993), arm64, with strict signatures, matching binary/dSYM UUIDs and valid device provisioning.
- Same-bundle installation, installed-version readback, normal launch without diagnostic arguments and process readback pass on iPhone 17 Pro (PID 1025). The independent formal bundle remains 4957. No uninstall, data clear, chat copy or restore was performed. Build, artifact and deployment records are in ignored `work/verification/`.

## Physical acceptance

Pending for 4993. The tests above do not establish animation smoothness or actual UIKit/SwiftUI layout. Key interactions are generation-time expand/collapse with resumed following, generation ending during a fold, first post-generation collapse without leaving the chat, historical code with later content, user interruption and short/long-code first/warm responsiveness. 4992 remains the separately preserved rollback source and signed artifact; it is not overwritten in the worktree.
