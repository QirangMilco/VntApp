import Foundation
import NetworkExtension

final class VPNManager {
  static let shared = VPNManager()

  private var extensionBundleIdentifier: String {
    if let explicit = Bundle.main.object(forInfoDictionaryKey: "APP_EXTENSION_BUNDLE_ID") as? String,
       !explicit.isEmpty,
       !explicit.contains("$(") {
      return explicit
    }
    return ""
  }

  private var resolvedExtensionBundleIdentifier: String {
    let embedded = embeddedExtensionBundleIds()
    if embedded.count == 1, let only = embedded.first {
      return only
    }

    let explicit = extensionBundleIdentifier
    if !explicit.isEmpty, embedded.contains(explicit) {
      return explicit
    }

    return explicit
  }
  private let localizedDescription = "VNT VPN"

  private init() {}

  private func embeddedExtensionBundleIds() -> [String] {
    guard let pluginsURL = Bundle.main.builtInPlugInsURL else {
      return []
    }
    guard let urls = try? FileManager.default.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil) else {
      return []
    }

    var result: [String] = []
    for url in urls where url.pathExtension == "appex" {
      if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
        result.append(bid)
      }
    }
    return result
  }

  private func matchManager(_ manager: NETunnelProviderManager) -> Bool {
    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
      return false
    }
    let bundle = proto.providerBundleIdentifier ?? ""
    let target = resolvedExtensionBundleIdentifier
    return !target.isEmpty && bundle == target
  }

  private func pickManager(from managers: [NETunnelProviderManager]?) -> NETunnelProviderManager? {
    guard let managers else { return nil }
    if let exact = managers.first(where: { matchManager($0) }) {
      return exact
    }
    if let byDesc = managers.first(where: { $0.localizedDescription == localizedDescription }) {
      return byDesc
    }
    return nil
  }

  func startVpn(with config: [String: Any], completion: @escaping (Int, Error?) -> Void) {
    NSLog("[iOS VPN] startVpn called: keys=\(Array(config.keys).sorted())")
    if let vntJson = config["vntConfigJson"] as? String {
      NSLog("[iOS VPN] vntConfigJson length=\(vntJson.count)")
    } else {
      NSLog("[iOS VPN] vntConfigJson missing")
    }
    do {
      SharedTunnelRuntimeState.clear()
      SharedTunnelRuntimeState.save(state: "starting")
      let shared = SharedTunnelConfig(dict: config)
      try shared.saveToAppGroup()
      NSLog("[iOS VPN] shared config saved: appGroup=\(SharedTunnelConfig.appGroup), ip=\(shared.virtualIp), netmask=\(shared.virtualNetmask), gateway=\(shared.virtualGateway), routeCount=\(shared.externalRoute.count)")
    } catch {
      NSLog("[iOS VPN] save shared config failed: \(error.localizedDescription)")
      completion(0, error)
      return
    }

    loadOrCreateManager { [weak self] manager, error in
      guard let self else {
        completion(0, NSError(domain: "VPNManager", code: -99, userInfo: [NSLocalizedDescriptionKey: "VPNManager 已释放"]))
        return
      }
      guard let manager else {
        completion(0, error ?? NSError(domain: "VPNManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法初始化 VPN 管理器"]))
        return
      }

      let extBundleId = self.resolvedExtensionBundleIdentifier
      guard !extBundleId.isEmpty else {
        NSLog("[iOS VPN] APP_EXTENSION_BUNDLE_ID missing")
        completion(0, NSError(domain: "VPNManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "缺少 APP_EXTENSION_BUNDLE_ID，请在 Xcode Build Settings 或 xcconfig 中配置"] ))
        return
      }

      let embedded = self.embeddedExtensionBundleIds()
      NSLog("[iOS VPN] embedded appex bundleIds=\(embedded)")
      guard !extBundleId.isEmpty, embedded.contains(extBundleId) else {
        completion(0, NSError(domain: "VPNManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "未解析到可用扩展标识，resolved=\(extBundleId)，embedded=\(embedded)"]))
        return
      }

      let proto = NETunnelProviderProtocol()
      proto.providerBundleIdentifier = extBundleId
      proto.serverAddress = (config["tunnelServerAddress"] as? String) ?? "vnt"
      proto.providerConfiguration = [
        "appGroup": SharedTunnelConfig.appGroup,
        "tunnelConfig": config,
      ]

      manager.protocolConfiguration = proto
      manager.localizedDescription = self.localizedDescription
      manager.isEnabled = true

      manager.saveToPreferences { saveError in
        if let saveError {
          NSLog("[iOS VPN] saveToPreferences failed: \(saveError.localizedDescription)")
          completion(0, saveError)
          return
        }

        manager.loadFromPreferences { loadError in
          if let loadError {
            NSLog("[iOS VPN] loadFromPreferences failed: \(loadError.localizedDescription)")
            completion(0, loadError)
            return
          }

          do {
            try manager.connection.startVPNTunnel()
            NSLog("[iOS VPN] startVPNTunnel invoked")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
              NSLog("[iOS VPN] post-start status t+0.3s: \(manager.connection.status.rawValue)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
              NSLog("[iOS VPN] post-start status t+1.0s: \(manager.connection.status.rawValue)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
              NSLog("[iOS VPN] post-start status t+2.0s: \(manager.connection.status.rawValue)")
            }

            completion(1, nil)
          } catch {
            NSLog("[iOS VPN] startVPNTunnel failed: \(error.localizedDescription)")
            completion(0, error)
          }
        }
      }
    }
  }

  func stopVpn() {
    loadOrCreateManager { manager, _ in
      manager?.connection.stopVPNTunnel()
      SharedTunnelRuntimeState.save(state: "stopped")
    }
  }

  func isVpnRunning() -> Bool {
    return currentStatus() == .connected || currentStatus() == .connecting || currentStatus() == .reasserting
  }

  func currentStatus() -> NEVPNStatus {
    var status: NEVPNStatus = .invalid
    let semaphore = DispatchSemaphore(value: 0)

    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
      defer { semaphore.signal() }
      guard let self else { return }
      if let manager = self.pickManager(from: managers) {
        status = manager.connection.status
      }
    }

    _ = semaphore.wait(timeout: .now() + 1)
    return status
  }

  private func statusPayload(status: NEVPNStatus) -> [String: Any] {
    let sharedState = SharedTunnelRuntimeState.load()
    return [
      "vpnStatus": mapStatus(status),
      "vpnStatusRaw": status.rawValue,
      "isRunning": status == .connected || status == .connecting || status == .reasserting,
      "runtimeState": sharedState?.state ?? "unknown",
      "runtimeMessage": sharedState?.message as Any,
      "runtimeUpdatedAt": sharedState?.updatedAt as Any,
    ]
  }

  func runtimeStatus() -> [String: Any] {
    // 同步接口不再阻塞等待系统查询，避免主线程卡死导致恒 invalid。
    return statusPayload(status: .invalid)
  }

  func runtimeStatusAsync(completion: @escaping ([String: Any]) -> Void) {
    loadOrCreateManager { [weak self] manager, _ in
      guard let self else {
        completion(["vpnStatus": "unknown", "vpnStatusRaw": -1, "isRunning": false, "runtimeState": "unknown"])
        return
      }

      let status = manager?.connection.status ?? .invalid
      var merged = self.statusPayload(status: status)
      merged["lastDisconnectError"] = nil
      merged["lastDisconnectErrorDomain"] = nil
      merged["lastDisconnectErrorCode"] = 0

      guard let session = manager?.connection as? NETunnelProviderSession else {
        completion(merged)
        return
      }

      let request = ["action": "status"]
      guard let requestData = try? JSONSerialization.data(withJSONObject: request, options: []) else {
        completion(merged)
        return
      }

      do {
        try session.sendProviderMessage(requestData) { data in
          guard
            let data,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
          else {
            completion(merged)
            return
          }

          merged["extensionRunning"] = obj["running"] as? Bool ?? false
          merged["extensionState"] = obj["state"] as? String ?? "unknown"
          merged["extensionMessage"] = obj["message"]
          merged["extensionUpdatedAt"] = obj["updatedAt"]
          merged["extensionUptimeSec"] = obj["uptimeSec"]
          merged["extensionPacketsFromSystem"] = obj["packetsFromSystem"]
          merged["extensionPacketsToSystem"] = obj["packetsToSystem"]
          merged["extensionBytesFromSystem"] = obj["bytesFromSystem"]
          merged["extensionBytesToSystem"] = obj["bytesToSystem"]
          merged["extensionOutputQueueLen"] = obj["outputQueueLen"]
          merged["extensionOutputDropped"] = obj["outputDropped"]
          merged["extensionPollErrorCount"] = obj["pollErrorCount"]
          merged["extensionLastErrorCode"] = obj["lastErrorCode"]
          merged["extensionIpv6Enabled"] = obj["ipv6Enabled"]
          merged["extensionIpv6MapSize"] = obj["ipv6MapSize"]
          merged["extensionIpv6MapMissCount"] = obj["ipv6MapMissCount"]
          merged["extensionIpv6CompatDowngradeCount"] = obj["ipv6CompatDowngradeCount"]
          merged["extensionVirtualIp"] = obj["virtualIp"]
          merged["extensionVirtualNetmask"] = obj["virtualNetmask"]
          merged["extensionVirtualGateway"] = obj["virtualGateway"]
          merged["extensionVirtualNetwork"] = obj["virtualNetwork"]
          merged["extensionTunnelServerAddress"] = obj["tunnelServerAddress"]
          merged["extensionRouteCount"] = obj["routeCount"]
          merged["extensionConfigUpdatedAt"] = obj["configUpdatedAt"]
          merged["extensionPeerDevices"] = obj["peerDevices"]
          merged["extensionCurrentStatus"] = obj["currentStatus"]
          merged["extensionRustLastError"] = obj["rustLastError"]
          merged["extensionRustLastErrorCode"] = obj["rustLastErrorCode"]
          merged["extensionAppliedVirtualIp"] = obj["appliedVirtualIp"]
          merged["extensionAppliedVirtualNetmask"] = obj["appliedVirtualNetmask"]
          merged["extensionAppliedVirtualGateway"] = obj["appliedVirtualGateway"]
          merged["extensionDebugEvents"] = obj["debugEvents"]
          completion(merged)
        }
      } catch {
        merged["extensionMessage"] = error.localizedDescription
        completion(merged)
      }
    }
  }

  private func loadOrCreateManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      if let error {
        completion(nil, error)
        return
      }
      guard let self else {
        completion(nil, NSError(domain: "VPNManager", code: -98, userInfo: [NSLocalizedDescriptionKey: "VPNManager 已释放"]))
        return
      }

#if DEBUG
      if let managers {
        NSLog("[iOS VPN] loadAllFromPreferences managers=\(managers.count)")
        for (idx, m) in managers.enumerated() {
          let proto = m.protocolConfiguration as? NETunnelProviderProtocol
          let bid = proto?.providerBundleIdentifier ?? ""
          NSLog("[iOS VPN] manager[\(idx)]: enabled=\(m.isEnabled) status=\(m.connection.status.rawValue) bundle=\(bid) desc=\(m.localizedDescription ?? "")")
        }
      } else {
        NSLog("[iOS VPN] loadAllFromPreferences managers=0")
      }
#endif

      if let manager = self.pickManager(from: managers) {
        completion(manager, nil)
      } else {
        NSLog("[iOS VPN] no matched manager, create new")
        completion(NETunnelProviderManager(), nil)
      }
    }
  }

  private func mapStatus(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid:
      return "invalid"
    case .disconnected:
      return "disconnected"
    case .connecting:
      return "connecting"
    case .connected:
      return "connected"
    case .reasserting:
      return "reasserting"
    case .disconnecting:
      return "disconnecting"
    @unknown default:
      return "unknown"
    }
  }
}
