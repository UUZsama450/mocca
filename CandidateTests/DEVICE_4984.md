# 4984 新助手聊天归属修复真机候选

2026-09-09，用户明确请求安装到当前手机。基于手机原测试版 4982 对应源码 71fbf65；候选为 mocca-orphan-chat-ownership-4982-a，分支 codex/orphan-chat-ownership-4982。仅包含本候选聊天归属修复及构建号变更，不包含其他候选的滚动或工具续答修改。4983 已由另一个候选使用，因此主程序与扩展统一使用 4984。

签名 Release generic iOS 编译成功。主程序与扩展均为 0.1.0 (4984)、arm64，严格签名、Mach-O/dSYM UUID 配对、描述文件有效期与目标设备资格检查通过。手机 iPhone 17 Pro 上 com.uuzsama450.mocca.migration 从 4982 原位覆盖至 4984，安装和启动成功，读回版本 4984，主程序及扩展进程均存在。另一个 com.uuzsama450.mocca 保持 4957。

没有卸载、清空或重新导入数据，没有新增聊天备份。本次未做聊天字节一致性比对。22 项离线检查已通过；部署证据不代表新建助手、重启和完整 ZIP 导入的真机验收。请在手机确认原“新助手”及另建助手不再显示那 7 条无归属旧聊天，原助手聊天与群聊正常。

原 4982 安装包仍在原候选 work/verification/device-4982/derived/Build/Products/Release-iphoneos/Mocca.app，已复核签名与既有 UUID，可供授权后的回退。没有创建重复安装包或存档副本。

部署日志、签名结果、版本与进程读回、源码哈希和结果摘要位于本候选 work/verification/：build-signed-4984.log、artifact-4984-verification.json、install-4984.json、launch-4984.json、apps-after-4984.json、processes-after-4984.json、result.json。
