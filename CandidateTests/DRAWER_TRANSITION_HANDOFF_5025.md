# 5025：独立审查前两项的复现与修正

整理与实现：Codex，2026-09-13。

## 来源与范围

- 基线是手机测试包 5024 的源码提交 `61f64602f8fa7675041fb7810c718195b442b780`。
- 候选目录：`work/candidates/mocca-drawer-transition-handoff-5025-a`；分支：`codex/drawer-transition-handoff-5025`。
- 用户转回的 `Mocca-5015-5024-independent-review-and-evidence.zip` 包含报告、反例构建器和测试结果。归档 SHA-256：`90fe7fb234b4e42d586a0d7c12a38cfd37cde5cfc0ca44c6f66ea48bc78f9799`。
- 审查反例引用的 5024 `RootView.swift` SHA-256：`1154d0973304c8025b9e928a8bcee0a408b9c91625e732a2a38e0b11d353bedd`，已和源码核对。
- 将已检查过的反例构建器的两个 Linux 路径改成本机路径后，重新生成的 Swift 文件与归档内版本逐字节相同；编译执行的五组结果与审查者结果一致。
- 产品变更仅为 `RootView.swift` 中的两处所有权处理，以及主程序/扩展 Debug、Release 构建号统一改为 5025。Bundle ID 保持 `com.uuzsama450.mocca.migration`。

## 1. 动画接替期间连续保留刷新保护

5024 中按钮反向打开、外部语义关闭接管、再次 settle 三条路径，会先以默认参数调用 `cancelDrawerSettleWork()`。若此时仅动画持有刷新保护，取消会同步放行等待中的文字刷新，然后新动画才重新取得保护。5023 已修正的手指→动画路径不能覆盖这个组合。

这三条路径同步、无条件启动接替动画，因此改为 `cancelDrawerSettleWork(releasingViewportFreeze: false)`，把原有保护交给接替动画完成时释放。真正结束且没有接替者的取消仍保留默认释放行为；场景中断仍在显示位置归并后释放。没有增加计时器或修改冻结键。

组合测试执行实际 Root 方法、实际 Spring 驱动与实际 `DrawerViewportRefreshFreeze`，覆盖四种转交方式、三个中间位置、聊天滚动视图已注册/未注册：24 个场景。5024 每例都提前刷新、切换 generation；第一步修正后均保持连续保护，并仅在最终端点刷新一次。还检查原位置接续、弹簧中间采样、旧驱动/9 ms 任务失效、语义观察者不重启动画、最终滚动锁与 streaming 状态。

## 2. 稳定打开时也撤销待执行的自动关闭

5024 的中断方法先判断是否存在手势或动画。抽屉稳定打开、仅有 `pendingDrawerCloseConversationID` 时会提前返回；随后相同聊天的 ready 回调可以在中断之后启动新的关闭动画。

将待关闭 ID 的清理移到提前返回之前。策略是取消这一次 UI 自动关闭意图：保留选择的聊天和加载工作，保持稳定抽屉原位置。重新进入前台本身不重新发起关闭。用户再次点同一聊天会走既有直接关闭路径；另选聊天后，其新的 ready 回调仍能正常关闭。

四个 pending-only 场景覆盖有/无注册滚动视图、单次/重复中断。5024 都残留意图并被晚到 ready 启动关闭；第二步修正后均不启动驱动、不改变稳定端点，也不触发触感。另有两个场景检查中断后的新选择、无关 ready 和重复 ready，确认新请求仍能完成。

## 验证

`CandidateTests/check_drawer_transition_handoff.py` 提取当前实际方法，不移除 freeze hooks。它还重新运行已有 26 个关闭/反向/滚动锁场景，并让它们与真实冻结逻辑共同执行。

| 验证阶段 | 新增 42 个组合场景中的失败 | 既有 26 个场景 |
| --- | --- | --- |
| 5024 | 24 个动画转交 + 4 个 pending-only，均与预期反例对应 | 通过 |
| 仅修第 1 项 | 仅余 4 个 pending-only | 通过 |
| 两项修正完成 | 0 | 通过 |

还通过原有 146 个场景中断测试与 2 个 drag→settle 连续刷新测试，候选合计 216 个受控场景通过。旧 146 个测试的 pending ID 都设置在活动手势/动画场景内，两个稳定端点场景没有 pending，因而遗漏了本次组合；本次补测保留这个区别。

完整 Debug iOS Simulator 编译通过（289.30 秒），产物内主程序和 `GenerationActivityExtension` 的构建号均核对为 5025。专用 iPhone 17 Pro / iOS 26.2 模拟器完成 8/8 项界面回归，0 失败、0 跳过（342.61 秒）：

- 历史消息阅读位置在键盘开关前后保持。
- 反复开关键盘及底部回弹。
- 既有非原生面板对照路径的键盘及重新进入聊天。
- 空聊天、手势开关抽屉和遮罩点击。
- 长聊天 A→B→A、相同聊天再次点击及正文滚动。
- 原生面板的键盘及重新进入聊天。
- 小幅取消与连续三轮手指开关抽屉。
- 稳定打开/关闭时进入后台再返回，并继续使用键盘。

另外查看了后台返回后稳定打开的抽屉截图，以及原生键盘打开时完整显示在输入框上方的尾部消息截图。图片验证是端点显示检查，不是动画帧耗时测量。专用模拟器已在完成后关闭，未操作用户手机。

重跑命令（仓库目录内，macOS/Xcode）：

```sh
/usr/bin/python3 CandidateTests/check_drawer_transition_handoff.py
/usr/bin/python3 CandidateTests/check_drawer_scene_interruption.py
/usr/bin/python3 CandidateTests/check_drag_settle_refresh_handoff.py --expect-continuous
```

原审查复现材料保存在主检出的 `work/reviews/gpt6-pro-5024-evidence-20260913/`；本候选的命令、源码哈希、逐步 diff、生成的 Swift 与完整结果在 `work/verification/drawer-transition-handoff/`。最终完整编译及模拟器结果在同目录的 `build-result.json`、`ui-result.json` 与 `REGRESSION.xcresult`。

## 验证边界与待验收

受控测试使用真实算法和回调，显示时钟、UIKit 接收对象、Observation 通知与状态存储是测试替身。模拟器交互结果应单列，不能从受控测试推断真实 scenePhase 投递、绘制耗时或 FPS。

手机尚未安装 5025。实机需重点观察连续反向打开/关闭是否有额外闪动、选择聊天过程中切出再返回是否仍可正常选聊，以及原有键盘、阅读位置和拖动动画。没有将这两处调用顺序缺口直接认定为所有侧栏卡顿的原因。

5019 冻结键覆盖与收益、旧 fade 层兼容性、键盘取消的动画实例归属、分支保存失败传播及聊天入口同步开销仍维持独立审查结论，本候选未扩大修改范围。
