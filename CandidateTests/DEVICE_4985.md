# 4985 删除交接候选部署记录

2026-09-09，用户授权规划、实现并安装删除消息修复。候选目录 `mocca-message-deletion-handoff-4985-a`，分支 `codex/message-deletion-handoff-4985`；精确 4984 源码基线提交 `70b13ed`，最终产品修改提交 `8ca8b7d`。不包含其他滚动候选和未实装的 4958 折叠机制。

产品差异仅 RootView.swift 和主程序/扩展构建号。RootView 新增 249 行、删除 555 行，净减少 306 行，其余 40 个产品 Swift 文件与已部署 4984 一致。

最终 generic iOS 签名 Release 构建成功。主 App 和扩展均 0.1.0 (4985)、arm64、严格签名通过、Mach-O/dSYM UUID 匹配，已签名 application-identifier 精确匹配各自 Bundle；同开发团队的通配符 profile 覆盖该标识、包含目标设备且未过期。初次校验脚本把 profile 误要求为精确 Bundle 字符串，已修正为校验通配符授权范围，同时仍严格核验签名内实际 Bundle 标识；此校验脚本变更不涉及产品源码或构建参数。

iPhone 17 Pro 上 com.uuzsama450.mocca.migration 已从 4984 同 Bundle 覆盖至 4985；安装、启动、版本读回成功，当前安装目录下主程序与 GenerationActivityExtension 进程均存在。另一份 com.uuzsama450.mocca 保持 4957。

28 项产品方法离线行为检查、24,576 组存留集合检查和 22 项原聊天归属检查通过。没有运行新的模拟器或真机复现场景。删除后是否仍出现空白、阅读位置与性能等手机交互验收仍待用户确认。

未卸载、清数据、导入或复制聊天，未新增聊天备份；未进行聊天字节级比对。原 4984 签名回退包仍在原候选 work/verification/build-derived/Build/Products/Release-iphoneos/Mocca.app，签名已复核。

证据目录 work/verification/ 包含源码清单及 SHA-256、source-scope.json、deletion-handoff-tests.log、ownership-tests.log、最终 build-signed-4985.log、artifact-4985-verification.json、install-4985.json、launch-4985.json、apps-after-4985.json、processes-after-4985.json、result.json。先前一次主动中断构建及输入框复查前的成功构建日志只作过程记录，最终结论取最终构建和对应源码哈希。
