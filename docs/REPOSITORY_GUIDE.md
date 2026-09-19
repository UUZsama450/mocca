# Repository guide / 仓库说明

[English](../README.md) · [简体中文](../README.zh-CN.md)

## Source snapshot / 源码快照

This repository begins with a prepared snapshot derived from development build 1.0 (5058). It has an independent Git history; earlier experimental branches, private development metadata and local verification outputs remain outside this repository. Kelivo attribution, licenses, compatibility identifiers and source provenance are retained. See [source baseline](SOURCE_BASELINE.md).

本仓库从基于开发版 1.0（5058）整理的源码快照开始，使用独立的 Git 历史。早期实验分支、私人开发元数据和本机验证产物保留在原本的本地目录。Kelivo 来源、许可证、兼容标识与源码基线记录继续保留。

This is a publication candidate for [UUZsama450/mocca](https://github.com/UUZsama450/mocca), created as a private repository. No downloadable release has been created. It differs from both the installed development build and the separate App Store 5057 submission.

这是为 [UUZsama450/mocca](https://github.com/UUZsama450/mocca) 私有仓库准备的发布候选，尚未创建可下载版本。它与手机上的开发版、单独送审的 App Store 5057 均有区别。

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

The source and build inputs were preserved from the reviewed preparation tree. That tree passed unsigned iOS Debug builds after asset cleanup. An earlier portable-build pass also built an exported Release variant with sponsorship explicitly enabled. The independent snapshot changes documentation only; those build results are inherited evidence, not a new build of this repository. Device interaction, real purchases and release signing require their own verification.

源码与构建输入保留自已核对的整理版本。素材清理后的该版本通过了不签名 iOS Debug 构建；此前的可移植配置检查也成功构建了明确开启赞助的导出 Release 版本。本独立快照只更新说明文档，沿用这些构建证据，没有把它说成新仓库重新构建的结果。真机交互、实际购买和发布签名需要分别验证。

Generated apps, build caches, device logs, private chats, backups, signing credentials and machine-local overrides are outside the source snapshot. See [.gitignore](../.gitignore) for exclusion rules. Ignore rules support this boundary; they do not replace reviewing the tracked tree and Git history before publication.

生成的 App、构建缓存、设备日志、私人聊天、备份、签名凭据和本机配置不属于这份源码快照。排除规则见 [.gitignore](../.gitignore)；规则不能代替上传前对实际跟踪文件和 Git 历史的检查。

## Next publication steps / 后续发布步骤

1. Review this snapshot and its commit identity, then upload to the intended private repository. / 核对本快照与提交身份，再上传到选定的私有仓库。
2. Verify repository visibility, bilingual documentation and source links. / 核对仓库可见性、中英文说明和源码链接。
3. Handle public source and any binary release separately, with exact source correspondence and distribution checks. / 公开源码和二进制发布分别处理，核对对应源码及分发事项。
