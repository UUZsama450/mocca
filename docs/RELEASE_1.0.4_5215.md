# Mocca 1.0.4 (5215)

Opening settings information popovers could leave the interface unresponsive. The shared image/context and memory explanation component now uses a stable UIKit anchor and independent content host, measures its size once, and keeps its native arrow, text layout, scrolling and animation. Reopening consults current presentation visibility instead of a cached Boolean.

The source matches the adopted phone build's shared explanation component. Existing portable signing, sponsorship gates, reviewed assets and background identifiers are retained. Only `Mocca/SettingsViews.swift` and project build metadata change among portable product inputs relative to 5211. The App Store package retains the established production identity and excludes StoreKit simulation.

Six focused simulator cases passed, including repeated reopening, memory navigation, image/context responsiveness, presenter-driven dismissal and deliberate missed-callback injection. The user confirmed the original freeze was resolved, later observed taps during another bubble's closing animation, and authorized distributing 5215. This does not establish phone FPS or temperature, or guarantee that taps during a presentation transition are queued. Tests remain in the private development fixture and are not linked into distribution packages.

Release build and package verification results are recorded in the accompanying build manifest. The existing `v1.0.4` release page is reused after backing up and verifying the previous assets. Its historical Git tag remains at the original 5206 snapshot; use the explicitly linked 5215 source archive and commit for these downloads.

The GitHub IPA requires the user's own signing. App Store review is independent, with manual release after approval.
