# Offscreen stream tail lease candidate

## Baseline and version boundary

- Exact source base: accepted build 4948 commit `959be25fc089962f13aeb250a005bcd5d9092c5a`.
- Source `CURRENT_PROJECT_VERSION` is 4951 for the app and extension in every configuration.
- Product bundle identifiers remain `com.uuzsama450.mocca` and `com.uuzsama450.mocca.GenerationActivityExtension`.
- Build 4951 was allocated only after source, mechanism-test, and simulator-build gates passed and the user explicitly authorized an in-place daily-app install.

## Prior evidence retained

- 4949 already implemented bounded streaming display cadence. It was a valid partial optimization, but device observation still became progressively janky during a long stream.
- The separate 4950 migration candidate attempted offscreen publication suspension, but used the top edge (`minY`) of one giant streaming message. That does not prove the growing live tail is offscreen; this candidate uses the bottom edge (`maxY`).

## Narrow change

- Provider delivery and the authoritative raw streaming buffer remain live.
- Completion continues to parse and persist the full raw response.
- Visible text publication can be suspended by two independent owners:
  - `detachedTail`: the user has manually left the live tail and its bottom is safely below the viewport.
  - `drawer`: the drawer is visually covering or moving over the transcript.
- Releasing one owner cannot resume publication while the other owner remains.
- Drawer release follows the existing sampled visual settle completion at progress zero, not the semantic close flag that changes about one frame after close begins.
- A detached-tail catch-up is deferred while the user's scroll motion is active and resumes inside the existing bounded 4949 cadence when the tail approaches.
- Lease bookkeeping is reference-backed and non-observable so it does not become another transcript-wide SwiftUI invalidation source.

## Explicit non-changes

- No cadence, first-visible-prefix, provider, Markdown parser, TextKit, animation, or persistence behavior was changed.
- No cache or prewarm was added.
- No accepted 4948 worktree or migration-bundle app was modified.

## Verification

- Independent policy/owner test executable: `OFFSCREEN_STREAM_POLICY_TESTS=PASS assertions=13`.
- `git diff --check`: clean.
- Debug arm64 iOS Simulator build with code signing disabled: `BUILD SUCCEEDED` before version allocation.
- Only the pre-existing `UITextItemInteraction` iOS 17 deprecation warning appeared.

## Acceptance boundary

The mechanism predicts less competing transcript work while the live tail is not being watched or while the drawer is visually active. It does not claim to improve bottom-watched streaming or scrolling a completed giant message. Build/install/launch evidence below does not constitute interaction acceptance; the candidate is not accepted until tested on the user's iPhone 17 Pro with a cold long stream.

## Build 4951 deployment

- A generic signed Release build succeeded. Main app and extension were 4951, arm64, strictly signed, and their binary/dSYM UUIDs matched.
- The first install attempt used the project's long-lived developer team `Z44VFV3SBB`. iOS rejected the overwrite because the installed daily app's application-identifier prefix is the older team `ZJCFBZ9ZZF`; post-failure readback confirmed daily 4949 and migration 4950 were unchanged.
- The same 4951 artifact was then re-signed through a command-line team override with `ZJCFBZ9ZZF`, matching the installed daily app. The project file itself retains `Z44VFV3SBB`; only this physical-test artifact used the old team.
- The old team's main and extension provisioning profiles expire at 2026-09-02 03:36 UTC (11:36 China Standard Time), so this deployment is a short test window, not a long-lived developer-account migration.
- Same-bundle in-place installation succeeded with no uninstall or data clear. Device readback showed daily `com.uuzsama450.mocca` at 0.1.0 (4951) and the separate migration app still at 0.1.0 (4950).
- The daily app launched, and its main app plus `GenerationActivityExtension` processes were observed from the newly installed bundle path.
- No chat-store snapshot or byte-identical preservation proof was requested or collected. Same-bundle installation preserves the container by design, but that is not a byte-level chat-data proof.
- Deployment is verified; cold long-stream scrolling, drawer interaction, and visual acceptance remain for the user's iPhone 17 Pro test.
