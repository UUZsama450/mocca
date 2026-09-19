# 5000: restore protection, HTML preview, assistant history search

Internal development / verification record. Not App Store copy or an App resource.

Baseline: phone test app `com.uuzsama450.mocca.migration` 0.1.0 (4999),
source `3bd3a788855bebd32b37336215bd66b08bbc4cdf`.
Candidate: `codex/recovery-html-history-5000`, product commit `8f06fce`.
Product delta: +654 / -167 lines (net +487), across seven files including build
numbers. Most added code belongs to restore-only failure handling.

## Scope

- Native and legacy backup restore stage incoming directories before replacing
  live files, retain old directories through commit, and roll back catchable
  failures. The restore-only checkpoint captures affected model/defaults/Keychain
  state in memory. Credential bytes are not written to another plaintext file.
- Restore verifies settings and credentials before the primary conversation
  store commit. Calendar notification scheduling follows successful commit.
  Actual rollback failures retain recovery files and stop further persistence;
  temporary cleanup failures alone do not lock chat persistence.
- The existing safety ZIP for a user-requested overwrite is moved out of export
  temporary cleanup and exposed before restore starts, including failure paths
  and reopening the backup page. Routine installation does not create a ZIP.
- HTML places trusted policy markup before source parsing instead of locating
  a head tag with regex. Chat-enabled previews install WebKit resource rules
  before running the source; stale compilation callbacks and subframe bridge
  requests are rejected. Ordinary preview CSP/CDN policy is unchanged.
- `search_conversations` now uses the initiating assistant's other explicitly
  owned single chats, as chosen by the user. It excludes groups, unassigned
  chats, other assistants and the source chat. Live source ownership and tool
  permission are rechecked; changing the selected UI chat does not alter scope.
  Results use visible reply versions and return bounded historical text as data.

## Boundaries

- Restore rollback covers caught in-process errors, not a crash-atomic transaction
  across all files, UserDefaults and Keychain. No power-loss/force-kill guarantee.
- WebKit resource rules are not a complete network sandbox. A synthetic macOS
  WKWebView test demonstrated WebRTC STUN traffic despite private CSP and rules.
  The former absolute offline claim is removed; the chat permission explanation
  now says that resource restriction is not complete disconnection and asks the
  user to authorize only trusted pages. No real chat content was used in tests.
- Heavy-chat entry delay, images, long text and top/bottom scrolling remain
  paused. The accepted table-height fix and 4999 table implementation are kept.
- The separate no-file backup contract, MCP, calendar-load, Claude-stream and
  StoreKit audit items are outside this change.

## Validation

- History: 83 checks in a synthetic Foundation host extracting production scope,
  search, visible-version projection, schema and tool-handler code. Includes
  revoked ownership/tool permission, UI switches, extra scope arguments,
  malformed limits and Unicode boundaries. This is not a provider roundtrip.
- HTML: extracted iOS 17 SDK view/coordinator typecheck passed. Actual macOS
  WKWebView fixtures cover source comments, full documents, fragments, original
  attributes/styles/title, SVG, Canvas, interaction and resource isolation.
  110 checks passed. The HTTP positive control received 5 requests and four
  private-resource cases each received zero, including document rewriting and
  CSP removal. Both ordinary/private WebRTC controls emitted 5 local STUN
  packets; this is the confirmed limitation above. The final report is in
  `work/verification/html-preview-host/report.json`.
- Backup: 37 isolated scenarios / 136 assertions passed using extracted
  production transaction, file, checkpoint, model rollback and persistence
  functions. Security calls use an in-memory adapter; defaults use a unique
  suite, and real file I/O uses a temporary fixture directory. This covers
  staging/exchange failures, credential faults, model rollback, cleanup-only
  failure and the final primary-commit boundary. Report:
  `work/verification/backup-restore-host/results.log`. No real chat restore.
- Build/sign/install evidence is recorded separately from interaction acceptance.
  Source input hashes: `work/verification/build-source-inputs-5000.json`.

## Deployment (2026-09-11)

Signed generic iOS Release build succeeded. All 46 source inputs still match the
frozen manifest; main app and extension passed strict signing, arm64, version,
profile/device and dSYM UUID checks. The verified 4999 rollback artifact remains
available. Existing UITextItemInteraction deprecation and absent-AppIntents
metadata warnings remain; there were no build errors.

After the iPhone 17 Pro reconnected, the test bundle was overwrite-installed
from 4999 to 5000 and launched. App readback confirms 5000; the distinct formal
bundle remains 4957. Main PID 3212 matches the launch result and process snapshot;
extension PID 3208 runs from the new install directory. Records:
`work/verification/artifact-5000.json` and `deployment-5000.json`.

No uninstall, data clear, phone chat copy or extra backup was performed. Version
and process checks do not prove chat byte equality. No real-chat backup restore,
provider history-search roundtrip or iPhone HTML interaction was performed;
functional phone acceptance remains with the user's ordinary use. No App Store
metadata or submission action was taken.

Reproduce from this candidate with `/usr/bin/python3`:

```sh
/usr/bin/python3 CandidateTests/check_assistant_history_search.py
/usr/bin/python3 CandidateTests/check_backup_restore_transaction.py
/usr/bin/python3 CandidateTests/check_html_preview_isolation.py --output work/verification/html-preview-host
```

Primary references: [WebKit resource rules](https://webkit.org/blog/3476/content-blockers-first-look/)
and [WebKit's WebRTC CSP support issue](https://bugs.webkit.org/show_bug.cgi?id=255651).
