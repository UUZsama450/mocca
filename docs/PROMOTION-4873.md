# Mocca 4873 baseline promotion into build 4874

Date: 2026-08-26

## Source lineage

- The installed iPhone app read back as `com.uuzsama450.mocca` version `0.1.0` build `4873`.
- Build 4873 was created from the accepted 4872 visible-layer drawer candidate.
- Its only candidate-level behavior change was mutually exclusive status-bar scroll-to-top ownership between the visible chat and drawer list.
- The accepted 4872 and 4873 source trees remain preserved under `work/candidates/`.

## Promotion into `develop`

The accepted 4873 candidate was promoted through a Git three-way merge with the existing distribution-preparation checkpoint. Conflict resolution intentionally:

- retained the device-deployed white Mocca icon and 4873 drawer behavior;
- retained the App Store and open-source documents, privacy manifest, and StoreKit restore UI;
- retained the full lazy Apple Reminders tool and its usage description;
- retained the first-release decision to omit HealthKit and removed merged HealthKit UI remnants;
- assigned build 4874 to the combined Git source so it remains distinguishable from the already-installed 4873 candidate.

## Verification boundary

- JSON and plist validation: PASS.
- Conflict-marker, whitespace, HealthKit-remnant, and required-symbol scans: PASS.
- Generic iOS Simulator Debug build: PASS.
- No phone installation, uninstall, data clear, or chat-store access occurred during promotion.
- The combined distribution-preparation changes still require final Archive, TestFlight, App Store Sandbox, and physical interaction acceptance before release.
