# Mocca 1.0.4 (5219)

This update removes the Restore Purchases action and explicit App Store sync from consumable sponsorship. The sponsorship page, accessibility hints, help, privacy text and local StoreKit descriptions no longer promise permanent decorations or restoration after reinstalling or changing devices. Existing local decoration records, verified purchase processing and backup formats are preserved.

The product baseline includes the MCP management and provider-order changes from build 5218. The portable project retains configurable signing, disabled-by-default sponsorship, neutral examples and reviewed artwork. The App Store package is reviewed separately and remains subject to manual publication after approval.

Validation: seven SponsorStore host scenarios cover product-loading failure/retry, partial catalogs, cancellation, concurrent requests and purchase-status isolation. Release package verification covers frozen sources, production build conditions, signatures where applicable, bundle versions, resources and exclusion of test fixtures. Host checks do not represent an actual paid transaction or physical-device UX acceptance.

Use the explicit 5219 source archive and BUILD-INFO-5219.json. The historical v1.0.4 tag remains unchanged.
