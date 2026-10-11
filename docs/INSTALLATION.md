# Install the GitHub IPA / 安装 GitHub IPA

The release contains an **unsigned** iPhone IPA. It requires your own Apple signing identity and a compatible signing workflow; downloading it does not install it automatically. The main app and Live Activity extension both need valid signing. An App Store release uses a separate Apple-reviewed distribution build.

Release 内提供的是**未签名** iPhone IPA，需要使用自己的 Apple 签名和兼容的重签工具，下载后不能直接点开安装。主应用和实时活动扩展都需要有效签名。App Store 版本使用另外签名、经 Apple 审核的分发包。

- Requires iOS 17 or later. / 需要 iOS 17 或更高版本。
- Verify the download against `SHA256SUMS.txt`. / 可用校验文件核对下载是否完整。
- The package uses the source repository’s placeholder bundle identifiers and disables sponsorship. / 使用源码仓库的占位应用标识，默认关闭赞助。
- No model account, API key, service credit, certificate or provisioning profile is included. / 不附带模型账户、API Key、服务额度、签名证书或描述文件。
- Back up existing chats in Mocca before replacing an installation; a different app identity may use a separate data container. / 替换已有安装前，请先在 Mocca 中备份聊天；不同应用标识可能使用独立的数据空间。

This package has been compiled and inspected locally. Third-party re-signing and installation have not been verified as part of this release. For your own build, follow [build configuration](BUILD_CONFIGURATION.md).

此包完成本地编译与内容核对；本次未验证第三方重签装机。自行构建请参考[构建配置](BUILD_CONFIGURATION.md)。
