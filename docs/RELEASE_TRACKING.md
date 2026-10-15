# 版本与发布记录 / Version and release tracking

更新时间 / Updated: 2026-10-15

| Channel | Version | Distribution |
| --- | --- | --- |
| GitHub main 源码 / source | **1.0.4 (5215)** | 设置说明气泡修复 / settings info-popover fix |
| Xcode 工程默认值 / project defaults | **1.0.4 (5215)** | 可配置签名 / configurable signing |
| GitHub 下载包 / preview | [**1.0.4 (5215)**](https://github.com/UUZsama450/mocca/releases/tag/v1.0.4) | 沿用原发布页，需要自行签名 / same release page, own signing required |
| App Store | **1.0.4 (5215)** | 单独送审，通过后手动发布 / separate review, manual release after approval |

两种发行包使用同一份已采用的功能源码。公开工程保留可配置签名、默认关闭赞助和整理过的素材，因此 GitHub IPA 与 App Store 签名包不相同。

原 `v1.0.4` 标签仍指向历史 5206 源码。5215 的确切源码提交、源码归档及校验值在发布说明和 `BUILD-INFO.json` 中明确标注；请使用 5215 对应源码链接，不要把页面底部自动生成的旧标签源码归档误认为 5215。旧附件在替换前已本地备份并校验。5210 未作为单独 Release 发布。

The existing release page carries the refreshed 5215 download. The historical `v1.0.4` Git tag is preserved; the release notes and build manifest identify the exact 5215 source commit and source archive. GitHub's automatic tag archives retain the original tag snapshot. The App Store update is reviewed independently; GitHub availability does not mean the store update is live.

See [release verification](RELEASE_1.0.4_5215.md).
