# 4995 code syntax highlighting candidate

## Baseline and scope

- Branch: `codex/code-syntax-highlighting-4995`.
- Source baseline: `aa677604ff89a30974861020a6603bb4b017ce25`, the clean 4994 candidate at `work/candidates/mocca-code-fold-prose-refresh-4994-a`. All 42 recorded 4994 source inputs matched before branching.
- The iPhone 17 Pro inventory on 2026-09-10 confirmed test bundle `com.uuzsama450.mocca.migration` at `0.1.0 (4994)` and formal bundle `com.uuzsama450.mocca` at `0.1.0 (4957)`.
- This candidate is `0.1.0 (4995)`, built for the test bundle. Preparation left the phone unchanged; the later explicitly authorized installation is recorded below.
- Navigation top/bottom frame drops remain a separate paused investigation. RootView, AppModel, the fold/scroll owners, and persistence sources are unchanged.

## Resulting behavior

Fenced code with a recognized language receives syntax colors in the existing native UITextView, including while its text is streaming. The existing code-block appearance setting chooses a light (`xcode`) or dark (`atom-one-dark`) syntax palette, including following the system appearance. Unknown or absent languages use plain text; no automatic grammar detection runs.

HighlighterSwift is pinned to 3.1.0, revision `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0`. It runs highlight.js locally through JavaScriptCore. The engine does not execute code from messages. Its license notices are included in the app bundle.

One actor owns the parser. Each live text host permits one outstanding request and retains only its latest pending snapshot. Generation checks discard stale results. This is bounded whole-snapshot parsing with coalesced requests, not an incremental lexer. Finished results use a cache bounded by 32 entries, an estimated 2 MiB of source/run payload, and 24,000 color runs.

Only foreground colors reach UITextView. The existing font, paragraph style, measurement, selection, copy, horizontal scrolling, HTML preview, and fold ownership remain in place. Streaming appends retain existing prefix colors; a completed result recolors only the changed run suffix. Newly arrived text can briefly use its ordinary foreground color before analysis finishes.

## Explicit limits

- Streaming source: at most 8,192 UTF16 units; settled source: at most 32,768. Folded code is evaluated using its displayed prefix.
- At most 3,000 returned color runs. Exceeding a limit returns the complete original displayed code in plain color, with no truncation or loss of copyable content.
- Crossing the streaming limit clears the previous colors. After the block closes or generation finishes, it can become colored again if it fits the settled limits.
- Input length is checked before parsing. The returned-run limit is checked after parsing and is not a hard CPU deadline. An in-progress synchronous JavaScript parse cannot be interrupted by task cancellation.
- Background parsing, result checks, and native text-color updates have costs. No zero-cost or physical-device frame-rate guarantee is made.

## Verification

- Backend host matrix: PASS using the real production source and pinned dependency, covering common grammars, language aliases, unknown/plaintext fallback, Unicode and UTF16 ranges, streaming prefixes, completion, folded/full content, themes, concurrent requests, and input/output limits. See `CodeSyntaxHostVerification.md` for reproducible commands, source hash, and host timing limitations.
- Native styler scheduler semantics: PASS 11 cases using real NSMutableAttributedString and minimal UIKit stand-ins. Stale results, cancellation, latest-only scheduling, appended suffixes, theme/language changes, UTF16 text identity, and preservation of non-color attributes are covered. This is not actual UIKit layout or pixel verification.
- Existing deletion/position handoff: PASS 157 behavior checks; prose viewport refresh: PASS 15 cases; layout snapshot epochs: PASS 9 cases. These harness results do not establish real-device interaction acceptance.
- Final signed generic-device Release build and artifact verification: PASS on 2026-09-10. The build used implementation commit `9e68eb2ba71a6c4309712ee2cc7878160fbb149d`; all 46 frozen source/package/license inputs remained unchanged. App and extension both report 0.1.0 (4995), match the test bundle IDs, pass strict/deep signature verification, and have matching arm64 dSYM UUIDs. The actual bundle contains highlight.js, both selected CSS palettes, and the license notices.
- App binary SHA-256: `d24449a4b7a8d09a81551e926942aa24563ade8d012e03c7b8dfd5cadfca7c49`; extension binary SHA-256: `0473ead6f4a264632e3ddf68ba09568e6b5b004e012a48b9f99076267b5de352`.
- Raw evidence: `work/verification/build-4995-final.log`, `build-source-inputs-4995.json`, and `artifact-4995.json`. The preparation checkpoint inventory reported test 4994 and formal 4957, before the later authorized installation below.

## Physical-device acceptance still pending

Check light/dark/system colors, partial streaming strings/comments, copy and selection, horizontal offsets, code folding during streaming, HTML preview, large-code fallback, and long-chat drawer/navigation frame pacing on the iPhone 17 Pro. A successful build or host harness does not mark these interactions accepted.

## Authorized deployment on 2026-09-10

The user explicitly requested installation after the candidate was prepared. Fresh preflight confirmed the iPhone 17 Pro was available, test bundle 4994/formal bundle 4957, no competing install/build task, unchanged candidate source/artifact hashes, and valid main/extension profiles containing this phone.

Same-Bundle-ID overwrite installation and normal foreground launch both succeeded. Fresh app readback reports test `com.uuzsama450.mocca.migration` at `0.1.0 (4995)`; formal `com.uuzsama450.mocca` remains `0.1.0 (4957)`. Process readback found both the main app (PID 1161) and extension (PID 1158) under the newly installed application bundle URL.

No uninstall, data clear, chat-container inspection/copy, migration, or restore was performed. This proves deployment and process startup, not byte-identical chat preservation or physical interaction acceptance. Code highlighting appearance, streaming feel, and frame pacing still await the user's on-phone check.

Evidence: `work/verification/deployment-4995.json`, `install-4995.json`, `launch-4995.json`, `phone-postinstall-4995.json`, and `processes-postinstall-4995.json`. The unchanged 4994 source and verified artifact remain available for rollback.
