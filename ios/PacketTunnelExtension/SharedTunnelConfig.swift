import Foundation

struct TunnelRoute: Codable {
  let destination: String
  let netmask: String
}

struct SharedTunnelRuntimeState: Codable {
  static let storeKey = "vnt.shared.tunnel.runtime"

  let state: String
  let message: String?
  let updatedAt: TimeInterval

  static func save(state: String, message: String? = nil) {
    guard let defaults = UserDefaults(suiteName: SharedTunnelConfig.appGroup) else { return }
    let value = SharedTunnelRuntimeState(state: state, message: message, updatedAt: Date().timeIntervalSince1970)
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: storeKey)
  }

  static func load() -> SharedTunnelRuntimeState? {
    guard
      let defaults = UserDefaults(suiteName: SharedTunnelConfig.appGroup),
      let data = defaults.data(forKey: storeKey)
    else {
      return nil
    }
    return try? JSONDecoder().decode(SharedTunnelRuntimeState.self, from: data)
  }

  static func clear() {
    guard let defaults = UserDefaults(suiteName: SharedTunnelConfig.appGroup) else { return }
    defaults.removeObject(forKey: storeKey)
  }
}

struct SharedTunnelConfig: Codable {
  static var appGroupOverride: String?

  static var appGroup: String {
    if let override = appGroupOverride, !override.isEmpty {
      return override
    }
    if let value = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_ID") as? String,
       !value.isEmpty,
       !value.contains("$(") {
      return value
    }
    return "group.com.example.vntapp.shared"
  }
  static let storeKey = "vnt.shared.tunnel.config"

  static func sharedLogDirectoryPath() -> String? {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      return nil
    }
    let logs = container.appendingPathComponent("logs", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      return logs.path
    } catch {
      return nil
    }
  }

  let virtualIp: String
  let virtualNetmask: String
  let virtualGateway: String
  let virtualNetwork: String?
  let virtualIpAutoAssigned: Bool
  let mtu: Int
  let externalRoute: [TunnelRoute]
  let dnsServers: [String]
  let tunnelServerAddress: String?
  let vntConfigJson: String?
  let updatedAt: TimeInterval

  init(dict: [String: Any]) {
    self.virtualIp = (dict["virtualIp"] as? String) ?? ""
    self.virtualNetmask = (dict["virtualNetmask"] as? String) ?? ""
    self.virtualGateway = (dict["virtualGateway"] as? String) ?? ""
    self.virtualNetwork = dict["virtualNetwork"] as? String
    self.virtualIpAutoAssigned = (dict["virtualIpAutoAssigned"] as? Bool) ?? false
    self.mtu = (dict["mtu"] as? Int) ?? 1400

    let routes = (dict["externalRoute"] as? [[String: Any]]) ?? []
    self.externalRoute = routes.compactMap { item in
      guard
        let destination = item["destination"] as? String,
        let netmask = item["netmask"] as? String
      else {
        return nil
      }
      return TunnelRoute(destination: destination, netmask: netmask)
    }

    self.dnsServers = (dict["dnsServers"] as? [String]) ?? []
    self.tunnelServerAddress = dict["tunnelServerAddress"] as? String
    self.vntConfigJson = dict["vntConfigJson"] as? String
    self.updatedAt = Date().timeIntervalSince1970
  }

  static func loadFromAppGroup() -> SharedTunnelConfig? {
    guard
      let defaults = UserDefaults(suiteName: appGroup),
      let data = defaults.data(forKey: storeKey)
    else {
      return nil
    }
    return try? JSONDecoder().decode(SharedTunnelConfig.self, from: data)
  }
}
