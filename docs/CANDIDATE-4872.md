# Mocca 4872 permanent visible-layer drawer repair

Base: Mocca 0.1.0 (4871 physical-device acceptance candidate).

Status: default-on promotion candidate. Build 4871 was launched on the physical
iPhone with `-diagnoseDrawerTrackedVisibleLayerMotion` and accepted after
extended use: the deep-title drawer remained smooth, bidirectional fade and
spring feel returned, and the title list did not return to the top.

## Only promotion change

- Enable the accepted visible-parent-layer route during normal launches.
- Retain `-disableDrawerTrackedVisibleLayerMotion` as a diagnostic opt-out.
- Bump the main app and extension build number from 4871 to 4872.

No animation constants, list structure, scroll host, row identity, gesture
threshold, conversation data, or other behavior changed from the accepted 4871
session.

## Icon refresh

The user-provided desktop `猫猫图标_Apple_干净版.icon` differs from this
candidate only in the Icon Composer automatic background fill. Its six PNG
layers are byte-identical. The candidate fill is updated from the prior 92%
gray value to the provided pure-white sRGB value; no cat, bubble, eye, whisker,
layer geometry, or source-image asset changed.

## Required checks

- Debug simulator build: PASS.
- Normal simulator launch without the 4871 enable argument: PASS; the verified
  drawer-sized parent layer was accepted with 16 child layers.
- Generic iOS Release build and strict signature verification: PASS; main app
  and extension are arm64 build 4872 and both binary/dSYM UUID pairs match.
- Same-bundle in-place install on the physical iPhone: PASS; no uninstall or
  data clear was performed.
- Normal physical-device launch without the 4871 enable argument: PASS; the
  verified drawer-sized parent layer was accepted with 15 child layers.
- Installed-app readback: Mocca 0.1.0 (4872); main app and Mocca activity
  extension processes were present.
- Interaction acceptance remains inherited from the identical 4871 motion
  route; 4872 deployment evidence does not replace physical interaction proof.

## 2026-08-26 renewal and white-icon deployment

- Removed only the two exact cached Mocca provisioning profiles temporarily;
  Xcode generated new main-app and extension profiles, and the old files were
  restored afterward alongside the new profiles.
- New main-app profile expires `2026-09-02T03:36:11Z`; new extension profile
  expires `2026-09-02T03:36:01Z`.
- Final compiled home-screen and About icons were rendered and visually checked
  with the pure-white background.
- Final strict signature, arm64, bundle/build identities, and both binary/dSYM
  UUID pairs: PASS.
- The renewed white-icon build was installed in place with the same bundle ID,
  launched without diagnostic arguments, and read back as Mocca 0.1.0 (4872).
- Main app, Mocca activity extension, and the default-on verified drawer parent
  layer were observed after launch. No uninstall, data clear, or chat-store
  access was performed.
