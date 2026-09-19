# Mocca 4932 Content Mutation Phase 1 R2 — Build Verification Handoff

Please verify this revision with the same environment used for baseline 4932 and
R1:

- Xcode 26.3
- arm64 / generic iOS device
- code signing disabled
- clean build

This repair is intentionally limited to the two R1 build findings:

1. `ChatView.body` type-check pressure
   - The full `ChatNativeBottomPositionModifier` construction now lives in a
     concrete helper returning `ChatNativeBottomPositionModifier`.
   - `MessageContentMutationBridge` construction now lives in a concrete helper.
   - The added standalone viewport-session `.onChange` was removed. Session
     invalidation is folded into the existing `bottomAnchorID` observer, and
     historical-window generation changes pass through one cancellation helper.

2. Swift 6 MainActor diagnostics in `ChatContentMutation.swift`
   - Initial `UIScrollView` geometry is read inside the coordinator's
     `@MainActor begin` method and passed into the nested lease as scalar
     snapshots. The nested initializer no longer reads UIKit properties.

No deletion or reasoning-collapse migration was added. No fixed delay, repeated
`scrollTo`, or code-collapse-specific task was added.

Please first report the unmodified clean-build result and all diagnostics. Do
not install on device unless the clean build succeeds. If it fails, include the
first compiler error and its surrounding source lines without changing code.
