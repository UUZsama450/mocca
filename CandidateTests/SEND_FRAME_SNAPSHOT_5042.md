# 5042：发送布局检查复用同步快照

基线：用户已确认气泡动画流畅、没有分段的 5041，提交 `fcba0ef2f86db96a3ad7c269c7a5ef904575ad9f`。分支：`codex/send-frame-snapshot-5042`。

## 产品改动

新增同步辅助函数 `hasValidConcreteMessageFrames(for:)`。每批检查先核对一次当前 anchor 与 frame revision，再读取同一份 frame 字典，逐条检查已有几何数据。调用者仍限制窗口最多 24 条。

只替换两处逐条调用 `validConcreteMessageFrame` 的循环；原有单条验证函数不变。没有把快照存入 State 或缓存，也没有跨 await 使用它。

动画时长、滚动目标、发送/流式交接顺序、任务取消和跨 await 身份验证保持 5041 原样；5038 原生侧栏触摸分配也完整保留。版本号更新为 1.0（5042），测试 Bundle ID 不变。

## 验证

- `check_send_frame_snapshot.py` 从固定 5041 提交和当前源码提取两阶段真实判断，1,450 组结果完全一致。包括 0/1/12/23/24/25/40 条窗口、逐行缺失与无效 frame、过期身份、底部误差边界、无原生采样、暂存回复缺失等。
- 24 条正常窗口下，初始落位判断的 anchor 读取次数 26 → 3；发布后的末尾判断 25 → 2。这是测试 getter 计数，不是 CPU 耗时或 FPS 数据。
- 原有末尾布局策略的 16 项边界测试全部通过。
- 将新 helper 和两处调用替换逆向还原后，RootView 与 5041 逐字节一致。142 项产品输入中仅 RootView 与工程版本号改变，其他 140 项不变。

构建、签名与装机记录保存在主 checkout 的 `work/verification/send-frame-snapshot-5042/`；最新状态以该处 `REPORT.md` 为准。新的真机动画体验和 FPS 不由源码等价检查证明。
