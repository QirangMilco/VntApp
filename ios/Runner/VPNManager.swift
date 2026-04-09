import UIKit
import Flutter
import NetworkExtension
import Foundation
import Darwin

// Note: TunnelConfig and ExternalRoute are defined in SharedTunnelConfig.swift
// which is compiled into both the Runner and PacketTunnelExtension targets.

/// VPN Manager for VNT App - handles NEPacketTunnelProviderManager lifecycle
/// Provides a clean API for the Flutter side to start/stop VPN
@objc class VPNManager: NSObject {
    
    static let shared = VPNManager()
    
    private static let appGroupIdentifier = "group.io.mt64.v4"
    private static let bundleIdentifier = "io.mt63.v4"
    private static let tunnelBundleIdentifier = "io.mt63.v4.extension"
    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    
    private var tunnelManager: NETunnelProviderManager?
    /// Queue to protect tunnelManager access and coordinate async operations
    private let managerQueue = DispatchQueue(label: "com.vnt.vpnmanager", qos: .userInitiated)
    private var managerReady = false
    
    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroupIdentifier) ?? UserDefaults.standard
    }
    
    /// Unix Domain Socket path for fd transfer (in App Group container)
    private var socketPath: String {
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        return (containerURL?.appendingPathComponent("vnt_fd.sock").path) ?? "/tmp/vnt_fd.sock"
    }
    
    /// Status callback for Flutter
    var statusHandler: ((String) -> Void)?
    
    // Singleton
    private override init() {
        super.init()
        if Self.isSimulator {
            managerReady = true
            NSLog("[VPNManager] Running on iOS Simulator, NetworkExtension is unavailable")
            return
        }
        loadTunnelManager()
    }
    
    // MARK: - Tunnel Manager Management
    
    private func loadTunnelManager() {
        NSLog("[VPNManager] loadTunnelManager called")
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            self?.managerQueue.async {
                guard let self = self else { return }
                
                if let error = error {
                    let nsErr = error as NSError
                    NSLog("[VPNManager] Error loading tunnel manager: \(error)")
                    NSLog("[VPNManager] Error domain: \(nsErr.domain), code: \(nsErr.code)")
                    NSLog("[VPNManager] Error userInfo: \(nsErr.userInfo)")
                    self.showAlert(title: "VPN 加载失败", message: "\(nsErr.domain) (\(nsErr.code))\n\(nsErr.localizedDescription)\n详情: \(nsErr.userInfo)")
                    // Try to create a fresh one
                    self.doCreateTunnelManager()
                    return
                }
                
                if let manager = managers?.first {
                    self.tunnelManager = manager
                    NSLog("[VPNManager] Loaded existing tunnel manager: enabled=\(manager.isEnabled), desc=\(manager.localizedDescription ?? "nil")")
                    if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                        NSLog("[VPNManager] Protocol: providerBundle=\(proto.providerBundleIdentifier ?? "nil"), server=\(proto.serverAddress ?? "nil")")
                    }
                } else {
                    NSLog("[VPNManager] No existing manager found, creating new one")
                    self.doCreateTunnelManager()
                }
                self.managerReady = true
            }
        }
    }
    
    private func doCreateTunnelManager() {
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = Self.tunnelBundleIdentifier
        tunnelProtocol.providerConfiguration = [:]
        tunnelProtocol.serverAddress = "VNT"
        
        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = "VNT VPN"
        manager.isEnabled = true
        
        NSLog("[VPNManager] Creating new tunnel manager with bundleId=\(Self.tunnelBundleIdentifier)")
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                let nsErr = error as NSError
                NSLog("[VPNManager] ❌ Error saving NEW tunnel manager: \(error)")
                NSLog("[VPNManager] ❌ Error domain: \(nsErr.domain), code: \(nsErr.code)")
                NSLog("[VPNManager] ❌ Error userInfo: \(nsErr.userInfo)")
                self?.showAlert(title: "VPN 创建失败", message: "保存隧道配置出错:\n\(nsErr.domain) (\(nsErr.code))\n\(nsErr.localizedDescription)\n详情: \(nsErr.userInfo)")
                self?.managerReady = true
                return
            }
            
            NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                self?.managerQueue.async {
                    self?.tunnelManager = managers?.first
                    NSLog("[VPNManager] ✅ Tunnel manager created and saved successfully")
                    self?.managerReady = true
                }
            }
        }
    }
    
    // MARK: - Public API
    
    /// Start VPN with the given device configuration
    /// - Parameters:
    ///   - config: Dictionary with keys: virtualIp, virtualNetmask, virtualGateway, virtualNetwork, mtu, externalRoute, dnsServers, tunnelServerAddress
    ///   - completion: Called with the TUN file descriptor when ready, or error
    @objc func startVpn(config: [String: Any], completion: @escaping (Int, Error?) -> Void) {
        NSLog("[VPNManager] startVpn called")

        if Self.isSimulator {
            let error = NSError(
                domain: "VPNManager",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "iOS 模拟器不支持 Network Extension，请在真机上启用 VPN"]
            )
            NSLog("[VPNManager] startVpn blocked on simulator")
            DispatchQueue.main.async { completion(-1, error) }
            return
        }
        
        // Dispatch the entire operation to a background queue to NEVER block the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Build tunnel config
            let tunnelServerAddress = config["tunnelServerAddress"] as? String
            let tunnelConfig = TunnelConfig(
                virtualIp: config["virtualIp"] as? String ?? "",
                virtualNetmask: config["virtualNetmask"] as? String ?? "255.255.255.0",
                virtualGateway: config["virtualGateway"] as? String ?? "",
                virtualNetwork: config["virtualNetwork"] as? String ?? "",
                mtu: config["mtu"] as? Int ?? 1400,
                tunnelRemoteAddress: self.parseServerIPv4(tunnelServerAddress) ?? "127.0.0.1",
                tunnelServerAddress: tunnelServerAddress,
                externalRoutes: self.parseExternalRoutes(config["externalRoute"] as? [[String: String]] ?? []),
                dnsServers: config["dnsServers"] as? [String] ?? []
            )
            
            // Save config to shared defaults for the Extension to read
            if let encoded = try? JSONEncoder().encode(tunnelConfig) {
                self.sharedDefaults.set(encoded, forKey: "tunnelConfig")
                NSLog("[VPNManager] Tunnel config saved to shared defaults")
            }
            
            // Clear previous tunnel ready state
            self.sharedDefaults.removeObject(forKey: "tunnelReady")
            self.sharedDefaults.removeObject(forKey: "tunnelReadyTime")
            
            // Run the actual start on the serial manager queue to coordinate async operations
            self.doStartVpn(tunnelConfig: tunnelConfig, completion: completion)
        }
    }
    
    /// Core start logic — runs on managerQueue, fully async, NEVER blocks
    private func doStartVpn(tunnelConfig: TunnelConfig, completion: @escaping (Int, Error?) -> Void) {
        managerQueue.async { [weak self] in
            guard let self = self else { return }
            
            NSLog("[VPNManager] doStartVpn: managerReady=\(self.managerReady), tunnelManager=\(self.tunnelManager != nil ? "exists" : "nil")")
            
            // If tunnel manager is not ready yet, wait for it
            if !self.managerReady || self.tunnelManager == nil {
                NSLog("[VPNManager] Tunnel manager not ready, waiting...")
                // Re-dispatch after a short delay to check again
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.doStartVpn(tunnelConfig: tunnelConfig, completion: completion)
                }
                return
            }
            
            guard let manager = self.tunnelManager else {
                let error = NSError(domain: "VPNManager", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Tunnel manager not available"])
                NSLog("[VPNManager] ❌ Tunnel manager not available")
                self.showAlert(title: "VPN 启动失败", message: "Tunnel Manager 不可用\n请检查 Network Extension 权限配置")
                DispatchQueue.main.async { completion(-1, error) }
                return
            }
            
            NSLog("[VPNManager] ✅ Manager reloaded, preparing VPN tunnel...")
            self.tunnelManager = manager

            // iOS may persist a disabled/stale manager (e.g. after re-signing/profile changes).
            // NEVPNErrorDomain Code=2 usually means configuration disabled.
            let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
            let bundleMatches = (proto?.providerBundleIdentifier == Self.tunnelBundleIdentifier)
            if !manager.isEnabled || !bundleMatches {
                NSLog("[VPNManager] ⚠️ Manager needs refresh: enabled=\(manager.isEnabled), bundle=\(proto?.providerBundleIdentifier ?? "nil"), expected=\(Self.tunnelBundleIdentifier)")

                let refreshedProto = NETunnelProviderProtocol()
                refreshedProto.providerBundleIdentifier = Self.tunnelBundleIdentifier
                refreshedProto.providerConfiguration = proto?.providerConfiguration ?? [:]
                refreshedProto.serverAddress = proto?.serverAddress ?? "VNT"

                manager.protocolConfiguration = refreshedProto
                manager.localizedDescription = manager.localizedDescription ?? "VNT VPN"
                manager.isEnabled = true

                manager.saveToPreferences { [weak self] error in
                    guard let self = self else { return }
                    if let error = error as NSError? {
                        NSLog("[VPNManager] ❌ Failed to save refreshed manager: \(error)")
                        DispatchQueue.main.async { completion(-1, error) }
                        return
                    }
                    manager.loadFromPreferences { loadError in
                        if let loadError = loadError as NSError? {
                            NSLog("[VPNManager] ❌ Failed to reload refreshed manager: \(loadError)")
                            DispatchQueue.main.async { completion(-1, loadError) }
                            return
                        }
                        self.tunnelManager = manager
                        self.doStartVpn(tunnelConfig: tunnelConfig, completion: completion)
                    }
                }
                return
            }
            
            // Start the tunnel
            do {
                try manager.connection.startVPNTunnel(options: nil)
                NSLog("[VPNManager] ✅ VPN startVPNTunnel called, waiting for tunnel ready...")
                
                // Wait for Extension to signal readiness, then receive fd via Unix socket
                self.waitForTunnelAndReceiveFd(completion: completion)
                
            } catch let error as NSError {
                NSLog("[VPNManager] ❌ Error starting VPN tunnel: \(error)")
                NSLog("[VPNManager] ❌ Error domain: \(error.domain), code: \(error.code)")
                NSLog("[VPNManager] ❌ Error userInfo: \(error.userInfo)")
                self.showAlert(title: "VPN 连接失败", message: "\(error.domain) (\(error.code))\n\(error.localizedDescription)\n详情: \(error.userInfo)")
                DispatchQueue.main.async { completion(-1, error) }
            }
        }
    }
    
    /// Stop VPN
    @objc func stopVpn() {
        NSLog("[VPNManager] stopVpn called")
        tunnelManager?.connection.stopVPNTunnel()
        sharedDefaults.set(false, forKey: "tunnelReady")
        statusHandler?("stopped")
    }
    
    /// Check if VPN is currently connected
    @objc func isVpnRunning() -> Bool {
        return tunnelManager?.connection.status == .connected
    }
    
    /// Get VPN connection status as a string (for Flutter)
    @objc func getVpnStatusString() -> String {
        guard let status = tunnelManager?.connection.status else {
            return "loading"  // tunnelManager not loaded yet
        }
        let statusStr: String
        switch status {
        case .invalid: statusStr = "invalid"
        case .disconnected: statusStr = "disconnected"
        case .connecting: statusStr = "connecting"
        case .connected: statusStr = "connected"
        case .reasserting: statusStr = "reasserting"
        case .disconnecting: statusStr = "disconnecting"
        @unknown default: statusStr = "unknown"
        }
        NSLog("[VPNManager] getVpnStatusString: \(statusStr)")
        return statusStr
    }
    
    /// Stop VPN if it's currently connected, returns true if stopped
    @objc func stopVpnIfConnected() -> Bool {
        guard let manager = tunnelManager else {
            NSLog("[VPNManager] stopVpnIfConnected: tunnelManager is nil, cannot stop")
            return false
        }
        let status = manager.connection.status
        if status == .connected || status == .connecting || status == .reasserting {
            NSLog("[VPNManager] Stopping stale VPN connection (status was: \(status.rawValue))")
            manager.connection.stopVPNTunnel()
            sharedDefaults.set(false, forKey: "tunnelReady")
            return true
        }
        NSLog("[VPNManager] stopVpnIfConnected: status is \(status.rawValue), no need to stop")
        return false
    }
    
    // MARK: - FD Transfer via Unix Domain Socket
    
    /// Wait for Extension to be ready, then connect to its Unix socket to receive fd
    /// Uses a poller object to manage the async polling lifecycle
    private func waitForTunnelAndReceiveFd(completion: @escaping (Int, Error?) -> Void) {
        let poller = TunnelReadyPoller(
            sharedDefaults: sharedDefaults,
            tunnelManager: tunnelManager,
            maxWait: 30,
            pollInterval: 0.3,
            receiveFdFromExtension: { [weak self] completion in
                self?.receiveFdFromExtension(retries: 5, completion: completion)
            },
            showAlert: { [weak self] title, message in
                self?.showAlert(title: title, message: message)
            },
            completion: { [weak self] fd, error in
                if error == nil {
                    self?.statusHandler?("connected")
                }
                completion(fd, error)
            }
        )
        // Store poller to prevent deallocation
        objc_setAssociatedObject(self, "fdWaitPoller", poller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        poller.start()
    }
    
    /// Connect to Extension's Unix Domain Socket and receive the utun fd via SCM_RIGHTS
    /// Includes retry logic in case the Extension socket is not ready yet
    private func receiveFdFromExtension(retries: Int = 5, completion: @escaping (Int, Error?) -> Void) {
        receiveFdFromExtensionAttempt(remainingRetries: retries, completion: completion)
    }
    
    private func receiveFdFromExtensionAttempt(remainingRetries: Int, completion: @escaping (Int, Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            guard sock >= 0 else {
                let error = NSError(domain: "VPNManager", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix Domain Socket: errno=\(errno)"])
                completion(-1, error)
                return
            }
            defer { close(sock) }
            
            // Connect to Extension's socket
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathData = self.socketPath.cString(using: .utf8)!
            // Use the full sockaddr_un struct approach to avoid Swift 6 tuple issues
            withUnsafeMutableBytes(of: &addr) { rawPtr in
                let sunPathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 2
                let dest = rawPtr.baseAddress!.advanced(by: sunPathOffset)
                let count = min(pathData.count - 1, 103) // exclude null terminator
                memcpy(dest, pathData, count)
                dest.advanced(by: count).initializeMemory(as: UInt8.self, to: 0)
            }
            
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPtr in
                    connect(sock, reboundPtr, addrLen)
                }
            }
            
            guard connectResult == 0 else {
                if remainingRetries > 0 {
                    NSLog("[VPNManager] Failed to connect to Extension socket (errno=%d), retrying... (%d left)", errno, remainingRetries)
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                        self.receiveFdFromExtensionAttempt(remainingRetries: remainingRetries - 1, completion: completion)
                    }
                    return
                }
                let error = NSError(domain: "VPNManager", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Extension socket after retries: errno=\(errno)"])
                NSLog("[VPNManager] ❌ Failed to connect to Extension socket after all retries: %d", errno)
                self.showAlert(title: "VPN 连接失败", message: "无法连接到 Extension\n请检查:\n1. App Group 配置是否正确\n2. 重新安装应用后重试")
                completion(-1, error)
                return
            }
            
            NSLog("[VPNManager] Connected to Extension socket, receiving fds...")
            
            // Receive the pipe fds using recvmsg with SCM_RIGHTS
            let receivedFds = self.receiveFileDescriptors(sock: sock)
            
            if receivedFds.count == 2 {
                let appReadFd = receivedFds[0]  // App reads from this (Extension → App)
                let appWriteFd = receivedFds[1] // App writes to this (App → Extension)
                NSLog("[VPNManager] Successfully received 2 pipe fds: readFd=%d, writeFd=%d", appReadFd, appWriteFd)
                
                // Encode two fds into a single Int (will be passed as u32 to Rust):
                // low 16 bits = read_fd, high 16 bits = write_fd
                let encodedFd = Int(UInt32(truncatingIfNeeded: UInt64(appReadFd) & 0xFFFF)
                    | ((UInt32(truncatingIfNeeded: UInt64(appWriteFd) & 0xFFFF) << 16)))
                NSLog("[VPNManager] Encoded fd value: %u (0x%x)", encodedFd, encodedFd)
                DispatchQueue.main.async { completion(encodedFd, nil) }
            } else {
                NSLog("[VPNManager] Expected 2 fds, got %d", receivedFds.count)
                if remainingRetries > 0 {
                    NSLog("[VPNManager] Retrying... (%d left)", remainingRetries)
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                        self.receiveFdFromExtensionAttempt(remainingRetries: remainingRetries - 1, completion: completion)
                    }
                    return
                }
                let error = NSError(domain: "VPNManager", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: "Expected 2 fds from Extension, got \(receivedFds.count)"])
                NSLog("[VPNManager] ❌ Failed to receive fds after all retries")
                completion(-1, error)
            }
        }
    }
    
    /// Receive multiple file descriptors from a connected Unix Domain Socket using SCM_RIGHTS
    /// Returns array of received file descriptors
    private func receiveFileDescriptors(sock: Int32) -> [Int32] {
        var buf = [UInt8](repeating: 0, count: 1)
        
        // Control message buffer — generous size for up to 4 fds
        let maxFds = 4
        let cmsgDataSize = MemoryLayout<Int32>.size * maxFds
        let cmsgBufferSize = MemoryLayout<cmsghdr>.size + cmsgDataSize
        var cmsgBuffer = [UInt8](repeating: 0, count: cmsgBufferSize)
        
        var msg = msghdr()
        msg.msg_name = nil
        msg.msg_namelen = 0
        msg.msg_controllen = socklen_t(cmsgBufferSize)
        
        var receivedFds: [Int32] = []
        
        let result: Int32 = cmsgBuffer.withUnsafeMutableBytes { cmsgRaw in
            buf.withUnsafeMutableBufferPointer { bufPtr in
                var iov = iovec(
                    iov_base: bufPtr.baseAddress,
                    iov_len: 1
                )
                
                msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
                msg.msg_iovlen = 1
                msg.msg_control = cmsgRaw.baseAddress
                
                let recvResult = withUnsafeMutablePointer(to: &msg) { msgPtr in
                    recvmsg(sock, msgPtr, 0)
                }
                
                guard recvResult > 0 else {
                    NSLog("[VPNManager] recvmsg failed: %d", errno)
                    return Int32(-1)
                }
                
                // Parse control messages to extract fds
                let bufferBase = cmsgRaw.baseAddress!
                var offset = 0
                
                while offset + MemoryLayout<cmsghdr>.size <= Int(msg.msg_controllen) {
                    let cmsg = bufferBase.advanced(by: offset).assumingMemoryBound(to: cmsghdr.self)
                    
                    if cmsg.pointee.cmsg_level == SOL_SOCKET && cmsg.pointee.cmsg_type == SCM_RIGHTS {
                        let cmsgDataLen = Int(cmsg.pointee.cmsg_len) - MemoryLayout<cmsghdr>.size
                        let fdCount = cmsgDataLen / MemoryLayout<Int32>.size
                        for i in 0..<fdCount {
                            let fdPtr = UnsafeRawPointer(cmsg).advanced(by: MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size * i)
                                .assumingMemoryBound(to: Int32.self)
                            receivedFds.append(fdPtr.pointee)
                        }
                        break
                    }
                    
                    let cmsgLen = Int(cmsg.pointee.cmsg_len)
                    let alignedLen = (cmsgLen + MemoryLayout<Int>.alignment - 1) & ~(MemoryLayout<Int>.alignment - 1)
                    offset += alignedLen
                    if offset == 0 { break }
                }
                return Int32(0)
            }
        }
        
        if result < 0 {
            return []
        }
        return receivedFds
    }
    
    // MARK: - UI Alert Helper

    /// Show an alert dialog on the main thread so errors are visible on device without Xcode console
    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            guard let rootVC = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                NSLog("[VPNManager] ⚠️ Cannot show alert: no key window root view controller")
                return
            }
            // Find the topmost presented view controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            topVC.present(alert, animated: true)
        }
    }

    // MARK: - Private Helpers

    private func parseExternalRoutes(_ routes: [[String: String]]) -> [ExternalRoute] {
        return routes.compactMap { route in
            guard let destination = route["destination"],
                  let netmask = route["netmask"] else { return nil }
            return ExternalRoute(destination: destination, netmask: netmask)
        }
    }

    private func parseServerIPv4(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if let schemeRange = s.range(of: "://") {
            s = String(s[schemeRange.upperBound...])
        }
        if s.hasPrefix("[") {
            return nil
        }
        if let slashIndex = s.firstIndex(of: "/") {
            s = String(s[..<slashIndex])
        }
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard let host = parts.first, !host.isEmpty else {
            return nil
        }
        var addr = in_addr()
        return host.withCString { cStr -> String? in
            if inet_pton(AF_INET, cStr, &addr) == 1 {
                return String(host)
            }
            return nil
        }
    }
    
    // MARK: - Connection Status Monitoring
    
    @objc func startMonitoringStatus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange(_:)),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }
    
    @objc func vpnStatusDidChange(_ notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }
        let status: String
        switch connection.status {
        case .invalid: status = "invalid"
        case .disconnected: status = "disconnected"
        case .connecting: status = "connecting"
        case .connected: status = "connected"
        case .reasserting: status = "reasserting"
        case .disconnecting: status = "disconnecting"
        @unknown default: status = "unknown"
        }
        NSLog("[VPNManager] VPN status changed: %@", status)
        statusHandler?(status)
    }
    
    @objc func stopMonitoringStatus() {
        NotificationCenter.default.removeObserver(self, name: .NEVPNStatusDidChange, object: nil)
    }
    
    deinit {
        stopMonitoringStatus()
    }
}

// MARK: - Tunnel Ready Poller

/// Helper class that polls for tunnel readiness using DispatchQueue
/// Extracted from VPNManager to avoid Swift's "closure captures variable before declaration" issue
private class TunnelReadyPoller: NSObject {
    private let sharedDefaults: UserDefaults
    private weak var tunnelManager: NETunnelProviderManager?
    private let maxWait: TimeInterval
    private let pollInterval: TimeInterval
    private let startTime = Date()
    private var completionCalled = false
    private let receiveFdFromExtension: (@escaping (Int, Error?) -> Void) -> Void
    private let showAlert: (String, String) -> Void
    private let completion: (Int, Error?) -> Void
    
    init(sharedDefaults: UserDefaults,
         tunnelManager: NETunnelProviderManager?,
         maxWait: TimeInterval,
         pollInterval: TimeInterval,
         receiveFdFromExtension: @escaping (@escaping (Int, Error?) -> Void) -> Void,
         showAlert: @escaping (String, String) -> Void,
         completion: @escaping (Int, Error?) -> Void) {
        self.sharedDefaults = sharedDefaults
        self.tunnelManager = tunnelManager
        self.maxWait = maxWait
        self.pollInterval = pollInterval
        self.receiveFdFromExtension = receiveFdFromExtension
        self.showAlert = showAlert
        self.completion = completion
    }
    
    func start() {
        scheduleNextCheck()
    }
    
    private func scheduleNextCheck() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.check()
        }
    }
    
    private func safeCompletion(fd: Int, error: Error?) {
        guard !completionCalled else {
            NSLog("[TunnelReadyPoller] ⚠️ completion already called, ignoring duplicate")
            return
        }
        completionCalled = true
        completion(fd, error)
    }
    
    private func check() {
        guard !completionCalled else { return }
        
        let tunnelReady = sharedDefaults.bool(forKey: "tunnelReady")
        let status = tunnelManager?.connection.status
        
        if tunnelReady {
            NSLog("[TunnelReadyPoller] Extension signaled tunnelReady, connecting to receive fd...")
            receiveFdFromExtension { fd, error in
                self.safeCompletion(fd: fd, error: error)
            }
            return
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        if status == .disconnected && elapsed > 5 {
            NSLog("[TunnelReadyPoller] VPN tunnel disconnected after %.1fs", elapsed)
            let error = NSError(domain: "VPNManager", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "VPN tunnel disconnected: \(String(describing: status))"])
            showAlert("VPN 已断开", "VPN 隧道连接异常断开\n状态: \(String(describing: status))")
            safeCompletion(fd: -1, error: error)
            return
        }
        
        if status == .invalid && elapsed > 5 {
            NSLog("[TunnelReadyPoller] VPN tunnel invalid after %.1fs", elapsed)
            let error = NSError(domain: "VPNManager", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "VPN tunnel invalid"])
            showAlert("VPN 配置无效", "VPN 隧道配置无效\n请尝试重新添加 VPN 配置")
            safeCompletion(fd: -1, error: error)
            return
        }
        
        if elapsed > maxWait {
            NSLog("[TunnelReadyPoller] Timeout after %.1fs", elapsed)
            let error = NSError(domain: "VPNManager", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for VPN tunnel to start (30s)"])
            showAlert("VPN 超时", "等待 VPN 隧道就绪超时 (30秒)\nExtension 可能未正常启动\n请检查:\n1. App Group 配置是否正确\n2. PacketTunnel Extension 是否已签名\n3. 设置 > VPN 中是否已添加 VPN 配置")
            safeCompletion(fd: -1, error: error)
            return
        }
        
        scheduleNextCheck()
    }
}
