# Development workflow / 开发维护流程

[English README](../README.md) · [中文说明](../README.zh-CN.md) · [Build configuration / 构建配置](BUILD_CONFIGURATION.md)

## Start from main / 从主线开始

`main` is the current portable source baseline. Start a focused branch from the latest `main`, keep each change small, and explain its purpose in the commit message. Before switching or updating an existing checkout, preserve any uncommitted work.

`main` 是当前可移植源码基线。新功能或修复从最新 `main` 建立独立分支，每次提交说明解决的问题；切换或更新已有工作目录前，先保存其中未提交的修改。

## Verify and merge / 验证与合并

Build the source and run checks appropriate to the change. For scrolling, keyboard, favorites and rendering changes, distinguish automated checks from physical-device interaction results. Open a pull request describing the problem, behavior change, checks and remaining limits. Merge accepted work into `main`; keep incomplete experiments on their branches.

完成构建及与修改范围匹配的检查。滚动、键盘、收藏和文字渲染的修改，应分别记录自动检查和真机体验。通过 Pull Request 说明问题、改动、验证及尚未验证的范围，确认后合入 `main`；未完成的实验留在对应分支。

Uploading a branch preserves that branch online; it does not make it the default version. Updating source does not create an IPA or submit an App Store build.

上传分支只是在网上保存该分支，不会自动成为默认版本。源码更新也不会自动生成 IPA 或提交 App Store。

## Source updates from the device-development repository / 从装机开发仓库同步

The original device-development history is maintained separately. Select the accepted build and its frozen source manifest; apply the verified application changes to a branch based on this repository's current `main`. Preserve the portable configuration, sponsorship gate, attribution and reviewed assets. Compare the resulting source with the selected inputs, build this portable variant, and retain the existing GitHub history when merging. Do not replace the repository with the complete private working directory or force-push its experimental history.

原装机开发历史单独保留。同步时先确定已验收的构建及冻结源码清单，再以本仓库最新 `main` 为基础应用核对过的修改，保留可移植配置、赞助开关、署名与整理后的素材。对照选定源码检查差异、重新编译可移植版本，再保留已有 GitHub 历史合入；不把整个私人工作目录或实验历史覆盖上传。

## Versions and records / 版本与记录

After an App Store update is confirmed published, align the GitHub formal release version, source tag and download links with that release. Earlier GitHub previews remain explicitly labeled with their version and build number; channel-specific signing and portable configuration are checked separately.

确认 App Store 新版本已发布后，将 GitHub 正式版的版本号、源码标签与下载链接一起对齐。提前提供的 GitHub 预览包明确标注版本及构建号；各渠道的签名和可移植配置分别核验。

- Keep app and extension build numbers aligned. / 主应用与扩展的构建号保持一致。
- Record the source commit and actual validation for each distributed build. A version tag identifies a specific source revision. / 分发构建记录源码提交及实际验证；版本标签标记明确的源码版本。
- Keep README languages aligned and distinguish the current source from older release downloads. / 中英文 README 同步，明确区分当前源码与旧版下载包。
- Preserve licenses and notices; exclude credentials, private conversations, signing files, device logs and generated build outputs. / 保留许可证与来源说明，排除凭据、私人聊天、签名、设备日志及构建产物。

## Current standalone checks / 当前可独立运行的检查

From the repository root on macOS with Xcode installed / 在装有 Xcode 的 macOS 上，从仓库根目录运行：

```sh
python3 CandidateTests/check_sponsorship_build_gate.py
python3 CandidateTests/check_favorite_publication.py
python3 CandidateTests/check_prose_viewport_refresh.py
python3 CandidateTests/check_completion_codecs.py --candidate-only
python3 CandidateTests/check_stream_display_work.py --candidate-only
```

These use current source and synthetic fixtures. Other historical harnesses can depend on their original commits or simulator setup; their presence is not a claim of current support. See [5135 verification](SNAPSHOT_5135.md).

以上检查使用当前源码与虚构数据。其他历史工具可能依赖原始提交或模拟器配置，保留文件不表示它们已适配当前版本。详见[5135 验证](SNAPSHOT_5135.md)。
