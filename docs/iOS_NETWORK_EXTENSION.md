# iOS Network Extension 实现指南

## 概述

本文档描述了 VntApp 的 iOS Network Extension 实现，用于创建 TUN 虚拟网络接口以支持 VPN 功能。

## 架构

```
┌────────────────────────────────────────────────────────────────────┐
│                         iOS App (Flutter)                          │
│  vnt_manager.dart                                                     │
│    └── generateTunFn() ───► VntAppCall.startVpn()                  │
│                                    │                               │
│                     MethodChannel('top.wherewego.vnt/vpn')            │
│                                    ▼                               │
│  AppDelegate.swift ───► VPNManager.swift                            │
│    └── NETunnelProviderManager                                      │
│         └── startVPNTunnel()                                        │
└────────────────────────────┬───────────────────────────────────────┘
                             │ System spawns Extension process
                             ▼
┌────────────────────────────────────────────────────────────────────┐
│              Packet Tunnel Extension (独立进程)                       │
│  PacketTunnelProvider.swift                                           │
│    ├── startTunnel()                                                 │
│    │   ├── 读取 UserDefaults (tunnelConfig)                           │
│    │   ├── 创建 NEPacketTunnelNetworkSettings (IP/路由/DNS)            │
│    │   ├── 设置 MTU                                                   │
│    │   ├── 获取 packetFlow 文件描述符 (fd)                             │
│    │   ├── 启动 Unix Domain Socket server                             │
│    │   ├── 通过 sendmsg(SCM_RIGHTS) 将 fd 传给主 App                   │
│    │   └── 在 UserDefaults 设置 tunnelReady=true                      │
│    └── stopTunnel()                                                  │
└────────────────────────────┬───────────────────────────────────────┘
                             │ fd 通过 Unix Domain Socket (SCM_RIGHTS) 传递
                             ▼
┌────────────────────────────────────────────────────────────────────┐
│                    主 App 进程 (VPNManager.swift)                     │
│  waitForTunnelAndReceiveFd()                                         │
│    ├── 轮询 UserDefaults 等待 tunnelReady=true                       │
│    ├── 连接到 Extension 的 Unix Domain Socket                        │
│    └── 通过 recvmsg(SCM_RIGHTS) 接收 fd                              │
└────────────────────────────┬───────────────────────────────────────┘
                             │ fd 传回 Flutter → Rust FFI
                             ▼
┌────────────────────────────────────────────────────────────────────┐
│                    Flutter Dart / Rust 层                             │
│  Rust FFI ◄── generateTun(fd) ◄── Flutter MethodChannel callback    │
│    └── ios_stub/device.rs                                             │
│         └── Device::new(fd) → 创建 TUN 设备                           │
│              └── 读写 IP 包 (自动添加 utun 4字节头)                     │
└────────────────────────────────────────────────────────────────────┘
```

## 文件描述符传递机制

**核心问题**：NEPacketTunnelProvider 运行在 Extension 独立进程中，创建的 utun fd 不能直接被主 App 使用。

**解决方案**：使用 POSIX 标准的 `sendmsg`/`recvmsg` + `SCM_RIGHTS` 机制跨进程传递文件描述符。

1. Extension 在 App Group 容器中创建 Unix Domain Socket（`vnt_fd.sock`）
2. 主 App 连接到这个 socket
3. Extension 调用 `sendmsg`，将 utun fd 作为 `SCM_RIGHTS` 辅助数据发送
4. 主 App 调用 `recvmsg`，从 `SCM_RIGHTS` 中提取 fd
5. 主 App 将 fd 通过 MethodChannel 传回 Flutter，再传给 Rust FFI

**Socket 路径**：`{AppGroupContainer}/vnt_fd.sock`

## 通信机制

主 App 和 Extension 之间通过两种方式通信：

1. **App Group UserDefaults**：
   - App → Extension: `tunnelConfig` (JSON 编码的 TunnelConfig)
   - Extension → App: `tunnelReady` (Bool), `tunnelReadyTime` (TimeInterval)

2. **Unix Domain Socket** (App Group container)：
   - Extension → App: utun 文件描述符 (via SCM_RIGHTS)

## 文件清单

### 新创建的文件

| 文件 | 说明 |
|------|------|
| `ios/PacketTunnelExtension/PacketTunnelProvider.swift` | NEPacketTunnelProvider 子类，含 fd 转移 |
| `ios/PacketTunnelExtension/Info.plist` | Extension 的 Info.plist (含 NSExtension 配置) |
| `ios/PacketTunnelExtension/PacketTunnelExtension.entitlements` | Extension 的 entitlements (App Group) |
| `ios/PacketTunnelExtension/SharedTunnelConfig.swift` | 共享配置占位文件 |
| `ios/Runner/VPNManager.swift` | NETunnelProviderManager 管理 + fd 接收 |
| `ios/Runner/Runner.entitlements` | 主 App 的 entitlements (Network Extension + App Group) |
| `docs/iOS_NETWORK_EXTENSION.md` | 本文档 |

### 修改的文件

| 文件 | 修改内容 |
|------|----------|
| `ios/Runner/AppDelegate.swift` | 注册 VPN Method Channel (startVpn/stopVpn/moveTaskToBack) |
| `ios/Runner/Info.plist` | 添加 `UIBackgroundModes` → `network-authentication` |
| `lib/vnt/vnt_manager.dart` | iOS 分支调用 MethodChannel；close() 添加 stopVpn；传递 virtualNetwork 和 tunnelServerAddress |

## Xcode 手动配置步骤（重要！）

以下步骤需要在 Xcode 中手动完成：

### 步骤 1：创建 App Group

1. 打开 Xcode → 项目 → Signing & Capabilities
2. 点击 "+ Capability" → 添加 "App Groups"
3. 点击 "+" 添加 App Group：`group.top.wherewego.vntApp`
4. 确保主 App Target 和 Extension Target 都启用了此 App Group

### 步骤 2：创建 Packet Tunnel Extension Target

1. File → New → Target → "Network Extension"
2. Product Name: `PacketTunnelExtension`
3. Bundle Identifier: `top.wherewego.vntApp.PacketTunnel`
4. Language: Swift
5. 取消勾选 "Include Tests"

### 步骤 3：配置 Extension Target

1. 在 Extension Target 的 Build Settings 中：
   - `IPHONEOS_DEPLOYMENT_TARGET` = `12.0`
   - `SWIFT_VERSION` = `5.0`
   - `PRODUCT_BUNDLE_IDENTIFIER` = `top.wherewego.vntApp.PacketTunnel`
   - `CODE_SIGN_ENTITLEMENTS` = `PacketTunnelExtension/PacketTunnelExtension.entitlements`

2. 在 Extension Target 的 Signing & Capabilities 中：
   - 添加 "App Groups" → `group.top.wherewego.vntApp`
   - 添加 "Network Extensions" → 勾选 "Packet Tunnel"

3. 在 Extension Target 的 Info 标签页中：
   - `NSExtensionPrincipalClass` = `$(PRODUCT_MODULE_NAME).PacketTunnelProvider`
   - `NSExtensionPointIdentifier` = `com.apple.networkextension.packet-tunnel`

### 步骤 4：配置主 App Target

1. 在主 App Target 的 Signing & Capabilities 中：
   - 添加 "Network Extensions" → 勾选 "Packet Tunnel"
   - 添加 "App Groups" → `group.top.wherewego.vntApp`

2. 在主 App Target 的 Build Settings 中：
   - `CODE_SIGN_ENTITLEMENTS` = `Runner/Runner.entitlements`

### 步骤 5：添加 Extension Target 的 pbxproj 配置

参考下面的 pbxproj 修改指南，需要添加：
- PBXFileReference: Extension 的所有 Swift/entitlements/plist 文件
- PBXBuildFile: Extension 的编译引用
- PBXGroup: PacketTunnelExtension 目录
- PBXNativeTarget: Extension target 定义
- PBXSourcesBuildPhase: Extension 的源码编译阶段
- PBXFrameworksBuildPhase: Extension 的框架链接阶段（需包含 NetworkExtension.framework）
- PBXResourcesBuildPhase: Extension 的资源编译阶段
- XCBuildConfiguration: Extension 的 Debug/Release/Profile 配置
- XCConfigurationList: Extension 的配置列表
- PBXTargetDependency: Extension 对主 App 的依赖
- PBXContainerItemProxy: Extension 的代理

## pbxproj 修改要点

需要在 `project.pbxproj` 中为 `PacketTunnelExtension` target 添加以下关键配置：

### 1. Framework 依赖
```
NetworkExtension.framework
```

### 2. 源文件
```
PacketTunnelExtension/PacketTunnelProvider.swift
PacketTunnelExtension/SharedTunnelConfig.swift
```

### 3. Entitlements 和 Info.plist
```
INFOPLIST_FILE = PacketTunnelExtension/Info.plist
CODE_SIGN_ENTITLEMENTS = PacketTunnelExtension/PacketTunnelExtension.entitlements
PRODUCT_BUNDLE_IDENTIFIER = top.wherewego.vntApp.PacketTunnel
```

## 注意事项

1. **开发者账号要求**：Network Extension 需要 Apple Developer Program 付费账号（$99/年），且需要在 [Apple Developer Portal](https://developer.apple.com) 中启用 Network Extension 权限。

2. **App Group 必须一致**：主 App 和 Extension 必须使用相同的 App Group ID (`group.top.wherewego.vntApp`)，否则无法共享 UserDefaults 和 Unix Domain Socket。

3. **Bundle Identifier 关系**：Extension 的 Bundle ID 必须是主 App Bundle ID 的子集（前缀匹配）。

4. **Extension 独立进程**：Network Extension 作为独立进程运行，与主 App 有独立的内存空间和生命周期。

5. **fd 传递安全**：SCM_RIGHTS 机制是 POSIX 标准，Apple 文档中未明确禁止用于 App-Extension 通信，但使用了私有 API (`packetFlow.value(forKeyPath: "socket.fileDescriptor")`)。在 App Store 审核中需要注意。

6. **调试 Extension**：在 Xcode 中选择 Extension 的 scheme 进行运行/调试，而不是 Runner 的 scheme。

## TunnelConfig 数据结构

| 字段 | 类型 | 说明 |
|------|------|------|
| virtualIp | String | VPN 分配的虚拟 IP |
| virtualNetmask | String | 子网掩码 |
| virtualGateway | String | 虚拟网关 |
| virtualNetwork | String | VPN 子网（如 10.26.0.0） |
| mtu | Int | MTU 值 |
| tunnelRemoteAddress | String | 隧道远端地址（iOS 必填，通常为 127.0.0.1） |
| tunnelServerAddress | String? | VNT 服务器地址（用于排除路由避免死循环） |
| externalRoutes | [ExternalRoute] | 外部路由列表 |
| dnsServers | [String] | DNS 服务器列表 |

## GitHub Actions 构建修改

在 `.github/workflows/build-ios.yml` 中需要：

1. 确保 pbxproj 文件包含 Extension target
2. 确保 Code Signing 配置正确
3. Extension 的 entitlements 文件被正确引用
