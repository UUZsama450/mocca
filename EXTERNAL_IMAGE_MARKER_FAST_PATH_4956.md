# Mocca 4956 — External Image Marker Fast Path

## Scope

- Base: Mocca 4955 (`9bfa494`).
- Skip the external-image regular expression and JSON request scan when the
  exact `<kg>` opening marker is absent.
- Preserve whitespace cleanup, completed control-block removal, and trailing
  partial-marker hiding exactly.
- Do not change Markdown rendering, code blocks, TextKit, scrolling, drawer
  behavior, stream cadence, first-text publication, or completion flushing.

## Verification boundary

- The focused candidate test passed 23 assertions comparing the old and new
  display result across ordinary text, Unicode, whitespace, completed markers,
  malformed markers, multiple markers, and partial streaming prefixes. It also
  confirms that marker-free input does not invoke the full regular expression.
- The previous scan-cleanup suite passed 128 assertions, and the existing
  offscreen streaming display-policy suite passed 13 assertions.
- The Release iPhoneOS build succeeded for app and extension build 4956. Both
  are strict-signature-valid arm64 binaries with matching individual dSYM UUIDs.
- Build success proves integration only. Thermal, frame-rate, and interaction
  acceptance remain physical-device checks.
