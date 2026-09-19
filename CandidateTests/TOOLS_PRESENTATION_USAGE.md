# 离线工具转场呈现分析

`analyze_tools_presentation.py` 只读已有 `hitches-updates.xml` 和 `display-surface-swap.xml`；不录制、不导出、不访问手机、不改产品。需 `/usr/bin/python3`。支持新 `run/exports/`、旧 `run/presentation/`，也可直接指定含两张表的目录；多个位置同时有表时要求明确指定，避免猜错证据。

```sh
/usr/bin/python3 -B CandidateTests/analyze_tools_presentation.py \
  --run-dir work/verification/tools-transition-refresh-phone-5033/b \
  --pid CURRENT_PID \
  --output work/verification/tools-transition-refresh-phone-5033/b/presentation-analysis.json
```

把 `CURRENT_PID` 换成该次录制的 PID。输出目录须已存在；脚本拒绝覆盖已有文件。支持新的逐表 `*-receipt.json` 与旧 `export-receipts.json`；存在失败 receipt 时拒绝分析。没有 receipt 时仍验证完整 XML，并明确标记缺少导出退出状态。若有 TOC，则核对 PID 与唯一 run。

默认整个记录作为 `all` 段，HID 仅按时间顺序编号，**不猜 route、方向或第一个输入是准备动作**。可用 `--segments FILE` 传显式分段；也兼容已有 `phase-envelopes.json`：

```json
{
  "segments": [{"id": "instruction", "start_s": 10, "end_s": 20}],
  "input_labels": [{"segment": "instruction", "input_group": 1, "label": "用户明确记录的准备动作"}]
}
```

时间单位为相对 trace 起点的秒。分段不能重叠。`--exclude-input instruction:1` 显式排除某组，仍保留其全部指标供复核；输入标签不会自动排除数据。不存在的组号会报错。

- 默认 `--hid-source matched`，只用唯一匹配目标 PID 的 swap 携带的 HID。可能漏掉同一触摸的末个时间；输出列出相同显示器/表面池上未匹配 swap 携带的 HID。
- `--hid-source target-surface-pool` 额外用上述池上的 HID，复现 5032 原分析口径。这是较弱的输入归属，报告明确区分；**严格交换间隔始终要求两端唯一匹配 PID**。
- 三个观察窗为末个已记录 HID 后 50–250 ms、50–300 ms、0–500 ms。窗口受下一输入/段结束裁剪，并报告有效严格相邻 pair 数；默认至少 5 对才能纳入中央窗分类，可用 `--min-strict-pairs` 显式调整。0.2/0.3/0.4/0.5 秒 HID 分组不一致时标记不稳定，排除汇总资格，不补造输入。
- 重复 key、跨 PID 冲突、未匹配行不会先被过滤再连接；它们留在原始时间序列里作为间隔断点。显示器用唯一相交 key 建立映射；歧义不算目标匹配。输出显示实际/desired/generation 间隔及其分布，不给整个包络计算 FPS。

输出同时含详细 `segments[].input_groups[].windows` 和便于 CPU 关联的顶层 `windows` 数组。顶层 `time_origin="trace_start"`；每个扁平窗口包含 `id`、`bounds_s`、`window_name`、`segment`、`input_group`、`excluded_by_user`、`eligible_for_comparison`、`strict_pair_count`、`actual_swap_gap_median_ms` 和 `cadence_band`。band 只按实测中位间隔分为 `near_8_33_ms`、`near_16_67_ms`、`other`，不是 route 或 CPU 推断。显示缓冲交换也不证明每次像素变化。

回归检查（旧 XML 只读；验证前后 SHA-256 相同）：

```sh
/usr/bin/python3 -B CandidateTests/check_tools_presentation_analysis.py \
  --fixture-run "${MOCCA_WORKSPACE}/work/candidates/mocca-settings-polish-5032-a/work/verification/bottom-tools-motion-phone-5032/attempt-06-device-name"
```

检查覆盖：跨 PID/重复 key/未匹配间隔不桥接、显示器歧义、XML 引用和截断、失败 receipt、新 exports/receipt 格式、无默认 route/准备组，以及 5032 的三个观察窗逐组复现。旧轮使用显式分段、`--hid-source target-surface-pool`、`--exclude-input more-instruction:1` 后复现 **12 个约 8.33 ms + 12 个约 16.67 ms**；该历史数字没有写进通用分析器。

`MOCCA_WORKSPACE` is the local development checkout containing the historical `work/` evidence; those private artifacts are not distributed with this repository.
