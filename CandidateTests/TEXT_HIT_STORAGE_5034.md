# 5034 判空读取 UIKit 验证

`prepare_text_hit_storage_harness.py` 只准备独立测试 App 的 Swift 源码、Info.plist 和命令清单，不编译、签名、启动或操作任何设备。

从明确的基线目录和本候选 `MessageMarkdownView.swift` 提取 `isPointNearGlyph` / `isPointNearVisibleGlyph` 的真实方法体。生成器要求两版只差 `attributedText.length` → `textStorage.length`；供测试调用时仅去掉方法的 `private`。

```sh
/usr/bin/python3 CandidateTests/prepare_text_hit_storage_harness.py --baseline-root "${MOCCA_WORKSPACE}/work/candidates/mocca-tools-transition-refresh-5033-a"
```

输出在 `work/verification/text-hit-storage-5034/`。由负责执行的主任务读取 `manifest.json` 中的 `build_command` 和 `sign_command` 数组顺序执行，再将 `app` 安装到它选定的任务模拟器，启动 `bundle_id`。App 写出 `Documents/text-hit-storage-results.json`，输出 PASS/FAIL 后退出；失败 exit 1，写报告失败 exit 2。准备状态 `PREPARED_NOT_EXECUTED` 不代表运行通过。

验证用两套独立、同配置的真实 NSTextStorage / NSLayoutManager / UITextView。它们各自跨内容更新复用，不共享布局；逐点交替先查候选或基线。内容包括空、中文、多行、组合 emoji、附件、链接，以及长→短→清空→恢复，两种宽度、两种实际命中算法。

`first-query` 是每次赋值后、测试未主动 ensureLayout 之前的固定点查询；UIKit 本身仍可能因 setter/布局提前准备内容，不能称为绝对冷启动。之后按真实 glyph 矩形生成中心和容差边沿查询，并重复一遍。整个测试不是性能基准。

每批逐点判断相等，基线 getter 至少读取一次/查询，候选 getter 必须零读取；同一 UITextView 子类只在查询期间计数，初始赋值/fixture 准备不计入。空内容必须全部不命中，非空 fixture 必须实际覆盖至少一个可命中的原生 glyph，防止两版都恒返回 false 而假通过。

这里使用真实 TextKit 查询，而非手写 glyph/layout mock。宿主用标准 NSLayoutManager，因为产品自定义 manager 重写的是绘制；没有复制绘制、选区手柄、完整 SwiftUI 行或侧栏手势。真实选字、反应、链接动作、群聊与手机性能仍需产品交互验收。

`MOCCA_WORKSPACE` is the local development checkout containing the historical `work/` evidence; those private artifacts are not distributed with this repository.
