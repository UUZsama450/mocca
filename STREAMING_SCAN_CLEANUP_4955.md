# Mocca 4955 — Streaming Scan Cleanup

## Scope

- Base: accepted Mocca 4954 (`07e747b`).
- Remove three behavior-equivalent repeated scans from the Markdown/streaming
  display path.
- Do not change code-block disclosure, chat scrolling, viewport ownership,
  drawer animation, stream publication cadence, first-text publication, or
  completion flush.

## Changes

1. The streaming tail fade still reveals exactly one through eight composed
   characters, but derives that count from at most the first sixteen composed
   characters instead of counting the complete growing response.
2. Search-image control filtering skips its regular expression when the
   case-insensitive opening marker is absent. Inputs containing the marker use
   the existing parser and trailing-marker behavior unchanged.
3. Native Markdown selection routing resolves unified, mixed, or legacy output
   in one function. Code/table messages no longer repeat the whitespace and
   block-kind scans.

## Verification boundary

- Candidate equivalence tests passed 128 assertions comparing the old and new
  decisions for Unicode fade input, Markdown route combinations, and
  search-image marker cases.
- The existing offscreen streaming display-policy suite passed 13 assertions.
- The Release iPhoneOS build succeeded for app and extension build 4955. Both
  signatures verify, and the arm64 app binary UUID matches its dSYM.
- Compiler/build success proves integration only. Frame rate, thermal behavior,
  and interaction feel still require the user's iPhone 17 Pro.
- The separate 4952 code-fold candidate is intentionally not merged here.
