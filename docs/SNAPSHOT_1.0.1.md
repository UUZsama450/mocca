# 1.0.1 (5157)

This patch keeps the native chat transcript and its system top bar mounted while a conversation is empty. Sending the first message fills that existing view, fixing the missing top fade observed when the keyboard was still open. It also carries the accepted send-animation and scroll-position fixes, and removes retired conversation-entry bookkeeping and drawer comparison routes.

本补丁在空对话阶段就保留原生聊天列表和系统顶部栏。首次发送沿用同一个列表，修复键盘展开时发送首条消息后顶部渐隐消失的问题，同时纳入已验证的发送动画、滚动落点修复，清理已退役的入场状态和抽屉比较入口。

## Source and validation

- Based on installed device build 1.0 (5156); 1.0.1 (5157) changes version metadata without adding product behavior.
- The top-fade fix was confirmed by the user on a physical iPhone in 5155. Combined 5156 passed seven simulator send scenarios, two drawer UI tests, eight lifetime checks, and signed Release build/install checks.
- Simulator checks used iOS 26.2. The reported top-fade issue and acceptance were on an iOS 27 phone; simulator results alone do not establish that acceptance. No fresh physical-device FPS measurement is claimed.
- The portable source retains configurable signing, sponsorship disabled by default, neutral examples, and the established asset selection. Shared transcript, composer, and Markdown implementation files match the development source. See [variant manifest](SOURCE_VARIANT_1.0.1.json).

基线为已安装的 1.0（5156）；1.0.1（5157）只调整版本元数据。顶部渐隐修复在 5155 获得用户真机确认；合并清理后的 5156 已通过 7 项模拟器发送场景、2 项抽屉 UI 测试、8 项生命周期检查，以及签名 Release 构建与覆盖安装验证。模拟器系统为 iOS 26.2，真机为 iOS 27；未重新测量真机帧率。

App Store review and release are tracked separately from source synchronization. The older 5135 unsigned IPA remains in release history; this source update does not relabel that binary as 1.0.1.

App Store 审核与发布独立记录。旧的 5135 未签名 IPA 保留在发布历史中，不会因源码升级而被改称为 1.0.1。

## 2026-10-04 submission record

The fresh portable Release simulator build passed with all 143 frozen product inputs unchanged. The production archive passed version, signature, entitlement, dSYM, privacy-manifest, and source-provenance checks. App Store Connect accepted **1.0.1 (5157)** and now shows **Waiting for Review**. English metadata and five screenshots using the current app UI are included. Release remains manual after approval.

本次可移植源码的 Release 模拟器构建通过，143 项冻结产品输入未变化。正式归档的版本、签名、权限、符号、隐私清单和来源检查均通过。App Store Connect 已接收 **1.0.1（5157）**，当前状态为 **正在等待审核**；包含英文介绍及五张基于当前 App 界面的英文商品图。审核通过后仍需手动发布。
