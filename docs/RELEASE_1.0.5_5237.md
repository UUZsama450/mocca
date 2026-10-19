# Mocca 1.0.5 (5237)

This update continues the published 5233 source and adds:

- Preserve the current reading position when selecting the already-open conversation from the sidebar. First entry, favorites and other navigation keep their existing behavior.
- Send complete text attachments without the former 60,000-character prefix truncation. Remove the Markdown body-size caps while retaining file-count, permission and revision checks.
- Confirm large imports when text exceeds 60,000 characters or a file exceeds 100 MB. Batch imports share one confirmation. ZIP files remain attachments; archives are not automatically extracted or read.
- Offer an optional “Don't remind me again” choice and a Large File Reminders switch in Settings → Preferences. The preference is saved only on confirmation; cancel does not commit it.
- Use system blue, aligned actions and a bottom opt-out capsule, with fully wrapping filenames and English/localized layouts.

Reminder checks run at import or edit boundaries, not on every message send. Previously accepted Markdown content retains its approval; historical attachments are not retroactively prompted. Removing app-side truncation does not expand a provider's model context limit.

Validation for this change: 13 hosted tests, 119 runtime assertions, five simulator UI tests, and focused sidebar position checks. UI coverage includes Chinese/English, dark mode, a green parent theme, long filenames, cancellation and opt-out persistence. Local phone build 5237 was installed in place and its version and launch verified; this is not a claim about device performance or App Review approval.

The portable project preserves configurable signing and disables sponsorship by default. App Store distribution uses the existing production identity. App Store and TestFlight delivery status is reported separately from source availability.
