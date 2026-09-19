# Mocca 4873 status-bar scroll ownership repair

Base: accepted Mocca 0.1.0 (4872) permanent visible-layer drawer candidate.

## Only source change

- Keep exactly one `scrollsToTop` owner for the currently visible surface.
- Drawer closed: the real chat scroll view owns the status-bar action.
- Drawer open: the drawer title list owns the status-bar action.
- During a horizontal drawer gesture: neither surface owns the action.

The 4872 tracked visible-layer route, drawer animation constants, list structure,
row identity, gesture thresholds, conversation data, and icon assets are unchanged.

## Verification boundary

- Source delta from 4872: only `Mocca/RootView.swift` plus this note.
- Build/sign/install/launch evidence is recorded separately from physical touch
  acceptance. No uninstall, data clear, or chat-store access is permitted.

## 2026-08-26 deployment

- Generic iOS Release build with build number 4873: PASS.
- Main app and activity extension: arm64, strict signature, expected bundle IDs,
  and build 4873: PASS.
- Main binary/dSYM UUID: `F43B66EB-7A38-38A6-BC30-1E45E964FFED`.
- Extension binary/dSYM UUID: `97D24F46-6264-3D72-BFD8-08DA9712C5B8`.
- Same-bundle in-place install: PASS; no uninstall or data clear was performed.
- Installed-app readback: Mocca 0.1.0 (4873); main app and activity extension
  processes were present after launch.
- No chat-store snapshot or byte-identical data comparison was requested or
  performed. Physical status-bar and drawer interaction acceptance remains for
  the user to perform on the device.
