# Reply version replacement cleanup candidate

Baseline: accepted installed4988 product69dcad7, candidate snapshot5e6cfca. The user requested optimization of accumulated <1/2> code and asked whether bounded entry also resolves manual up/down backroom. This candidate performs one behavior-preserving cleanup, not a new viewport strategy.

RootView.swift only: +32/-54, net22 fewer product lines. Consolidate three equivalent version-tail diagnostic event formats while preserving lazy autoclosure formatting. Reuse the compact-window decision inside the synchronous MainActor post-yield branch instead of reconstructing it from optional revision state. The version-current identity guard remains before the decision; natural/direct acknowledgement, fallback release, top-seed, delays/retries, cancellation, actual version persistence and existing entry/deletion behavior are retained.

No actor suspension occurs between the compact decision and its use; intervening calls format diagnostics and, only when not compact, release the version request. Baseline/candidate comparison executes the actual old/new branch fragments across3456 combinations of identity, optional direct request, row counts around24, compact ownership, ACK, cached snapshot, held drawer and diagnostics. Outputs match for state, callback order, diagnostic messages and disabled-diagnostic ID formatting. Native/frame callback internals are mocks.

Also passed:18 version/entry interaction checks,24 entry lifecycle checks,37 deletion checks plus24576 selection combinations, swiftc parse, git diff --check. Existing proxy-command, Task-start, millisecond-wait and retry sequences match baseline. OnlyRootView differs from signed4988 product inputs. No full app build, version bump, phone installation or logging re-enable was performed. This is source cleanup, not measured runtime performance improvement or physical acceptance.

## Manual scrolling boundary

Entry initially prepares at most12 rows with a text budget. Small scrolling within the retained concrete window benefits from concrete row layout; this does not guarantee every dynamic-height case. AppModel.loadEarlierMessages releases concrete entry and loads up to20 earlier rows; RootView.scheduleMessageWindowLoad also clears the prior compact-bottom marker. A latest12-row window can therefore become32 rows and use the original lazy stack. Manual return to bottom does not call ordinary selectConversation/prepareConcreteConversationEntryWindow again. Explicit bottom navigation is another existing route and may activate its own compact window if needed.

Thus user-tail up/down backroom is not established as fully fixed. Entry acceptance, paging/return scrolling, and <1/2> physical acceptance remain separate. Preserving concrete layout forever would remove the current work bound and is not part of this cleanup. No historical rejected candidate was used as product source.

Evidence: work/verification/result.json, version-cleanup-equivalence.log, version-entry-checks.log, entry-tests.log, deletion-tests.log.
