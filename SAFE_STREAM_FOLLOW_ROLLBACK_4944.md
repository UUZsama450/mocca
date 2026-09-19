# Mocca 4944 safe streaming-follow rollback

- Complete baseline: `mocca-tail-deletion-concrete-successor-4940-a`.
- Preserved: all 4940 non-table production code, including the bounded concrete-tail deletion handoff.
- Reverted: only `Mocca/MessageMarkdownView.swift`, byte-for-byte to the physically accepted 4937 source before the table-layout experiment chain began.
- Packaging change: main app and `GenerationActivityExtension` build numbers are 4944.
- Installation policy: same-bundle overwrite only; no uninstall, data clear, or chat-store copy.
- The table-overlap repair chain from 4938 through 4943 is frozen and is not included.
