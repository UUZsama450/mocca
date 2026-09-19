# 5027：快速反向时侧栏渐隐层的写入冲突

整理与修复：Codex。基于 5026 `3491e0f2d48cd90da5610dee5720634c50319001`，包含 5025 的交接修复和 5026 的聊天查找缓存。独立候选为 `work/candidates/mocca-drawer-fade-ownership-5027-a`，分支 `codex/drawer-fade-ownership-5027`。

## 问题与证据

用户报告快速开合、反向侧栏时，标题、头像、图标的渐隐偶尔闪一下。旧实现用 `.opacity(0.999)` 标记 SwiftUI 的内容合成层，再查找 `_UIInheritedView` 对应的 CALayer，直接写入随侧栏进度变化的透明度和位移，并排队补写一次。

这使同一图层出现两个写入方：Mocca 希望透明度是 `0.35 + 0.65 * progress`，SwiftUI 提交内容更新时仍按自己的声明恢复到 `0.999`。

隔离验证提取了 5026 的真实实现，在 iOS 26.2 模拟器运行实际 SwiftUI/UIKit 视图，记录 CALayer KVO 与调用栈。最终带深列表滚动的内容更新场景，旧版捕获到 9 次框架写入错误的 `0.999`，其中一次在下一帧采样仍存在。调用链包含 `SwiftUICore DisplayList.ViewUpdater.Platform.updateState → UIView.setAlpha → UIView._backing_setAlpha → CALayer.setOpacity`。

因此已经取得该写入冲突的运行时证据；它与用户描述吻合，但这不是用户手机上那一次闪烁的同步抓取，不能据此宣布所有实机闪烁都已解决。

## 修改

- 删除旧图层查找、直接 CALayer 写入、异步补写队列与九处调用。
- 在原内容合成组上使用 SwiftUI 的 `visualEffect`，由 SwiftUI 统一管理透明度与横向位移。仍保留原来的 0.35→1 渐隐和 24 pt 视差。
- 继续使用已有的跟手/弹簧进度。中途转为上下滚动、列表模型已归到终点而主面板弹簧尚未结束时，视觉修饰器单独跟随剩余进度，避免渐隐突然跳到全亮。
- 保留侧栏背景、列表、手势、弹簧、键盘、聊天内容和存储实现；没有新增宿主、常驻动画驱动或产品逐帧日志。版本号改为 5027。

公开 API 参考：[Apple visualEffect 文档](https://developer.apple.com/documentation/swiftui/view/visualeffect(_:))。故障判定依据是上面的实际写入记录，不是仅凭 API 文档推断。

## 验证方式

`CandidateTests/check_drawer_fade_runtime.py` 提取旧版和当前源码，在仅有合成数据的专用模拟器中编译、运行原生隔离程序。每个版本分别检查稳定内容、周期性内容更新；每次持续 9 秒，以 0.7 秒为周期快速来回。包含 1,000 条合成行，以及中间 3 秒的上下滚动接管阶段。

透明度、横向位置、原生滚动视图身份、深处滚动位置和列表内容 body 次数分别记录。候选测试中的旧定位器仅作观察使用，不会写入图层；它没有进入产品源码。

`CandidateTests/check_drawer_fade_contracts.py` 核对源码范围，并复用之前的交接和生命周期测试。仅将测试里已删除的命令式透明度观察点换成从当前源码提取的视觉进度表达式，原有取消、终点、刷新保护断言不变。

完整 App 以 Debug iOS Simulator 构建，随后用独立 UI 测试工程驱动这个实际 App。测试数据由现有 `-previewNavigationStress` 等参数生成。

## 结果

2026-09-14 全部通过：

| 隔离场景 | 框架写入次数 | 写入错误值 | 下一帧透明度错误 | 横向位置错误 | 内容 body 次数 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 5026 稳定内容 | 3 | 3 | 1 | 0 | 1 |
| 5026 内容更新 | 9 | 9 | 1 | 0 | 7 |
| 5027 稳定内容 | 525 | 0 | 0 | 0 | 1 |
| 5027 内容更新 | 526 | 0 | 0 | 0 | 7 |

这里“框架写入”只统计 SwiftUI 写入；旧版另外由 Mocca 自己逐帧写入并补写，不能把表内次数误读为总写入量或性能差异。候选版则由框架执行需要的进度更新。

四组测试均保持同一个原生滚动视图，在 1,800 和 2,900 pt 深处没有观测到滚动位置偏离。内容 body 次数没有增加，但这不是整个 App CPU、GPU 或帧率的测量。

- 42 个交接场景、26 个原驱动场景、146 个生命周期场景：214/214 通过；另有 8 项分离收尾进度检查通过。
- 产品范围校验通过；AppModel、消息渲染、聊天存储、输入框和原动画/手势/场景逻辑保持基线实现。
- 完整 Debug iOS Simulator 构建通过，构建耗时约 244 秒；App 版本回读为 5027，Bundle ID 为 `com.uuzsama450.mocca.migration`。
- 实际 App 的 7 项 UI 回归通过，0 失败、0 跳过：反复开合后的搜索与选聊天、历史阅读位置与键盘、空聊天手势、聊天切换与侧栏、原键盘开合、中途/重复拖动、稳定端点退后台恢复。
- 已查看搜索返回后的截图，侧栏标题、图标、选中行、底部入口正常显示。

可在此候选根目录使用 `/usr/bin/python3 CandidateTests/check_drawer_fade_contracts.py` 和 `/usr/bin/python3 CandidateTests/check_drawer_fade_runtime.py` 重跑对应检查。运行时脚本按本机 iOS 26.2、x86_64 模拟器环境配置；UI 工程与准确命令保存在证据目录的 `DrawerFadeQA.xcodeproj` 和 `ui-command.json`。

本次测试对应的 `Mocca/RootView.swift` SHA-256：`b7a753f3a5c86867401489997766049a49b4fb150d4831a51488d5c0183f4d2e`。

## 证据位置与验收边界

本候选的 `work/verification/drawer-fade-ownership/` 保存构建日志、运行时 JSON、调用栈、场景测试结果、UI 测试 xcresult、构建命令与 App 版本回读。测试脚本和本文随候选提交，生成物留在忽略的 work 目录。

本轮没有连接、安装或操作用户手机，也没有提交 TestFlight。模拟器编译、受控测试与 body 次数不能证明 iPhone 17 Pro 的帧时间、功耗或视觉手感。实机仍需确认快速反向、中途上下滚动、深列表位置、渐隐外观与长聊天收尾；手机验收前将本项标记为“代码修复及隔离验证通过，实机待验收”。
