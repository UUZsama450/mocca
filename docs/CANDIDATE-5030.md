# 5030：切换聊天的短暂淡入实验

用户希望试用约 0.1 秒的轻过渡，尽量保持现有性能，并明确要求考虑快速连续切换，完成后安装手机。

## 基线与范围

- 基线：5029，`ddbdea8d1b81c354a05f116030d099250bec5b04`。
- 独立分支：`codex/conversation-fade-5030`。
- 手机预检：iPhone 17 Pro 的测试包 `com.uuzsama450.mocca.migration` 为 1.0 (5029)，独立正式包 `com.uuzsama450.mocca` 为 1.0 (5024)。
- 产品变动只有 `RootView.swift` 的 24 行新增及主程序/扩展四处构建号 5030。
- 选字代码和先前讨论的表情栏可选改动保持原样。

## 行为

`ConversationSwitchFadeModifier` 位于非空聊天的 `ScrollViewReader` 外、现有会话滚动 identity 外。只有会话 ID 变化触发系统 keyframe animator，将内容透明度从 0.25 提升到 1，持续 0.10 秒。没有纯白覆盖层或额外空白等待。

快速切换会替换当前动画，并从当前已呈现的透明度继续走向 1，不重复降低到起点，也不排队执行旧完成回调。开启减弱动态效果时输出始终为 1。

初次显示、进入空聊天、空聊天发送第一条消息保持现有显示方式。只更新同一会话文本时不重播淡入。背景、标题、输入框、消息导航按钮和表情条在动画范围之外。

不增加 Task、定时器、显示链、固定等待、旧聊天快照、滚动写入或 readiness gate。动画逐帧闭包只修改现有内容代理的 opacity，未在里面构造或测量消息文本。

Apple API 依据：
[keyframeAnimator](https://developer.apple.com/documentation/swiftui/view/keyframeanimator(initialvalue:trigger:content:keyframes:))
说明新 trigger 会用当前插值替换进行中的动画，结束后保留最终值。

## 验证与证据

- `work/verification/conversation-fade-5030/scope-proof.json`：移除新增组件与唯一调用后，RootView 与 5029 完全一致；其他产品源文件未变。
- `CandidateTests/check_conversation_switch_fade.py`：提取原样动画组件，在独立 SwiftUI + UITextView 测试 App 中与无动画基线对比。仅为观测插入 opacity 记录，并将只读系统减弱动态效果环境键映射到可控制测试键。
- `CandidateTests/ConversationSwitchFadeUITests.swift`：完整 App 的长/短/空聊天、同会话返回、切换后键盘及收侧栏检查。XCTest 点按会等待空闲，不能作为 100 毫秒内连续触发的证据；该情形由独立运行时测试覆盖。
- 安装前需通过运行时测试、完整 App 界面检查、Release 编译、主程序/扩展签名、设备资格、版本与 dSYM 对应验证。最终结果见下方后续记录及 `work/verification/device-5030/`。
- 模拟器对比只证明所测构建/布局行为，不是 17 Pro 的 FPS 或视觉接受结论。

## 回退与手机验收

已核验的 5029 原包位于：
`../mocca-reaction-dismissal-regressions-5029-a/work/verification/device-5029/DerivedData/Build/Products/Release-iphoneos/Mocca.app`。
主程序 SHA-256：`35908007a845e13c45708c6849431b574499404740df4a3c0641396651cac5ce`。

手机待验收：普通聊天互切时过渡是否可见且舒服；连续快速切换是否无反复闪暗/残留透明；长/短/空聊天切换是否正确落位；切换后开合侧栏、键盘、选字及流式是否保持原体验。用户若不喜欢，保留 5029 作为这次单变量实验的回退点。

常规安装使用相同测试 Bundle 覆盖，不卸载、不清空、不复制聊天存档、不产生新聊天备份；没有请求或收集聊天逐字节保留证明。

## 运行时结果与测试更正

- 39 项既有会话进入/窗口生命周期检查通过。
- 原样组件的 SwiftUI 运行时对比通过：两组均为 15 次正文构造、15 次原生文本写入、14 次文本控件创建、28 次 updateUIView，所测终点滚动位置和内容高度一致。
- 捕获到实际中途接替：当前透明度 `0.8347968993`，下一次起点也是 `0.8347968993`，随后到达 1。连续快速请求、首次出现、文本更新、空聊天往返、减弱动态效果均通过对应断言。
- 初版测试在 App 首屏出现前排队所有动作，导致冷启动时动作合并；该结果无效。后来对照中的环境/会话同轮更新也出现滞后，不能把它归为产品零时长动画缺陷。测试现已先快照输入值、等宿主出现、逐阶段等待，并按真实渲染帧触发一次中途接替。产品最终保留原 24 行实现，没有加入为该测试异常尝试的额外动画分支。
- 运行时报告为 `work/verification/conversation-fade-5030/runtime-summary.json`，并保存了无效测试的原始输出用于追溯。性能结论仅限上述构造/写入/布局观测，不能换算为手机 FPS。
- 完整 Debug 模拟器构建成功，146 份产品输入哈希匹配。完整 App 两项 UI 测试通过：`testKeyboardAfterConversationSwitch` 与 `testLongShortEmptyAndSameConversation`。结果为 `ConversationFadeUITests.xcresult`，截图单独导出到 `ui-attachments/`。这些是终点与交互检查，不是逐帧白屏或手机帧率证明。
