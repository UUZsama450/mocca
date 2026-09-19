# Mocca 5047: independent-review correctness repairs

Candidate: `work/candidates/mocca-review-correctness-5047-a`, branch `codex/review-correctness-5047`.
Base: 5046 source `87c1d6d66dad3c087af327a2ef5ba2c809fe7e25`.
Deployment identity: `com.uuzsama450.mocca.migration`, version 1.0 (5047).

## Scope and behavior

Each repair has its own implementation commit. This candidate combines them for integrated verification.

- **A1 / c405223 — MCP refresh ownership.** Requests re-find the server by ID, check connection identity and the latest request token, and merge the latest local tool preferences. Configuration saves, deletion and configuration restoration invalidate outstanding refreshes. Stale successes and errors are discarded. Explicit Sync saves without starting a second automatic refresh.
- **A2 / f4205ea — Approval lifetime.** MCP and calendar share one request-identified admission slot. Contending calls receive the explicit `approval_busy` result and execute no tool; callers may retry after the current approval finishes. This is intentional conflict rejection, not a queue. Cancellation and stopping a run resolve the waiter; stale alert callbacks cannot resolve a newer request. Executing a tool checks conversation/run/message/persistence identity again after suspension. Calendar objects edited during approval and MCP configurations changed during approval require a new request.
- **A3 / cfffd82 — Failed-save recovery.** A successful authoritative reload retains separate unsent composer packets with unchanged destinations. Missing or ownership-changed destinations get a fresh empty “恢复的未发送草稿” conversation. The previous transcript never overwrites the reloaded store. Attachment reclamation retains all recovered composer attachments. Sending rechecks selection after recovery so an old send cannot silently target a replacement conversation.
- **A4 / 58ff7cc — Branch transaction.** A new branch is staged and saved synchronously before navigation is published. Failure removes only that staged branch. Source records, selected versions and navigation remain unchanged; normal bookmark-clearing behavior is preserved on successful branching.

## Verification and reproduction

All generated stores, provider credentials and attachments in the tests are synthetic. No phone chat database is read, copied, altered or backed up by the verification scripts.

1. `/usr/bin/python3 CandidateTests/run_review_mcp_refresh.py` extracts the unchanged production MCP methods and types into a Swift 6 harness with deterministic network/storage substitutes. Nine cases: delete target, delete predecessor, latest preferences, reverse success order, stale error, changed connection, delete/re-add identity, task cancellation, and single explicit sync.
2. `/usr/bin/python3 CandidateTests/run_review_approvals.py` extracts unchanged production admission, resolution and lifetime checks. Exercises same-kind and cross-kind contention, stale callbacks, exactly-once completion, cancellation before/during admission, and invalid run/message/epoch/conversation.
3. `/usr/bin/python3 CandidateTests/prepare_review_correctness_host.py <new-output-directory>` creates a disposable full-app hosted XCTest target. Private fault-control hooks are appended only to copied source files in that host. Product methods and SQLite commit/reload paths are otherwise unchanged. `ReviewCorrectnessTests.swift` exercises failed send → successful reload → successful retry, real attachment bytes and orphan cleanup, missing/changed destinations, repeat recovery, branch failure/retry, stop/late approval, and executor cancellation races. The QA bundle is separate from the phone bundle.
4. `/usr/bin/python3 CandidateTests/prepare_review_approval_ui.py` generates an isolated SwiftUI UI host using the actual approval methods and actual alert modifier. XCUITest checks repeated MCP/calendar presentation and responses, and cross-kind contention without losing the original approval. This verifies the alert mechanism, not all RootView modal combinations.

The initial hosted run exposed two test-fixture issues: generated subsecond dates compared against the storage codec round-trip, and an assertion that incorrectly attributed startup MCP discovery to tool execution. The final fixture uses exact-second dates, keeps full-record equality assertions, and tests the executor result for `request_expired`. Initial logs are retained.

Build/test commands, extracted-method hashes, logs and result bundles are under `work/review-tests` and `work/review-approval-ui`. Verified automatic results:

- Swift 6 MCP harness: all nine scenarios passed.
- Swift 6 approval harness: all seven scenario groups passed (including both kinds and their contention).
- Full-app hosted XCTest: **9/9 passed**, final combined run `HostedCombined.xcresult` (the preceding 8-case run also passed); 146 product input hashes unchanged during the run.
- SwiftUI approval UI host: **3/3 passed**, `FinalTests.xcresult`, including cancellation dismissing the alert and a usable following request.
- Final signed Release passed in 427.9 seconds. All 146 input hashes stayed unchanged and match the successful full-app hosted tests. Main app and extension are 1.0 (5047), arm64, strictly signed, with matching Mach-O/dSYM UUIDs. `artifact-verification.json` contains exact identities.

An earlier Release build was cancelled after a source review added the restore-status cleanup. It is not a deployment artifact; the final Release run checks that every one of its 146 source inputs exactly matches the successful full-app test run.

## Performance and remaining acceptance

No new work is added to scrolling, Markdown layout or animation frames. No polling loop, retry timer, additional normal-send database write, or whole-store backup was introduced. Recovery work runs only after a blocked store reload; MCP checks run on tool operations. The send selection check uses the existing conversation lookup cache. These are code-path observations, not measured iPhone frame-time or launch-latency results.

This candidate does not resolve or diagnose first-send latency, long rich-content cold entry, the deferred reading/return-to-bottom behavior, or backup restoration under process termination. Draft preservation here is recovery within the running app; it does not introduce durable unsent-draft storage across process termination. Physical iPhone interaction/performance acceptance remains separate from automated tests and signed build/install proof.

The combined ninth test covers a persisted partial reply and pending approval during failed-save recovery: recovery resolves the old approval as expired, invalidates the run, preserves unsent input, and displays the partial reply as interrupted.

## Device deployment — 2026-09-16

Installed in place on the iPhone 17 Pro and launched successfully. Installed-app readback confirms `com.uuzsama450.mocca.migration` **1.0 (5047)**; the production bundle remains **1.0 (5029)**. Main process PID 6944 and extension PID 6934 were observed from the newly installed app path. No uninstall, data clear, or conversation-store copy was performed. This confirms deployment and process launch, not byte-identical chat contents or physical interaction/performance acceptance.

`work/review-tests/FINAL-VERIFICATION.json` links the final source identity, all automated results, matching 146 product inputs, and deployment evidence. The user still needs to accept real-device behavior; first-send latency remains unresolved.
