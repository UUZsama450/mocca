# 更新记录 / Changelog

## 1.0.2（5189）— 源码同步 / Source update

相较上一份 GitHub 源码 **1.0.2（5173）**，同步到手机 5189 已采用的改动。

- 模型入口移至发送按钮旁，可选择名称或气泡样式，并记住服务商列表的折叠状态；微调默认侧边栏颜色。
- 群聊可为每位成员单独选择模型，助手可按需接收消息发送时间。
- 图片附件异步准备并显示加载状态，准备完成后再允许发送。
- 减少请求准备、历史版本选择和附件读取占用主线程的工作。
- 改善长代码高亮与分批着色，修复 Markdown 行内代码和 Unicode 分隔符的兼容处理。
- 复用流式文本测量结果，减少普通文本的重复扫描及发送保存时的重复身份计算。
- 保留现有存档格式、保存检查、独立备份和中断恢复；日常版不含发送耗时复制入口及观测器。

Changes since the previous GitHub **1.0.2 (5173)** source, aligned with the installed 5189 build.

- Place the model picker beside Send, add name and bubble styles, remember provider folding, and refine the default drawer color.
- Choose models per group member and optionally include message send times in assistant context.
- Prepare image attachments asynchronously, show loading state, and wait for preparation before sending.
- Reduce main-thread request preparation, history-version selection, and attachment-reading work.
- Improve long-code highlighting and batched color updates; repair inline-code and Unicode-delimiter handling.
- Reuse streaming-text measurements and reduce repeated ordinary-text scans and save-identity construction.
- Preserve the archive format, validation, independent backups, and interrupted-reply recovery. The daily build has no send-timing copy entry or observer.

本次为源码更新，下载包及 App Store 发布另行记录。This source update does not publish a new binary or change an App Store release.

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
