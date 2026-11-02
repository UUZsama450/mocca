# Mocca 1.0.7 (5286) source synchronization

Date: 2026-11-03 (Asia/Shanghai).

The installed phone app was read back as **1.0.7 (5286)**. Its installation identity matches the retained 5286 deployment receipt. This update continues GitHub `main` from `4a2bc3a30d7ab1349014ce2e0ad99c4dcd011977` and copies the frozen product inputs used for that build. All **160 files** match the [SHA-256 manifest](SOURCE_5286_SHA256.json), including the app, extension, resources, shared configuration, project, scheme and dependency lockfile.

当前手机版本已读回为 **1.0.7（5286）**，安装标识与 5286 部署记录一致。此次延续已有 GitHub 历史，160 项产品文件与装机冻结清单逐一匹配；之后的本地实验未纳入此次同步。

## Changes since 5271 / 相对 5271 的更新

- Drawer panel translation uses the layer to avoid repeated descendant layout notifications. Gesture ownership, scrim/shadow updates, keyboard timing and scroll policy are observed by the affected views.
- Native message content is constructed when hosted. Message identity arrays and layout lookups are reused without changing the selected message window.
- Settled short quotes and long prose inside mixed Markdown reuse immutable preparation. Existing cache limits and memory-warning cleanup are retained.
- Composer height edits carry transcript motion through additive Core Animation compensation. Touch interruption adopts the displayed position, and hit testing restores its temporary touch flag. Selection edge scrolling accounts for the composer and exact document endpoints.
- OpenRouter image-only models use the Images endpoint. Model endpoint metadata, reference images, usage, custom routing, cancellation and errors are retained; title, summary and OCR text consumers avoid image-only generation.

See the [changelog](../CHANGELOG.md) for the bilingual summary. These are the installed changes; this synchronization adds no new product behavior. The Xcode project retains the frozen XML serialization; its only semantic differences from 5271 are the four app/extension build numbers.

## Verification / 验证

- All **160** product-input SHA-256 values match the installed build's frozen source.
- OpenRouter regression: **200 Swift assertions passed**, plus request-format checks against a localhost fixture. This covers dedicated Images routing, legacy model metadata, catalog persistence, text-only guards, existing chat/Responses routes, error handling, cancellation and generated-image saving. Document reading, settings, localization and attachment value types use isolated adapters; responses and image bytes are synthetic.
- Sponsorship build gate: **5 configurations passed** (disabled, enabled, missing, unresolved and invalid). Enabled commerce was not invoked.
- Full unsigned Release/arm64 compilation: **passed** with Xcode 26.3 (17C529). The app and extension both report 1.0.7 (5286), use the portable placeholder identifiers, and the app reports sponsorship disabled.

Reproduce the standalone checks from the repository root on macOS:

```sh
python3 CandidateTests/check_openrouter_image_api.py
python3 CandidateTests/check_sponsorship_build_gate.py
```

The portable build uses the checked-in defaults:

```sh
xcodebuild -jobs 2 -project Mocca.xcodeproj -scheme Mocca \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO build
```

The verification build reuses a local package cache with automatic resolution and updates disabled, using the checked-in resolved versions. It does not override the product version, app identity, development team, sponsorship setting or application compilation conditions.

The historical `check_prose_viewport_refresh.py` harness was attempted but cannot run against this snapshot because its source-extraction boundaries refer to older method signatures/ordering. No pass is claimed; the harness and product code are retained unchanged. Earlier UI, motion and performance results are not represented as fresh runs here. These checks do not measure phone FPS, heat, power or long-term interaction behavior.

本次核验包括源码哈希、200 条生图回归断言、请求格式检查、5 种赞助配置及可移植版本编译。历史 prose viewport 脚本的源码提取规则已过时，未宣称通过；没有为适配旧脚本而改动产品代码。编译和隔离测试不等于新的真机性能验收。

## Distribution scope / 分发范围

Only source and its documentation/regression fixtures are synchronized to `main`. Configurable signing, sponsorship disabled by default, attribution and assets remain intact. Existing GitHub Release pages, tags and IPA assets are preserved. This update performs no phone installation, app-container access, paid provider request or App Store action.

本次只同步源码、版本说明和回归用例，不新建或修改 Release、标签、IPA，也不重新安装手机或访问聊天数据容器。
