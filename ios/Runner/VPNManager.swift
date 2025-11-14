import NetworkExtension
import Foundation

class VPNManager {
    
    static let shared = VPNManager()
    
    private var vpnManager: NETunnelProviderManager?
    private var completionHandler: ((Bool, Error?) -> Void)?
    
    // 加载现有的VPN配置
    func loadVPNConfiguration(completion: @escaping (Bool, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                completion(false, error)
                return
            }
            
            if let managers = managers, !managers.isEmpty {
                self?.vpnManager = managers.first
            } else {
                self?.vpnManager = NETunnelProviderManager()
                self?.setupVPNConfiguration()
            }
            
            completion(true, nil)
        }
    }
    
    // 设置VPN配置
    private func setupVPNConfiguration() {
        guard let vpnManager = vpnManager else { return }
        
        let providerProtocol = NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = "com.vntapp.VpnProvider"
        providerProtocol.serverAddress = "vnt-app"
        
        vpnManager.protocolConfiguration = providerProtocol
        vpnManager.localizedDescription = "VntApp VPN"
        vpnManager.isEnabled = true
        
        saveVPNConfiguration {
            print("VPN configuration saved")
        }
    }
    
    // 保存VPN配置
    private func saveVPNConfiguration(completion: @escaping () -> Void) {
        guard let vpnManager = vpnManager else { return }
        
        vpnManager.saveToPreferences { [weak self] error in
            if let error = error {
                print("Failed to save VPN configuration: \(error.localizedDescription)")
                return
            }
            
            vpnManager.loadFromPreferences { error in
                if let error = error {
                    print("Failed to load VPN configuration: \(error.localizedDescription)")
                    return
                }
                completion()
            }
        }
    }
    
    // 启动VPN
    func startVPN(completion: @escaping (Bool, Error?) -> Void) {
        self.completionHandler = completion
        
        loadVPNConfiguration { [weak self] success, error in
            guard success, let self = self else {
                completion(false, error)
                return
            }
            
            guard let vpnManager = self.vpnManager else {
                completion(false, NSError(domain: "VPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "VPN manager not initialized"]))
                return
            }
            
            do {
                try vpnManager.connection.startVPNTunnel()
                completion(true, nil)
            } catch {
                print("Failed to start VPN: \(error.localizedDescription)")
                completion(false, error)
            }
        }
    }
    
    // 停止VPN
    func stopVPN() {
        guard let vpnManager = vpnManager else { return }
        
        if vpnManager.connection.status == .connected || 
           vpnManager.connection.status == .connecting || 
           vpnManager.connection.status == .reasserting {
            vpnManager.connection.stopVPNTunnel()
        }
    }
    
    // 获取VPN状态
    func getVPNStatus() -> String {
        guard let vpnManager = vpnManager else { return "disconnected" }
        
        switch vpnManager.connection.status {
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .disconnecting:
            return "disconnecting"
        case .disconnected:
            return "disconnected"
        case .invalid:
            return "invalid"
        case .reasserting:
            return "reasserting"
        @unknown default:
            return "unknown"
        }
    }
    
    // 保存VPN配置到App Group
    func saveVPNConfigToAppGroup(config: [String: Any]) -> Bool {
        return AppGroupManager.shared.saveDictionary(config, forKey: "vpn_config")
    }
    
    // 请求VPN权限
    func requestVPNAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        loadVPNConfiguration { success, error in
            guard success, let vpnManager = self.vpnManager else {
                print("Failed to load VPN configuration: \(error?.localizedDescription ?? "Unknown error")")
                completion(false, error)
                return
            }
            
            // 检查当前VPN状态
            let currentStatus = vpnManager.connection.status
            print("Current VPN status: \(currentStatus)")
            
            // 检查是否是我们的VPN配置
            if let config = vpnManager.protocolConfiguration as? NETunnelProviderProtocol,
               config.providerBundleIdentifier == "com.vntapp.VpnProvider" {
                // 这是我们的VPN配置
                completion(true, nil)
                return
            }
            
            // 确保VPN配置正确设置
            self.setupVPNConfiguration()
            
            // 保存配置会触发系统的VPN权限请求对话框
            vpnManager.saveToPreferences { saveError in
                if let saveError = saveError {
                    print("Failed to request VPN authorization: \(saveError.localizedDescription)")
                    completion(false, saveError)
                    return
                }
                
                // 重新加载配置以确保状态正确
                vpnManager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        print("Failed to reload VPN configuration after saving: \(loadError.localizedDescription)")
                        // 即使重新加载失败，保存成功也意味着权限请求已发起
                        completion(true, nil)
                    } else {
                        // 权限请求对话框已经弹出，返回成功
                        print("VPN authorization request initiated")
                        completion(true, nil)
                    }
                }
            }
        }
    }
}