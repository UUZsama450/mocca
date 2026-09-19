# Mocca 0.1.0 (4945) 首次送审候选

日期：2026-08-31

## 候选定位

- 正式功能基线：Mocca 0.1.0 (4944)
- 商店送审候选：Mocca 0.1.0 (4945)
- App Store 付费开发者团队：`Z44VFV3SBB`（4944 日用版使用的旧开发团队不用于商店上传）
- 4945 仅在 4944 上补齐应用内使用文档、隐私政策、许可证与来源入口，并更新 Build 号。
- 4944 的聊天、存储、渲染和流式跟随核心文件未在 4945 中修改。
- 不卸载现有 App；后续真机验证继续使用相同 Bundle ID 覆盖安装，以保留本地数据。

## 已完成的本地准备

- [x] 使用文档从占位页面替换为可阅读的原生页面
- [x] App 内可查看隐私政策
- [x] App 内可查看许可证与来源说明
- [x] 根目录 `PRIVACY.md` 已转为正式政策并标注生效日期
- [x] 三个赞助商品 ID、类型、文案、恢复入口和源码读取路径完成静态复核
- [x] `SettingsViews.swift` 通过 Swift 语法解析
- [x] 主 App、后台扩展和本地 StoreKit 配置均切换到付费开发者团队 `Z44VFV3SBB`
- [x] Xcode 工程文件与 Privacy Manifest 通过格式校验
- [x] 与 4944 对比，除设置/文档、隐私政策和 Build 号外无其他文件变化
- [x] Apple Developer 付费团队已注册主 App ID：`com.uuzsama450.mocca`
- [x] Apple Developer 付费团队已注册扩展 App ID：`com.uuzsama450.mocca.GenerationActivityExtension`
- [x] App Store Connect 已创建 Mocca 记录（Apple ID `6807043522`，SKU `mocca-ios-001`）

## 仍未完成，不能误报为已通过

- [ ] 最终 Release Archive、Validate App 和上传
- [ ] Xcode Archive Privacy Report 复核
- [ ] 4945 真机文档、链接和赞助页面验收
- [ ] 三个真实 App Store Connect IAP 的创建、截图、审核备注和 Sandbox 测试
- [ ] 公开 HTTPS Privacy Policy URL
- [ ] 公开 HTTPS Support URL 与稳定联系方式
- [ ] App Store Connect 版本号统一为 `0.1.0`，并补齐元数据、截图、隐私、年龄分级、出口合规和审核联系人
- [ ] 素材权利、商标与 AGPL/App Store 分发路线的最终发布决定
- [ ] 审核员可用且可撤销的第三方模型测试凭据，或无需凭据即可完整审核的替代路径

## 发布控制

首次版本应选择“审核通过后由开发者手动发布”。审核通过后，先公开与 0.1.0 (4945) 一致的源码 Tag/Release，再手动发布 App。审核期间如果修改二进制，需要新 Build 并重新提交审核。
