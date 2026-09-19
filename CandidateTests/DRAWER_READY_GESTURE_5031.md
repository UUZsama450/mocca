# 5031：待就绪自动关闭与横向手势所有权

`check_drawer_ready_gesture_ownership.py` 用 5030 的 `c79ef3ab396fc121245204243f2fb1ccef200100` 作反例，与当前候选源码运行同一套检查。

## 执行的真实代码

- 直接提取 `drawerDragGesture` 完整 `onChanged` / `onEnded` 闭包体，只把闭包签名改成接受受控拖动值的方法签名；所有 guard、识别阈值、手指更新、结束选择与 defer 原样执行，没有手动模拟清除 pending。
- 复用 `check_drawer_transition_handoff.harness` 的实际 Root 请求、ready、取消、收尾、进度观察和中断方法，实际 Spring 驱动器、9 ms Task、取消/sequence 条件、手指进度存储和 viewport freeze。
- 从驱动器只读保存实际旧 Root progress/completion 闭包，在取消后及替换动画后再次调用，验证旧 sequence 不能写入新状态。
- 检查原生聊天滚动 gate、侧栏 coordinator 的手势所有权和状态栏回顶 gate。侧栏实际 UIKit 滚动禁用还依赖 SwiftUI 的 `.scrollDisabled`；本宿主不把 coordinator 标记误当成已经送达原生侧栏的渲染状态。

## 28 个场景，174 项断言

每种情况分别使用有、无注册聊天滚动宿主：

1. 自动关闭请求 → 真正的横向识别 → 持指移动 → 无关/相同/重复 ready → 继续移动 → 手势结束打开或关闭。
2. 低于识别阈值、尚未确定的斜向移动、纵向意图、正文选字、横向滚动内容、输入框选字、非活动 scene：没有获取横向所有权时保留 pending；触摸结束不误撤销，之后原 ready 仍正常关闭。
3. 正常 ready 先发生，在 9 ms 语义关闭之前、之后及完全收完三个阶段重新横向接管；继承采样位置、取消旧 Task/driver、拒绝旧 callbacks，最后正常打开。
4. 持指及尚未持指两个阶段进入后台，重复中断和晚到 ready 不启动动画；返回后新的选择可以关闭，无关与重复 ready 不消耗或重复执行新请求。

有效运行结果：

| 源码 | 场景 | 断言 | 失败场景 |
| --- | ---: | ---: | ---: |
| 5030 基线 | 28 | 174 | 4 个预期反例 |
| 当前 5031 候选 | 28 | 174 | 0 |

基线四个失败场景均是“pending → 横向持指 → ready”，分别组合有/无聊天宿主及最终打开/关闭。每个场景精确失败同样五项：识别未清 pending；held ready 启动 driver；手指与滚动 gate 所有权丢失；继续移动时仍存在竞争 driver；9 ms 后持指期间发生语义关闭。其余断言通过。候选同一顺序全部通过。

初版测试曾要求替身侧栏的 `isScrollEnabled` 在识别后立即为 false；这超出宿主实际执行的 SwiftUI 边界，现改为检查真实 coordinator 与聊天原生 gate，没有修改替身来伪造产品绘制结果。

## 证据与重跑

```sh
/usr/bin/python3 CandidateTests/check_drawer_ready_gesture_ownership.py
```

输出在 `work/verification/drawer-ready-gesture-5031/`：`result.json` 包含源文件/闭包/生成宿主 SHA-256、全部断言和真实 trace；`5030.swift`、`candidate.swift` 保存生成的实际执行代码；另有编译命令、编译日志与运行日志。重跑覆盖同名诊断文件。

这是 macOS 上的受控源码合同。手势数值和投递、命中测试 gate、scene 投递、Observation、UIKit 接收器与显示时钟是替身；没有构建完整 iOS App、启动模拟器或操作手机。通过不证明真实识别器时序、文字排版、逐帧动画或手机 FPS；它也没有比较同量普通正文与代码。
