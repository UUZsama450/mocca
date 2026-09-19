# Model selector provider balance

When a provider has `balanceEnabled`, the model selector's provider header includes a trailing compact balance button. Tap to refresh. Disabled providers do not instantiate this view. Long names stay on one line; the balance is capped at 160 points, and VoiceOver receives the full value.

`ModelSelectorProviderBalance` owns a `ProviderBalanceQueryState` and surface ID locally. The parent selector constructs this child but never reads result/fetch/error fields. The result is not written to AppModel or provider configuration. This reuses the existing request controller; no polling, per-model requests, global balance state or persistent balance cache is added. Each mounted provider header keeps its own result; reopening the selector creates a fresh query. A header that disappears during search/favorites filtering releases its visible surface and cancels in-flight work; when remounted it can query again.

The existing 450 ms debounce, 15 second timeout, key-specific invalidation, last-surface cancellation and stale-response guard are unchanged. The compact control keeps a successful value visible during manual refresh, reports unavailable on failure, and supports retry. Provider-returned strings and OpenRouter's existing detailed result format are used as returned; the UI does not guess a currency or change balance arithmetic.

## Evidence

`check_model_selector_balance.py <output>`:

- Runs the original production request lifecycle harness with fake responses: disabled/missing-key/invalid-URL behavior, changed request key, stale success/error, unrelated provider edits, visibility cancellation, shared surfaces, debounce and timeout.
- Constructs the actual header and compact leaf from production source with only query dependency injection and a glyph stub. A returned balance notifies the leaf once and its parent zero times. 100 same-key updates result in one transport request.
- Asserts the query controller is unchanged from the localization checkpoint, the selector has no query-result reads, and the leaf has no AppModel access.

This is a source-extracted native Observation fixture, not a full iOS hierarchy FPS measurement. The UI test uses the actual selector with two sample providers and a fake balance transport in the disposable QA host: only the enabled provider gets a badge, and the refresh button works. The fixtures never query real accounts.

Final verification on 2026-09-19: the unsigned generic iOS Debug build and both UI tests passed; the combined simulator suite passed 5/5. The inspected English screenshot shows the long provider name truncated within its own area and the balance aligned on the right. Test balance `12.34` is synthetic. Physical-device frame times remain unmeasured.
