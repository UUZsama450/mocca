# Mocca 4932 — Content Mutation Phase 1 Candidate

## R2 compiler repair

The first package was rejected before device testing because Xcode 26.3 timed
out while type-checking `ChatView.body`, and Swift 6 reported two main-actor
isolation warnings in the coordinator's nested lease initializer. R2 keeps the
same Phase 1 behavior but changes the integration shape:

- The large `ChatNativeBottomPositionModifier` construction now lives in a
  concrete, explicitly typed `ChatView` helper instead of the already complex
  `body` expression.
- The message mutation bridge is built by a typed helper rather than an inline
  pair of closures in the `MessageRow` initializer.
- The extra direct viewport-session `.onChange` was removed from `body`.
  Session invalidation now piggybacks on the existing bottom-anchor observer,
  while every historical-window generation change goes through one explicit
  cancellation helper.
- UIKit content and bounds measurements are captured in the outer main-actor
  `begin` method and passed into the nested lease as scalar values. The nested
  initializer no longer reads main-actor-isolated `UIScrollView` properties.

This package still requires one real Xcode clean build. The Linux container can
parse Swift syntax but cannot run Apple's SwiftUI/UIKit type checker.

This candidate introduces one shared, bounded viewport-handoff mechanism for **chat content height mutations** and wires only **manual Markdown code-block expand/collapse** into it.

It intentionally does **not** migrate deletion or reasoning-collapse ownership yet. Those existing mechanisms remain unchanged except that they now cancel/preempt an active code-block mutation when they take ownership. This keeps the first real-device test surface narrow and reversible.

## What changed

- Added `Mocca/ChatContentMutation.swift`.
  - Stable `ChatViewportSessionID` is separate from the transcript/tail revision (`ConversationBottomAnchorID`). Ordinary message revisions do not invalidate a disclosure transaction.
  - A single `ChatContentMutationCoordinator` owns one physical content-height mutation at a time.
  - Two viewport policies only: keep true exact bottom, or preserve the control-side visible anchor.
  - No fixed landing delay, no delayed `scrollTo`, no retry loop, no GeometryReader/PreferenceKey feed into `ChatView`.
  - Animated code-block mutations are sampled with `CADisplayLink` only while a lease exists; corrections occur only after measured geometry actually changes.
  - The code-block probe prefers presentation-layer geometry so the handoff follows the visible animation rather than immediately snapping to the committed model frame.
  - Native user touch/drag/deceleration invalidates the lease and stops all further writes.
- `MessageMarkdownView.swift` now reports a thin mutation description before toggling a non-streaming collapsible code block.
  - Both header and footer controls use one toggle path.
  - One tiny native anchor probe is attached per live, collapsible, non-streaming code block.
  - The child reports facts only; it does not decide whether to scroll to bottom.
- `RootView.swift` owns admission and arbitration for this first shared path.
  - Competing send/navigation/keyboard/deletion/window-loading owners block or cancel the mutation.
  - Passive stream/layout follow is gated while the lease is active.
  - iOS 18 retained semantic `.bottom` ownership is released while the physical mutation driver is active, then re-armed only if the source was truly at concrete exact bottom and auto-follow was previously engaged.
  - A stable viewport-session change cancels the lease. A mere `messageIDs` revision does not.
- `Mocca.xcodeproj/project.pbxproj` includes the new Swift source in the Mocca target.

## Explicitly not migrated yet

- `messageDeletionLandingTask`
- `automaticReasoningCollapseOwner`
- navigation tasks
- send positioning
- keyboard landing/pinning
- historical-window loading

These are not wrapped in a fake mega-coordinator. Once this Phase 1 path passes real-device tests, deletion can be migrated into the same mutation kernel and its specialized polling/landing code can then be deleted.

## Real-device acceptance matrix

Test in a long conversation and a short conversation:

1. Middle of transcript, expand from code-block header: header does not jump.
2. Middle of transcript, collapse from code-block header: header does not jump or land in blank space.
3. Middle of transcript, expand from footer: footer remains visually under the same finger/reading position as far as physical scroll bounds allow.
4. Middle of transcript, collapse from footer: same expectation; no blank frame.
5. True concrete bottom, expand/collapse from both controls: remain at real bottom.
6. While disclosure is animating, immediately drag vertically: user wins; no delayed correction after release.
7. While disclosure is animating, trigger drawer, navigation, keyboard, send, or deletion: old mutation must not fire later.
8. Switch conversations during disclosure: no delayed jump in either conversation.
9. Repeated rapid expand/collapse: newest direct user mutation supersedes the previous lease, with no stale landing.
10. Side drawer drag over long Markdown after no mutation is active: compare frame feel with 4932 baseline. The mutation display link must be absent while idle.

## Diagnostics

Add launch argument:

`-diagnoseContentMutation`

The new coordinator will emit `[content-mutation]` BEGIN / CORRECT / COMPLETE / RUNTIME_INVALIDATE lines. Existing `ChatBottomTrace` also emits `CONTENT_MUTATION_*` lifecycle entries.

## Static checks performed in this package

- `swiftc -frontend -parse` passes for `ChatContentMutation.swift`, `MessageMarkdownView.swift`, and `RootView.swift` in the available Swift 6.2 parser.
- `plutil -lint Mocca.xcodeproj/project.pbxproj` passes.
- `git diff --check` passes.
- The new mutation coordinator contains no `Task.sleep`, delayed dispatch, `scrollTo`, or GeometryReader-based correction.

The container is Linux and has no Apple iOS SDK/Xcode, so full SwiftUI/UIKit type-checking and an iOS build cannot be truthfully claimed here. The candidate should be built once in Xcode before device testing.
