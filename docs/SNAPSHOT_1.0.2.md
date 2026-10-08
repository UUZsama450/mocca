# 1.0.2 (5173)

[更新说明 / Changelog](../CHANGELOG.md) · [Build configuration](BUILD_CONFIGURATION.md)

The [changelog](../CHANGELOG.md) compares the previous GitHub **1.0.1 (5157)** source with this **1.0.2 (5173)** source. The exact product range is [381f550b → f3eaeabe](https://github.com/UUZsama450/mocca/compare/381f550bfd3d7123eb4dafb8d6c8da1e69946b9f...f3eaeabe27d70b45f9c7a87fe88b8f59a05b817b).

[更新说明](../CHANGELOG.md)以 GitHub 上一版 **1.0.1（5157）** 为起点，核对本次实际合入的代码变化；下列边界补充说明便签、缓存和恢复的行为。

- Profile editing adds Save, an unsaved-change indicator and leave confirmation. Topics start collapsed; entries and topics can be edited or deleted, and the latest deletion can be undone while the page remains open. Existing profile fields migrate to notes. Conflicting user/assistant edits keep the draft open without overwriting live content.
- Assistant note editing is off by default and requires both profile usage and editing permission. Dynamic profile/recent-memory content sits before the latest user message, after stable history. This preserves the earlier prompt prefix when that content changes; it does not guarantee a cache hit or zero token cost. Changing tool permissions can still change the tool set.
- Reply recovery protects received progress, including reasoning-only and tool-only replies and replies with streaming display disabled. It marks interrupted runs and does not automatically resend or resume the model request. Content not received by the app cannot be recovered, and sudden termination can still lose progress not yet saved.

资料页支持保存、未保存提醒和返回确认；便签默认折叠，可重命名、逐条编辑与删除，离开页面前可撤销最近一次删除，旧资料自动迁移。用户与助手修改冲突时保留草稿，避免覆盖已保存内容。助手编辑默认关闭，需同时开启资料使用及编辑权限。动态资料与近期记忆靠近最新用户消息插入，减少对前部提示缓存的影响，不保证零 token 或必然命中缓存。中断恢复涵盖已接收的正文、思考和工具进度，也适用于关闭流式显示的回复；不会自动重发或续接请求，尚未收到或尚未保存的内容仍可能缺失。

## Source and validation

- Based on phone **1.0.1 (5172)**. The user accepted the profile Save/account-card changes and the faster settling motion. No new physical-device FPS result is claimed.
- Retained validation: 12 profile/model/tool/cache cases plus 7 profile UI cases; 51 background-recovery cases; 47 settling cases and five existing-conversation send scenarios for both baseline and candidate.
- Portable Release simulator build passed with all 146 frozen inputs unchanged. Sponsorship configuration and disabled-operation checks passed all five cases; completion-codec checks passed 1,111 cases.
- All 154 frozen phone inputs were compared with this 146-input portable variant. Intentional differences preserve configurable signing, sponsorship disabled by default, neutral examples, and reviewed assets. See the [variant manifest](SOURCE_VARIANT_1.0.2.json).
- App and extension use **1.0.2 (5173)**. The app target now enables the same streaming compilation condition used by the installed phone build; package-generated conditions are retained.

本次同步源码，没有生成新的下载包或提交 App Store；旧的 5135 IPA 仍为历史预览版本。正式发布与安装单独记录。
