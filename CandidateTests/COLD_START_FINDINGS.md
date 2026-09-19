# 冷启动首次发送：当前诊断状态

手机开发版已经核验仍为 4978，正式版 4957 未动。用户反馈重开后的第一次发送比第二次明显卡。

4978 源码确认：主库存档在启动加载，独立上一代备份首次进入 save 时才 load/decode；发送 saveImmediately 通过 queue.sync 同步等待。此前连续保存基准未覆盖每次进程重启后的首次保存，不能据此声称冷发送已解决。

新增只读源代码诊断使用 4800 条合成消息，每次重新启动独立模拟器进程，使用实际存储源码和优化编译。三轮结果：

| 版本 | 加载中位数 | 重启后首次保存中位数 | 第二次保存中位数 |
| --- | ---: | ---: | ---: |
| 已装 4978 | 625.91 ms | 657.36 ms | 20.61 ms |
| 未装 4979 工作改动 | 1236.31 ms | 57.89 ms | 19.01 ms |

4978 首次保存中备份阶段约 638–648 ms，第二次约 5–6 ms。这确认存储层存在冷/热差异，但未定位用户真机这次卡顿的全部原因。

4979 工作改动去掉重复的库内恢复路径，并将备份读取提前至加载；数据说明这主要移动等待，不能宣称消除总开销。该提前加载改动已放弃。用户随后明确希望继续优化、不要求配合真机复现；现在改为持久化提交代次驱动的记录复制，继续同一候选的验证及已授权装机。不要把工作目录 build 4979 当作手机当前版本，也不要直接回退到不识别新数据库的 4977。

证据：`work/verification/cold/` 下 harness、两版存储源/编译命令日志、逐轮原始输出及 `cold-results.json`；`work/verification/device-apps-cold-check.json` 为装机版本回读。仅合成数据，无手机聊天副本。

## Final 4979 approach

The final candidate no longer decodes or retains a backup snapshot during ordinary loading or saving. It applies persisted changed records directly to the independent previous-generation database. One-time legacy/4978 alignment occurs during initialization; routine launches retain primary-only loading. Full source and restart logs: `cold-4979-final`, `4979-final-run-*.log`. Measurements and final validation are appended after completion.

## Final paired measurements

After the Release compiler exited, alternate the optimized actual 4978 and final 4979 executables across three new-process runs, on the same simulator with 4800-message synthetic stores. Keep every raw run, including the slower first OS-cache run. Median results:

| Version | Load | First save after reopen | Second save |
| --- | ---: | ---: | ---: |
| 4978 | 641.04 ms | 651.52 ms | 19.54 ms |
| Final 4979 | 630.51 ms | 27.03 ms | 18.98 ms |

These are post-upgrade restarts. One-time 4978 alignment remains a full encoded-record copy during initialization; it is not counted as ordinary startup or hidden as a warm save. The concurrent-build diagnostics in `4979-final-run-*.log` are retained but are not used for this comparison. Raw paired results: `work/verification/cold/paired-final-results.json` and `paired-final-*.log`. No physical-device performance result is claimed.

Final hosted XCTest: 18/18 passed (`record-tests-4979-final.xcresult`). Real process-death harness: old complete snapshot after exit before commit, new complete snapshot after exit after commit (`crash/results-4979.json`). Final 4978 → 4979 → 4978 → 4979 synthetic interoperability preserved 4802 record keys and all 4801 unaffected encoded records byte-for-byte (`interoperability-final.json`).
