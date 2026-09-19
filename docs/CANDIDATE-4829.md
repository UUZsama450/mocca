# Mocca rebrand candidate 4829

## Baseline

- Derived independently from candidate 4828.
- The 4828 source and the physical device were not modified.

## Changed identity

- App/project/target/product: `Mocca`
- Main bundle: `com.uuzsama450.mocca`
- Activity extension: `com.uuzsama450.mocca.GenerationActivityExtension`
- Build: `0.1.0 (4829)`
- Visible product copy, including the app-font preview, now says `Mocca`.
- New backup files and schemas, background identifiers, StoreKit products,
  provider branding, web bridge, activity names, and model prompts use Mocca.

## Compatibility boundary

Legacy import names and tokens are retained only where changing them would
break old ZIP/native backup import, migrated attachment identity, provider-icon
decoding, or saved reaction parsing. Historical candidate records are unchanged.

## Not changed

- App icon artwork.
- Functional behavior inherited from 4828.
- No device build/install and no chat-container access.
