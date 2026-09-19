# Mocca 4957 - Image Prompt and Bounded Control Prefix

## Scope

- Base: accepted Mocca 4956 (`be9efd9`).
- Tell an assistant with user-enabled image generation that emitting `<kg>` performs the image action now, instead of merely returning a prompt.
- Bound lowercasing of a trailing streaming control-marker candidate to the longest supported marker prefix.
- Do not change image request parsing, Markdown, TextKit, code blocks, scrolling, drawer behavior, stream cadence, first-text publication, or completion flushing.

## Verification boundary

- The new bounded-prefix suite passed 128 assertions covering every partial control-marker prefix, uppercase variants, ordinary text, Unicode, Markdown-like `<` text, and a 50,000-character impossible suffix.
- The 4955 scan-cleanup suite passed 128 assertions, the 4956 external-image marker suite passed 23, and the existing offscreen streaming policy suite passed 13.
- The Release iPhoneOS build succeeded for app and extension build 4957. Both are strict-signature-valid arm64 binaries with matching individual dSYM UUIDs.
- Build success proves integration only. Real image generation and interaction performance remain physical-device acceptance checks.
