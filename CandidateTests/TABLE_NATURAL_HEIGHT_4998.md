# 4998 Markdown 表格自然高度修复

基于手机 `0.1.0 (4997)` 的源码 `f132927f7099d300af4b6a14fc70f65729ece529`，新分支 `codex/table-natural-height-4998`。4997 原分支与签名安装产物保留；基线 46 份构建输入重新校验一致。

## 问题与改动

长短单元格混合时，原表格 Grid 的短行在实际放置时被额外拉高，整张表格因此超过横向 ScrollView 采用的高度；后续正文与操作栏按原来的总高度继续排列，表现为覆盖表格，以及滚动已到底但还有表格内容在下面。

仅在 `MarkdownTableBlock` 的 Grid 后增加 `.fixedSize(horizontal: false, vertical: true)`，使其测量和放置使用自然行高。保留单元格 `maxHeight: .infinity`，从而保留同一行各格等高、背景铺满；列宽、字号、换行、内边距、网格样式、横向滚动与选择菜单均未修改。

没有增加测高状态、缓存、延时、重试、滚动补偿或内容重建。版本配置主程序和扩展统一为 4998。除该 Swift 文件和版本配置，原 46 份构建输入中其余内容均与 4997 一致。

## 真机原生样本

在 iPhone 17 Pro 上运行独立 SwiftUI 小宿主，直接提取 4997 `MarkdownTableBlock`，仅加入后台几何探针和单变量开关；表格解析类型直接提取原文件。测试宿主使用系统字体、SwiftUI 前后正文、生成的表格内容，单元格菜单与横向手势登记用空实现，不读取聊天，也不调用模型服务。

宽度 356 / 320 / 500；行距 4 / 8；数据行数 1 / 3 / 8 / 16；每个场景分别记录初始内容与追加长文后状态，共 48 个场景。

| 单变量 | Grid 超出横向宿主 | 表格文字越过后正文起点 | 同一行单元格不等高 |
|---|---:|---:|---:|
| 4997 原始结构 | 48/48 | 42/48 | 0/48 |
| 仅 Grid 垂直自然高度 | 0/48 | 0/48 | 0/48 |
| 仅横向 ScrollView 垂直自然高度 | 48/48 | 42/48 | 0/48 |
| 仅移除单元格可伸展高度 | 0/48 | 0/48 | 48/48 |

具体样本：356 宽、一行数据、行距 4、追加长文后，表头自然高 39.667，却在原实现中被拉到 332.583；Grid 实际高 958.750，横向宿主高 666.833。修复后表头恢复 39.667，Grid 高 665.833，加上下各 0.5 边框正好被宿主容纳。

修复前后全部 1,152 个文字 frame 的宽高一致，宿主、后正文及操作栏的 frame 也一致；48 个样本的 Grid 超高均可由各行额外拉伸高度解释。修复消除了 Grid 内部多余高度，没有挪动操作栏或裁掉文字。

现有记录直接观测到了各层 frame，没有直接记录 SwiftUI 的 proposal 分配算法；“有限高度触发 flexible row 分配”是机制解释，不能说已观察到框架内部代码。

## 证据与复核

真机宿主、提取源文件、四组有效日志、签名构建/安装/卸载记录位于基线目录：

`../mocca-chat-render-work-reuse-4997-a/work/verification/table-height-ios-host/`

有效修复日志为 `gridNatural-correct-console.log`。第一次 `gridNatural-console.log` 因入口将字面量 `--` 识别成变体而运行了 baseline，不能用作修复结果；其全部 frame 与首次 baseline 完全一致，保留为重复基线记录。其他有效变体均核验了日志内部 variant。

运行记录对比检查：

```sh
/usr/bin/python3 CandidateTests/check_table_height_frames.py \
  ../mocca-chat-render-work-reuse-4997-a/work/verification/table-height-ios-host/baseline-console.log \
  ../mocca-chat-render-work-reuse-4997-a/work/verification/table-height-ios-host/gridNatural-correct-console.log \
  --output work/verification/table-height-device-comparison.json
```

检查 PASS：匹配场景、完整几何快照、原版确实复现、修复后表格及消息边界、文字尺寸不变、行内等高、自然行高均通过。两位独立源码/日志复核未发现阻断问题。

macOS 独立 48 场景与额外 4 场景去 Layout 探针复核也得到相同方向，记录位于基线 `work/verification/table-height-macos-host/`。它是辅助证据，不替代 iOS。

临时宿主使用独立 Bundle ID `com.uuzsama450.mocca.tableheightprobe`，验证结束已卸载，返回原 Mocca 4997；未卸载或读取 Mocca 数据容器。

## 验收边界

样本是实际 iPhone 的原生布局证据，尚不等于完整 App 原消息验收。还需确认原故障聊天的最后一行、后正文、操作栏与真实滚动底部；同时看流式结束、重新进入聊天、代码块混排、选择菜单及横向滑动。

没有测量正常聊天/侧栏帧率，不承诺零布局成本；没有新增每帧任务或解析工作。对最低支持 iOS 版本及其他系统版本的完整矩阵尚未执行。

## 完整 App 构建与部署

修复提交 `ab8bc16`。唯一一次完整 4998 Release 构建成功；既有 UITextItemInteraction 弃用和 AppIntents 元数据跳过提示仍在，没有编译错误。46 份冻结输入构建后全部一致。主程序/扩展签名、arm64、4998 版本和 dSYM UUID 匹配通过，描述文件与已验证包含目标手机的 4997 完全一致且仍有效。4997 回退产物的主程序/扩展签名与二进制哈希重新通过。

2026-09-11 01:53（Asia/Shanghai）在 iPhone 17 Pro 完成同 Bundle ID 覆盖安装并普通模式启动；设备回读 `0.1.0 (4998)`，启动参数为空，主进程 PID 1483、扩展 PID 1484 均匹配新安装路径。证据为 `work/verification/artifact-4998.json`、`deployment-4998.json` 及对应原始构建、安装、启动、应用和进程记录。

没有卸载 Mocca、清理或读取聊天容器，也没有新建聊天备份；未采集聊天逐字节一致性证明。真机小宿主的布局回归通过，完整 App 原故障消息与真实交互仍待用户验收。

## 用户回报与影响范围复核

4998 装机后，用户在被请回看原回复后反馈“没有问题诶”。记录为原表格问题的用户真机正向验收，不扩展为所有功能/系统版本通过。此前章节的待验收描述是装机当时的状态。

再查调用点：本约束同时用于 mixedContent 和 legacyContent 的 Markdown 表格，因此助手两种显示样式、开启 Markdown 的用户消息，以及展开且开启 Markdown 的思考内容里的表格都会生效。纯正文/代码块没有执行这处 Grid 约束；含表格的消息高度和滚动范围会随正确行高更新。没有改解析器、文本内容、存储、网络、滚动协调器或高亮。自然行高仍随内容、字体和列宽变化。

风险判断为较低，依据是局部布局约束、有效失败/通过对照、文字尺寸及同行铺底保持、完整构建与原问题的用户验收。仍未覆盖所有自定义字体、超大表格及其他 iOS 版本；未进行帧率对比，不能宣称绝对零成本。
