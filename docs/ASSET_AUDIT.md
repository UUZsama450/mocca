# 素材来源与实际用途核对

核对日期：2026-09-20。范围为 5058 发布准备树的 PNG/SVG、资源目录配置、代码引用和 Xcode 26.3 构建产物。逐文件哈希、来源链接与状态见 [ASSET_INVENTORY.json](ASSET_INVENTORY.json)。

本表区分“文件来源能够追溯”和“特定品牌使用已经获得授权”。哈希匹配、开源许可和商标使用条件不是同一件事；这里不把来源核对写成所有品牌的授权结论。

## 当前图标与头像

| 资源 | 实际用途与来源 | 处理 |
| --- | --- | --- |
| `Mocca/AppIcon.icon/` | 当前猫猫图标；由项目制作并整理，维护者已确认制作来源，本地留档 | 保留 5 张活动图层，以及编辑文件仍引用的隐藏背景层 |
| `DefaultAssistantAvatar.imageset`、`DefaultUserAvatar.imageset` | 项目制作的默认头像；六张尺寸图与 4800 候选逐字节一致，制作与导入记录已核对 | 保留；不影响照片、自定义图片和表情头像的优先级 |
| `AssistantAvatar.imageset` | 旧 `asset:AssistantAvatar` 以及 About 图片读取失败时仍可能引用 | 经维护者确认，保留兼容名称，三张尺寸图改为当前默认机器人头像；旧粉色图不再分发 |
| `ProviderMocca.imageset/mocca.png` | 与固定 Kelivo 上游的 `assets/icons/kelivo.png` 逐字节一致；旧显式品牌配置仍可引用 | 标记为 Kelivo 历史品牌素材，不能称为 Mocca 自有图标；暂保留兼容引用 |
| `AboutAppIcon.png`（构建生成） | 从编译后的 App 图标生成；不是旧助手头像 | 源码不重复存放生成图，构建脚本保留 |

详细制作记录、个人目录和会话内容只保存在本地核对证据中，不纳入公开素材清单。

## 已移除的冗余素材

- `AppIcon.appiconset` 的 9 张旧粉色尺寸图及目录配置：已由当前 Icon Composer 图标取代。
- `AppIcon.icon/Assets/` 的 4 张 UUID 文件名草稿：未被 `icon.json` 引用。
- 原件仍存在于本地基线提交 `e56768c` 及原开发历史，未删除原开发目录中的文件。

移除后不签名 Debug 构建通过。独立 App 图标 PNG、About 图片和活动图层编译内容与清理前一致；保留图层和 `icon.json` 逐字节不变。Assets.car 中整张图标的封装摘要在清理前的 Debug/Release 之间已经不同，因此不把该摘要作为跨构建像素一致的证据。未做新的手机安装或 iOS 界面验收。

## 服务商与搜索服务素材

固定比较版本：Kelivo `5abbcf58fd9731691b9c3fcb15abf9e0120aac70`；历史 Kelivo `04664e2d6d483c60e2f01e60e601956db81a2cd8`；Lobe Icons `a94750e3f5f8fc33757b839d85030e742284e43a`。

当前 27 张 SVG 中，20 张与当前固定 Kelivo 版本逐字节一致，OpenRouter 与历史固定版本逐字节一致；其他文件存在尺寸、格式、布局或渐变方面的本地调整。Bing、LinkUp 的上游样本 XML 结构有问题，本地文件均能正常解析；只报告 path 内容匹配，不把它们写成完整文件相同。

| 当前资源 | 固定来源链接 | 比对与改动说明 |
| --- | --- | --- |
| `ProviderAIHubMix.imageset` / `aihubmix-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/aihubmix-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `ProviderAlibabaCloud.imageset` / `alibabacloud-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/alibabacloud-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `ProviderByteDance.imageset` / `bytedance-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/bytedance-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `ProviderClaude.imageset` / `claude-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/claude-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `ProviderDeepSeek.imageset` / `deepseek-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/deepseek-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `ProviderGemini.imageset` / `gemini-color.svg` | [来源](https://github.com/lobehub/lobe-icons/blob/a94750e3f5f8fc33757b839d85030e742284e43a/packages/static-svg/icons/gemini-color.svg) | 由旧图改编：保留星形轮廓、展开弧线参数、简化渐变；修改见本地 9ec0df2 |
| `ProviderGrok.imageset` / `grok.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/grok.svg) | 与固定 Kelivo 版本逐字节一致 |
| `ProviderOpenAI.imageset` / `openai.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/openai.svg) | 与固定 Kelivo 版本逐字节一致 |
| `ProviderOpenRouter.imageset` / `openrouter.svg` | [来源](https://github.com/chevey339/kelivo/blob/04664e2d6d483c60e2f01e60e601956db81a2cd8/assets/icons/openrouter.svg) | 与 2026-08-31 的固定 Kelivo 版本逐字节一致 |
| `ProviderSiliconFlow.imageset` / `siliconflow-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/siliconflow-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `ProviderTensdaq.imageset` / `tensdaq-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/tensdaq-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `ProviderZhipu.imageset` / `zhipu-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/zhipu-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchBing.imageset` / `bing-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/bing-color.svg) | 全部 path 命令匹配；本地已修正 XML 结构/布局，上游原件 XML 无法直接解析 |
| `SearchBocha.imageset` / `bocha-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/bocha-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchBrave.imageset` / `brave-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/brave-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchDuckDuckGo.imageset` / `duckduckgo-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/duckduckgo-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchExa.imageset` / `exa-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/exa-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchJina.imageset` / `jina-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/jina-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchLinkUp.imageset` / `linkup.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/linkup.svg) | 全部 path 命令匹配；本地已修正 XML 结构/布局，上游原件 XML 无法直接解析 |
| `SearchMetaso.imageset` / `metaso-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/metaso-color.svg) | 绘图子节点匹配；根尺寸/标题等有差异 |
| `SearchOllama.imageset` / `ollama.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/ollama.svg) | 绘图子节点匹配；根尺寸/标题等有差异 |
| `SearchPerplexity.imageset` / `perplexity-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/perplexity-color.svg) | 绘图子节点匹配；根尺寸/标题等有差异 |
| `SearchQuerit.imageset` / `querit-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/querit-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchSearXNG.imageset` / `searxng-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/searxng-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchSerper.imageset` / `serper.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/serper.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchTavily.imageset` / `tavily-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/tavily-color.svg) | 与固定 Kelivo 版本逐字节一致 |
| `SearchZhipu.imageset` / `zhipu-color.svg` | [来源](https://github.com/chevey339/kelivo/blob/5abbcf58fd9731691b9c3fcb15abf9e0120aac70/assets/icons/zhipu-color.svg) | 与固定 Kelivo 版本逐字节一致 |

## 许可证、署名与兼容边界

- Kelivo 来源与修改说明继续保留在 [NOTICE.md](../NOTICE.md)，项目许可证为 [AGPL-3.0](../LICENSE)。
- 一部分服务商图形可进一步追溯至 [Lobe Icons](https://github.com/lobehub/lobe-icons)。该项目的 [MIT 许可](https://github.com/lobehub/lobe-icons/blob/a94750e3f5f8fc33757b839d85030e742284e43a/LICENSE) 原文已保存在 [LobeIcons-LICENSE.txt](../Mocca/LobeIcons-LICENSE.txt)，并作为 App 资源随包分发。清单分别记录完整字节匹配、绘图结构匹配及本地改编，不混为同一种证据。
- 名称、Logo 和商标属于各自权利人；服务选择界面中的标识不代表与 Mocca 的隶属或背书关系。MIT/AGPL 不替代品牌方的商标使用条件。
- 旧备份标识与存储字段不是“多余词语”。本轮没有批量重命名，也没有删除旧头像/品牌的兼容名称。
- 2026-08-26 的“32 个与本地 Kelivo 副本相同”是历史检查记录；那个本地副本不是本轮固定的公开上游版本，不能沿用为当前素材数量或授权结论。

## 后续发布检查

来源台账已更新，仍需结合实际发布方式复核第三方品牌的使用条件。旧粉色助手图片已按维护者选择替换为默认机器人，兼容资源名称仍保留。公开源码历史、作者信息和对应二进制版本仍按发布准备流程处理。
