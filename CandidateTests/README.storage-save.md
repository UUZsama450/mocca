> Historical 4977 encoding-cache baseline only. For the 4978 record-storage implementation and current tests, read `README.record-storage.md`. The legacy cross-writer tests below are not the 4978 acceptance suite.

# 4977 storage encoding candidate

Status: code, 12 hosted tests and unsigned arm64 Debug app/extension build passed; not installed. This is a separate candidate from the assistant-creation fix.

Baseline: exact installed 4977 working snapshot on 02f40f4, copied from `../mocca-4957-bottom-distance-isolation-a`. The inherited RootView and build-number diff belong to 4977. Storage changes are confined to ConversationStore.swift and one ID traversal in AppModel.swift.

## Problem and change

The send path stages a user message and assistant placeholder, then synchronously commits a full ConversationSnapshot before clearing the draft, performing send presentation, or starting the request. Persisting first protects the message if the app stops and preserves the existing failed-save rollback. The snapshot includes every persisted conversation, even when the visible chat is empty.

The candidate reuses JSON bytes for unchanged individual messages. It compares the complete ChatMessage value, including metadata and nested parts; it does not infer equality from IDs, text length or timestamps. Changed/new messages are encoded by JSONEncoder. Conversation metadata is freshly encoded every time. IDs and message strings are always encoded by Foundation; assembly only supplies JSON delimiters. UUID-keyed message dictionaries retain their v1 alternating key/value array representation.

Cache admission is bounded to 64 MiB of encoded bytes and 16,384 entries per store. Entries also retain message values and dictionary overhead: 64 MiB is NOT a cap on total added resident memory. Removed messages are pruned; changed entries are removed before replacement. Oversized/full-cache messages are encoded normally, without correctness depending on cache admission. The cache exists only in memory and may be discarded safely. The existing serial executor remains its sole production access lane.

The first save after creating the store has a cold cache and must encode all messages. Subsequent saves still compare messages, assemble/hash/check/write the FULL snapshot. This is a bounded CPU optimization, not incremental disk storage or removal of the synchronous send barrier. It does not establish that persistence is the only cause of the reported send pause.

Intermediate flattened ChatMessage arrays used for ID/schema traversal are replaced by joined traversal. Identity digest ordering, structural validation, receipt hashes, file protection, staged readback, atomic replacement, previous-generation backup and failure ordering remain intact. No new timers, tasks, alternate writers, file formats, migrations or backup generations are introduced.

## Whole-store save entry points

Source anchors below refer to AppModel.swift in this candidate (line count unchanged).

| Operation | Source lines | Scheduling |
| --- | --- | --- |
| Startup repair / recovery retry | 1201, 1452 | synchronous |
| Select message version | 1662 | synchronous |
| Clear/compress context | 3791, 3902 | synchronous |
| Delete assistant and affected chats | 5050 | synchronous |
| Branch chat / change group members / rename / delete chat | 5248, 5303, 5329, 5392 | synchronous |
| Restore/import chat graph | 6227 | synchronous |
| Send | 6792 | synchronous, before draft clear/request |
| Edit/delete messages or all versions | 6876, 6935, 7016 | synchronous |
| Bookmark / image collapse / user reaction | 7033, 7048, 7059 | synchronous |
| Translation placeholder / result | 7075, 7093 | synchronous |
| Regenerate / continue / group assistant staging | 7229, 7292, 7401 | synchronous |
| Generic message mutation | 8830 | synchronous |
| Reasoning expansion | 8998, 11211-11220 | existing 240 ms delay, then synchronous |
| Automatic summary start / result | 10602, 10682 | synchronous |
| Stream text/tool updates | 8458, 8656, 11197-11207 | existing 900 ms debounce, serial background save |
| Successful generation completion | 10827 | serial background save |
| Stop/cancel/failure finalization | 10963 | synchronous |
| Generated title | 11108, 11110 | automatic background / manual synchronous |

Separately, exporting a backup with chats enabled also encodes the complete snapshot as `chats.json` (`BackupService.swift:367-399`). That explicit export path is unchanged; it is not an ordinary ConversationStore commit and does not use the new cache.

Line 2190 belongs to a DEBUG preview fixture and is excluded from the production inventory. All rows above converge on the same snapshot builder and ConversationStore.save; preferences and provider/assistant settings also have separate persistence mechanisms and are not all whole-chat writes.

## Flutter Kelivo comparison

Read-only source: the local Kelivo checkout, `lib/core/services/chat/chat_service.dart` ([upstream project](https://github.com/chevey339/kelivo)).

`addMessage` (903 onward) awaits `_messagesBox.put(message.id, message)` (963), updates the owning conversation's message IDs/time and awaits `conversation.save()` (976). Message updates use a keyed message put as well (1030-1078). The chat controller awaits message insertion before updating the visible message list (`chat_controller.dart:453`). It still waits for persistence, but its application write granularity is individual records instead of a JSON serialization of every chat. This source does not establish that two Hive box writes form one cross-box transaction or that its recovery guarantees equal Mocca's current snapshot transaction.

Eliminating full-file writes in Mocca would require a separately designed transactional record store, including migration, receipt/recovery replacement and older-version rollback. This candidate retains compatibility with 4957/4977's reader and writer.

## Reproduction and acceptance

`prepare_storage_save_test_host.py` builds an isolated hosted XCTest project using the borrowed test-host patch; it does not modify the shipping project. It appends the exact 02f40f4 ConversationStore implementation renamed to BaselineConversationStore to the generated test source. The shared models match the baseline. This permits old/new writes and cross-version reads in the SAME test process.

Use only a disposable simulator. The tests create synthetic conversations in temporary directories, never phone chat content. The paired benchmark alternates old/new order and edits one message before EVERY save. It includes a small store, a ~45 MB multi-chat store and a ~45 MB single long chat. Report cold save separately from later saves. Simulator Debug timings are relative evidence, not iPhone latency or UI acceptance.

Safety coverage: complete-value invalidation (including unchanged IDs/timestamps), Unicode/escaping, headers, ordering, deletion/re-addition, cache limits/disabled cache, failed staging, duplicate IDs, old/new reader and writer compatibility, authorized reduction receipts, receipt installation failure after commit, corrupt-primary backup recovery, unsupported newer schema refusal, cold-start streaming recovery and separate store instances.

Evidence and final results are under `work/verification/`. Original 4977 source/artifact remains the rollback point. No phone installation or phone data mutation is part of this run.

## Measured results (2026-09-08)

All results below are x86_64 iOS 26.2 simulator Debug tests on the Mac. No phone performance claim is made. Each warm sample changed a message; these are full save timings, not cache-hit-only microbenchmarks.

| Fixture | Old warm median | Candidate warm median | Reduction |
| --- | ---: | ---: | ---: |
| 120 chats / 4,800 messages / 45.47 MB | 947 ms | 569 ms | 39.9% |
| One chat / 4,800 messages / 45.44 MB | 1,602 ms | 827 ms | 48.4% |
| One small chat / 4 messages / 2.9 KB | 4.85 ms | 4.87 ms | effectively unchanged |

Warm medians use saves 2-5. The first paired large multi-chat candidate save was a 2,002 ms outlier versus the old 960 ms; it is retained in the raw results, not excluded silently. This prompted six fresh-store cold repetitions per large fixture with alternating old/new order and autorelease pools. Cold medians were 847 -> 818 ms (multi-chat) and 760 -> 787 ms (single-chat), approximately -3.4% and +3.6%. Cold saves do not have a demonstrated speedup; a systematic 2x regression was not reproduced. Timings fluctuate, and this is not statistical proof of equivalence or phone acceptance.

Safety suite: 11/11 passed in encoding-tests-v3.xcresult. Additional cold benchmark: 1/1 passed in cold-tests.xcresult. There were no skipped tests. Historical reader/writer compatibility used the actual baseline store implementation and unchanged shared models, not only JSONDecoder equivalence.

Raw metrics: paired-benchmark.json and cold-benchmark.json. Raw XCTest summaries: encoding-summary-v3.json and cold-summary.json. Source scope and SHA-256 evidence: source-audit.json. Recheck Header field parity whenever ConversationSnapshot's schema changes.
