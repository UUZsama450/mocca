# Mocca 开源发布检查表

> 历史规划记录：下面的勾选和阻塞项反映早期准备状态，未随 5058 整理逐项更新。当前文件与验证范围见[仓库说明](REPOSITORY_GUIDE.md)和[源码基线](SOURCE_BASELINE.md)。早期“32 个素材”、签名配置和扫描待办不能作为当前结论；商店发布事项仍需对应正式版本单独核对。

本文件用于准备首次公开仓库和与 App Store 对应的源码版本。勾选表示已经对最终发布树完成验证，而不是仅完成过方向性讨论。

## 一、仓库安全

- [x] `work/`、构建目录、ZIP、签名材料和本机密钥配置已加入 `.gitignore`
- [ ] 使用专门工具扫描最终工作树和全部 Git 历史中的密钥
- [ ] 确认 Git 历史不包含聊天、备份、附件、设备日志或签名产物
- [ ] 决定是否保留或匿名化当前提交作者邮箱
- [ ] 确认 GitHub Actions、Release 附件和缓存也不含敏感内容

## 二、许可证与来源

- [x] 添加上游 AGPL-3.0 许可证文本
- [x] 添加 `NOTICE.md`，说明上游、非官方身份、修改方向与兼容范围
- [x] 添加 `THIRD_PARTY_NOTICES.md`
- [ ] 对最终源码完成逐文件来源与贡献者权利复核
- [ ] 对 AGPL 与 App Store 分发条款的路线作出明确决定
- [x] 确认应用内可以查看许可证和来源说明
- [ ] 补上与商店二进制对应的公开源码链接

## 三、素材与商标

- [ ] 处理 `docs/ASSET_AUDIT.md` 中全部 32 个上游同源资源
- [ ] 锁定最终 Mocca App 图标源文件并保留作者/生成过程记录
- [ ] 为每个服务商与搜索 Logo 登记来源、许可和商标说明
- [ ] 对无法确认的素材进行替换或移除
- [ ] 确认 App Store 截图、宣传图和仓库图片同样具有发布权利

## 四、隐私与 App Store

- [x] 起草 `PRIVACY.md`
- [x] 添加独立的 `docs/APP_STORE_SUBMISSION_CHECKLIST.md`，区分本地、后台和条件合规门槛
- [ ] 对最终 Archive 生成并审阅 Xcode Privacy Report
- [x] 添加 `PrivacyInfo.xcprivacy`，声明当前 `UserDefaults` 与系统运行时间 Required Reason API 理由
- [x] 在 App 内提供容易找到的隐私政策和许可证入口
- [ ] 在 App 内补上对应源码入口
- [ ] 确保 App Store Privacy Labels 与最终数据流一致
- [ ] 核对照片、相机、位置、日历、提醒事项和语音权限的实际调用时机
- [ ] 准备稳定的公开隐私政策 URL 和支持联系方式

## 五、公开构建

- [ ] 将开发团队与 Bundle Identifier 调整为贡献者可配置方式
- [ ] 从全新匿名目录克隆并构建 Debug/Release
- [ ] 验证模拟器构建不依赖个人签名或本机文件
- [ ] 验证真机签名说明足以让贡献者使用自己的团队
- [ ] 确认仓库中的版本号、Build 号与 App Store 审核版本一致

## 六、同步发布顺序

- [ ] App Store Connect 选择审核通过后手动发布
- [ ] 审核通过后冻结最终提交，不再混入未审核功能
- [ ] 为对应源码创建带版本与 Build 号的 Git Tag
- [ ] 先公开仓库并创建 GitHub Release
- [ ] 从公开地址重新克隆、扫描并构建一次
- [ ] 确认源码、License、Notice、隐私政策和素材台账均可访问
- [ ] 最后在 App Store Connect 手动发布

## 当前公开阻塞项

1. 32 个与上游逐字节相同的资源尚未全部核清。
2. 最终 Archive 隐私报告和公开源码入口尚未完成。
3. 尚未使用专门密钥扫描工具完成全历史发布审计。
4. 个人开发团队、Bundle Identifier 和提交邮箱的公开策略尚未决定。
5. AGPL 与 App Store 分发条款的最终处理路线尚未确定。

App Store 首次送审的完整硬门槛与推荐顺序见 [APP_STORE_SUBMISSION_CHECKLIST.md](APP_STORE_SUBMISSION_CHECKLIST.md)。
