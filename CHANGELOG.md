# 更新记录 / Changelog

## 1.0.6

本次先发布源码更新，暂未附带新版 IPA。App Store 版本独立发布。

### 新增与改进

- **公式显示**：支持正文中的行内公式与独立公式，改进 Markdown 段落和数学内容的混合显示。
- **搜索提示词**：可以自定义搜索工具提示词、恢复默认；离开编辑页前可保存、放弃修改或继续编辑。
- **图片搜索**：新增按助手保存的开关，默认关闭。搜图结果的后续发送遵循现有历史图片开关和数量上限。
- **搜索服务**：支持 DeepSeek 搜索和自定义 JSON 搜索接口。
- **Mocca 配色**：新增拿铁、抹茶、莓果、雾蓝四组预设，保留默认与自定义颜色；统一按钮、选择控件和开关的主题色。
- **助手设置**：新建助手默认显示助手头像和名字；MCP 服务器列表新增快捷管理入口，返回后保留助手草稿。
- **历史消息**：改进重新生成、回复版本和删除操作，保持后续消息及阅读位置的一致性。
- 优化大文件导入提醒与设置入口，精简默认供应商列表。

### English

This release updates the source code. A new IPA is not attached. App Store releases are handled separately.

- Render inline and display math in prose, with improved mixed Markdown and formula handling.
- Customize the search tool prompt, restore defaults, and choose whether to save changes when leaving.
- Add a per-assistant image-search toggle, off by default. Historical image sending keeps its existing global switch and shared limit.
- Support DeepSeek search and custom JSON search endpoints.
- Add Latte, Matcha, Berry, and Mist Blue presets; retain default/custom colors and align controls with the selected theme.
- Enable assistant avatars and names by default for new assistants. Add an MCP management shortcut that preserves the assistant draft.
- Improve historical regeneration, reply-version handling, and deletion consistency.
- Refine large-file import reminders and simplify the default provider list.

### Validation

本地验证涵盖偏好保存、旧数据兼容、搜索协议、图片发送限制、主题颜色及页面操作。GitHub 源码保留可自定义签名与默认关闭赞助的构建配置。未进行新的真机性能或 FPS 验收。

Local checks cover preference persistence, backward compatibility, search contracts, historical-image limits, theme colors, and UI workflows. Source builds retain configurable signing and sponsorship disabled by default. This release does not claim new physical-device performance or FPS measurements.

## 1.0.5（5237）

- 修复重复选择当前对话时阅读位置跳动的问题。
- 取消文本附件与 Markdown 正文的应用侧截断/大小限制，保留完整内容。
- 新增大文件确认提醒，支持“不再提醒”及在偏好设置中重新开启。
- 统一提醒弹窗为系统蓝色，改进按钮对齐与长文件名显示。

- Preserve reading position when reselecting the current conversation.
- Preserve complete text attachments and Markdown bodies without the previous app-side truncation or body-size caps.
- Add large-file confirmation with opt-out and a preference to enable reminders again.
- Refine the reminder sheet with system blue, aligned actions and complete filename wrapping.

## 1.0.5（5228）

- 修复离底部发送消息时，聊天列表可能出现的反向往返滚动。
- 新增聊天分段设置，支持普通聊天和群聊按自然段展示回复，以及可选的自定义气泡间距。
- 普通聊天支持连续发送，等待时间可在 3–15 秒之间调整，默认 7 秒；回复期间新增的消息归入下一批。
- 改进输入框字号、光标与伸缩显示，调整行内代码外观。
- 统一普通设置行字重，以及侧边栏群聊和助手箭头的方向与动画。

- Fix back-and-forth transcript motion when sending away from the bottom.
- Add paragraph-based reply presentation for single and group chats, with optional custom bubble spacing.
- Add consecutive sending in single chats with a configurable 3–15 second wait, defaulting to 7 seconds. Messages added during a reply form the next batch.
- Refine composer font sizing, caret and resizing behavior, and inline-code appearance.
- Align standard settings typography and the direction and animation of group and assistant drawer arrows.

## 1.0.4（5219）

- 移除消耗型赞助的“恢复购买”入口与系统同步调用，保留已有纪念装扮记录。
- 简化赞助说明，移除“永久”和换机恢复承诺，更新中英文帮助与隐私说明。
- 改进聊天中的 MCP 服务器管理、独立选择与返回体验；供应商设置排在默认模型之前。

- Remove the Restore Purchases action and system sync for consumable tips while preserving existing decoration records.
- Clarify sponsorship wording, removing permanence and cross-device restoration claims from help and privacy text.
- Improve chat MCP server management, individual selection and return behavior; place Providers before Default Models in settings.

## 1.0.4（5216）

- 修复切换日历等助手分页时，顶部分页栏自动滚回最左侧的问题。
- 保留顶部内容遮挡、系统滚动边缘效果和 5215 的说明气泡修复。

- Preserve the horizontal tab-strip position when switching assistant pages, including Calendar.
- Retain header occlusion, the native scroll edge and the settings-popover fix from 5215.

## 1.0.4（5215）

- 修复打开“图片与上下文”和记忆说明时界面可能卡住的问题。
- 说明气泡使用独立的原生呈现与一次性尺寸测量，保留箭头、文字排版和系统动画。
- 保留 5211 的助手顶部、模型选择、工具面板和聊天改进。
- 发布包不包含测试夹具、故障注入或调试器记录。

- Fix the interface becoming unresponsive when opening image/context or memory explanations.
- Present explanations through an independent native popover with one-time sizing, retaining the arrow, typography and system animation.
- Retain the assistant-header, model-picker, tools-panel and chat improvements from 5211.
- Distribution packages exclude test fixtures, fault injection and debugger recording.

## 1.0.4（5211）

- 修复助手编辑页滚动内容穿过标题和分页栏的问题，统一顶部背景。
- 保留已采用的模型卡片对齐、助手管理、工具及说明气泡改进。
- 更新现有 `v1.0.4` 发布页的下载包；5210 仅完成准备，未发布为独立 Release。

### English

- Prevent assistant-editor content from showing behind the title and tabs; use one continuous header background.
- Retain the adopted model-card alignment, assistant management, tools and information-popover improvements.
- Refresh downloads on the existing `v1.0.4` release page. Build 5210 was prepared but not published as a separate release.

## 1.0.4（5210，源码准备 / source preparation）

- 优化模型卡片两排布局，对齐品牌、模型类型和能力图标。
- 完善助手多选删除、独立滚动列表与编辑页顶部样式。
- 改进工具、MCP 面板以及记忆和图像说明气泡。
- 此构建完成源码同步与打包准备，后续由 5211 替代，未发布独立 Release。

### English

- Refine two-row model cards and align brand, kind and capability icons.
- Improve assistant multi-select deletion, independent list scrolling and the native editor header.
- Refine tools/MCP panels and memory/image information popovers.
- Source synchronization and packaging were prepared, then superseded by 5211 before a separate Release was published.

## 1.0.4（5206）

- 优化模型选择、工具面板和聊天界面。
- 改进聊天搜索、启动速度与长对话显示。
- 完善中断提示和对话分支，保留回复版本。

### English

- Refine model selection, the tools panel and chat interface.
- Improve conversation search, startup and long-chat rendering.
- Clarify interruptions and preserve reply versions in conversation branches.

## 1.0.3（5194）

- 新增模型品牌图标，支持群聊成员独立选模。
- 优化长文选择、流式显示与代码高亮。
- 改善消息发送、图片加载和聊天界面。

### English

- Add model brand icons and per-member model selection in group chats.
- Improve long-text selection, streaming display and code highlighting.
- Refine message sending, image loading and the chat interface.

## 1.0.2（5173）

相较 GitHub 上一版 **1.0.1（5157）**。

- 新增主题便签：支持折叠、重命名、逐条编辑和删除撤销，兼容旧版资料。
- 可授权助手编辑便签，并减少资料、近期记忆更新对提示缓存的影响。
- 资料页新增保存、未保存提示和返回确认，避免覆盖用户与助手同时修改的内容。
- 个人资料移入设置，调整头像卡片、侧边栏玻璃按钮及输入栏布局。
- 优化流式长文、代码和表格的底部跟随，减少输入栏遮挡与代码块抖动。
- 优化首条消息入场，加快发送后文字回落，修复部分键盘切换后的动画失效与末尾下坠。
- 改进后台、锁屏及中断后的回复保存与恢复，保留已接收的正文、思考和工具进度。
- 回复通知显示对应助手头像，并完善后台生成开关与通知的联动。

### English

Changes since the previous GitHub source, **1.0.1 (5157)**.

- Add collapsible profile-note topics with rename, entry editing and deletion undo; migrate existing profile data.
- Allow optional assistant editing of notes and reduce prompt-cache disruption when profiles or recent memory change.
- Add explicit profile saving, unsaved-change indicators and leave confirmation; protect concurrent user and assistant edits.
- Move profiles into Settings and refine the avatar card, glass sidebar buttons and composer layout.
- Improve bottom following for streaming prose, code and tables, reducing composer overlap and code-block bobbing.
- Improve first-message entrance and speed up text settling; fix certain keyboard-triggered animation skips and late downward jumps.
- Improve reply-progress saving and recovery across backgrounding, locking and interruptions, retaining received text, reasoning and tool progress.
- Show the replying assistant's avatar in notifications and align notification behavior with background-generation settings.
