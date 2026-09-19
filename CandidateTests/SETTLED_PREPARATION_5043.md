# 5043: reuse settled long-content preparation

Baseline: 5042 / `a29bf62c516c876702f8c8f3139f72d340207a03`.

## Product behavior

Long unified, settled prose can reuse the styled attributed string across new native view instances. Each consumer retains its own coordinator, UITextView, text storage, layout and selection. Exact source, style signature and appearance participate in the key. Attachments are excluded, streaming bypasses the cache, and mixed prose segments retain their previous path.

Settled tables with at least 24 rows can reuse column widths. The actual resolved body/header fonts and complete table data identify the entry. Cell layout, row height, Grid structure, links, menus and horizontal scrolling are unchanged.

Each cache holds at most four entries and 131,072 logical weight units; table accounting includes empty cells/rows. This is a retention policy, not an exact byte count. Memory warnings clear both caches. There are no native view caches, background jobs, on-disk caches or per-frame timers.

This targets repeated preparation. It does not eliminate cold TextKit measurement, live text layout or full Grid creation. Phone entry latency/FPS is unmeasured until a matched 17 Pro comparison.

## Tests

`check_settled_preparation.py OUTPUT SIMULATOR_ID` extracts the actual cache and baseline/candidate table measurement, then uses simulator UIKit. The font resolver bridge is shared by both table variants. It checks attribute/text equality, native text sizing across four widths, native storage/selection isolation, content/style/appearance invalidation, attachments, entry/weight limits, memory-pressure clearing, and 108 cold/warm/streaming table scenarios. It reports work counts, not performance timings.

`LongContentEntryUITests.swift` uses a dedicated simulator and an explicitly requested DEBUG fixture containing long prose and a 96-row table. It revisits both through the real sidebar, verifies the concrete tail above the composer and opens the keyboard. The new fixture is compiled out of Release.

The UI runner also includes the existing `SendHandoffBoundaryUITests.swift` to exercise long sending and reader takeover during the local diagnostic stream. `check_send_frame_snapshot.py`, `check_send_tail_destination.py`, `check_conversation_entry.py`, and `check_prose_viewport_refresh.py` provide relevant existing checks. The viewport test's UIKit double was refreshed to include existing drawer refresh-key fields; its product implementation is unchanged.

The actual results, build inputs and deployment receipts are recorded outside this source checkout in the parent repository at `work/verification/long-content-preparation-5043/REPORT.md`.

## Attribute ownership

After the builder publishes a result, its attribute objects are treated as values and are not mutated in place. Consumers replace attributed-string ranges through Foundation APIs. This follows [Apple's attributed string ownership contract](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/AttributedStrings/Tasks/ChangingAttrStrings.html); copying an attributed string is not a promise to isolate illegal external mutation of a previously assigned attribute object. Native attachments with mutable geometry are excluded explicitly.

## Rollback and acceptance

The 5042 worktree and signed app remain intact. Rollback uses the same migration Bundle ID. Real-device acceptance should distinguish first entry after process restart from warm reentry, and preserve full bottom text, selection, keyboard, drawer interaction and the user-accepted 5041 send/stream animation. No chat-store copy or byte-identity claim is part of this change.
