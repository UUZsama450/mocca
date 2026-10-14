# 版本与发布记录 / Version and release tracking

更新时间 / Updated: 2026-10-15

| 项目 / Channel | 对应版本 / Identity | 状态 / Meaning |
| --- | --- | --- |
| GitHub main 源码 / source | 手机基线 / phone baseline **1.0.4 (5210)** | 已采用改动 / adopted source progress |
| Xcode 工程默认值 / project defaults | **1.0.4 (5210)** | 本次发布构建 / release build |
| GitHub 下载包 / downloadable preview | [**1.0.4 (5210)**](https://github.com/UUZsama450/mocca/releases/tag/v1.0.4-build.5210) | 新预览包，需自行签名；旧 5206 保留 / new preview requiring own signing; 5206 retained |
| App Store | [商店页面 / store listing](https://apps.apple.com/us/app/mocca-ai-chat/id6807043522) | 1.0.4 (5210) 单独送审，审核通过后手动发布 / separate 5210 submission and manual release |

本次在源码同步之后，另行发布 **1.0.4（5210）** 的 GitHub 预览包，并提交对应 App Store 构建。两者使用同一份已采用功能源码，但公开工程保留可配置签名、默认关闭赞助和经过整理的素材；GitHub IPA 需要自行签名，不能视作 App Store 签名包。

旧标签 `v1.0.4` 和 5206 附件保持不变，新构建使用 `v1.0.4-build.5210`。公开源码提交、产品输入校验值和两种发行形式记录在[本次发布验证](RELEASE_1.0.4_5210.md)与随包 `BUILD-INFO.json` 中。

This release follows the source-only sync with a separate **1.0.4 (5210)** preview and corresponding App Store submission. Both share the adopted feature source; portable signing, disabled sponsorship and reviewed assets distinguish the GitHub package. The original `v1.0.4` / 5206 download remains unchanged. See the release verification and packaged build manifest for provenance. Store approval and publication are separate from GitHub availability.
