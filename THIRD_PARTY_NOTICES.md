# 第三方项目、素材与商标说明

本文件记录随源码或应用分发的第三方内容及来源。逐项素材路径、哈希、实际用途和修改说明见 [素材核对表](docs/ASSET_AUDIT.md) 与 [文件清单](docs/ASSET_INVENTORY.json)。文件来源可追溯不等于第三方商标使用获得了单独授权。

## 上游项目

| 项目 | 用途 | 来源与条件 |
| --- | --- | --- |
| [Kelivo](https://github.com/chevey339/kelivo) | 产品与数据生态来源、旧版兼容、部分服务标识与文案 | AGPL-3.0；保留许可证、来源及修改说明，分发时核对相应版本源码 |

Mocca 的具体修改与非官方关系见 [NOTICE.md](NOTICE.md)。

## 项目图标与默认头像

- `Mocca/AppIcon.icon/`：当前猫猫图标的可编辑图层，制作来源已由维护者确认并在本地留档。本次移除未引用草稿和被替代的旧粉色 App 图标，保留当前图层。
- `DefaultAssistantAvatar.imageset`、`DefaultUserAvatar.imageset`：项目制作并整理的默认头像，制作与导入记录已核对。
- `AssistantAvatar.imageset`：保留旧备份需要的资源名称；经维护者确认，旧粉色图片改为当前默认小机器人头像，并提供三个尺寸。
- `ProviderMocca.imageset/mocca.png`：虽然目录名含 Mocca，实际图案与 Kelivo 的 `assets/icons/kelivo.png` 相同，属于历史品牌兼容资源，**不列为 Mocca 自有视觉**。它不再是新配置的可选/自动推断图标，但旧配置仍可显式引用。

个人制作记录、私聊和本机目录不包含在公开文件清单中。

## 服务商与搜索服务 Logo

`Provider*.imageset` 与 `Search*.imageset` 中的名称和标识用于区分用户配置的兼容服务。各品牌名称、Logo 和商标归各自权利人所有，不表示与 Mocca 存在合作、认可或背书关系。

2026-09-20 已对 27 张 SVG 逐项记录固定上游链接与本地修改。当前固定 Kelivo 版本中有 20 张逐字节一致，OpenRouter 与另一固定历史版本一致，其余有尺寸、XML、布局或渐变调整。详细证据与比较范围见素材核对表。

其中一部分图形可追溯至 [Lobe Icons](https://github.com/lobehub/lobe-icons)，包括完整文件匹配、绘图结构匹配与本地改编。Lobe Icons 的 MIT 许可原文保存在 [Mocca/LobeIcons-LICENSE.txt](Mocca/LobeIcons-LICENSE.txt)，并作为 App 资源随包分发：

> Copyright (c) 2023 LobeHub

MIT/AGPL 是相应文件的许可说明，不把第三方品牌或商标转让给 Mocca。本次完成来源与分发署名核对，未逐品牌作出商标授权结论。

## 本轮清理范围

移除了 13 张冗余 PNG（9 张旧粉色 App 图标、4 张未引用草稿）以及旧 AppIcon 目录配置；替换旧粉色助手头像并保留兼容名称。当前保留 43 个 PNG/SVG 文件，逐文件清单作为后续核对基线。

旧文档中“32 张与本地 Kelivo 副本相同”是 2026-08-26 的历史观察，不能继续作为当前文件数量或当前公开上游版本的结论。

## 运行时下载内容

Mocca 可以按用户操作加载远程图片或字体。远程内容仍受其来源网站和作者的条款约束；下载或显示不代表这些内容被纳入 Mocca 的源码许可证。

## 代码语法高亮（4995）

- [HighlighterSwift](https://github.com/smittytone/HighlighterSwift)：固定 3.1.0，提交 `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0`，MIT。包含 Highlightr 的 MIT 许可代码与 highlight.js 11.11.1（BSD-3-Clause）。Swift Package 无其他包依赖。
- 仅在本地解析显式标注语言的代码并提取前景色；不执行消息里的代码。应用继续使用原生 UITextView，不导入库的字体、背景或布局。
- 版权与许可证原文保留在 `Mocca/CodeHighlighting-LICENSE.txt`，同时作为应用资源随包分发。包版本与提交记录在 `Mocca.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。

## 界面英文翻译

`Mocca/Localizable.xcstrings` 中一部分英文文案依据 [Kelivo](https://github.com/chevey339/kelivo) 的 `lib/l10n/app_en.arb`、`app_zh.arb` 中相同中文键整理，沿用上游 AGPL-3.0 许可证。其余文案针对 Mocca 的 SwiftUI 界面补充和调整。上游译文贡献者的权利和仓库许可证继续适用；此次修改包括去除 Flutter 插值格式、适配 Mocca 参数与界面术语。
