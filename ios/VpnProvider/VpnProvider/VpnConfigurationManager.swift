import Foundation
import NetworkExtension

class VpnConfigurationManager {
    
    static let shared = VpnConfigurationManager()
    
    private let appGroupName = "group.com.vntapp.shared"
    private let vpnManager = NEVPNManager.shared()
    
    // 配置VPN管理器
    func setupVpnManager() {
        vpnManager.loadFromPreferences { error in
            if let error = error {
                print("Failed to load VPN preferences: \(error.localizedDescription)")
                return
            }
            
            let config = NETunnelProviderManager()
            config.loadFromPreferences { error in
                if let error = error {
                    print("Failed to load tunnel provider preferences: \(error.localizedDescription)")
                    return
                }
            }
        }
    }
    
    // 创建VPN配置
    func createVpnConfiguration(vpnConfig: [String: Any], completion: @escaping (Error?) -> Void) {
        let providerProtocol = NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = "com.vntapp.VpnProvider"
        providerProtocol.serverAddress = vpnConfig["serverAddress"] as? String ?? "10.0.0.1"
        
        // 设置VPN配置参数
        var providerConfiguration: [String: Any] = [:]
        providerConfiguration["virtualIp"] = vpnConfig["virtualIp"] as? String
        providerConfiguration["virtualNetmask"] = vpnConfig["virtualNetmask"] as? String
        providerConfiguration["virtualGateway"] = vpnConfig["virtualGateway"] as? String
        providerConfiguration["virtualNetwork"] = vpnConfig["virtualNetwork"] as? String
        
        if let dnsServers = vpnConfig["dnsServers"] as? [String] {
            providerConfiguration["dnsServers"] = dnsServers
        }
        
        providerProtocol.providerConfiguration = providerConfiguration
        
        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = providerProtocol
        manager.localizedDescription = "VntApp VPN"
        manager.isEnabled = true
        
        // 保存VPN配置
        manager.saveToPreferences { error in
            if let error = error {
                print("Failed to save VPN preferences: \(error.localizedDescription)")
                completion(error)
                return
            }
            
            manager.loadFromPreferences { error in
                if let error = error {
                    print("Failed to load VPN preferences after save: \(error.localizedDescription)")
                    completion(error)
                    return
                }
                
                completion(nil)
            }
        }
    }
    
    // 启动VPN
    func startVpn(completion: @escaping (Error?) -> Void) {
        let manager = NETunnelProviderManager()
        manager.loadFromPreferences { error in
            if let error = error {
                print("Failed to load VPN preferences: \(error.localizedDescription)")
                completion(error)
                return
            }
            
            do {
                try manager.connection.startVPNTunnel()
                completion(nil)
            } catch {
                print("Failed to start VPN tunnel: \(error.localizedDescription)")
                completion(error)
            }
        }
    }
    
    // 停止VPN
    func stopVpn() {
        let manager = NETunnelProviderManager()
        manager.loadFromPreferences { _ in
            manager.connection.stopVPNTunnel()
        }
    }
    
    // 获取VPN连接状态
    func getVpnStatus() -> NEVPNStatus {
        return vpnManager.connection.status
    }
    
    // 保存配置到App Group，供VPN扩展访问
    func saveConfigToAppGroup(config: [String: Any]) {
        if let userDefaults = UserDefaults(suiteName: appGroupName) {
            userDefaults.set(config, forKey: "vntConfig")
            userDefaults.synchronize()
        }
    }
    
    // 从App Group读取配置
    func loadConfigFromAppGroup() -> [String: Any]? {
        if let userDefaults = UserDefaults(suiteName: appGroupName) {
            return userDefaults.dictionary(forKey: "vntConfig")
        }
        return nil
    }
}