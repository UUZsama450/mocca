# 1.0.2 (5173)

[更新说明 / Changelog](../CHANGELOG.md) · [Build configuration](BUILD_CONFIGURATION.md)

This source update includes profile notes and assistant-editing permission, refreshed Settings and composer controls, faster existing-text settling after sending, streaming-code layout fixes, background reply recovery, and assistant avatars in reply notifications.

本次包含个人资料便签与助手编辑权限、设置及输入栏调整、发送后文字更快回落、流式代码布局修复、后台回复恢复和助手头像通知。便签提示放在消息尾部上下文，保持固定系统提示前缀稳定。

## Source and validation

- Based on phone **1.0.1 (5172)**. The user accepted the profile Save/account-card changes and the faster settling motion. No new physical-device FPS result is claimed.
- Retained validation: 12 profile/model/tool/cache cases plus 7 profile UI cases; 51 background-recovery cases; 47 settling cases and five existing-conversation send scenarios for both baseline and candidate.
- Portable Release simulator build passed with all 146 frozen inputs unchanged. Sponsorship configuration and disabled-operation checks passed all five cases; completion-codec checks passed 1,111 cases.
- All 154 frozen phone inputs were compared with this 146-input portable variant. Intentional differences preserve configurable signing, sponsorship disabled by default, neutral examples, and reviewed assets. See the [variant manifest](SOURCE_VARIANT_1.0.2.json).
- App and extension use **1.0.2 (5173)**. The app target now enables the same streaming compilation condition used by the installed phone build; package-generated conditions are retained.

本次同步源码，没有生成新的下载包或提交 App Store；旧的 5135 IPA 仍为历史预览版本。正式发布与安装单独记录。
