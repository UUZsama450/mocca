# Mocca 1.0.4 (5211)

The assistant editor now obscures scrolling prompt content behind the title and tabs using one continuous background. Native controls, tab layout and the soft lower scroll edge are retained. This replaces the 5210 native-header restoration after the user reported text showing through it.

## Source and verification

- Development feature commit: `46dc81c` (accepted on the phone as 1.0.4 build 5211).
- Portable base: `3a8d71384aed00008ff653ad413b7e3a5efbb9ac`.
- Only `Mocca/AssistantViews.swift` and project build metadata change among portable product inputs. Existing portable signing, disabled sponsorship, neutral fixtures and reviewed assets are preserved.
- Three focused UI cases passed: light/dark outer Form scrolling and the remaining editor tabs. Baseline screenshots reproduced the defect. The final phone build was installed in place, launched and visually accepted by the user.
- The App Store source differs from the frozen phone inputs only in production identity, build metadata and removal of StoreKit simulation across four distribution files. No new phone performance or thermal claim is made.
- The portable arm64 Release passed with all 149 product inputs unchanged, and its unsigned IPA passed ZIP, bundle/version, resource and fixture checks. The App Store archive passed with all 157 inputs unchanged and strict signature, profile and dSYM checks. Uploaded production IPA checks are recorded separately with the local distribution receipt.

## Release page and source archives

The user chose to update the existing `v1.0.4` release page to build 5211 after locally backing up all four 5206 assets and checking their published hashes. The historical Git tag remains unchanged. The release notes link the exact new source commit; `Mocca-1.0.4-5211-source.zip` contains that commit's tree. GitHub's automatic Source code links at the bottom of the page still refer to the original tag snapshot. Build 5210 was prepared but never published as a separate release.

The GitHub IPA is unsigned and requires the user's own signing. App Store review and manual release after approval are independent of GitHub availability.
