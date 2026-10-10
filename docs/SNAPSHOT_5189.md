# 1.0.2 (5189) source update

[Changelog / 更新说明](../CHANGELOG.md) · [Build configuration / 构建配置](BUILD_CONFIGURATION.md)

This snapshot updates the previous GitHub 1.0.2 (5173) source to the application logic installed as 1.0.2 (5189). It includes the model-picker and group-member controls, asynchronous image preparation, optional message-time context, request-preparation cleanup, Markdown and long-code improvements, streaming-text measurement reuse, and shared save-identity computation described in the changelog.

本次将 GitHub 上一份 1.0.2（5173）源码同步到手机已安装的 1.0.2（5189）。具体功能变化见更新说明。发送保存继续使用原来的存档格式、校验、独立备份和中断恢复，日常源码不含发送耗时复制入口或观测器。

## Source correspondence / 源码对应关系

The 155 frozen phone inputs were compared with 147 portable build inputs. All 55 shared Swift files retain the same portability differences as the previous published source; the new request-preparation file matches the phone source. Configurable signing, sponsorship disabled by default, neutral synthetic examples, reviewed artwork and the bundled icon license remain intact. The [variant manifest](SOURCE_VARIANT_5189.json) records the intentional differences and source hashes.

已核对 155 项手机冻结输入与 147 项可移植构建输入。55 个共有 Swift 文件与手机源码之间的差异仍限于原有可移植配置和中性示例，新请求准备文件与手机源码一致；签名配置、默认关闭的赞助、原有素材及图标许可继续保留。

The app and extension declare build 5189 in both Debug and Release. The app target enables `STREAM_HEIGHT_PHONE_CANDIDATE` and `PROSE_MEASUREMENT_REUSE_CANDIDATE`; package-generated compilation conditions are preserved.

## Verification / 验证

The complete portable Release simulator build passed with Xcode 26.3 (17C529), with all 147 frozen inputs unchanged. App and extension identities and build numbers passed readback. Sponsorship is `NO`; both app runtime conditions and Highlighter's `SWIFT_PACKAGE` condition are present. All 250 bundled highlighting JavaScript/CSS assets match the installed 5189 package. Send-timing and injected fixture markers are absent from the built app.

完整 Release 模拟器构建通过，147 项冻结输入未变；主应用与扩展版本、应用标识、默认关闭的赞助、渲染编译条件及高亮资源核对通过。最终产物没有发送耗时入口、观测器或注入的测试夹具。

```sh
xcodebuild -project Mocca.xcodeproj -scheme Mocca \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The following checks ran against this portable tree:

```sh
python3 CandidateTests/check_sponsorship_build_gate.py
python3 CandidateTests/check_completion_codecs.py --candidate-only
python3 CandidateTests/check_group_member_models.py
python3 CandidateTests/check_markdown_inline_repairs.py
python3 CandidateTests/check_code_syntax_styler.py
```

All passed: five sponsorship configuration/disabled-operation cases, 1,111 completion-codec cases, group/member isolation and persistence/rollback checks, 819 inline Markdown checks, and 15 color-scheduling/foreground semantics cases. These are synthetic host checks; they do not measure phone frame rate, rendering pixels or actual purchases.

以上检查全部通过，涵盖赞助配置与关闭状态、控制片段解析、群聊成员模型隔离及保存失败回退、行内 Markdown 与着色调度。它们使用虚构测试数据，不代替真机画面、帧率或实际购买验证。

The existing storage validation is retained as prior evidence: 75 application/storage guard checks, including 336 identity comparisons, and six complete sends with whole-archive readback in small and 12,000-message synthetic archives. The current store source is byte-identical to that tested implementation; the model's only portable Swift difference is neutral preview wording. Those earlier checks are not reported as newly rerun for this source synchronization.

保存保护的既有证据包括 75 项检查（含 336 次身份对照）和小存档／12,000 条消息存档的六次完整发送及整库回读；按源码对应关系引用，本次没有将旧结果记作新测试。

## Distribution boundary / 分发范围

This update synchronizes source only. It does not install another phone build, publish a new IPA, change repository visibility or submit an App Store version. Earlier release documents and downloads retain their original build context. Phone timing reports, diagnostic builds and private development artifacts remain in the local workspace.

本次只同步源码。手机版本、现有下载包、仓库可见性与 App Store 状态保持各自的发布记录；真机耗时报告、诊断安装包及本机开发产物继续留在本地。
