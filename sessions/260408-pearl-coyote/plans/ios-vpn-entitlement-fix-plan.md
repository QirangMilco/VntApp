# iOS VPN 连接失败修复计划

## 目标
修复点击“连接”后 `NEVPNErrorDomain Code=2` 与 `client is not entitled`，确保真机可成功启动 Packet Tunnel。

## 问题结论
1. `ios/Runner/Runner.entitlements` 与 `ios/PacketTunnelExtension/PacketTunnelExtension.entitlements` 的 `com.apple.security.application-groups` 为空，导致 `container_create_or_lookup_app_group_path_by_app_group_identifier: client is not entitled`。
2. 代码硬编码的扩展 Bundle ID 为 `top.wherewego.vntApp.PacketTunnel`，但工程实际扩展 Bundle ID 是 `io.mt63.v4.extension`（`ios/Runner.xcodeproj/project.pbxproj`）。`providerBundleIdentifier` 不匹配会触发 `NEVPNErrorDomain Code=2`。

## TODO
- [ ] 统一 iOS 标识符（App Group / Extension Bundle ID）
- [ ] 修改 entitlements，写入正确 App Group
- [ ] 修改 Swift 常量，使用实际 extension bundle id
- [ ] 本地静态校验（grep）确认无残留冲突值
- [ ] 给出真机验证步骤与验收标准

## 执行步骤

### 1) 修正 entitlements
- 文件：`ios/Runner/Runner.entitlements`
  - `com.apple.security.application-groups` 改为：
    - `group.io.mt63.v4`
- 文件：`ios/PacketTunnelExtension/PacketTunnelExtension.entitlements`
  - `com.apple.security.application-groups` 改为：
    - `group.io.mt63.v4`

### 2) 修正 Swift 中硬编码标识符
- 文件：`ios/Runner/VPNManager.swift`
  - `appGroupIdentifier`：`group.top.wherewego.vntApp` → `group.io.mt63.v4`
  - `bundleIdentifier` 可删除或保持一致为 `io.mt63.v4`（当前未使用）
  - `tunnelBundleIdentifier`：`top.wherewego.vntApp.PacketTunnel` → `io.mt63.v4.extension`
- 文件：`ios/Runner/AppDelegate.swift`
  - `appGroupIdentifier`：`group.top.wherewego.vntApp` → `group.io.mt63.v4`
- 文件：`ios/PacketTunnelExtension/PacketTunnelProvider.swift`
  - `appGroupIdentifier`：`group.top.wherewego.vntApp` → `group.io.mt63.v4`

### 3) Xcode Signing & Capabilities 对齐（真机必须）
- Runner 与 PacketTunnelExtension 两个 Target：
  - 开启 **App Groups**，并勾选 `group.io.mt63.v4`
  - 开启 **Network Extensions**（Packet Tunnel）
- 确认两者使用同一 Team 下可用的 profile，且 profile 已包含上述能力。

### 4) 验证
- 清理并重装：删除手机旧 App 与旧 VPN 配置后重新安装。
- 连接时日志应满足：
  - 不再出现 `client is not entitled`
  - `startVPNTunnel` 不再报 `NEVPNErrorDomain Code=2`
  - 出现 `Tunnel config saved to shared defaults`、Extension 侧 `startTunnel called`，并进入 `connected`。

## 验收标准
1. 点击连接后不再抛 `PlatformException(VPN_START_FAILED, ... NEVPNErrorDomain error 2)`。
2. App 与 Extension 均能访问同一 App Group 容器。
3. VPN 状态可稳定变为 `connected`，并可正常收发数据。