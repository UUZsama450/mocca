# Mocca 1.0.7 (5271) source synchronization

Date: 2026-10-29 (Asia/Shanghai).

The installed phone app was read back as **1.0.7 (5271)**. This source update starts from GitHub `main` commit `0d95385dedce6ee68369585c5be5125c3e1959ab` and applies the frozen product inputs used to build that installed version. All **160 files** match the installation source [SHA-256 manifest](SOURCE_5271_SHA256.json), including the shared configuration, app and extension sources, resources, Xcode project, shared scheme and dependency lockfile.

当前手机安装版本已读回为 **1.0.7（5271）**。本次从已有 GitHub `main` 继续，160 项产品输入与装机冻结清单逐文件一致。保留可配置签名、默认关闭赞助、原有素材和署名；手机构建命令另行提供实际应用标识、开发团队和赞助开关。

## Changes since 5257 / 相对 5257 的更新

- Local backup listing, restore, sharing/saving and confirmed deletion of backup copies. Storage scans run in the background, include backup and other app data, and preserve the selected temporary export during restore.
- ZIP attachment expansion through existing text, image, PDF, DOCX and OCR handling. Preserve original archives in stored messages and relative paths in request content; retain integrity checks, cancellation, cache reuse and abandoned temporary-directory cleanup without fixed file-count or expanded-size caps.
- Immediate composer and transcript height updates for text edits, isolated geometry observation, measurement reuse and message-lookup reuse. Retain independent group-control motion and selection-handle edge scrolling.
- Neutral settings navigation text before iOS 26, with existing page-specific control colors.

These are the installed source changes. This synchronization adds no new product behavior beyond build 5271. The backup and ZIP regression fixtures are included, and existing composer fixtures use the current APIs.

## Verification / 验证

- All 160 frozen product-input SHA-256 values match the synchronized source.
- Production backup-file/storage checks: **23 passed**, using disposable synthetic local files.
- Production restore transaction control flow: **37 isolated scenarios / 136 assertions passed**, including filesystem, settings, rollback and commit behavior. Security and defaults use isolated adapters; model payloads are value stand-ins.
- Sponsorship build gate: **5 configurations passed** (disabled, enabled, missing, unresolved and invalid). Enabled commerce was not invoked.
- Full unsigned Debug/arm64 compilation: **passed** with Xcode 26.3 (17C529). The app and extension both report 1.0.7 (5271), use the portable placeholder identifiers, and the app reports sponsorship disabled.

Reproduce the standalone checks from the repository root:

```sh
python3 CandidateTests/run_backup_storage_checks.py
python3 CandidateTests/check_backup_restore_transaction.py
python3 CandidateTests/check_sponsorship_build_gate.py
```

The portable compilation uses Xcode 26.3 (17C529):

```sh
xcodebuild -jobs 2 -project Mocca.xcodeproj -scheme Mocca \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO build
```

The synchronization build additionally reuses a local package cache with automatic package resolution and package updates disabled, using the checked-in resolved versions. No product version, app identity, development team or sponsorship setting is overridden for this compile check.

ZIP and UI test fixtures are retained for reproduction; their earlier results are not represented as fresh runs in this source synchronization. Compilation and installation metadata do not establish physical-device motion, FPS, heat, power, or older-iOS appearance acceptance. This update neither reinstalls the phone app nor reads its chat-data container.

## Distribution scope / 分发范围

This update synchronizes source commits to `main`. Existing GitHub Release pages, tags and IPA assets are preserved. No new Release, tag, binary upload or App Store action is part of this update.

本次只同步源码提交，不新建或修改 Release、标签和 IPA，也不执行 App Store 操作。中英文 README 已区分当前 5271 源码与已有 Release 下载。
