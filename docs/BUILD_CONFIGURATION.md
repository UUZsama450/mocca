# Build configuration / 构建配置

[English README](../README.md) · [中文说明](../README.zh-CN.md)

## Defaults / 默认值

Both Debug and Release inherit [Shared.xcconfig](../Configuration/Shared.xcconfig).
Debug 与 Release 使用相同的公开默认配置，Release 不会自动开启赞助。

| Setting | Default | Purpose / 用途 |
| --- | --- | --- |
| `MOCCA_BUNDLE_IDENTIFIER` | `org.example.mocca` | Main app identity / 主应用标识 |
| `MOCCA_DEVELOPMENT_TEAM` | empty / 空 | Your Apple development team / 自己的开发团队 |
| `MOCCA_ENABLE_SPONSORSHIP` | `NO` | Explicit `YES` enables sponsorship / 只有明确设为 `YES` 才开启赞助 |

The extension uses `$(MOCCA_BUNDLE_IDENTIFIER).GenerationActivityExtension`. Background task registration and the permitted identifiers in Info.plist use the main app identity plus `.background-generation`. Change the shared app setting, rather than overriding `PRODUCT_BUNDLE_IDENTIFIER` globally: a global override would give the app and extension the same identifier.

扩展标识、后台任务注册与 Info.plist 许可名单自动关联主应用标识。请修改 `MOCCA_BUNDLE_IDENTIFIER`，不要全局覆盖 `PRODUCT_BUNDLE_IDENTIFIER`，否则主应用和扩展会得到相同标识。

## Local development / 本地开发

From the repository root / 在仓库根目录执行：

```sh
cp Configuration/Local.xcconfig.example Configuration/Local.xcconfig
```

Edit the copy to use your own unique identifier and team. `Local.xcconfig` is ignored by Git and overrides the public defaults. Do not store passwords or signing private keys in build settings. Simulator builds do not need this file; device signing requires your own valid signing setup.

修改复制出的文件，填写自己的唯一应用标识和开发团队。Git 会忽略 `Local.xcconfig`，其中的值会覆盖公开默认值。构建配置里不要存放密码或签名私钥。模拟器构建无需此文件；真机构建需要自己的有效签名配置。

Unsigned compile check / 不签名的编译检查：

```sh
xcodebuild -project Mocca.xcodeproj -scheme Mocca \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

This produces a compile-check artifact, not an installable or distributable IPA.
这是编译检查产物，不能直接当作可安装、可分发的 IPA。

## Sponsorship / 赞助

The setting is expanded into `MoccaSponsorshipEnabled` in the built Info.plist. Missing, invalid, or unresolved values keep sponsorship disabled. The settings row, settings search result, destination, and sponsorship help section share the gate. `SponsorStore` also rejects preparation, retry, transaction listening, purchase, and restore calls while disabled.

开关写入构建产物的 Info.plist。缺失、无效或未展开的值均视为关闭；设置行、搜索结果、目标页和使用文档中的赞助说明一起隐藏。StoreKit 相关公开操作也会直接返回。赞助源码、备份字段、历史装扮和聊天彩蛋实现保留，关闭入口不会删除已有数据。

For local purchase testing / 本地购买测试：

1. Set `MOCCA_ENABLE_SPONSORSHIP = YES` in `Configuration/Local.xcconfig` and rebuild. / 在本机配置中开启并重新构建。
2. In Xcode, choose **Product > Scheme > Edit Scheme > Run > Options > StoreKit Configuration**, then select `Mocca/Sponsor.storekit`. / 在运行方案中明确选择该 StoreKit 测试文件。
3. Run from Xcode to test simulated products and transactions. These are not real payments or proof that production purchases work. / 从 Xcode 运行以测试模拟商品和交易；这不是实际付款，也不证明正式商店购买已可用。

The shared scheme does not automatically select a StoreKit simulation file. For a store release, explicitly enable sponsorship, use the correct app identity/team, and verify real product configuration separately. Product IDs in `SponsorStore.swift` and `Sponsor.storekit` belong to the original app; another publisher must configure their own products and update both as appropriate. Enabling this flag alone does not provide access to those products.

共享方案不自动选择模拟交易文件。商店发布需明确开启赞助、使用正确身份与团队，并单独验证实际商品配置。另一位发布者需要配置自己的商品并相应修改商品标识；仅开启开关不能获得原应用的商品。

## Compatibility / 兼容性

Keychain service names, notification names, and legacy backup identifiers remain stable. They are data-compatibility keys, not signing credentials. Changing them as part of a rename could make existing data inaccessible.

Keychain 服务名、通知名与旧备份标识继续保留，它们用于数据兼容，并非签名凭据。本次只使构建身份与后台任务标识可配置，不批量改写这些存储名称。

These portable defaults apply to the source snapshot, currently 1.0 (5135). Building it does not replace an installed app or alter an App Store release. A store archive needs its own source and identity verification.

这些可移植默认值用于当前 1.0（5135）源码快照。构建源码不会替换已安装应用或改变 App Store 发布；正式归档需要单独核对源码与应用身份。

Configuration file semantics: [Apple Xcode documentation](https://developer.apple.com/documentation/xcode/adding-a-build-configuration-file-to-your-project).

## Local verification / 本地验证

On macOS with Xcode installed, run `python3 CandidateTests/check_sponsorship_build_gate.py`. It compiles the actual configuration and sponsor store into isolated host bundles, checks five configuration values, and calls disabled commerce entry points. Enabled commerce is not invoked; successful payments and iOS UI still require separate testing.

安装 Xcode 的 macOS 上可运行上述命令：测试会编译实际源码，核对五种配置值和关闭状态下的操作入口。测试不会执行已开启的交易，不代替实际购买或 iOS 界面验收。
