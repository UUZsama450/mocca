# Mocca 1.0.4 (5210)

[Changes](../CHANGELOG.md) · [Installation](INSTALLATION.md) · [Version tracking](RELEASE_TRACKING.md)

The adopted phone UI is now packaged as build 5210 on both distribution paths. Model metadata is center-aligned, assistant management includes guarded multi-select deletion and independent list scrolling, the editor uses its earlier native header, and tools/MCP and native information popovers retain the accepted improvements.

## Provenance

- Phone feature source: development commit `99211de57ac26bd6836fa7379c78a5ea009526bf`.
- Portable source sync: `2f6f3e72107b5fff5fe04c4f5c208fe46e7bc6d8` (PR #9).
- This release changes only the portable project build metadata from 5206 to 5210; all other product inputs match that validated source sync.
- The App Store source changes four distribution files from the frozen phone inputs: production bundle/background identifiers, build metadata and removal of StoreKit simulation. Feature/UI files are unchanged.
- Portable signing defaults, sponsorship disabled by default, neutral fixtures, reviewed artwork and existing notices are preserved. The two packages are not byte-identical or signed in the same way.

## Verification

The phone-development UI passed five focused tests and its appearance was accepted on device. The portable source sync passed its arm64 Release build and five sponsorship-configuration cases. The build-5210 portable arm64 Release passed with all 149 frozen product inputs unchanged. The unsigned IPA passed ZIP integrity, bundle/version, resource and fixture-exclusion checks. The App Store archive passed with all 157 frozen inputs unchanged; the uploaded production IPA passed strict signatures, distribution-profile and get-task-allow=false checks for both app and extension. No new physical-device performance claim is made.

## Distribution

The GitHub preview uses tag `v1.0.4-build.5210` and requires your own signing. Existing `v1.0.4` / 5206 assets remain intact. App Store review is separate, with manual release after approval. GitHub availability does not mean the store update is live.
