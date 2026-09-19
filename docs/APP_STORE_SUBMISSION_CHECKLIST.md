# Mocca App Store 首次送审检查表

审计日期：2026-08-31
审计范围：`mocca-app-store-release-4945-a` 候选中的 iOS 主 App、后台生成扩展、StoreKit 配置和发布文档。
证据边界：本文件可以确认仓库里的源码与配置，不能确认 App Store Connect、Developer Portal、协议、税务、银行、名称占用或各地区合规状态。

状态说明：

- `[x]`：已从当前仓库或本轮构建验证。
- `[ ]`：首次送审前仍需完成。
- `后台确认`：只能登录 App Store Connect / Developer Portal 后确认。
- `发布决策`：需要维护者选择路线，不能仅靠代码自动决定。

## 一、当前已经具备的本地基础

- [x] 主 App 使用独立 Bundle Identifier：`com.uuzsama450.mocca`
- [x] 后台扩展使用独立 Bundle Identifier：`com.uuzsama450.mocca.GenerationActivityExtension`
- [x] 当前最低系统版本为 iOS 17，设备族为 iPhone
- [x] 当前工程可使用 iOS 26 SDK 构建；2026-08-26 的无签名 iOS 模拟器 Debug 全量构建成功
- [x] 当前 App 图标构建源为 `Mocca/AppIcon.icon`
- [x] 已提供相机、照片、位置、日历和提醒事项用途说明
- [x] 首发版本已完整移除 HealthKit 工具、读取实现、用途说明和 entitlement
- [x] 三个赞助商品 Product ID 与 StoreKit 代码一致
- [x] 赞助页面会在付款前说明各档永久纪念装扮、共同的 `💧`、纯装饰属性和重复购买规则
- [x] 三个 StoreKit 商品说明均在 Apple 的 45 字符限制内
- [x] 已有正式隐私政策、AGPL 许可证、来源说明和第三方资源台账

以上只证明本地准备基础，不等于 App Store Connect 已可点击“提交审核”。

## 二、本地送审关键项与阻塞项

### 1. Privacy Manifest 与 Required Reason API

- [x] 添加 `Mocca/PrivacyInfo.xcprivacy` 并加入主 App Target
- [x] 声明当前源码明确使用的 Required Reason API：
  - `NSPrivacyAccessedAPICategoryUserDefaults`，理由 `CA92.1`
  - `NSPrivacyAccessedAPICategorySystemBootTime`，理由 `35F9.1`
- [ ] 用最终 Release Archive 生成 Xcode Privacy Report，确认文件元数据 API 是否还需要 `FileTimestamp` 类别及对应理由
- [ ] 确认主 App、扩展和所有未来引入的第三方 SDK 各自携带正确的隐私清单
- [ ] 确认 `NSPrivacyCollectedDataTypes`、App Store Privacy Labels 与最终数据流一致，不凭当前草案盲填

Apple 要求 App 或 SDK在隐私清单中说明收集的数据与 Required Reason API；源码使用的每个 API 类别都要有与真实功能一致的获准理由。

### 2. 公开隐私政策与支持入口

- [x] 把 `PRIVACY.md` 从“发布前草案”变成正式政策并补齐生效日期
- [ ] 在送审前提供可公开访问的 HTTPS 隐私政策 URL
- [ ] 在送审前提供可公开访问的 Support URL，页面要有真实可用的联系方式
- [x] 在 App 内“设置 → 关于”添加容易找到的：
  - 隐私政策
  - 使用文档
  - 开源许可证 / 来源说明
- [x] 使用文档不再是“暂未开放”占位页面
- [ ] 在 App 内补上稳定的支持与联系入口及对应源码地址
- [ ] 在真机上验证所有链接可以打开，不能是私有仓库、占位地址或待上线页面

注意：源码仓库可以等审核通过后、正式手动发布前再公开；但隐私政策和支持页面必须在提交审核时就已经公开可访问，不能等审核通过才上线。

### 3. HealthKit 首发路线（已完成）

- [x] 首发版本选择不提供 HealthKit 功能
- [x] 移除 `HealthKit` import、查询服务、工具定义和工具执行路径
- [x] 移除助手设置中的健康工具入口和聊天工具状态文案
- [x] 移除 `NSHealthShareUsageDescription`
- [x] 移除 `com.apple.developer.healthkit` entitlement 及其工程签名配置
- [x] 从隐私政策和迁移提示中移除健康数据处理说明

最终 Release Archive 仍需确认签名 entitlement 和 Privacy Report 中均不存在 HealthKit / Health Data。若未来重新加入，必须重新完成 Apple 健康数据规则、隐私披露和审核路线评估。

### 4. 赞助、永久装扮与恢复

- [x] 购买只通过 StoreKit 完成
- [x] 付款前会说明各档获得的永久纯装饰
- [x] 代码只接受已验证且未撤销的交易
- [x] 任意档位会解锁共同的 `💧`，并只解锁该档对应装扮
- [x] 添加用户可见的“恢复购买 / 找回纪念装扮”入口
- [x] 恢复操作调用 Apple 同步并重新读取已验证购买历史
- [ ] Sandbox 验证：小、中、大三个档位各自首次购买、同档重复购买、取消、Pending、失败、退款/撤销
- [ ] Sandbox 验证：退出重开、删除重装、同 Apple Account 换机后，只恢复买过档位的永久装扮
- [x] 源码确认恢复只解锁已购档位的永久衣柜项目，不会重新发放一次性掉落彩蛋
- [ ] 后台确认 Paid Apps Agreement、税务和银行信息可用
- [ ] 后台创建三个 Consumable IAP，并核对 Product ID、价格、税务类别、地区、中文/英文名称与说明
- [ ] 为每个 IAP 上传审核截图并填写 Review Notes
- [ ] 首次提交 Consumable IAP 时，把三个商品和首个 App 版本放进同一审核提交

当前“可重复投喂 + 首次留下永久纪念装扮”不是自动拒审项，但属于需要向审核员解释并完成真实恢复验证的非典型组合。

### 5. 权利、许可证与素材

- [ ] 完成 `docs/ASSET_AUDIT.md` 中 32 个上游同源素材的权利核查、替换或移除
- [ ] 锁定最终 Mocca 图标和助手头像，并留存作者、生成过程与发布权利记录
- [ ] 核清所有服务商 / 搜索 Logo 的来源、许可和品牌使用规则；无法确认时改为文字或系统符号
- [ ] 确认 App Store 截图、预览和宣传图的全部内容具有发布权利，不出现真实聊天、密钥或未经许可的内容
- [ ] 发布决策：解决上游 AGPL-3.0 与 App Store 分发条款的许可路线；必要时取得版权所有者的额外许可或专业法律意见
- [x] App 内提供许可证和来源说明
- [ ] App 内提供与商店二进制对应的公开源码链接
- [ ] 在 Review Notes 说明 Mocca 是独立、非官方衍生项目，以及保留 Kelivo 名称仅用于旧备份兼容

Apple 会要求开发者拥有 App 中全部内容的使用权。仓库开源许可证文件本身不能替代素材授权和 App Store 二进制分发权限。

## 三、App Store Connect 必填项（当前仓库无法确认）

### 1. 账号、协议和 App 记录

- [ ] 后台确认 Apple Developer Program 会员有效且账号合规审查已完成
- [ ] 后台确认 `Mocca` 名称可用，并完成必要的商标/名称冲突检查
- [x] 创建 App 记录并绑定正确 Bundle ID、SKU、主语言和 iOS 平台（Apple ID `6807043522`）
- [ ] 选择 Primary Category；当前工程声明为 Productivity，但以后台最终选择为准
- [ ] 回答 Content Rights
- [ ] 设置 Copyright
- [ ] 选择免费 App 价格、税务类别和可用地区
- [ ] 选择“审核通过后由开发者手动发布”，以便同步公开源码

### 2. 产品页元数据

- [ ] App 名称（最多 30 字符）
- [ ] Subtitle（最多 30 字符）
- [ ] Description（必填，最多 4000 字符）
- [ ] Keywords（必填，最多 100 bytes）
- [ ] Support URL（必填）
- [ ] Privacy Policy URL（iOS 必填）
- [ ] Copyright（必填）
- [ ] iPhone 截图：按 App Store Connect 当前要求上传所需设备尺寸，画面必须来自最终版本
- [ ] 可选：Promotional Text、Marketing URL、App Preview

### 3. App Privacy、年龄与合规问卷

- [ ] 完成 App Privacy 问卷，并覆盖应用自身及集成/调用的第三方数据实践
- [ ] 设置年龄分级；`Unrated` App 不能发布
- [ ] 对 AI 生成内容、网页访问、用户自定义服务商及可能出现的成人/暴力内容如实回答年龄分级问题
- [ ] 回答加密出口合规问题；确认仅使用系统/标准加密是否可豁免，再决定是否添加 `ITSAppUsesNonExemptEncryption`
- [ ] 完成 Digital Services Act (DSA) trader / non-trader 状态；若作为 trader 在欧盟分发，提交并验证公开联系信息
- [ ] 若在中国大陆上架，确认是否需要 ICP 备案号及其他许可，并保证备案主体、App 名称和后台元数据一致
- [ ] 中国开发者后台确认国务院第 810 号令要求的税务合规信息
- [ ] 回答 Regulated Medical Device 状态；当前 Mocca 不提供 HealthKit 功能，也不应宣称诊断或医疗用途

### 4. App Review 信息

- [ ] 填写审核联系人姓名、邮箱和国际格式电话号码
- [ ] App 不要求 Mocca 自有账号时，在 Review Notes 明确“无需登录；用户自行配置第三方 API Key”
- [ ] 提供一条审核员能够实际测试的路径；不能要求审核员自备付费第三方 API Key 才能进入核心界面
- [ ] Review Notes 说明：
  - 模型与 API Key 由用户自行配置
  - 后台生成 / Live Activity 的入口和测试方式
  - 照片、相机、位置、日历和提醒事项的按需权限触发方式
  - 三个赞助档位、共同 `💧`、对应永久装扮、重复购买和恢复方式
  - Mocca 与 Kelivo 的非官方来源和兼容关系
- [x] 本地静态确认使用文档、隐私政策和许可证页面无占位文字或开发开关
- [ ] 最终构建中所有审核入口、按钮、外部链接和商品均可用

## 四、当前不适用或条件触发的要求

- Mocca 当前没有自建账号注册/登录，因此“App 内删除账号”要求暂不适用；未来增加账号系统时必须同时提供删除入口。
- Mocca 当前不使用第三方社交登录，因此 Sign in with Apple 要求暂不适用。
- 当前源码未发现广告 SDK、行为分析 SDK或 ATT 跟踪逻辑；仍要以最终 Archive Privacy Report 为准。
- 当前语音功能是音频播放/第三方 TTS，没有发现麦克风采集，因此目前不需要 `NSMicrophoneUsageDescription`；未来加入录音/语音输入时必须先补用途说明。
- 当前源码提供完整、按需授权的 Apple Reminders 工具，并已声明 `NSRemindersFullAccessUsageDescription`；最终真机与 Sandbox 验收需覆盖查看、创建、更新、完成、重新打开和删除。
- 当前首发版本不包含 HealthKit 能力，因此无需 HealthKit 读取或写入用途说明。
- Marketing URL、App Preview 和自定 EULA 通常不是首次 iOS 版本硬性必填；Support URL、Privacy Policy URL、截图和产品描述是必填。

## 五、最终构建与提交门槛

- [ ] 冻结首发功能与源码提交，确认没有隔壁实验、诊断开关或未接受候选混入
- [ ] 统一最终 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`
- [ ] 用 Xcode 26 或更高版本、iOS 26 SDK 或更高版本制作 Release Archive
- [ ] Archive Validate App 通过，无签名、entitlement、隐私清单、图标或扩展错误
- [ ] 审阅 Archive Privacy Report
- [ ] 在最新正式 iOS 真机上完成冷启动、长聊天、备份恢复、权限拒绝/允许、后台生成和赞助 Sandbox 验收
- [ ] TestFlight 内部测试通过；如进行外部测试，完成 Beta App Review 所需资料
- [ ] 上传最终 Build，并确认主 App 与扩展版本、签名、Bundle ID 正确
- [ ] App Store Connect 选择该 Build，补齐全部必填字段
- [ ] 将首个 App 版本与三个 Consumable IAP 一起加入审核提交
- [ ] 选择手动发布并提交审核

## 六、推荐完成顺序

1. 用最终 Archive Privacy Report 校准 Privacy Manifest 和 App Privacy 回答。
2. 完成 App 内隐私、支持、许可证和源码入口。
3. 上线最小公开隐私政策页与支持页。
4. 完成赞助 StoreKit Sandbox 购买与恢复验收。
5. 完成素材、商标和 AGPL/App Store 分发权限审计。
6. 在 App Store Connect 补齐账号协议、App 记录、IAP、元数据、截图、隐私、年龄和地区合规。
7. 冻结源码，制作最终 Release Archive，完成真机/TestFlight 验收。
8. App 与三个 IAP 一起提交，审核通过后先公开对应源码 Tag/Release，再手动发布 App。

## 七、Apple 官方依据

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Submitting to the App Store](https://developer.apple.com/app-store/submitting/)
- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Required App Store Connect properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Required Reason API declarations](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Protecting HealthKit user privacy](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)
- [Submit an In-App Purchase](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)
- [In-App Purchase metadata](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/)
- [Age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)
- [EU Digital Services Act trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/)
- [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [China mainland availability information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)
