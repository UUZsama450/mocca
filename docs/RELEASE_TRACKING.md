# 版本与发布记录 / Version and release tracking

更新时间 / Updated: 2026-10-15

| 项目 / Channel | 对应版本 / Identity | 状态 / Meaning |
| --- | --- | --- |
| GitHub main 源码 / source | 手机基线 / phone baseline **1.0.4 (5210)** | 已采用改动的未发布源码进度 / adopted source progress, unreleased |
| Xcode 工程默认值 / project defaults | **1.0.4 (5206)** | 本次源码同步保留元数据 / metadata retained during source sync |
| GitHub 下载包 / downloadable preview | [**1.0.4 (5206)**](https://github.com/UUZsama450/mocca/releases/tag/v1.0.4) | 原有预览包，需自行签名 / existing preview requiring own signing |
| App Store | [商店页面 / store listing](https://apps.apple.com/us/app/mocca-ai-chat/id6807043522) | 单独送审与发布；此次源码同步不变更商店 / separate review and release, unchanged by this sync |

**同步源码不等于发布新版本。** 5210 表示本次采用的手机源码基线；公开工程保留可配置签名、默认关闭赞助及经过整理的素材，两者不是同一个签名安装包。[源码差异与验证](SNAPSHOT_5210.md)记录对应关系。

下一次正式打包时：确认同一份源码提交，选择版本号和递增构建号，将两者及提交 SHA 写入构建记录，再分别更新 GitHub 发布说明和 App Store 提交。已有标签、安装包及校验值保留，避免旧下载链接悄悄变成另一份包。

如果继续为同一版本提供新的 GitHub 预览包，可在单独发布时用构建号区分标签（例如 v1.0.4-build.5210）；这只是命名示例，本次未创建该标签或发布包。App Store 是否沿用 1.0.4 取决于该版本是否已经正式发布，提交前检查实际状态。

**Source synchronization is not a release.** Phone build 5210 identifies the adopted source baseline. Portable signing, disabled sponsorship and reviewed assets remain separate from the device package. For the next distribution, record the exact source commit, marketing version and incremented build number together. Keep existing tags and downloads immutable; publish new assets separately when requested. Check App Store state before choosing whether to reuse an unreleased marketing version.
