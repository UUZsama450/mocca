# Localization follow-up — 5055

Baseline: `5ae7b83e75d7e653894b4a93db4f0c95410809fb` (5054), reported by the user as performing well on iPhone 17 Pro. Candidate identity remains `com.uuzsama450.mocca.migration`; the separate App Store app is not replaced.

## Changes

- Profile card/text-area titles now retain `LocalizedStringKey`, allowing the existing locale environment and catalog to translate them. The shared profile avatar, editor bindings and persisted profile are unchanged.
- The language picker is in Appearance & App, immediately above Color Mode. Language search retains a direct picker and no longer also shows an empty-result message.
- OpenRouter balances retain remaining/total values as `ProviderBalanceResult`, with labels resolved at the display boundary. The model list shows the compact amount (`Balance: 12.34`); provider details retain remaining and total. Raw custom-provider strings remain untouched. Query identity, debounce, timeout, cancellation and visible-surface ownership are unchanged; language changes are not request inputs.
- Sponsor reward descriptions, keepsake names and transient status messages are translated. Status keys/arguments are retained so a cached status can change language without repeating StoreKit work. Purchase IDs, transaction verification and entitlement persistence are unchanged. Longer reward descriptions can wrap.
- Search/voice service descriptions, setting search contexts and three accessibility labels also receive missing translations.

## Performance and data boundaries

`AppModel.swift`, `AppLocalization.swift`, `ComposerView.swift`, `MessageMarkdownView.swift`, and `ConversationStore.swift` are byte-identical to 5054. Fourteen existing drawer/navigation ownership blocks pass the localization scope check. RootView changes are limited to accessibility strings, with no new state, tasks, timers, invalidation sources or gesture changes.

The production query harness passes stale success/error rejection, cancellation, shared surfaces, debounce, timeout and provider draft ownership checks. The balance observation fixture records 0 parent notifications, 1 leaf notification on completion, and 1 request after 100 equivalent updates. Compiled resource tests cover both balance languages, untouched custom provider text, sponsor text, language persistence and no-op notification suppression.

Evidence: parent workspace `work/verification/localization-polish-5055-20260919/`. These checks establish source isolation and tested behavior, not physical iPhone frame times. Same-bundle deployment does not establish byte-identical chat preservation; no new chat snapshot is requested.

## Simulator result

All 6 tests passed: real Settings picker placement/switching and relaunch persistence, parent draft retention, English Profile and Sponsor screens, balance header and refresh, and three AppModel/language observation isolation tests. Screenshots were inspected. Visual inspection caught a redundant English balance prefix that hid the amount; the compact-header follow-up also passed in `BalanceCompact.xcresult`; its screenshot shows the complete amount.

The simulator uses isolated app data and a fake balance response. Sponsor products are unavailable in this QA bundle, allowing the translated load status to be inspected without a purchase. Profile nickname is stored user data and is deliberately not translated. This is not physical-device interaction or FPS acceptance.
