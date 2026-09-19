# 5033 工具转场：最小真机 A/B/A 采集方案

2026-09-14。本文规划下一轮采集。5033 完整 Release 与签名校验已完成，尚未安装实验包或开始新采样；待用户准备好后先采手机现有 5032 的 A1。

目的：仅改变工具内部转场期间的短暂高刷新请求，检查之前约 16.669 ms 的子页交换节奏是否接近约 8.335 ms，并观察 AsyncRenderer / 主线程交接路径是否同时改变。动画、布局、页面内容和采集工具保持一致。既有 5032 记录是历史 A0，**不是此次同轮 A1→B→A2 的第一个 A**；若本轮只录 B 和回退 A，必须称为历史 A0 + B/A，不能写成完成同轮 A/B/A。

## 采集前约定

- A1、A2 使用同一个已核验的 5032 产物；B 使用 5033 单变量产物。5032 产品提交是 `a0929b5`，本候选基线 `e99f9d4` 还包含审计材料。每轮另记实际版本、Bundle ID、可执行文件/dSYM UUID 和 PID；PID 15946 只属于旧记录。
- 只用用户的 iPhone 17 Pro。保持相同静止聊天、指令列表、初始弹层高度、亮度、充电方式及低电量模式设置。每次安装后先回到相同状态，静置到相近温度；用同一套预热操作，不把首轮自动称为冷缓存。
- A/B/A 安装由主任务按既有授权完成，沿用同 Bundle ID 覆盖并保留数据。这个文档不安排卸载、清数据或额外备份。
- 不增加测量用 CADisplayLink、FPS 浮层、常驻刷新请求、录屏或新动画。B 的短暂高刷请求是实验变量；观察器不能再给 A 启动同类请求。沿用相同 Instruments 模板也仍有观察开销。

## 每个 A1 / B / A2 的最小操作

所有操作仍需用户亲手完成；采集程序不能代替真实点击。开始录制前一次讲完操作，录制期间不用用户读长提示或逐组回消息。

1. 工具首页↔更多工具，4 个往返，结束在首页。
2. 进入更多工具一次作为准备；更多↔指令注入，4 个往返，结束在更多。
3. 更多↔上下文管理，4 个往返，结束在更多；随后静止约 2 秒结束。

相邻点击大约间隔 0.8–1 秒，让约 0.30 秒的转场完整结束；组间可以停 2 秒帮助辨认。约 25 次计划点击通常能放入 35–45 秒，但**计划次数不是观测次数**。提前在电脑记录阶段提示时间作为粗包络；最终用 trace 的 HID 输入组核对实际分组。若漏点、点错或步骤中断，记录事实，不强凑 8/9/8 组或猜方向。主观反馈等录制停止后再分别记录，区分进入、返回及整体感觉。

沿用旧轮唯一完整成功的命令形状，将时限从 180 秒缩为 45 秒。以下只是待执行模板；设备选择和 PID 必须由主任务在该轮开始前核实：

```sh
xcrun xctrace record \
  --template 'Animation Hitches' \
  --device "$moccaTraceDevice" \
  --attach "$moccaTracePID" \
  --time-limit 45s \
  --output "$moccaTraceOutput"
```

旧成功轮的设备显示名是 `Blender 2.93.1`，PID 是 15946；它们是历史取值，不应直接写死到新轮。等待日志明确进入录制状态后才通知用户开始。完成后给该 recorder 一次正常停止请求，或让 45 秒上限自然结束；等待“已保存”及退出 0。旧轮实际采集 126.006 秒，但连同停止整理、写盘总耗时 284.807 秒，因此停止后的写盘时间不能误算为采样长度，也不能仅因没有新日志就把正在保存的 trace 判为失败。

A1、B、A2 分开放进 `work/verification/tools-transition-refresh-phone-5033/a1/`、`b/`、`a2/`，不覆盖旧输出。每轮保留 command、record log、result、用户操作/反馈与实际 run 元数据；每次安装或重启后重新核对 PID。若 45 秒内未完成，保留这一轮的实际覆盖情况后再决定补录，不在分析阶段补造缺失动作。

## 只读取四张已验证有用的表

先验证 trace 已保存，再按 TOC 的实际 run 编号和 PID 校验；成功导出一次就保留，不反复导出。按顺序读取：

| 表 | 用途 |
| --- | --- |
| `hitches-updates` | Mocca PID、level-0 App Update 与 swap/surface 归属 |
| `display-surface-swap` | 实际 swap timestamp、desired presentation time、generation、HID |
| `time-profile` | Running 采样权重、主线程/AsyncRenderer 堆栈 |
| `runloop-events` | 主线程完整非等待区间与嵌套层级 |

本轮不必重试旧轮失败或无完整 receipt 的 `time-sample`、`displayed-surfaces-interval`、GPU/render/potential-hangs 等表。只少导出表会减少 XML 和读取器开销，**不会减少模板已经录下的原始 trace**；缩短录制、把说明和回复移到录制外，才是本方案减少原始体积的方法。旧有效 trace 文件逻辑大小约 447 MB，另外还有原始 ktrace / 工作临时文件；不能只按 XML 大小预算空间，也不承诺 45 秒线性对应固定大小。

普通读取器曾在 `objc_release` 崩溃。可复用已证实的恢复方式：只给每一个离线导出子进程局部设置 `NSZombieEnabled=YES`，不设为全局、不传入 recorder 或手机 App。导出串行执行，单表有超时、独立日志和 receipt，验证退出 0、完整 XML、真实 schema、行数/单位/PID。某表失败就标缺失；不要把空文件当零事件。开始前检查磁盘余量，遇到 ENOSPC 停止追加导出；只处理有明确归属的本轮无效临时文件，不触碰原始有效证据。子进程禁写崩溃 core 也可减少重复失败的磁盘放大，不改变手机采样。

## 旧分析工具可复用的部分与必须参数化的部分

旧证据位于候选 mocca-settings-polish-5032-a（本地历史材料：`work/candidates/mocca-settings-polish-5032-a`） 的 `work/verification/bottom-tools-motion-phone-5032/attempt-06-device-name/`。使用时从该轮复制 helper 到新证据目录再适配，不能对旧目录就地重跑覆盖。

- `presentation/trace_xml.py` 的文件内 ID/ref 流式解析可直接沿用。`prepare_phases.py` 接受实际 TOC 或真实 run metadata；新轮粗包络仍不能伪装成精确点击时间。
- `record.py`、`export_presentation.py`、`analyze_updates.py` 写死旧 PID；改为本轮参数/元数据。旧导出脚本会访问许多失败表，需仅选择上述四表，保留逐表 receipt。
- `analyze_swaps.py` 把指令第一个 HID 组固定当成准备，且说明文字含固定的 706 个匹配；都要改成新轮事实。只在实际手动序列支持时标准备/推定方向。旧 0.2/0.3/0.4/0.5 秒阈值一致性应重新检验，不能假定成立。
- `cpu-recovered/analyze_cpu.py` 固定 PID 15946、旧单位观测、全部 nesting=1、包络外恰有 1 ms 等断言。这些是旧数据验证，不是新 run 的常量。将 PID/包络参数化，重新校准单位；若出现嵌套必须按等待区间并集分析，不能直接去掉保护后压平。新录制时段缺事件可标覆盖不足，不能为了通过断言强行复制旧结果。

首要指标仍用最后 HID 后 50–250 ms，辅以 50–300 ms 与 0–500 ms 敏感窗口；只取原始 swap 流中相邻、且两端都唯一匹配 Mocca App Update 的记录。按方向分别展示每组 actual/desired 间隔分布和有效 pair 数；不跨未匹配记录拼接间隔，不把整段包络换算成 FPS。窗口被下一输入截断或有效 pair 太少时应显式标注。

再用相同窗口比较 AsyncRenderer 权重、主线程 DisplayList/异步交接路径、非等待长区间。A1→B 改善且 A2 回到原特征，才支持这次短暂高刷请求的可重复影响；若 A1/A2 本身明显不同，就保留温度/顺序/系统波动这一不确定性。B 退出工具后不应持续请求高刷；静止尾段可以辅助观察，lease 释放本身仍要结合实现与取消/离页验证，不能仅凭几秒没采到回调证明。

## 已准备的采集与离线工具

- `CandidateTests/record_tools_transition_trace.py` 显式接收 device、PID、build、A/B 阶段和新目录；默认录 45 秒，不安装或启动 App，不改变 App 的刷新安排。
- `CandidateTests/export_tools_transition_trace.py` 对已保存 trace 串行导出 TOC 和上述四表，验证记录 PID、schema、完整 XML，按表保存 receipt；读取器局部使用 NSZombie 恢复选项。
- 呈现工具及用法见 `CandidateTests/analyze_tools_presentation.py`、`TOOLS_PRESENTATION_USAGE.md`。9 项离线验证通过，旧 XML 复现 706 个唯一匹配以及显式排除准备组后的 12 快 / 12 慢；不把旧值当成新轮断言。
- CPU 工具及用法见 `CandidateTests/analyze_tools_transition_cpu.py`、`TOOLS_TRANSITION_CPU.md`。旧 24 窗口的 240 项权重比较一致，另有 11 项边界检查通过。它处理 Running 采样及包含交接的堆栈，当前不自动重建 runloop 非等待时长。

这些验证使用旧证据检查分析工具，没有产生 5033 的真机性能结论。
