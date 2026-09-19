# Assistant history title search

Baseline: accepted migration build 5057, commit `5c199036a1b53b0423897555ae6f3096fc6f204e`.
Candidate: `codex/history-title-search`.

When the user supplies a window title such as `App被苹果拒审`, the previous tool
searched only message bodies. A conversation with that title and the message
`我们的app被拒绝啦😱` therefore returned zero matches.

The tool now resolves exact titles first, including duplicate titles within its
existing scope. If no exact title exists, partial-title matches precede body
matches. Same-rank results retain the existing recency order. The existing
query and conversation-count limits remain in place. Title matches return up
to four recent visible user/assistant message snippets, each using the existing
280-scalar content budget, so an opening greeting does not consume the only
context slot. Empty conversations return title metadata and an empty messages
array. Hidden reply versions, other assistants, group chats, unassigned chats,
and the requesting conversation remain excluded.

The tool description explains title matching and retrying shorter queries.
The tool-result card displays the actual number of matches, including zero,
instead of the number of JSON fields; existing Chinese/English strings are reused.

## Performance boundary

Title matching runs only inside an explicit `search_conversations` invocation.
No background index, persistent cache, sidebar gesture, drawer animation,
observation, or persistence implementation changed. Exact-title lookups stop
before reading unrelated message bodies, even with the default five-result
limit. The existing search and visible-message projection still execute on
MainActor: this change does not establish a frame-time guarantee during a tool
call. iPhone sidebar performance and provider roundtrip acceptance are unmeasured.

## Verification

- 100 assertions passed in `CandidateTests/check_assistant_history_search.py`,
  extracting production search, scope, visible-version projection and tool code.
- The regression fixture reproduces title/body wording differences, partial and
  case-insensitive titles, scope exclusions, bounded recent context, empty chats,
  selected versions, Unicode and unchanged body matching.
- With 1000 other owned conversations, a default-limit exact-title lookup reads
  only the matched conversation's messages. This is a deterministic host check,
  not a physical-device benchmark.
- Static comparison confirms AppModel changes are confined to the history-tool
  search function and RootView changes to the tool-result summary.
- Full generic iOS Release build passed (`CODE_SIGNING_ALLOWED=NO`); this is compile/link validation, not signed deployment.

## Device deployment (2026-09-20)

Build 5058 was signed and overwrite-installed onto the iPhone 17 Pro using the
existing `com.uuzsama450.mocca.migration` identity. Readback confirms Mocca 1.0
(5058). Main app PID 16522 and extension PID 16520 use the new installed bundle.
Main/extension strict signatures, arm64, Mach-O/dSYM UUIDs, profile expiry and
device membership, exact signed entitlements, and 149 frozen source files passed.
Evidence: `work/verification/deployment-5058/deployment.json` and `artifact.json`.

No uninstall, data clear, new conversation backup or App Store action occurred.
Chat bytes were not copied/compared; deployment checks do not prove byte-for-byte
chat equality. Real model title search and iPhone sidebar frame times remain
unverified. The user can retry the same window title after this installation.
