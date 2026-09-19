# 5031：手指接管时撤销等待就绪的自动关闭

## 问题与最终行为

选中另一个聊天后，侧栏会等待目标内容就绪再自动关闭。5030 在用户已经开始横向拖动时，只取消正在运行的收尾动画，仍保留等待就绪的关闭请求。迟到的就绪回调可以重新启动关闭，并释放手势活动标记，而同一次触摸的后续移动仍可写入侧栏位置。

5031 在真正识别到侧栏横向手势、取得控制权的同一处撤销旧的待关闭请求。就绪先到时，沿用既有动画取消、序号失效和当前画面位置接管；手势先到时，旧就绪回调不再拥有关闭授权。松手后的开合仍由原有手势判定负责；下一次聊天或助手选择可以重新申请正常关闭。

## 基线与范围

- 基线：5030，`c79ef3ab396fc121245204243f2fb1ccef200100`。
- 候选分支：`codex/drawer-ready-gesture-5031`。
- 候选目录：`work/candidates/mocca-drawer-ready-gesture-5031-a`。
- 产品逻辑只增加一次 `pendingDrawerCloseConversationID = nil`，另有三行说明注释；app/extension 的 Debug/Release 构建号均为 5031。
- 位置在横向距离、方向、选字及横向内容滚动的判断之后。未达到识别阈值、竖向意图、选字和横向内容控件接管时，旧请求保留。
- 未增加状态、等待时间、任务或逐帧处理；消息、定位、排版、高亮、引用图标、聊天淡入、弹簧参数及高刷请求沿用基线。

`work/verification/drawer-ready-gesture-5031/scope-proof.json` 对比全部 146 份产品输入：去掉上述插入和四处构建号变更后，与 5030 完全相同。

## 验证方法与边界

新增回归直接提取产品 `drawerDragGesture` 的 `onChanged` / `onEnded` 回调执行，并复用产品的关闭请求、取消、进度、刷新保护和收尾驱动代码。手势值、UIKit 接收端、Observation 交付和 display-link 时钟使用受控替身。要求 5030 暴露持指期间的迟到就绪问题，而 5031 保持手指控制；同时验证未识别及被其他交互接管的触摸、正常就绪、松手开关、动画中途反向、旧回调和场景中断。

该验证能判断控制权和回调时序，不等于真实手势识别、画面显示帧数或 17 Pro 手感验收。完整 Release 构建另行校验真实 iOS 类型和编译路径。

这次修复针对自动关闭与手势的控制冲突，不能据此宣布复杂内容排版与动画重叠的问题已解决，亦不提供 FPS 提升结论。

## 部署状态

制作候选的首轮只完成本地验证；用户随后明确授权装机试用。已将提交 `17fa65781cd6b7faf366635f0a7f4d59f6daa2cd` 对应的原签名产物安装到 iPhone 17 Pro，测试包从 5030 原位覆盖为 5031，并正常启动。安装后版本、主程序与同一安装目录下的扩展进程均已读回；独立正式包仍为 5024。

没有卸载、清空、读取、导出或复制真实聊天，没有新增聊天备份，也没有请求或收集聊天逐字节保留证明。原 5030 候选及其已签名产物保留。实际交互与帧率仍待用户试用；安装记录见 `work/verification/device-5031/DEPLOYMENT.md` 和 `deployment-receipt.json`。

## 验证结果

- 新的 `CandidateTests/check_drawer_ready_gesture_ownership.py`：每版 28 个场景、174 项断言。5030 在有无滚动宿主、松手开或关的四组持指场景中，均精确暴露五项控制权失败；5031 全部通过。实际 `onChanged` / `onEnded` 正文保持原样提取，报告保存每份输入及闭包哈希。
- `CandidateTests/check_conversation_entry.py`：39 项会话进入检查通过。
- `CandidateTests/check_drawer_transition_handoff.py`：当前 42 项组合交接、26 项既有回归通过；5024 历史对照仍保留预期的 28 个旧问题。
- `CandidateTests/check_drawer_scene_interruption.py`：146 个场景通过。
- 独立代码复核未发现阻塞问题：同一次选择与申请自动关闭处于同步调用链；就绪先到和手势先到均有完整的控制权交接。

两份旧交接测试初次运行失败，因为它们还在检查已经不由产品驱动的旧显示通道替身。5030 与 5031 的相关提取代码逐字一致，并复现相同失败。测试现在连接真实 `DrawerLivePanelMotionReceiver`，同时核对 tracker 与接收端的最终位置；其他断言和历史对照保留。对照原始证据位于 `work/verification/drawer-ready-gesture-5031/legacy-test-compatibility/`。

新测试详情见 `CandidateTests/DRAWER_READY_GESTURE_5031.md`；原始结果见 `work/verification/drawer-ready-gesture-5031/result.json`。Release 构建结果另记于同目录的 `build-result.json`。
