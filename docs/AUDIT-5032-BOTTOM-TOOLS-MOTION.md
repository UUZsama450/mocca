# 5032 工具内部转场只读审计

用户反馈：默认工具面板进入“更多工具”很流畅，但从“更多工具”进入“指令注入”“上下文管理”及返回较不流畅。截图提供外观和页面身份，不能提供实际帧率。本次安装原有 5032 产物后只读审计，没有修改工具动画或增加高刷请求。

## 源码已确认

1. **内部导航共用动画入口。** `BottomToolsModel.open` 是 easeInOut 0.30 秒；`back` 是 easeInOut 0.28 秒；页面容器另外统一应用 route 驱动的 easeInOut 0.30 秒。实际横移/透明度由相同 `navigationPage` 计算。不能只把 back 的 0.28 当成最终呈现时长，也没有专门为两个深层页面设置较低帧率的分支。位置：`BottomToolsSheet.swift:87、94、202、281`。
2. **同时执行的系统弹层动画不同。** 默认 root 高度为 355 pt，More / Instruction / Context 的目标高度同为 320 pt；route onChange 以 0.26 秒动画设置 selectedDetent。所以默认 root↔More 有高度变化，而 More↔两个子页通常没有高度变化。若用户手动拉高了弹层，下一次 route 切换也可能改变高度，不能笼统说所有深层导航永远不改高度。位置：`BottomToolsSheet.swift:160、229、335`。
3. **工具导航没有自己的显式高刷请求。** open/back、route onChange、sheet onAppear 和 `BottomToolsPresentationHost` 均不启动高刷 lease。现有 DrawerHighRefreshLease 预建后暂停，在侧栏横向接管时启动，松手约 700 ms 后暂停；工具页没有接用。已安装 5032 的 Info.plist 中 `CADisableMinimumFrameDurationOnPhone=true`，全局高刷权限未漏配。位置：`RootView.swift:468、2248、2607、2635、3021`。
4. **进入子页面不等于执行工具。** 指令项目在打开最外层工具面板前已从内存准备；进入指令页只展示标题、分组和选择状态。上下文页显示两项按钮，只有进一步点击并确认才调用压缩或清除/恢复操作。未找到在进入子页时自动进行网络、压缩摘要或整段 Markdown 排版的入口。位置：`AppModel.swift:6798`；`BottomToolsSheet.swift:711、862`。
5. **内容创建仍是另一项待测因素。** More 在自身和两个子 route 间留在同一结构分支；深层页按 switch 加入，返回时移除。root↔More 也存在目的内容插入/移除，所以仅凭这种结构不能归因于深层独有的重建缺陷。三个页面共用横移/透明度公式并不意味着内容创建、合成和系统 frame pacing 的运行成本相同。

## 当前判断与界限

最有辨别力的差异是“原生弹层高度动画 + 内部横移”与“主要只有内部横移”。系统对这两条路径的实际刷新节奏可能不同，这与用户感受相符；但没有真实帧时间记录，不能把它写成已证实的 120 Hz 对 60 Hz，也不能把缺少显式高刷 lease 直接认定为根因。

Apple 的 [ProMotion 文档](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays) 说明 UIKit、SwiftUI 等框架会自动处理部分 frame pacing；应用无法强制显示器使用指定刷新率。`preferredFrameRateRange` 也只是系统尽量满足的提示，受设备和系统条件影响。全局 opt-in 和显式请求都不等于实际帧率保证。

若继续验证，应在 iPhone 17 Pro 上固定同一静止聊天、相同页面内容和初始弹层高度，比较 root↔More、More↔Instruction、More↔Context；分别记录 forward/back 的合成帧间隔和主线程超时。观察用 display link 自身可能改变刷新节奏，不能把它记录的回调频率等同于屏幕实际出帧。随后仅做一个有边界的实验：保持页面内容、时长、曲线、布局不变，在内部转场开始/结束期间短暂请求高刷新，并验证结束/取消/离页后释放。若卡顿不改善，应回到页面创建、布局或事务时间线，避免叠加计时器和常驻高刷。

独立交叉检查在 `work/verification/bottom-tools-motion-audit-5032/navigation-audit.md` 与 `refresh-audit.md`；10 个导航和 More/Instruction 相关声明与 5031 逐字相同。返回时新声明切换到空分支，但 SwiftUI 可能保留正在移除的旧内容参与转场，不能推断为第一帧立即销毁。产品提交仍为 `a0929b5`。本次审计没有进行帧率实测或性能修复。

后续已按用户要求完成[隔离模拟器对照测量](AUDIT-5032-BOTTOM-TOOLS-SIMULATOR.md)：指令列表从 8 条变为空后，进入时的集中主线程工作明显缩短；上下文没有相同证据。该结果补充内容布局因素，仍未证实真机刷新率差异，也没有据此实施高刷修复。

随后完成了[iPhone 17 Pro 真机记录分析](AUDIT-5032-BOTTOM-TOOLS-PHONE.md)：动画中段的 App 缓冲交换呈现约 8.335 / 16.669 ms 两种节奏，与 AsyncRenderer 路径高度同现。该结果补上运行证据，但尚未实施单变量高刷实验或确认系统选择路径的具体触发条件。
