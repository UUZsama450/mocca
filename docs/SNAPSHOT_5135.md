# Mocca 1.0 (5135) source baseline / 源码基线

[English README](../README.md) · [中文说明](../README.zh-CN.md) · [Development workflow / 开发流程](DEVELOPMENT_WORKFLOW.md)

This source update is based on the installed 5135 device build. The original favorite-entry text gap was reported fixed by the device user on 2026-10-02. The local development mainline was consolidated from its frozen source inputs before preparing this portable update.

本次源码以已安装的 5135 真机版本为基线。2026-10-02，使用者确认原收藏进入时局部文字短暂缺失的问题已修复。本地开发主线先按照冻结的装机源码整理，再准备本次可移植源码更新。

## Changes since 5128 / 相比 5128 的变化

- Favorite navigation waits for the measured target position and matching native scroll geometry after inserting earlier history, then refreshes the existing text drawing coverage before the original cover fade.
- Includes the intervening phone-source changes for message selection, message details transitions, regeneration/resend follow, same-conversation reading position, preference controls and removal of superseded code.
- App and extension build numbers are explicitly 5135 in both Debug and Release. The README, source records and maintenance guide identify the same source baseline.

收藏补入历史消息后，等待目标行位置及滚动几何信息一致，在原有遮罩淡出前刷新文字绘制范围。同期已沿用的文本选择、消息详情过渡、重新生成／重发跟随、同会话阅读位置、偏好控件和旧代码整理也纳入本次源码。主应用与扩展的 Debug、Release 构建号均明确为 5135，文档统一说明当前基线。

## Portable variant / 可移植版本

The app logic is taken from the selected phone source. Existing publication-specific configuration is retained: configurable signing identity, sponsorship off by default, reviewed artwork and neutral examples. [File hashes and intentional differences](SOURCE_VARIANT_5135.json) map the prepared variant to the frozen phone inputs. The portable tree is built separately; it is not the signed phone archive.

应用逻辑来自选定的真机源码，继续保留既有发布配置：自行填写签名身份、默认关闭赞助、已整理的素材及中性示例。文件哈希清单列明与冻结装机输入的对应和有意差异。可移植源码单独构建，不等同于真机签名归档。

## Verification / 验证

Fresh checks on 2026-10-02 with Xcode 26.3:

- Unsigned Release build for the iOS Simulator passed in 538.3 seconds. All 143 product/configuration/resource inputs remained unchanged during compilation.
- Eight resolved build-setting combinations passed: main app and extension, Debug and Release, default settings and synthetic overrides.
- Five sponsorship configuration cases passed without executing enabled commerce.
- Twelve favorite publication-condition and 21 text-coverage checks passed against the prepared source.
- 1,111 completion-codec cases and 410 streaming-display checks passed in standalone candidate-only mode.
- Changed documentation links, conflict markers and private-path checks passed. The secret scan matched the four previously reviewed storage-field-name false positives, with no new findings.

2026-10-02 使用 Xcode 26.3 重新验证：不签名的 iOS 模拟器 Release 构建通过（538.3 秒），编译期间 143 项输入保持一致；8 组构建设置、5 种赞助配置、12 项收藏发布条件、21 项文字范围、1,111 项生成收尾解析及 410 项流式显示检查通过。修改文档的链接、冲突标记和私人路径检查通过；凭据扫描仅保留此前已核对的四项存储字段名误报，无新增发现。

The original device candidate also passed six diagnostic and nine ordinary simulator favorite entries before installation. Its original phone interaction is now user-confirmed. These source checks do not measure physical-device frame rate, prove every historical harness current, or validate enabled purchases; existing compiler warnings remain.

原装机候选另已通过 6 次带诊断、9 次普通模拟器收藏进入，原问题的真机体验现已得到用户确认。以上源码检查不测量真机帧率，不表示全部历史工具已适配，也不验证已开启的实际交易；编译中仍有既有警告。

The existing 5128 unsigned IPA release remains an older preview. This update changes source only and does not create a 5135 binary download or alter App Store distribution.

现有 5128 未签名 IPA 仍是旧版预览。本次只更新源码，不创建 5135 安装包下载，也不改变 App Store 分发。
