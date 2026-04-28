# 实现记录

## 2026-04-15 iOS 应用内日志恢复

- iOS 当前未恢复 Rust 文件日志，`lib/main.dart` 仍跳过 `initLogWithPath`，原因是启动阶段曾出现白屏卡死。
- 先用 PacketTunnel 扩展现有 `runtimeStatusAsync + debugEvents` 链路恢复应用内可见日志，风险更低。
- `PacketTunnelProvider.debugEvents` 原先仅保留 60 条，且部分关键诊断受 `#if DEBUG` 限制，发布版信息不足；本次已扩大容量并补充关键状态事件。
- 宿主应用日志页现在在 iOS 上走诊断日志模式，不依赖 `vnt-core.log` 文件。
- 若后续要恢复真正的 Rust 文件日志，优先评估：
  1. 初始化时机延后到连接前或扩展内；
  2. logger 全局初始化幂等；
  3. 日志目录迁移到 App Group 共享容器，确保宿主应用可读。

## 2026-04-16 iOS 文件日志恢复（第二阶段）

- 已恢复 iOS 文件日志链路，但不在 `main.dart` 启动阶段初始化，改为 PacketTunnel 启动流程内延后初始化。
- 新增 Rust 导出函数 `vnt_ios_dataplane_init_log`，由扩展调用，初始化目录为 App Group 容器下 `logs`。
- `init_log_with_path` 增加全局幂等保护：已初始化后重复调用直接返回成功，避免重复初始化冲突。
- iOS 日志页改为“优先文件日志，失败回退诊断摘要”：
  - 优先读取 App Group 共享目录 `vnt-core*.log`
  - 若共享文件日志不可用，继续展示现有 iOS 诊断摘要
- 增加诊断字段 `extensionRustFileLogInitCode` / `extensionRustFileLogDir`，用于定位“为什么 iOS 没有生成文件日志”。
- 其他端日志体积上限确认：`10MB * (当前1 + 历史5) ≈ 60MB`，不是无限增长。
- 发布版调试策略保持“足够且不冗余”：保留关键状态/错误/阶段日志，不启用逐包高频 debug 明细。
