# Chinese / English interface candidate

Base: `b31ddc52dce2ce2408a075059613a39b6f898103` (5053 message-observation work plus the unread-dot leaf change). Product build number remains 5053 until a separately identified device build is prepared.

## Behavior

Settings has **语言 / Language** with **跟随系统 / 简体中文 / English**. The same control is available during initial provider setup. Default is system; a manual choice is saved locally under `mocca.interfaceLanguage`. This interface preference is independent of AppModel and its general preferences. No changes are made to user messages, names, assistant prompts, backups or model identifiers when changing language.

`AppLocalization` only publishes an effective-language change when the resolved language differs. Repeated activation, selecting the current value, and normal message updates do not write its language state. SwiftUI reads cached language bundles, and the separately hosted main chat panel explicitly receives the locale. No language-driven `.id(...)` or AppModel recreation is used. A real language change intentionally refreshes affected text and layout once.

The source-language catalog is Simplified Chinese. Chinese and English are supported; other system languages fall through the preferred-language list, then English. Chinese variants currently display Simplified Chinese. UI text and localized error descriptions are catalogued; AI prompts, tool payloads, logs and user-authored text are not translated. The existing message translation action still translates **to Chinese**, now explicitly labelled that way in English. Existing or AI-generated conversation titles are not rewritten.

System-owned permission dialogs follow iOS's app/system language, not the in-app override. New Live Activities receive the effective language; previously emitted notification text and existing activity detail snapshots are not retroactively translated.

## Verification

- `run_localization_host.py <output>` compiles the actual resolver with an isolated defaults suite and compiled string resources. Tests system resolution, explicit override, persistence, no-op notification suppression, lookup and interpolation.
- `check_localization_scope.py [output.json]` checks English resource completeness/parameter counts, unchanged AppModel business state and 14 drawer/navigation ownership blocks against the baseline, and that unread observation remains in its leaf.
- `prepare_localization_ui.py <output>` creates a separate simulator-only QA app (`com.mocca.localizationqa`). Production files are referenced. Its entry point offers a Settings/draft fixture or the real model selector with sample providers. A QA-only copy of ProviderViews replaces the balance transport with a fake response under the balance-test launch flag; production request algorithms are unchanged. Production targets/project remain free of XCTest dependencies.
- `LocalizationIsolationTests` runs against the actual AppModel in the simulator. It checks 40 language changes preserve messages and revisions without notifying message/drawer state; 100 background message edits do not notify the selected transcript or language readers; and repeated same-language requests are silent.
- `LocalizationUITests` taps the actual Settings picker in both system languages, checks persistence across launches, and verifies the QA draft survives a live language change. Its draft assertion is a parent-state retention test, not a physical-device chat-composer acceptance test.

These checks do not establish unchanged FPS. Device acceptance still requires the iPhone 17 Pro: same conversation/content and display settings, Chinese and English, steady and streaming replies, continuous drawer dragging and release, navigation buttons, keyboard/draft retention, and switching between chats while another reply streams. Compare frame times to the baseline under equivalent conditions. English text can wrap differently, so layout cost cannot be inferred solely from unchanged observation ownership.

## Resource maintenance

Keep localization at display boundaries. Do not localize persisted enum raw values, IDs, prompt instructions or arbitrary user strings. Use `%@` with explicit arguments for dynamic UI text; literal percentages in formatted strings must use `%%`. Prefer contextual wording and review longer English labels on a device. The catalog check verifies resource structure, not translation quality or all layout combinations.

Some matching English translations were adapted from Kelivo's AGPL-3.0 `app_en.arb` / `app_zh.arb`; see `THIRD_PARTY_NOTICES.md`.

## 2026-09-19 candidate result

Generic iOS Debug build passed (`build-10.log`, signing disabled). `LanguageUI-5.xcresult` passed all 5 tests, with Chinese/system/English selection, relaunch persistence, draft state retention, balance visibility/refresh, and production AppModel notification isolation. Screenshots were inspected and the default-model placeholder and model-kind labels corrected. The catalog audit covers 1,836 UI entries and 6 permission descriptions. No device install or frame-time capture was performed.

Evidence is retained under the parent workspace's `work/verification/english-localization-20260919/`, including `scope.json`, `test-summary.json`, `balance/`, and `final-screenshots/`. The Settings screenshot contains a QA-only draft fixture above the production Settings view; the balance screenshot uses fake provider data.
