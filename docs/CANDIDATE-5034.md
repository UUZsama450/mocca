# 5034：文字触摸判空直接读取现有存储

5033 真机快速反向记录中，新触摸的文字命中检测采到了 `UITextView.attributedText` 读取、过滤和复制。两条命中函数只需要判断文本是否为空，因此改为读取同一个 `UITextView.textStorage.length`，避免这一步获取富文本的工作。

## 来源与范围

- 基线：`codex/tools-transition-refresh-5033`，`c3a80f246db7d8fc876f1dcd63ac0fdad0f69a41`。
- 候选：`codex/text-hit-storage-5034`，产品提交 `a1b164f5d211587f2c6968cc702bccf9632905f8`，迁移包 `com.uuzsama450.mocca.migration`，版本 `1.0 (5034)`。
- 产品改动：`MessageMarkdownView.swift` 中 `isPointNearGlyph`、`isPointNearVisibleGlyph` 的两处判空；App 与扩展的四个构建号。
- 146 个基线构建输入中，其余 144 个文件与5033构建后哈希一致。5033的签名App和扩展保留且二进制哈希已核对。

该文本视图自建 TextKit 1 的 `NSTextStorage → NSLayoutManager → NSTextContainer`，内容更新同步写入同一存储。新判断每次读取当前长度，没有缓存。选区优先分支、字形布局和几何容差、链接与附件、空白反应区、侧栏方向识别、收尾取消和交接状态均保持原实现。

## 验证与证据

- 范围核验：[scope-proof.json](../work/verification/text-hit-storage-5034/scope-proof.json)。
- 独立 UIKit 对照：从5033与5034源码提取两条实际方法，使用真实文本存储、布局管理器与文本视图；逐点比较内容更新前后的命中结果，并统计 getter 调用。测试只使用合成文本，不访问聊天数据。运行通过：120批、13,704个点位对照全部一致；基线getter读取13,704次，候选为0。见[运行核验](../work/verification/text-hit-storage-5034/harness-runtime-verification.json)。这覆盖直接命中函数的正确性，不代替完整选字／手势界面验收。
- 签名 Release 构建通过，146个产品输入在构建前后保持不变；App／扩展均核对为1.0 (5034)、arm64、严格签名有效，且各自dSYM UUID一致。见[构建结果](../work/verification/text-hit-storage-5034/build-result.json)及[产物核验](../work/verification/text-hit-storage-5034/artifact-verification.json)。
- 已按用户授权，在iPhone 17 Pro上将迁移包5033原位覆盖为5034，并重新读取到1.0 (5034)。正式包5029的版本及安装路径不变。未卸载、清理或复制聊天数据，未启动诊断录制，未主动启动App；没有做聊天数据逐字节相等核验。见[安装核验](../work/verification/text-hit-storage-5034/installation-verification.json)。

模拟器在测试后恢复关闭。独立测试App未进入产品构建；模拟器结果用于正确性验证，不作为iPhone帧率证据。真实选字、反应、链接动作及侧栏手势验收仍待用户体验。

## 收益的证据边界

5033相关窗口内有19个分散的1ms命中测试样本，其中11个包含富文本getter／复制路径；这不是一次19ms调用，也不代表5034每次或总计恰好省下11ms。

本候选只去掉两处判空的getter读取。已观测到的交接状态写入时同步SwiftUI刷新，以及更新完成后的呈现偏差，不在本次改动内。因此不宣称全部卡顿已修复，也不宣称已测得5034真机帧率提升。

后续真机对照应沿用同一条文字聊天、不流式输出，分别检查正常开合与“松手后收尾未结束便反向拖动”；同时检查长按选字、链接、附件、空白反应、思考展开和群聊控件。若这一步收益有限，继续单独调查交接更新，不叠加未经测量的动画调整。
