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
    defaults.synchronize()
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
    defaults.synchronize()
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
    self.virtualIp = (dict["virtualIp"] as? String) ?? "10.26.0.2"
    self.virtualNetmask = (dict["virtualNetmask"] as? String) ?? "255.255.255.0"
    self.virtualGateway = (dict["virtualGateway"] as? String) ?? "10.26.0.1"
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
