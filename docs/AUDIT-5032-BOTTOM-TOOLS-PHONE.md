# 5032 工具转场：iPhone 17 Pro 实测

2026-09-14。用户完成三组操作后明确反馈：工具首页↔更多工具顺畅，指令注入和上下文管理进出有卡感。较早一次“没有明显区别”的选项已被随后文字更正，不能作为体验通过记录。

## 实测结论

**这轮真机记录确实出现不同的画面交换节奏。** 取每组输入最后一个 HID 时间后 50–250 ms，仅计算原始交换序列中相邻、且两端都能唯一关联到 Mocca 的记录：

| 操作（方向依照操作顺序推定） | 每个输入组的间隔中位数 | 对应节奏 |
| --- | ---: | --- |
| 首页↔更多工具 | 8 组均约 8.335 ms | 接近 120 次/秒 |
| 更多→指令注入 | 4 组均约 16.669 ms | 接近 60 次/秒 |
| 指令注入→更多 | 4 组均约 8.335 ms | 接近 120 次/秒 |
| 更多↔上下文管理 | 8 组均约 16.669 ms | 接近 60 次/秒，同时存在约 25 ms 间隔 |

这是匹配到 App 的显示缓冲交换记录，**不是整个页面固定锁帧、整个录制平均 FPS，也不保证每次交换的像素都发生变化**。HID 没有 route 标签，指令进入/返回方向根据用户往返顺序推定；最稳妥的结论是指令组内存在两种交替节奏，不能把其所有进出都称为 60。

交换时间对应的 `Desired Presentation Time` 间隔中位数同样接近 8.334 / 16.669 ms；各输入组 actual−desired 中位数都约 0.522 ms。低频片段因此并不只是相同目标节奏下偶发晚到一帧。该目标是管线导出的呈现时间，不能进一步等同为应用显式调用了某个 `preferredFrameRateRange`。

改变观察窗口后，快慢分组仍清楚；上下文的较长窗口会包含更多约 25 ms 间隔，50–300 ms 有一组中位数约 20.84 ms，0–500 ms 有一组约 25 ms。因此不能声称它“所有窗口都稳定 60”。

## 同时发生的 CPU 路径差异

与上述 24 个中段窗口交叉：

- 12 个约 8.335 ms 窗口，`AsyncRenderer` 与主线程异步交接路径采样均为 0。
- 12 个约 16.669 ms 窗口，`AsyncRenderer` 采样 18–40 ms，主线程异步交接路径 6–16 ms；主线程总采样中位数 26.5 ms，反而低于较快组的 67.5 ms。50–300 ms 的敏感性检查保持“快组未采到 AsyncRenderer，慢组均采到”的关联。
- 慢组可见 `ViewGraph.updateOutputsAsync`、DisplayList 更新、`UpdateGroup.syncMain` / moved callback 相关堆栈。这些名称下的采样包含真正执行更新的工作，不能将 `wait_for_lock` 名下全部权重算作锁阻塞。

整个三个操作包络内，主线程采样分别为 1317 / 862 / 553 ms，最长主 run loop 非等待区间分别为 59.40 / 31.03 / 30.74 ms；这些包络包含等提示和回复时间，不能作动画 FPS 分母。没有观察到两个子页比更多工具更严重的主线程长阻塞，不支持仅靠“子页主线程算得更多”解释本次差别。

**目前定位到渲染路径与呈现节奏高度同现，尚未证明哪个应用代码条件导致系统选择这条路径。** 同样的动画曲线只描述状态如何变化，不足以静态确定框架实际采用的更新线程、呈现目标和交换节奏。

## 与源码和模拟器结果的关系

导航仍共用 `open/back`、0.30/0.28 秒动画入口和同一横移/透明度公式；根页↔更多默认还伴随系统弹层 355↔320 pt 高度动画，两个子页默认同为 320 pt。工具导航没有独立的显式高刷 lease。全局高刷 opt-in 已存在。这些是解释运行差别的候选条件，不能由此断言系统调度原因已全部确认。

额外只读检索未找到 route→AppModel/RootView/ChatView 的显式状态转发或聊天写入：AppModel 以 `let bottomTools` 持有独立 Observable 对象；Root 只传对象，不读取 route；route observer 只修改弹层本地 detent。上下文页读取操作状态，不会在进入时自动压缩或清除聊天。范围见 `BottomToolsSheet.swift:70、87、94、229、281、878`，`AppModel.swift:913、3951、6798`，`RootView.swift:2305、3031`。

[模拟器对照](AUDIT-5032-BOTTOM-TOOLS-SIMULATOR.md)仍证明非空指令列表有创建/布局开销，但不能用模拟器的峰值代替这次真机证据，更不能用列表开销解释所有上下文转场。

下一步有辨别力的实验是仅在工具内部转场期间短暂请求更高刷新，比较上述交换节奏与异步渲染路径是否一起改变，并检查重复点击、返回、离页及取消后的释放。该实验尚未实施；没有修改动画、安装候选或宣布性能修复完成。

## 有效记录与测量方法

- 使用手机原有 `com.uuzsama450.mocca.migration` 1.0 (5032)，iPhone 17 Pro / iOS 27.0，PID 15946。二进制及 dSYM UUID 均为 `6218E94C-E644-37B8-BA9D-F1188DFDF670`，与采样里的 Mocca 二进制相符。产品代码仍是 `a0929b5`。
- 有效 run 是 `attempt-06-device-name`。真实起止为北京时间 22:05:35.119243–22:07:41.125028，126.005785 秒；模板 Animation Hitches，用户手动完成三组后停止，录制正常保存、退出 0。
- 三组先后由提示和用户确认划定包络。进一步从有效数据提取输入相关 HID 组，排除指令组开头的一次准备导航候选。分组阈值 0.2/0.3/0.4/0.5 秒得出相同组。没有把手动回复时间伪装成精确点击时刻；早于首 HID、又未匹配 App Update 的零散前缀交换记录不赋予导航标签。
- `hitches-updates` 导出 717 行，其中 708 行为有效 Mocca level-0 updates，9 行为 highlight 重复。`display-surface-swap` 有 916 行，706 行可通过唯一的 `(swap-id, surface-id)` 对关联到 Mocca updates；另 2 个 App Update 无对应 swap。两表各只有一个 display 标签且 706 个键唯一相交，以此建立显示器对应，未只按名字猜测。
- 严格间隔要求原始 swap 流中两个相邻端点均匹配，**不跨越未匹配记录拼接长间隔**。其余 210 个未匹配 swap 仅用于次要敏感性对照，不作为直接 PID 归属证据。导出的 `min-quanta` 全部为 2，未解释它的时间单位或当作帧率上限。
- CPU 有 3700 条 Running 样本，全部 `1000000 = 1.00 ms`。runloop 有 34022 行、5715 个完整主线程非等待区间，嵌套层级全部为 1。采样权重不是逐条调度计时，非等待墙钟区间也不是纯 CPU 或单帧时间；inclusive 堆栈归类互相重叠。符号部分未解析，不精确归因到某一 Swift view。
- 所有对比来自单轮手动操作记录，没有随机化顺序，不能把第一次记录的往返当成已证明的冷缓存。Profiler 也有观察开销。

## 导出恢复、失败与收尾

旧的 PID/name 附加曾失败；一次系统采样断连，另一次用户说明在看视频而作废，均没有混入结果。有效 run 保存后，普通 TOC 和部分定向导出在电脑端 `objc_release` / autorelease pool 内崩溃。

根据崩溃栈，导出子进程临时设置 `NSZombieEnabled=YES` 后恢复了 TOC、上述四张有效 XML。该选项仅作用于**录制结束后的电脑读取器**，未加到手机 App、采样过程或全局环境。使用退出状态、完整 XML 解析、表单位、PID、二进制 UUID 和跨表唯一匹配分别校验；保留读取器的 symbolicator zombie 警告。有关诊断用途见 Apple 的[对象生命周期崩溃排查](https://developer.apple.com/documentation/xcode/investigating-crashes-for-zombie-objects)。

不是所有表都恢复：`displayed-surfaces-interval` 仍崩溃，`time-sample` 失败，因此原始计时事件数交叉校验缺失。后续导出遇到 ENOSPC 后停止；没有完整结果的 GPU、render、potential-hangs 或 hitch 表不作零值/无卡顿结论。

只清理本轮两次无效录制遗留的 2,787,968,168 字节临时 ktrace；有效原始 ktrace、trace 包和已导出的 XML 均保留。未清理旧任务缓存、重装或重启 App、修改聊天数据；采样进程已退出。

证据目录为忽略的 `work/verification/bottom-tools-motion-phone-5032/`。有效 run 下的 `presentation/cadence-summary.json`、`swap-cadence.json`、`method-note.md`、`cpu-recovered/analysis.json` / `analyze_cpu.py`、`root-cross-check.json` 可复核数字；TOC、元数据恢复、导出 receipt、用户更正与失败记录也保留在同目录。
