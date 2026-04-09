# iOS 后台长期稳定可用改造计划

## 目标
将当前“App 进程内 Rust + Extension 仅转发 pipe”的架构，改为“Extension 进程内持续转发”，避免 App 进入后台后 pipe 断裂导致 VPN 失效。

## 验收标准
1. App 进入后台 10 分钟后，仍可从 iPhone 访问 `10.26.0.4` / `10.26.0.70` 服务。
2. 后台期间不再出现 `write total_length header failed: Broken pipe`。
3. 不依赖 App 前台保活，`PacketTunnelExtension` 独立维持数据面。
4. 前后台切换后无需手动重连。

## 一步一规划（小步执行）

### 步骤 1：收敛当前架构入口（仅梳理，不改行为）
- 梳理 `VPNManager.startVpn`、FD 传递、`ios_stub/device` 依赖链。
- 明确哪些 Rust 调用必须在 App 进程，哪些可迁移到 Extension。
- 输出“可迁移最小闭环”清单（控制面/数据面/日志）。

### 步骤 2：在 Extension 内实现最小数据面闭环（首次可运行版本）
- 在 `PacketTunnelProvider` 内启动独立转发工作线程（不依赖 App pipe 存活）。
- 保留现有配置下发方式，先实现 ICMP 与 TCP 基础转发可持续。
- 将 App->Extension pipe 改为“可选辅助通道”，非必需。

### 步骤 3：重构 Rust 设备抽象（iOS 双模式）
- 引入 iOS 设备双模式：
  - `AppPipeMode`（兼容旧链路）
  - `ExtensionNativeMode`（新后台稳定链路）
- 用显式配置选择模式，默认切到 `ExtensionNativeMode`。

### 步骤 4：清理会触发后台断连的调用路径
- 审核并调整 `main.dart`、`vnt_manager.dart` 中与 `stopVpn/stopVpnIfConnected/removeAll` 相关时机。
- 避免前后台切换期间误触发主动断开。

### 步骤 5：补齐可观测性与回归验证
- 保留并整理 `iOS ICMP TRACE`，新增 TCP 服务访问关键日志。
- 验证矩阵：
  - 前台连接、后台 10 分钟、回前台、锁屏/解锁。
  - `ping` + TCP 端口访问（10.26.0.4、10.26.0.70）。
- 通过后移除临时噪声日志，保留核心诊断点。

## 风险与对策
- 风险：Extension 内资源限制导致线程模型不稳。
  - 对策：先实现最小可用转发，再逐步恢复高级特性。
- 风险：控制面仍在 App 导致重连行为复杂。
  - 对策：短期先保持控制面兼容，后续再做完全内聚。
- 风险：历史兼容路径回归。
  - 对策：双模式并存，回滚开关可控。

## 交付顺序
1. 先完成步骤 1-2，拿到“后台 10 分钟仍可 ping/访问服务”的第一版。
2. 再做步骤 3-4 结构化清理。
3. 最后做步骤 5 收口。