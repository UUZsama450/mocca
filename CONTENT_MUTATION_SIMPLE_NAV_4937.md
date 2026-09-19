# Mocca 4937 candidate

This candidate starts from the complete 4934 content-mutation source and keeps
its ownership, cancellation, retained semantic-bottom release, and full-code
disclosure rendering.

It changes the physical correction rule so every `UIScrollView` offset remains
inside the current legal range. Exact-bottom mutations use the real maximum
offset; middle-of-transcript mutations preserve the tapped control only as far
as legal bounds permit. It does not add temporary bottom inset/headroom.

It also carries forward the accepted 4936 table-cell copy/share menu and the
single return-to-bottom control. The navigation preference is now exclusive:

- Always: the existing four-button navigation panel.
- While scrolling: the existing transient four-button panel.
- Simple: only the single return-to-bottom control.
- Never: neither control.

The simple control appears after leaving the latest-bottom hysteresis band and
disappears only after exact latest-bottom geometry is acknowledged.
