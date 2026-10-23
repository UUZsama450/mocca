## Mocca 1.0.6

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
