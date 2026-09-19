# Long prose entry candidate from 5045

Base: `32628f3fc1fd980443c2526737c1e11611698739` (the installed 5045 source record).
Candidate branch: `codex/plain-prose-entry-5045`.

## Problem and change

Opening a conversation with a long settled assistant message prepares a large
native text view on the UI thread. In the measured simulator cases, SwiftUI also
created a second host for the same content and width. That host queried its size
but never attached to the window. Both hosts previously received the whole
attributed string even though the second host reused the existing measured size.

The candidate makes two narrow changes in `MessageMarkdownView.swift`:

1. Skip asterisk/backtick compatibility repairs when neither delimiter occurs.
   The original Foundation Markdown parser and paragraph styling still run.
2. For an initially empty, unattached, settled long-prose host with fill width,
   allow `sizeThatFits` to return the existing exact shared measurement before
   assigning text. A cache miss follows the original assignment and detached
   measurement path. If the host enters a window, synchronously install its
   complete content in `didMoveToWindow`, including rule attachment sizing.
   Clear the one-shot callback on assignment or dismantling.

This reuses the existing signature/width/display-scale key and bounded size
cache. It introduces no estimated heights, paragraph splitting, timers,
background preparation, or additional cache. Already populated views retain
their original update path. Compact user bubbles and streaming prose do not
enter the new deferral path.

`AppModel.swift` changes are synthetic fixture flags inside `#if DEBUG`.
The 5045 keyboard, drawer, scroll ownership, message-window limits, persistence,
and send animation source are unchanged. This candidate does not include the
separate link-style-order experiment from 5043.

## Evidence and limits

Instrumented Debug simulator: iPhone 17 Pro model, iOS 26.2, x86_64.
Two synthetic lengths (18,540 and 74,325 UTF-16 units), three cold entries each:

- Native full-text assignments changed from two to one in all six entries.
- The original detached full-height measurement still runs once per cold entry.
- Actual final-line coordinates matched the baseline.
- Attributed parser output matched in 197 cases on macOS Foundation and iOS
  simulator Foundation, including CJK repairs, emoji, escaped delimiters, links,
  inline code, long paragraphs, and deterministic mixed syntax.
- The clean candidate app passed two cold-entry methods, long-message sending,
  and both plain/rich repeated-entry, native-selection, and keyboard methods.
  The initial selection driver timed out while repeatedly querying the full AX
  tree despite a visible native Copy menu. A single native-menu query fixed the
  driver; the two affected methods passed with the app binary unchanged.
- Both plain cold-entry screenshots matched the baseline pixel for pixel below
  the excluded 48 pt status-clock region.
- Rich content matched the same persisted baseline fixture in all three entry
  screenshots and the native-selection screenshot. The keyboard screenshot
  differed only in the blinking input caret (378 pixels); content geometry and
  decoration matched. The baseline control also passed its interaction checks.

These are computer experiment results. CPU draw callbacks are not displayed
frames, and simulator timings are not physical iPhone latency or frame rates.
The necessary first full-document measurement remains; this is a reduction in
duplicate work, not a complete solution for arbitrarily large messages.

## Reproduction

From this checkout on macOS with Xcode selected:

```sh
/usr/bin/python3 CandidateTests/check_plain_prose_repairs.py
```

That script extracts the real baseline and current inline parser into a temporary
Swift program, compiles with `-O`, and runs `ParserComparison.swift`.

UI drivers use an isolated simulator and the migration bundle with synthetic
fixtures. `PlainProseEntryUITests` restarts the app before each measured entry.
`WarmProseUITests` covers repeated entry, rich styles, native text selection,
and keyboard visibility. `SendHandoffBoundaryUITests.testSimpleLongSend` uses a
localhost-only fake model endpoint. Do not run fixture-seeding launch arguments
against a user's real chat store.

Detailed commands, binary/source hashes, logs, screenshots, and test result
bundles live in `work/verification/plain-prose-entry-5045/REPORT.md` in the main
workspace. The diagnostic implementation is retained separately on
`codex/plain-prose-entry-5045-lab`; profiling hooks are absent from this candidate.
