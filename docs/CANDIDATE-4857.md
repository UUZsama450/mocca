# Mocca 4857 App Store polish and attachment reuse candidate

Base: exact installed-source candidate 4856.

Changes:

- Replace the Backup and Restore footer's internal Kelivo version lineage with
  App Store-facing backup-format language.
- Detect duplicate picked files across persisted messages and pending composer
  attachments using byte count plus SHA-256. Ask whether to reuse the existing
  local file or save another copy. Reuse creates an independent attachment
  record while sharing the existing physical file.
- Keep pending-attachment deletion reference-aware so removing a reused draft
  attachment cannot delete a file still used by a sent message.
- Give the OCR prompt editor explicit theme action tint: system blue for the
  default palette and the configured accent for custom palettes.
- Make the group-chat bubble master switch authoritative. When it is off,
  group assistant messages use a background-free surface regardless of group
  or one-to-one bubble style; one-to-one assistant rendering is unchanged.
- New preference records keep group assistant bubbles enabled but start at
  10-percent opacity. Existing saved values continue to decode unchanged.
- Bump the app and extension build number to 4857.

Unchanged:

- The 4856 icon source and About-page icon behavior.
- The accepted drawer implementation inherited through 4856.
- Conversation storage schema, provider configuration, one-to-one assistant
  bubble selection, and existing saved user preferences.

Required verification:

- Swift parse and diff checks.
- Signed generic iOS Release build.
- Strict app and extension signatures, arm64, bundle IDs/build versions, and
  matching Mach-O/dSYM UUIDs.
- Same-bundle overwrite install, launch, and device version/process readback.
- Physical checks remain: duplicate-file alert and both choices, default-theme
  OCR blue buttons, group bubble off with a non-default style, group bubble on
  at the chosen opacity, and unchanged one-to-one assistant bubbles.
