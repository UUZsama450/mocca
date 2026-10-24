## Mocca 1.0.6 (5248)

本次先发布源码更新，暂未附带新版 IPA。App Store 版本独立发布。

### 5248 更新

- **输入与消息联动**：减少多行输入时重复的聊天布局工作。关闭输入框伸缩动画后，聊天消息仍平滑跟随；展开或收起群聊成员栏时，消息也同步移动。
- **默认配色**：恢复默认主题原有的蓝色控件和绿色开关，保留新增配色选项。
- **提示词编辑**：精简内置联网搜索提示词并改为英文，保留引用、图片与重试规则；已有自定义内容保持不变。OCR 提示词编辑改用普通正文字体。
- **退出确认**：搜索提示词的未保存提醒按“保存并离开 → 继续编辑 → 不保存”排列，“不保存”位于底部并保持红色。

### 1.0.6 新增与改进

- **公式显示**：支持正文中的行内公式与独立公式，改进 Markdown 段落和数学内容的混合显示。
- **搜索提示词**：可以自定义搜索工具提示词、恢复默认；离开编辑页前可保存、放弃修改或继续编辑。
- **图片搜索**：新增按助手保存的开关，默认关闭。搜图结果的后续发送遵循现有历史图片开关和数量上限。
- **搜索服务**：支持 DeepSeek 搜索和自定义 JSON 搜索接口。
- **Mocca 配色**：新增拿铁、抹茶、莓果、雾蓝四组预设，保留默认与自定义颜色；非默认配色的控件随所选主题调整。
- **助手设置**：新建助手默认显示助手头像和名字；MCP 服务器列表新增快捷管理入口，返回后保留助手草稿。
- **历史消息**：改进重新生成、回复版本和删除操作，保持后续消息及阅读位置的一致性。
- 优化大文件导入提醒与设置入口，精简默认供应商列表。

### English

This release updates the source code. A new IPA is not attached. App Store releases are handled separately.

- Reduce redundant transcript layout work during multiline typing. Keep message motion when composer resizing animation is disabled, and synchronize messages with group-member panel expansion and collapse.
- Restore the default theme's blue controls and green switches while retaining the additional palettes.
- Shorten the built-in web-search prompt and write it in English, retaining citation, image and retry rules. Preserve custom prompts. Use the regular body font in the OCR prompt editor.
- Order the search-prompt exit alert as Save and Leave, Keep Editing, then Discard; keep Discard red at the bottom.
- Render inline and display math in prose, with improved mixed Markdown and formula handling.
- Customize the search tool prompt, restore defaults, and choose whether to save changes when leaving.
- Add a per-assistant image-search toggle, off by default. Historical image sending keeps its existing global switch and shared limit.
- Support DeepSeek search and custom JSON search endpoints.
- Add Latte, Matcha, Berry, and Mist Blue presets; retain default/custom colors and apply selected colors to non-default theme controls.
- Enable assistant avatars and names by default for new assistants. Add an MCP management shortcut that preserves the assistant draft.
- Improve historical regeneration, reply-version handling, and deletion consistency.
- Refine large-file import reminders and simplify the default provider list.

### Validation

本地验证涵盖偏好保存、旧数据兼容、搜索协议、图片发送限制、主题颜色及页面操作。GitHub 源码保留可自定义签名与默认关闭赞助的构建配置。输入与群聊联动、历史阅读位置、搜索编辑流程及默认配色已完成本地回归；5248 已完成真机安装和启动核对。未进行新的真机 FPS 或功耗测量。

Local checks cover preference persistence, backward compatibility, search contracts, historical-image limits, theme colors, and UI workflows. Source builds retain configurable signing and sponsorship disabled by default. Composer and group-panel motion, reading-position preservation, prompt editing and default colors have local regression coverage. Build 5248 was installed and launched on a physical device. No new physical-device FPS or power measurements are claimed.

### Source / 源码

本页更新至 5248。历史 `v1.0.6` 标签及页面底部自动生成的 Source code 归档仍对应 5244；请使用 Release 顶部明确标注的 5248 源码链接与下载入口。

This page is updated to build 5248. The historical `v1.0.6` tag and automatic Source code archives at the bottom still identify build 5244. Use the explicit 5248 source and download links at the top of the release.
