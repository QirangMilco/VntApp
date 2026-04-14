import Flutter
import Foundation
import UIKit
#if canImport(AppIntents)
import AppIntents
#endif

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let vpnChannelName = "vnt.app/vpn"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "VntVpnChannel") {
      let channel = FlutterMethodChannel(name: vpnChannelName, binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleVpnMethod(call: call, result: result)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  fileprivate static func toggleDefaultConfigConnectionFromShortcut() async throws -> String {
    if isVpnRunningForShortcutToggle() {
      VPNManager.shared.stopVpn()
      return "已断开 VNT 连接"
    }

    let config = try loadDefaultNetworkConfigForShortcut()
    let payload = try buildStartPayload(from: config)

    let fd: Int = try await withCheckedThrowingContinuation { continuation in
      VPNManager.shared.startVpn(with: payload) { fd, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: fd)
        }
      }
    }

    guard fd > 0 else {
      throw NSError(
        domain: "ShortcutVPN",
        code: -2001,
        userInfo: [NSLocalizedDescriptionKey: "VPN 启动失败，返回 fd=\(fd)"]
      )
    }

    let name = (config["config_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "默认配置"
    return "已开始连接：\(name)"
  }

  fileprivate static func isVpnRunningForShortcutToggle() -> Bool {
    if VPNManager.shared.isVpnRunning() {
      return true
    }

    if let runtime = SharedTunnelRuntimeState.load()?.state.lowercased() {
      if runtime == "running" || runtime == "starting" {
        return true
      }
    }

    return false
  }

  fileprivate static func loadDefaultNetworkConfigForShortcut() throws -> [String: Any] {
    let defaults = UserDefaults.standard

    let defaultKey = ["default-key", "flutter.default-key"]
      .compactMap { defaults.string(forKey: $0) }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first(where: { !$0.isEmpty })

    guard let defaultKey, !defaultKey.isEmpty else {
      throw NSError(
        domain: "ShortcutVPN",
        code: -1001,
        userInfo: [NSLocalizedDescriptionKey: "未设置默认配置"]
      )
    }

    // 优先读取 data-key-native（JSON 数组字符串），兼容 flutter. 前缀
    var configJsonList: [String] = []
    if let nativeData = ["data-key-native", "flutter.data-key-native"]
      .compactMap({ defaults.string(forKey: $0) })
      .first,
       let nativeDataBytes = nativeData.data(using: .utf8),
       let parsed = try JSONSerialization.jsonObject(with: nativeDataBytes) as? [String] {
      configJsonList = parsed
    }

    // 回退读取 data-key（StringList），兼容 flutter. 前缀与 NSArray 存储
    if configJsonList.isEmpty {
      for key in ["data-key", "flutter.data-key"] {
        if let list = defaults.array(forKey: key) as? [String], !list.isEmpty {
          configJsonList = list
          break
        }
      }
    }

    guard !configJsonList.isEmpty else {
      throw NSError(
        domain: "ShortcutVPN",
        code: -1002,
        userInfo: [NSLocalizedDescriptionKey: "未读取到配置列表"]
      )
    }

    for item in configJsonList {
      guard let itemBytes = item.data(using: .utf8),
            let obj = try JSONSerialization.jsonObject(with: itemBytes) as? [String: Any] else {
        continue
      }
      let itemKey = (obj["itemKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if itemKey == defaultKey {
        return obj
      }
    }

    throw NSError(
      domain: "ShortcutVPN",
      code: -1003,
      userInfo: [NSLocalizedDescriptionKey: "默认配置不存在或已删除"]
    )
  }

  fileprivate static func buildStartPayload(from config: [String: Any]) throws -> [String: Any] {
    let virtualIp = stringValue(config["ip"])
    let hasStaticIp = !virtualIp.isEmpty
    let virtualNetmask = hasStaticIp ? defaultNetmask(for: virtualIp) : ""
    let virtualGateway = hasStaticIp ? deriveGateway(from: virtualIp) : ""
    let virtualNetwork = hasStaticIp ? deriveNetwork(ip: virtualIp, netmask: virtualNetmask) : ""

    let outIps = stringArray(config["out_ips"])
    let externalRoute = outIps.compactMap { cidrToRoute($0) }

    let vntConfigJson = try buildVntConfigJson(from: config)

    return [
      "virtualIp": virtualIp,
      "virtualNetmask": virtualNetmask,
      "virtualGateway": virtualGateway,
      "virtualNetwork": virtualNetwork,
      "virtualIpAutoAssigned": !hasStaticIp,
      "mtu": intValue(config["mtu"], defaultValue: 1400),
      "dnsServers": stringArray(config["dns"]),
      "tunnelServerAddress": stringValue(config["server_address"]),
      "externalRoute": externalRoute,
      "vntConfigJson": vntConfigJson,
    ]
  }

  fileprivate static func buildVntConfigJson(from config: [String: Any]) throws -> String {
    let token = stringValue(config["token"])
    let deviceId = stringValue(config["device_id"])
    let name = stringValue(config["name"])
    let serverAddress = stringValue(config["server_address"])
    let nameServers = stringArray(config["dns"])
    let stunServer = stringArray(config["stun_server"])
    let inIps = parseInIps(config["in_ips"])
    let outIps = parseOutIps(config["out_ips"])

    let passwordRaw = stringValue(config["password"])
    let ipRaw = stringValue(config["ip"])

    let map: [String: Any] = [
      "token": token,
      "deviceId": deviceId,
      "name": name,
      "serverAddressStr": serverAddress,
      "nameServers": nameServers,
      "stunServer": stunServer,
      "inIps": inIps,
      "outIps": outIps,
      "password": passwordRaw.isEmpty ? NSNull() : passwordRaw,
      "mtu": intOrNull(config["mtu"]),
      "ip": ipRaw.isEmpty ? NSNull() : ipRaw,
      "noProxy": boolValue(config["no_proxy"]),
      "serverEncrypt": boolValue(config["server_encrypt"]),
      "cipherModel": stringValue(config["cipher_model"]),
      "finger": boolValue(config["finger"]),
      "punchModel": stringValue(config["punch_model"]),
      "ports": intArrayOrNull(config["ports"]),
      "firstLatency": boolValue(config["first_latency"]),
      "useChannelType": stringValue(config["use_channel"]),
      "packetLossRate": doubleOrNull(config["packet_loss"]),
      "packetDelay": intValue(config["packet_delay"], defaultValue: 0),
      "portMappingList": stringArray(config["mapping"]),
      "compressor": {
        let value = stringValue(config["compressor"])
        return value.isEmpty ? "none" : value
      }(),
      "allowWireGuard": boolValue(config["allow_wire_guard"]),
      "localIpv4": stringValue(config["local_ipv4"]).isEmpty ? NSNull() : stringValue(config["local_ipv4"]),
      "enableIpv6OverVnt": false,
    ]

    let data = try JSONSerialization.data(withJSONObject: map)
    guard let json = String(data: data, encoding: .utf8) else {
      throw NSError(
        domain: "ShortcutVPN",
        code: -3001,
        userInfo: [NSLocalizedDescriptionKey: "生成 vntConfigJson 失败"]
      )
    }
    return json
  }

  fileprivate static func parseInIps(_ value: Any?) -> [[Any]] {
    let inputs = stringArray(value)
    return inputs.compactMap { item in
      let pair = item.split(separator: ",", omittingEmptySubsequences: false)
      guard pair.count == 2 else { return nil }

      let networkPart = String(pair[0])
      let relayIp = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !relayIp.isEmpty else { return nil }

      let net = networkPart.split(separator: "/", omittingEmptySubsequences: false)
      guard net.count == 2 else { return nil }

      let destination = String(net[0]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard let destinationInt = ipv4ToUInt32(destination) else { return nil }

      let prefix = Int(String(net[1]).trimmingCharacters(in: .whitespacesAndNewlines))
      guard let prefix, prefix >= 0, prefix <= 32 else { return nil }

      let mask = prefixToUInt32(prefix)
      return [destinationInt, mask, relayIp]
    }
  }

  fileprivate static func parseOutIps(_ value: Any?) -> [[Any]] {
    let inputs = stringArray(value)
    return inputs.compactMap { item in
      let net = item.split(separator: "/", omittingEmptySubsequences: false)
      guard net.count == 2 else { return nil }

      let destination = String(net[0]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard let destinationInt = ipv4ToUInt32(destination) else { return nil }

      let prefix = Int(String(net[1]).trimmingCharacters(in: .whitespacesAndNewlines))
      guard let prefix, prefix >= 0, prefix <= 32 else { return nil }

      let mask = prefixToUInt32(prefix)
      return [destinationInt, mask]
    }
  }

  fileprivate static func cidrToRoute(_ cidr: String) -> [String: String]? {
    let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }

    let destination = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = Int(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
    guard let prefix, prefix >= 0, prefix <= 32 else { return nil }

    let netmaskInt = prefixToUInt32(prefix)
    let netmask = ipv4FromUInt32(netmaskInt)
    return [
      "destination": destination,
      "netmask": netmask,
    ]
  }

  fileprivate static func defaultNetmask(for _: String) -> String {
    "255.255.255.0"
  }

  fileprivate static func deriveGateway(from ip: String) -> String {
    let seg = ip.split(separator: ".")
    guard seg.count == 4 else { return "10.26.0.1" }
    return "\(seg[0]).\(seg[1]).\(seg[2]).1"
  }

  fileprivate static func deriveNetwork(ip: String, netmask: String) -> String {
    let ipSeg = ip.split(separator: ".")
    let maskSeg = netmask.split(separator: ".")
    guard ipSeg.count == 4, maskSeg.count == 4 else { return "10.26.0.0" }

    var out: [Int] = []
    for i in 0..<4 {
      let ipPart = Int(ipSeg[i]) ?? 0
      let maskPart = Int(maskSeg[i]) ?? 0
      out.append(ipPart & maskPart)
    }

    return "\(out[0]).\(out[1]).\(out[2]).\(out[3])"
  }

  fileprivate static func ipv4ToUInt32(_ value: String) -> Int? {
    let seg = value.split(separator: ".")
    guard seg.count == 4 else { return nil }

    var result: UInt32 = 0
    for part in seg {
      guard let n = UInt32(part), n <= 255 else { return nil }
      result = (result << 8) | n
    }
    return Int(result)
  }

  fileprivate static func ipv4FromUInt32(_ value: Int) -> String {
    let a = (value >> 24) & 0xFF
    let b = (value >> 16) & 0xFF
    let c = (value >> 8) & 0xFF
    let d = value & 0xFF
    return "\(a).\(b).\(c).\(d)"
  }

  fileprivate static func prefixToUInt32(_ prefix: Int) -> Int {
    if prefix <= 0 { return 0 }
    if prefix >= 32 { return Int(UInt32.max) }
    let mask = UInt32.max << (32 - UInt32(prefix))
    return Int(mask)
  }

  fileprivate static func stringValue(_ value: Any?) -> String {
    if let v = value as? String {
      return v
    }
    return ""
  }

  fileprivate static func stringArray(_ value: Any?) -> [String] {
    guard let arr = value as? [Any] else { return [] }
    return arr.compactMap { item in
      if let v = item as? String {
        return v
      }
      return nil
    }
  }

  fileprivate static func intValue(_ value: Any?, defaultValue: Int) -> Int {
    if let v = value as? Int { return v }
    if let v = value as? NSNumber { return v.intValue }
    if let v = value as? String, let n = Int(v) { return n }
    return defaultValue
  }

  fileprivate static func intOrNull(_ value: Any?) -> Any {
    if let v = value as? Int { return v }
    if let v = value as? NSNumber { return v.intValue }
    if let v = value as? String, let n = Int(v) { return n }
    return NSNull()
  }

  fileprivate static func intArrayOrNull(_ value: Any?) -> Any {
    guard let arr = value as? [Any] else { return NSNull() }
    let out = arr.compactMap { item -> Int? in
      if let v = item as? Int { return v }
      if let v = item as? NSNumber { return v.intValue }
      if let v = item as? String, let n = Int(v) { return n }
      return nil
    }
    return out.isEmpty ? NSNull() : out
  }

  fileprivate static func boolValue(_ value: Any?) -> Bool {
    if let v = value as? Bool { return v }
    if let v = value as? NSNumber { return v.boolValue }
    if let v = value as? String {
      return v == "1" || v.lowercased() == "true"
    }
    return false
  }

  fileprivate static func doubleOrNull(_ value: Any?) -> Any {
    if let v = value as? Double {
      return v == 0 ? NSNull() : v
    }
    if let v = value as? NSNumber {
      let n = v.doubleValue
      return n == 0 ? NSNull() : n
    }
    if let v = value as? String, let n = Double(v) {
      return n == 0 ? NSNull() : n
    }
    return NSNull()
  }

  private func handleVpnMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startVpn":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "startVpn 参数无效", details: nil))
        return
      }

      VPNManager.shared.startVpn(with: args) { fd, error in
        if let error {
          result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
        } else {
          result(fd)
        }
      }

    case "stopVpn":
      VPNManager.shared.stopVpn()
      result(nil)

    case "isRunning":
      result(VPNManager.shared.isVpnRunning())

    case "startVnt":
      // iOS 场景由 Flutter 侧自行驱动配置选择与连接
      result(VPNManager.shared.isVpnRunning())

    case "stopVnt":
      VPNManager.shared.stopVpn()
      result(nil)

    case "getVpnStatus":
      VPNManager.shared.runtimeStatusAsync { status in
        result(status)
      }

    case "getDeviceInfo":
      VPNManager.shared.runtimeStatusAsync { status in
        result([
          "isConnected": status["isRunning"] as? Bool ?? false,
          "configName": "",
          "onlineCount": 0,
          "offlineCount": 0,
          "vpnStatus": status["vpnStatus"] as? String ?? "unknown",
          "runtimeState": status["runtimeState"] as? String ?? "unknown",
          "extensionState": status["extensionState"] as? String ?? "unknown",
          "extensionUptimeSec": status["extensionUptimeSec"] as? Int ?? 0,
        ])
      }

    case "moveTaskToBack", "isTileStart", "getTileConfigKey", "updateWidgetAndTile":
      // Android 专有接口：iOS 侧返回空值或默认值，保持 Flutter 通道兼容
      if call.method == "isTileStart" {
        result(false)
      } else {
        result(nil)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

#if canImport(AppIntents)
@available(iOS 16.0, *)
struct ToggleDefaultConfigIntent: AppIntent {
  static let title: LocalizedStringResource = "切换 VNT 连接"
  static let description = IntentDescription("未连接时连接默认配置，已连接时断开")
  static var openAppWhenRun: Bool = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let message = try await AppDelegate.toggleDefaultConfigConnectionFromShortcut()
    return .result(dialog: IntentDialog(stringLiteral: message))
  }
}

@available(iOS 16.0, *)
struct VntShortcutsProvider: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ToggleDefaultConfigIntent(),
      phrases: [
        "切换 \(.applicationName) 连接",
        "用 \(.applicationName) 连接默认配置",
        "用 \(.applicationName) 断开连接",
      ],
      shortTitle: "切换连接",
      systemImageName: "network"
    )
  }
}
#endif
