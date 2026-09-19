# 1.0 (5003)：输入框选区与侧栏手势

内部开发和验收记录，不随 App 打包。

## 来源

- 从干净的 `f95c891` / `codex/composer-navigation-interruption-5002` 建立独立候选。
- 分支：`codex/composer-selection-drawer-5003`。
- 5002 的 46 份冻结输入在改动前逐一核对，除本次正在编辑的两个 Swift 文件外全部一致。
- 完整保留 5001 生图修复及 5002 深色发送键、导航取消、纯思考回复操作入口修复；它们原有的待真机验收项目仍见对应记录。
- 本轮设备清单实际读到：iPhone 17 Pro 上测试 Bundle `com.uuzsama450.mocca.migration` 为 0.1.0 (5001)，独立正式 Bundle `com.uuzsama450.mocca` 为 0.1.0 (4957)。本次安装只针对测试 Bundle。
- 用户随后明确指定本包为 **1.0 (5003)** 并要求安装手机。主程序及扩展的四处构建配置均统一；不修改 App Store Connect，不执行正式上架。

## 可确认的缺口与修改

侧栏使用 `MainChatContainer` 上的同时拖动手势。既有
`DrawerTextSelectionInteractionGate` 只注册正文的 `GlyphSelectableTextView`，
而输入框是 SwiftUI `TextField(axis: .vertical)`，没有进入这项保护。

本轮仅在输入框聚焦、侧栏尚未决定接管本次拖动时，通过公开 responder-chain
action 取得当前编辑控件，以 `UITextInput` 的选区及端点光标矩形判断活跃触摸。
坐标使用该输入控件的 `textInputView`，选区周围沿用正文的 24 点容差以覆盖手柄。
命中后沿用 `drawerGestureLocked = false`，让出本次拖动。

- 保留原生选区、菜单、输入控件和正文已有的选择处理。
- 光标附近的拖动也交给输入控件；仅有焦点/选区但没有触摸，不阻止侧栏。
- 选区之外的正常右滑仍由原有方向和距离规则判断。
- 不按「键盘弹出」全局禁用侧栏，不改变侧栏按钮行为。
- 不增加定时器、显示链、轮询、SwiftUI 选区状态发布或整个聊天视图树搜索。
- 不调整颜色、布局、字体、动画参数、草稿保存和发送逻辑。

这属于源码路径说明，不代表已经测得性能无变化或真机手势通过。

## 验证

- 公开 API 声明核对于本机 iOS 26.2 SDK：`UIApplication.sendAction`、
  `UITextInput.selectedTextRange/selectionRects/caretRect/textInputView`、
  `UIGestureRecognizer.numberOfTouches/location(ofTouch:in:)`。
- `ComposerSelectionGateHarness.swift` 提取产品文件中的原样 gate，在独立模拟器
  测试 App 中运行。标准 UITextField、UITextView 及 SwiftUI 多行 TextField 共
  **32/32** 检查通过：选区上/下手柄、选中文本、空选区的插入光标、选区外触摸、
  无触摸、禁用/结束的识别器、释放焦点后无残留。
- 使用真实 UIKit 控件、选区几何及 responder dispatch，识别器的触摸位置为
  合成输入；不是对完整侧栏的手指拖动测试，不作为真机交互或性能结论。
- 测试 App 不使用 Mocca 数据、网络或聊天容器；测试后已关闭本轮启动的模拟器。
- 结果：`work/verification/selection-gate-harness/results.json`。
- 本包 46 份冻结输入：`work/verification/build-source-inputs-5003.json`。
- 最终 1.0 构建日志：`work/verification/build-1.0-5003.log`。
- 最终构建、签名与部署结果另存于 `work/verification/artifact-5003.json`。

原 0.1.0 构建在用户指定 1.0 后停止，未安装。最终包使用独立的
`work/verification/device-5003-1.0/derived` 输出，避免混淆版本产物。

2026-09-11 23:29（Asia/Shanghai）最终验证完成：

- 完整 Generic iOS Release `BUILD SUCCEEDED`，产品提交 `2b9a563`。
- 主程序与扩展均为 1.0 (5003)、arm64，严格签名通过，二进制与 dSYM UUID 一致。
- 描述文件有效至 2027-09-01，包含目标 iPhone，签名授权与 Bundle 对应。
- 46 份冻结构建输入匹配；5001 回退包的签名和二进制哈希通过。
- 同 Bundle 覆盖安装并正常启动成功；手机应用清单读回 1.0 (5003)。
- 主程序和扩展进程均对应新安装路径。独立正式 Bundle 仍为 0.1.0 (4957)。
- 真机手柄拖动与正常侧滑仍等待用户体验确认，没有把部署成功当作交互通过。

随后用户在 iPhone 17 Pro 试用后反馈「没问题啦」，确认本轮输入框选字与侧栏
冲突已解决。该反馈对应前一轮要求的手柄拖动及松手后正常侧滑；不扩大为所有
机型、所有选区边界场景或此前 5002 全部待办均通过。

## 真机验收

| 操作 | 预期 | 状态 |
| --- | --- | --- |
| 输入文字，选中一段，分别向右拖两个蓝色手柄 | 只改变选区，侧栏不出现 | 用户反馈原问题已解决 |
| 长按光标后左右移动 | 光标跟手，侧栏不出现 | 待真机 |
| 保持键盘/选区，从聊天正文空白处右滑 | 正常打开侧栏 | 待真机 |
| 松开选区手柄后，再进行正常侧滑 | 新手势可以正常打开侧栏 | 用户整体反馈没问题 |
| 多行、长草稿滚动到中间，再拖选区端点 | 选区跟手，不因坐标偏移误开侧栏 | 待真机 |
| 复制、粘贴、继续打字及发送 | 原有交互正常 | 待真机 |
| 正文选区、横向图片/表格、侧栏按钮开合 | 保留原有行为 | 待真机 |

## 回退

5001 已签名原包保留在：
`../mocca-native-image-replies-5001-a/work/verification/device-5001/derived/Build/Products/Release-iphoneos/Mocca.app`。

5002 源码、构建和包也保持原样。部署仅做同 Bundle 覆盖，不卸载、清空、导出或
复制聊天，不额外创建聊天备份；未做聊天快照，不能声称前后逐字节一致。

## iPhone Air 安装

2026-09-11 用户带来同学的 iPhone Air 并请求安装同一份 1.0：

- Air 实测为 iOS 26.6.1、开发者模式已开启、有线连接。
- 现有 5003 主程序及扩展签名均包含 Air，文件哈希与 17 Pro 使用的包一致，无须重编译。
- Air 原有 `com.uuzsama450.mocca` / 0.1.0 (4957)；新装测试 Bundle `com.uuzsama450.mocca.migration` / 1.0 (5003)，并存，不迁移或读取聊天。
- 首次启动因锁屏被系统拒绝。用户解锁后启动成功，应用清单读回 1.0 (5003)，主程序进程对应新安装路径。
- 当前未观察到扩展进程；扩展包的签名和设备资格已核对，不为验证而创建生成任务。
- Air 上功能与性能体验尚未测试。结果见 `work/verification/air-5003/deployment-receipt.json`。
