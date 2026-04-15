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
