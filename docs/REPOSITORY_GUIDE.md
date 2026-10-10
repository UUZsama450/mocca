# Repository guide / 仓库说明

[English](../README.md) · [简体中文](../README.zh-CN.md)

## Source snapshot / 源码快照

This repository began with a prepared snapshot of development build 1.0 (5058) and now tracks **1.0.2** with unreleased improvements from phone build 5189. It has an independent Git history; earlier experimental branches, private development metadata and local verification outputs remain outside this repository. Kelivo attribution, licenses, compatibility identifiers and source provenance are retained. See [source baseline](SOURCE_BASELINE.md).

本仓库从开发版 1.0（5058）的源码快照开始，当前版本标记仍为 **1.0.2**，源码纳入了来自手机 5189 的未发布改动，使用独立的 Git 历史。早期实验分支、私人开发元数据和本机验证产物保留在原本的本地目录。Kelivo 来源、许可证、兼容标识与源码基线记录继续保留。

This is a portable source snapshot for the private [UUZsama450/mocca](https://github.com/UUZsama450/mocca) repository. Configurable signing identity, disabled-by-default sponsorship and the reviewed asset set distinguish it from the device build. This update does not create a downloadable app or change App Store releases.

这是 [UUZsama450/mocca](https://github.com/UUZsama450/mocca) 私有仓库的可移植源码快照。可配置的签名身份、默认关闭的赞助及整理过的素材，使它与真机安装包有所区别。本次更新不创建可下载应用，也不改变 App Store 的发布状态。

## Contents / 目录

| Path | Purpose / 用途 |
| --- | --- |
| `Mocca/` | Swift sources, translations, resources and bundled notices / 应用代码、翻译、素材及随包说明 |
| `GenerationActivityExtension/` | Live Activity extension / 实时活动扩展 |
| `Mocca.xcodeproj/` | Shared Xcode project, scheme and pinned package dependency / 共享工程、构建方案和依赖记录 |
| `Configuration/` | Portable defaults and an example for local overrides / 可移植默认值和本机配置示例 |
| `CandidateTests/` | Test harnesses, synthetic fixtures and historical validation notes / 测试工具、虚构数据及历史验证笔记 |
| `docs/` | Build instructions, provenance, asset inventory and development records / 构建说明、来源、素材清单及开发记录 |
| Root Markdown files | Project introduction, policies, notices and historical engineering notes / 项目介绍、政策、声明与历史工程笔记 |

Historical notes retain their original build context. Their presence does not mean every old harness passes against this snapshot. Known verification limits are recorded in [source baseline](SOURCE_BASELINE.md).

历史笔记保留原来的构建版本语境，不表示所有旧测试工具在当前版本都通过。已知验证限制见[源码基线](SOURCE_BASELINE.md)。

## Verification boundary / 验证范围

The 5189 portable source is compiled and checked separately from the phone build. Commands, results and limits are recorded in [5189 verification](SNAPSHOT_5189.md). Earlier snapshot results remain historical evidence. Device interaction, real purchases and release signing require their own verification.

5189 可移植源码独立进行编译与检查，命令、结果和限制记录在[本次变更与验证](SNAPSHOT_5189.md)中。旧快照的结果继续作为历史证据保留。真机交互、实际购买和发布签名需要分别验证。

Generated apps, build caches, device logs, private chats, backups, signing credentials and machine-local overrides are outside the source snapshot. See [.gitignore](../.gitignore) for exclusion rules. Ignore rules support this boundary; they do not replace reviewing the tracked tree and Git history before publication.

生成的 App、构建缓存、设备日志、私人聊天、备份、签名凭据和本机配置不属于这份源码快照。排除规则见 [.gitignore](../.gitignore)；规则不能代替上传前对实际跟踪文件和 Git 历史的检查。

## Updating the repository / 更新仓库

Local Git commits preserve local versions; they do not update GitHub automatically. Selected source updates are reviewed, committed and explicitly synchronized to `main`, preserving the existing publication history. Repository visibility stays private. Public source or binary distribution is a separate action.

本地 Git 提交用于保存本地版本，不会自动更新 GitHub。选定的源码更新经过检查、提交，再明确同步到 `main`，保留已有发布历史。仓库继续保持私有；公开源码或分发安装包是另外的操作。

See [development workflow / 开发维护流程](DEVELOPMENT_WORKFLOW.md) for branch, validation, merge and synchronization steps.
