# 4989 Shared reply-version and deletion viewport handoff

Baseline: installed4988 product69dcad7, device acceptance records5e6cfca; first source cleanup0456757 was never installed. Candidate product5d8b1f6 (shared handoff46c8048 plus current-viewport clamp). User reported a middle/off-bottom long→short version switch entering backroom, then explicitly requested fixing/optimizing the whole <1/2> version switching route. Prior18 checks only asserted middle switching did not create a bottom owner; they did not validate retained reading position. Ordinary4988 conversation-entry acceptance remains separate.

## Behavior

Reply version buttons now enqueue the same native-release → exactly-once model commit → bounded concrete layout → one landing → measured acknowledgement protocol used by4987 deletion. The request records the replacement variant and a landing policy: the real latest tail at actual bottom keeps exact bottom; other visible version selections preserve the reply's lower edge (clamped to the readable viewport), or use a real-row target if no source frame exists. Native legal scroll bounds always limit correction. Completion requires the new frame to be visible, layout/container geometry to agree, and the requested version edge/bottom correction to have reached its legal destination.

Rapid replacements commit explicitly requested model changes exactly once while replacing the old viewport request. A same-group superseding request can inherit the reading edge before the intermediate variant has published its frame. The new request UUID and full source/landing anchor prevent old release/geometry callbacks from operating on a newer request. User interruption cancels positioning; a pending explicit model mutation is not silently dropped. Invalid cross-group versions are rejected before mutation.

Version entry yields pending/active navigation and conversation return; shared preparation cancels layout/stream-follow tasks and automatic reasoning-collapse ownership. Native release occurs on the existing request-scoped task and next-main-queue boundary, not a timed retry. A version button's touch does not reject initial admission; actual native touch/motion is checked at commit and landing.

The old VersionReplacementRevision state, direct target claim, direct ACK/fallback/compact-wait materializer branches are removed. Other generic bottom-row materialization routes retain their original top-seed/retry behavior; the new shared request disables native bottom following and owns concrete layout while active. Internal deletion-only plumbing names become MessageReplacement, including native release fields and logs. The pure deletion landing selector and operation remain separate; the AppModel window wrapper is renamed limitMessageWindowForConcreteLayout without algorithm changes. Canonical chat/version persistence logic is unchanged.

The initial local window remains bounded by12 rows and the existing20000 UTF16 text/reasoning/tool-text admission budget, with a single oversized target allowed alone. Concrete layout can persist through24 rows, then normal window behavior resumes. The inherited memory/height cost of a huge individual reply is not bounded by this budget.

## Verification

-55 compiled production-extracted behavior checks, including the prior37 deletion cases and18 new version cases: middle long→short and reverse, true-bottom tail, underflow clamp, missing new frame, visible but incorrectly positioned frame, rapid choices, stale release, cancellation, and invalid group.
-24576 deletion target combinations.
-24 ordinary-entry lifecycle checks.
-13 actual window selector checks plus1830 target/window combinations.
-swiftc parse and git diff --check.

Mocks supply model persistence/native geometry and UI callbacks in the offline checks. These checks do not emulate actual SwiftUI layout, pixels or performance. Removed cleanup-only golden/old-version-owner tests target code that no longer exists; their relevant lifecycle assertions are now in check_deletion_handoff.py. Existing diagnostic logs remain historical evidence.

OnlyRootView.swift, one AppModel API name and project version change versus signed4988 product inputs;39 other productSwift files match. No new timer/retry was added to the shared handoff. Generic Release build/signature/install/readback are recorded separately in DEVICE_4989.md after completion.

## Physical acceptance pending

First test the reported middle/off-bottom long→short case, then short→long and repeated choices at the same location. Also check tail-at-bottom variants, ordinary entry, deletion, history paging, same-window versions after paging, focused composer, and user interruption. Blank frames, forced global-bottom jumps while reading in the middle, stale-version landing, or visible stutter are failures. Do not equate internal LANDED with visible acceptance.

Rollback: verified strictly signed4988 migration app retained in the prior candidate. No uninstall, chat copy/import/clear or additional chat backup is authorized or planned. Build4989 uses the migration bundle; formal4957 remains separate.
