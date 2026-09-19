# 5017：省掉聊天滚动开关的同值写入

基线：`8fd39125598c32a5b01d1d491c2030d84fa3a89b`（独立保留的 5016）。
候选：`work/candidates/mocca-drawer-scroll-top-idempotence-5017-a`，分支
`codex/drawer-scroll-top-idempotence-5017`。本候选包含 5016 的关闭驱动器修复。

## 改动

`ChatScrollViewProbeUIView.scheduleResolution()` 已找到滚动容器时仍会调用
`DrawerNativeScrollGate.register()`，后者会重新应用开关状态。此前
`isScrollEnabled` 已经按实际值判断是否赋值，`scrollsToTop` 却每次都写。

现在为 `scrollsToTop` 使用同样的值检查，仅在当前值不符合 gate 状态时写入。
App 逻辑净增 2 行；工程的四处版本号换成 5017。注册、注销、开关状态切换和
纠正外部改值的路径保留；没有缓存一份容易失效的属性值。

这是源码可确认的重复操作清理。未测得它在当前手机上的调用次数、耗时或
帧率收益，不能据此判断它是有文本窗口卡顿的主要原因。

## 验证

```sh
/usr/bin/python3 -B CandidateTests/check_drawer_scroll_top_idempotence.py
/usr/bin/python3 -B CandidateTests/check_drawer_close_driver_reuse.py
```

- 新旧版 gate 共 8 组测试，80 项状态检查全部通过，覆盖 presented/gesture
  四种组合、延后注册、两个接收器、注销、状态切换、复位和外部属性改值。
- 在每组 100 次重复注册和重复 reset 的人工测试负载下，`scrollsToTop`
  同值 setter 调用均从 100 次降到 0 次。100 次是测试输入，不是真机观测值。
- 外部改错属性后重新注册，新旧版都执行一次必要纠正，最终状态相同。
- 关闭驱动器套件在 5017 上 26/26 通过；5015 对照只出现原定的 6 个正常
  关闭重启失败。测试脚本更新为报告当前版本，并允许由独立 gate 套件检查
  的源码区域；其余 RootView 内容仍与原基线核对。
- Release / generic iOS / arm64 / 禁用签名的 clean build：PASS，退出码 0。
  App 与扩展产物均为 1.0 / 5017、arm64。提示与 5016 相同：
  `UITextItemInteraction` 弃用，以及无 AppIntents 依赖时跳过元数据提取。

测试使用提取的生产声明和记录属性写入的接收器替身，不执行真实 UIKit setter
的内部工作。关闭套件执行真实 Spring 公式及异步取消逻辑，但不渲染 SwiftUI
视图、不识别真实触摸。因此两套测试都不是手机体验验收。

新证据目录：`work/verification/drawer-scroll-top-idempotence/`，含 gate 对照、
源文件范围校验、构建命令/日志/结果。关闭回归证据位于当前候选的
`work/verification/drawer-close-driver-reuse/`。

## 注册交接的后续调查

同一次源码检查还确认了一条有条件的所有权风险：如果两个 probe 先后注册
同一个 UIScrollView，旧 probe 再拆卸，当前 `NSHashTable` 不记录注册者，旧
probe 的 unregister 会移除共享接收器并恢复开关。新 probe 的重复注册可能
随后把它修复。已用当前 gate 的提取代码复现这一受控调用顺序，并确认 5017
的后续注册仍能修复开关，证据为 `owner-order-probe.json`。当前手机是否发生
这一顺序、是否对应卡顿，尚无证据。

同一交接还涉及共享 `WeakChatScrollViewBox`、delegate bridge 和延后的 resolve
回调。后续若修复，应把注册、注销和过期回调的责任一起核对，先用生命周期
对照验证旧 owner 无法清掉新 owner 的登记。不能单纯删掉重复 register。
5017 保留这些登记调用；当前值被错误恢复后仍会触发纠正。

## 真机验收和回退

本次未安装、未启动模拟器、未操作手机数据。用户回家后在 iPhone 17 Pro 的
空聊天和长文本聊天中检查侧边栏开合、取消/反向、聊天纵向滚动、点状态栏回
顶部、切换会话、文字选择和流式输出。5016 的收尾连续性也仍需真机确认。

若只需撤回本次同值写入优化，可回到独立保留的 5016。手指持续拖动、文字
排版/绘制和新旧 probe 所有权仍分别保留为后续调查项。
