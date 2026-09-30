# Mocca 5128 source update

[English README](../README.md) · [中文说明](../README.zh-CN.md)

This private source update advances the existing 5058 snapshot to development build **1.0 (5128)**. It includes the integrated application source and test tools, with the repository's portable configuration and reviewed assets retained. Original development history and generated deployment records stay outside the publication history.

本次私有源码更新从已有的 5058 快照升级到开发版 **1.0（5128）**，包含已整合的应用代码及测试工具，保留仓库原有的可移植配置和整理过的素材。原始开发历史及生成的部署记录不进入发布历史。

## Changes

- UIKit manages the chat transcript, cell reuse and scrolling. Keyboard, send positioning, history reading and message-version transitions include the intervening integration work.
- Drawer transitions pause unnecessary display work, native message rows avoid duplicate configuration, and selecting a conversation no longer repeats full-list filtering and date grouping. Date changes refresh their own grouping context.
- Reply completion moves identity preparation to the existing serial save executor, avoids repeated durable completion-journal writes, and skips unnecessary image parsing and notification text preparation. Save ordering, recovery and cancellation checks remain in place.
- The intervening source changes also include background cropping, image/attachment handling, search controls and sponsorship product-loading fixes.

UIKit 接管聊天列表、消息行复用和滚动，并包含键盘、发送定位、历史阅读及消息版本切换的整合改动。侧栏切换减少不必要的显示工作，消息行减少重复配置，选中聊天不再反复筛选和按日期整理整张侧栏列表；日期变化单独刷新分组上下文。生成结束时减少主线程准备、重复持久化日志写入及无用文本解析，同时保留保存顺序、恢复和取消检查。此外包含背景裁剪、图片附件、搜索控制及赞助商品加载等期间改动。

## Source variant

The update is derived from the frozen 5128 product inputs. As in the first snapshot, source builds use a configurable app identity and disable sponsorship unless explicitly enabled. The reviewed 5058 artwork, notices, neutral previews and synthetic examples are retained. Both app and extension build settings now specify 5128. This is a portable source variant, not a signed archive or App Store submission.

源码取自 5128 冻结的产品输入，继续使用可配置的应用身份，并默认关闭赞助。5058 整理过的素材、来源声明、中性预览及虚构示例继续保留。主应用和扩展的构建号均明确设为 5128。本版本是可移植源码，不是已签名归档或 App Store 送审包。

## Verification

The prepared source tree passed these checks with Xcode 26.3 on 2026-09-30:

- An unsigned Release build for the iOS Simulator, with sponsorship disabled. All 143 source/configuration/resource inputs were unchanged during the build. Built app and extension identities, version 5128, background task identifiers and the bundled Lobe Icons notice were checked.
- Eight resolved build-setting combinations: app and extension, Debug and Release, default settings and synthetic local overrides.
- Five sponsorship configuration cases, including disabled entry-point checks. Enabled commerce was not executed.
- 1,111 completion-codec cases using the current product functions. A long ordinary reply required zero full-image regex passes and no image-candidate index construction in the instrumented host.
- 410 streaming-display checks using synthetic model/service fixtures. Suspended and resumed display updates avoided the redundant filter calls covered by this host.

2026 年 9 月 30 日，整理后的源码使用 Xcode 26.3 通过不签名的 iOS 模拟器 Release 构建，编译期间 143 项源码、配置和资源输入保持一致。已核对主应用与扩展的身份及 5128 版本号、后台任务标识和随包许可文件；另通过 8 组构建设置、5 种赞助配置、1,111 项生成收尾数据解析及 410 项流式显示检查。测试没有执行已开启的实际交易。

These are fresh checks of this portable snapshot. Candidate-only hosts validate the current source; they do not recreate historical before/after measurements or establish physical-device frame rate, UI acceptance, durable-storage fault coverage or successful purchases.

以上是针对本可移植源码快照重新执行的检查。仅测当前快照的测试工具不重做历史前后对比，也不代表真机帧率、界面体验、持久化故障覆盖或实际购买已经验收。

## Run the standalone checks

From the repository root on macOS with Xcode 26.3:

```sh
python3 CandidateTests/check_sponsorship_build_gate.py
python3 CandidateTests/check_completion_codecs.py --candidate-only
python3 CandidateTests/check_stream_display_work.py --candidate-only
```

These commands compile the actual configuration/store or extracted product functions with synthetic fixtures. `--candidate-only` validates this snapshot without requiring unpublished development commits or local device receipts. It does not claim a before/after comparison. Generated outputs go to ignored temporary or `work/` directories.

这些命令使用真实配置与存储源码，或提取出的产品函数，配合虚构测试数据执行。`--candidate-only` 无需原始开发提交或本机装机收据，只验证当前快照，不声称完成前后版本对比。生成结果位于临时目录或已忽略的 `work/` 目录。

Other historical comparison and simulator harnesses retain their original development assumptions. They may require matching baseline commits, fixtures, simulator identifiers or build setup; this snapshot does not contain those private development records. Their presence is not a claim that every historical harness passes against 5128. These source checks do not measure physical-device frame rate or validate real purchases.

其他历史对比和模拟器测试保留各自的开发前提，可能需要匹配的基线提交、测试数据、模拟器标识或构建设置。本仓库不包含那些私人开发记录，也不声称全部历史工具均已在 5128 上通过。以上源码检查不测量真机帧率，不验证实际购买。
