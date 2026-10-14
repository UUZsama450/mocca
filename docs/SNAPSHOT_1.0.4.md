# 1.0.4 (5206)

[更新说明 / What’s new](../CHANGELOG.md) · [Installation](INSTALLATION.md) · [Source variant](SOURCE_VARIANT_1.0.4.json)

This release refines model selection, the tools panel and chat interface; improves conversation search, startup and long-chat rendering; and adds clearer interruption details and reply-version preservation when branching conversations. The composer uses the standard primary GPT icon tint.

## Source and verification

- Based on the accepted 5205 development build. Release-only product changes are version metadata and GPT icon tint. This release makes no new physical-device performance claim.
- The portable arm64 Release build passed with all 149 frozen product inputs unchanged. The separate App Store archive passed with all 157 frozen product inputs unchanged.
- Production model-balance lifecycle and observation checks passed, including cancellation, stale results, debounce, timeout, and one request across 100 equivalent updates.
- Group-member model checks passed for isolation, persistence, legacy decoding, reset, invalid selection, and save rollback. Sponsorship configuration and disabled-operation checks passed all five cases.
- Superseded tool rows, the old reasoning menu/binding, and the old attachment-button background are absent. One active tool-card background and one reasoning control remain. Storage and backup compatibility identifiers are retained.
- App and extension are 1.0.4 (5206). Signature/provisioning and dSYM checks passed for the App Store archive. The unsigned portable package excludes test fixtures, diagnostic markers, local data, certificates and provisioning profiles.
- Portable defaults preserve configurable signing, sponsorship disabled by default, neutral examples and reviewed assets. The source-variant manifest records differences and hashes. Existing README images remain fictional demonstrations.

## Distribution

The [GitHub preview IPA](https://github.com/UUZsama450/mocca/releases/tag/v1.0.4) requires your own signing. Third-party signing and installation have not been verified. Read the installation instructions and release SHA-256 checksums.

The App Store package is submitted separately and uses manual release after review. The GitHub release does not mean the store update is live. The [App Store page](https://apps.apple.com/us/app/mocca-ai-chat/id6807043522) shows the currently available store version.

本次发布基于已确认的 5205 开发版，保留字体与现有功能，并恢复 GPT 图标的常规颜色。旧工具行、思维链菜单和旧按钮背景已移除，数据兼容逻辑继续保留。GitHub 包需要自行签名；App Store 单独送审，通过后手动发布。
