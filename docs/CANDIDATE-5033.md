# 5033：工具切页短暂刷新请求实验

基线是已装机的 5032，产品提交 `a0929b5`，含审计材料的提交 `e99f9d4`。实验源码独立保存在 `work/candidates/mocca-tools-transition-refresh-5033-a`，分支 `codex/tools-transition-refresh-5033`，产品提交 `d04144a`。

## 实验变量

仅在工具面板有效的 `open/back` 路由改变前请求 80–120 Hz、preferred 120。请求独立于侧栏，只在面板显示、App active 且未被附件交接、嵌套设置或上下文确认覆盖时启用。60 Hz 设备不创建 display link。

回调为空，不写 SwiftUI 状态，也不驱动动画位置。最后一次导航后计划 450 ms 释放，覆盖原有 0.30/0.28 秒转场并留短余量；快速往返只续期一个 link，旧任务取消后不能提前停止新请求。450 ms 是计划期限，受主线程实际调度影响，不是动画结束的测量结果。

面板关闭、场景非 active、覆盖状态变化时取消并释放。`handleAction` 在原业务回调之前停止当前请求，覆盖系统选择器先呈现、附件交接状态下一轮才发布的时序。无修改聊天存储、正文排版、侧栏 owner 或原业务动作。

## 保持与验证

产品差异只包含 `BottomToolsSheet.swift` 的刷新请求/生命周期，以及 App 和 extension 四处 build number 5032→5033。`navigationPage`、detent 值、0.30/0.28/0.26/0.24 秒动画、各页内容保持原样。

- `CandidateTests/check_bottom_tools_transition_refresh.py` 提取真实 lease、完整 model、资格表达式和生命周期方法。受控 Swift Task 测试 42 场景 / 120 断言，保留原始 450 ms sleep 的宿主检查 3 场景 / 7 断言，全部通过。生成代码中删除取消 guard 的负对照会暴露旧任务提前释放。
- 同一脚本移除明确枚举的新增刷新代码后，将全文件与固定 `e99f9d4` 基线逐字比较；5032 SHA-256 为 `48bea7fe74da653e841f19fa576a4abb9b9e36854f8f7a3c71f68088c1e15068`，保持证明通过。
- 既有上下文确认 287 项检查通过。其生命周期检查改为检查 `onDisappear` 闭包内包含取消操作，不要求取消操作必须是第一行。
- 静态独立审查未发现阻塞问题。UIKit、动画和生命周期投递在受控测试中是替身；这些结果不能证明真机帧率或实际 SwiftUI 事件顺序。

完整 generic iOS Release 已通过，耗时 593.48 秒，146 份产品输入在构建前后完全一致。App 和 extension 均为 1.0 (5033)、arm64，严格签名通过，团队 `Z44VFV3SBB`，profile 包含目标 iPhone 17 Pro；二进制与各自 dSYM UUID 一致。主 App UUID 为 `9A58F0AD-D929-3468-8026-9F79AA671AAB`，extension 为 `A98D537A-990A-3642-A199-A0842A47B616`。

完整输入、构建、签名和回退依据保存在 `work/verification/tools-transition-refresh-5033/`。本次预检手机测试包为 5032，正式包为 5029。为保留同轮 A1，尚未安装 5033 或开始新采样；待用户准备好后先采原版。未有真机对照结果前不能宣布优化完成。

## 非阻塞边界

- 未找到现有触摸入口会在同一面板已经显示时重复调用 `presentBottomTools()`。若外部代码这样调用，`reset()` 可能关闭诊断资格，而资格布尔值没有变化，不再触发启用；原路由仍正常，只可能缺少实验刷新请求。本轮不为未观察到的调用链新增恢复补丁。
- 思维链强度的原生 Menu 没有呈现状态监听，可能与上一转场剩余的短租约重叠；Menu 不续期。未改变其手势或菜单行为。
- 请求高刷新只是提示，不保证系统按该速率呈现。已有侧栏代码也记录过请求活跃而某段 SwiftUI 动画仍约 60 的情况，因此必须比较实际 App-associated swap 和相同输入窗口，不能用 display-link 回调频率冒充效果。

## 真机对照与回退

[A/B/A 采集方案](EXPERIMENT-5033-TOOLS-REFRESH-ABA.md)规定：同一聊天和列表，原版 5032 A1 → 5033 B → 原版 5032 A2，三路分别往返；旧记录只是历史 A0。

原版 App 路径、Bundle ID、签名和二进制 SHA-256 已在 `baseline-rollback.json` 复核。使用原有 5032 产物同 Bundle ID 覆盖回退，不卸载或复制聊天。结束版本和实测状态必须在完成采集后单独记录。
