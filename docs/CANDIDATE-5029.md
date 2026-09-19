# 5029：表情条点击与退出清理

基线为手机安装的 5028（fcb0c106）。本次修改表情条，侧栏标题问题仍在调查。

## 已确认问题与修改

- 5028 的表情条“更多”真实点击命中了后面的空白遮罩，只有关闭动作，没有触发消息菜单。提取视图的触摸日志和完整应用均复现。给表情/更多按钮的 35 × 42 pt 内容区域添加明确的矩形点击形状，保留布局、玻璃材质和动画。
- 已有侧栏打开事件在进入其他清理任务的空闲判断之前清掉表情条。普通会话切换和进入空会话时同样清理；旧动画完成回调继续由已有的 presentation ID 检查阻止。
- 不增加定时器、显示刷新回调、常驻 GeometryReader 或逐帧监听。侧栏手势、动画驱动、刷新保护、会话存储和 5028 的其他功能保持原样。

## 验证更正

5028 的旧界面测试用“收藏按钮存在”判断消息菜单已经打开。侧栏本身也有同名按钮，即使菜单没有出现，这个断言仍可能通过。原 `assistant-more-actions` 截图实际没有菜单；原报告中这项通过结论撤回。此次旧测试与新回归测试都要求真正可见的“消息操作”标题和菜单动作。

5028 原提取视图：点击只记录 scrim tap；加入点击形状后：more button action → completion → parent more → sheet appeared。旧 5027 的提取绘制路径在同一模拟器、同一中心点击下能打开菜单，支持这是 5028 表情条改动引出的回归。

新测试覆盖更多按钮中心及两个内侧角点、表情按钮留白、外部关闭、侧栏手势打开后回到会话，以及原新聊天长按菜单。测试最终结果见 `work/verification/regressions-5029/`。

## 侧栏单条标题错位：代码审查结论，尚未定位根因

证据：用户原录屏 `ScreenRecording_09-14-2026 02-58-53_1.MP4`，时长 2.150 秒。在约 0.65 秒切换会话后，旧选中的 TestFlight 标题短暂出现在更下方，邻近其他行没有相同幅度的垂直移动。

- 普通点击走 `selectConversationFromDrawer` → `selectConversationWithoutAnimation` → `AppModel.selectConversation`。事务禁用动画；该路径不改 conversations 数组、标题或 updatedAt。selectedConversationID 的 didSet 仅清未读和旧请求。因此普通选择自身不触发重新排序。
- 日期分组只按 updatedAt / createdAt 排序。普通选择不写这些字段。异步标题生成属于另一条流程，当前录屏不能证明它同时发生。
- `DrawerContentMotionModifier` 只改内容整体透明度和 x 位移，没有标题 y 位移。`DrawerLiveMainPanelController` 的 UIKit transform 属于右侧聊天面板，不直接移动左侧标题。
- `DrawerListTopReturnCoordinator` 改整个 UIScrollView 的 contentOffset，用于越界回顶；它不是单条标题动画。聊天再生成快照也属于右侧聊天视口。
- `conversationRow` 的显式 ID 同时包含 conversationID、isSelected、hasUnreadReply、title。选择会话会重建旧选中行与新选中行；标题字重与选中背景也在同一次提交中改变。这是与“单条旧选中标题出错”最匹配的代码检查点。
- 该整行 ID 早于 5027，注释说明它用于防止懒列表保留旧选中背景/重命名后的旧标签。不能直接删除并宣布修复。
- 5027 把内容淡入/位移交回 SwiftUI 的 compositingGroup + visualEffect，5028 没改这部分。其与行重建的交互仍是假设，不能仅凭时间先后确定是 5027 或 5028 引入。

模拟器 iOS 26.2 的合成行场景和实际应用切换录制没有抓到同样错位；用户设备为 iOS 27。模拟器阴性结果不否定用户录屏，也不构成实机验收或 FPS 证明。原视频、逐帧图片、模拟器录制及触摸记录位于主仓库忽略目录 `work/verification/5028-user-regression/`。

下一步应限定在选择提交时两条受影响行的身份、布局坐标与绘制坐标是否一致，而不是试改缓存、延时或整体侧栏手势。标题相关产品代码在 5029 中保持不变。

## 本轮完成的验证

- 最终 Debug 编译通过；实际应用 `ReactionDismissalUITests` 3 项通过，`ReactionDismissalFinalUITests.xcresult`，107 秒。
- 真实菜单截图检查、三个点中心/角点点击、侧栏滑开/返回后无旧表情条、表情选择与外部关闭、原新聊天长按菜单均纳入最终界面检查。
- 首轮侧栏用例错误地要求被表情条遮罩覆盖的顶部按钮直接可点，已改用真实侧栏横向手势；原失败结果保留，不作为产品通过证据。
- `scope-proof.json` 核实 11 个声明/文件与 5028 相同，包括 Root 侧栏驱动、侧栏内容和位移、AppModel、文本渲染、存储及设置。
- 实机安装回执单独写入 `work/verification/device-5029/`；模拟器结果不代替 17 Pro 上的视觉和触觉验收。
