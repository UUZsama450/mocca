# 5026：重复聊天查找的位置缓存

作者：Codex。候选基于 5025 `6de779aa2ae86874ebc85387ef92a8caee29ebf6`，因此包含 5025 的两项侧栏中断修复。

## 问题与修改

用户反馈：原长聊天排在列表后面时滚动卡；相同可见内容的新分支排到前面后更顺，回原聊天仍卡。

确认的代码开销：`selectedConversation` 从头查找当前聊天；`selectedMessageProjection` 即使命中消息投影缓存，仍先从头查找聊天的版本选择。这使重复读取的成本与聊天在数组中的位置相关。

现在两个读取点共用一个只存 UUID 和数组位置的缓存。命中先核对请求 ID、下标范围及该位置当前 ID，再返回当前数组中的聊天值。`conversations.didSet` 清空缓存；重排、增删、整表替换和嵌套字段修改均重新查找。保留读取 canonical Observable 数组的动作，确保标题、版本选择和流式内容变化仍会通知界面。

缓存仅一项，不保存聊天资料副本、不扩大到所有聊天的索引字典。跨聊天搜索会替换这一个缓存槽，返回当前聊天时按 ID 重新核对。未将下标带过 await，也未替换写操作的定位规则。首次读取、列表变化后的首次读取及交替查询不同聊天仍可能线性查找。

产品改动仅 `AppModel.swift` 和工程 build number（四处 5025→5026）。存储、RootView、Markdown 渲染和键盘代码与 5025 完全相同。分支继承收藏是另一项待办，本次没有修改该规则。

## 测量

使用从 5025 和本候选提取的真实 getter、投影实现与属性观察器，编译为 macOS Swift 6 `-O` 程序；Conversation/ChatMessage 是合成数据类型。计数版本只给 ID 访问加计数；计时版本不含计数。每个位置先预热，两版交替计时五轮，取中位数。每轮 2,000 次，每次读取 selectedConversation 和已预热消息投影。

修改产品前还独立运行 `--baseline`，保留原始测量。以下为修改后同进程前后对照，均选数组末尾聊天：

| 合成聊天数 | 5025 总耗时 | 5026 总耗时 |
|---|---:|---:|
| 20 | 10.75 ms | 1.68 ms |
| 200 | 94.68 ms | 1.68 ms |
| 1000 | 461.27 ms | 1.65 ms |
| 3000 | 1376.48 ms | 1.55 ms |

3,000 条聊天时，100 次重复读取的聊天 ID 访问数由 600,000 降为 200；新实现只需每次两个身份核对。列表首项原本已是常量工作量，此次测量也没有显示明显退化。

这些结果只证明重复查找的成本被移除，不能换算成 iPhone FPS，也不能证明原长聊天的全部卡顿来自这里。17 Pro 上原聊天/相同内容分支的滚动对照仍待用户方便时验收。

## 验证

- 提取真实实现的 4,805 项等价性与 Observation 检查通过：缓存预热、切换、重排、插入、删除、同长度替换、空表、缺失 ID、重复 ID、标题/版本变化、流式消息变化、跨聊天查询和显式 snapshot。
- 完整 Debug 模拟器构建通过；真实 AppModel 的 6 项 hosted XCTest 全部通过（0 failure），覆盖重排/增删/同长度替换、当前标题与版本、跨聊天搜索、具体收藏版本跳转、Observation 更新和重复 ID 首项语义。构建加测试共 393.35 秒；没有产品测试钩子。
- 4 项模拟器交互回归全部通过（0 failure）：历史阅读位置保持、聊天入场与侧栏、键盘定位、部分拖动与连续往返拖动。测试工程构建加运行共 251.47 秒；测试后已关闭本轮模拟器。
- `git diff --check` 通过。
- 本轮未安装或启动手机上的 App，未读取或迁移手机聊天数据。

## 复现与证据

在候选根目录运行：

```sh
/usr/bin/python3 CandidateTests/check_conversation_lookup_cache.py
/usr/bin/python3 CandidateTests/prepare_conversation_lookup_test_host.py work/verification/conversation-lookup-cache/fresh-hosted
```

第二条只创建独立测试工程，产品源目录直接链接到本候选；不向产品加入测试钩子。它从已有的 StorageSaveTestHost.patch 添加 hosted XCTest target，并处理后来插入的 Swift package 工程段落。

本次证据目录：`work/verification/conversation-lookup-cache/`。

- `baseline-result.json`、`comparison-result.json`：基准、前后对照、源文件 SHA-256 与完整测量。
- `unit-command.json`、`unit.log`、`LookupTests.xcresult`：完整 Debug 模拟器构建及真实 AppModel 测试。
- `ui-command.json`、`InteractionTests.xcresult`：独立 UI 测试工程和交互结果。首次运行在测试开始前因 scheme 引用了旧工程名而退出；只修正测试工程引用后重跑，首次日志保留为 `setup-failed-ui.log`。
- `simulator.json`：本轮独占、只含合成数据的模拟器标识。
- `unit-summary.json`、`ui-summary.json`：从最终 xcresult 提取的通过数量；`source-provenance.json`：源文件指纹。
