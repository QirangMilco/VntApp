import NetworkExtension
import os.log
import Foundation
import Darwin
import System

// VNT FFI 结构体
typedef struct {
    const char *token;
    const char *device_id;
    const char *name;
    const char *server_address;
    const char *dns;
    const char *stun_server;
    const char *in_ip;
    const char *out_ip;
    const char *password;
    int mtu;
    const char *virtual_ip;
    bool server_encrypt;
    bool allow_wire_guard;
} VntConfig;

typedef struct {
    void (*success)(void);
    void (*connect)(const char *);
    bool (*handshake)(const char *);
    bool (*register_)(const char *);
    void (*error)(const char *);
    void (*stop)(void);
    void (*peer_client_list)(const char *);
} VntCallbacks;

// 全局变量，用于在回调中访问PacketTunnelProvider实例
var currentPacketTunnelProvider: PacketTunnelProvider?

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private let logger = Logger(subsystem: "com.vntapp.VpnProvider", category: "PacketTunnelProvider")
    private var isRunning = false
    private var appGroupName = "group.com.vntapp.shared"
    private var vpnConfig: [String: Any]?
    private var vntManager: OpaquePointer?
    private var vntWaitTask: Task<Void, Never>?
    
    // 性能监控相关
    private var stats: [String: Any] = [:]
    private var lastStatsResetTime: TimeInterval = Date().timeIntervalSince1970
    private var packetStats: PacketStatistics = PacketStatistics()
    
    // 错误处理和诊断
    private var errorHistory: [(timestamp: TimeInterval, error: String)] = []
    private let maxErrorHistory = 50
    private var testModeEnabled = false
    
    // 错误类型枚举
    private enum VpnError: Error, CustomStringConvertible {
        case configNotFound
        case initializationFailed(reason: String)
        case connectionError(reason: String)
        case packetProcessError(reason: String)
        case interfaceError(reason: String)
        case memoryError
        
        var description: String {
            switch self {
            case .configNotFound:
                return "配置文件未找到"
            case .initializationFailed(let reason):
                return "初始化失败: \(reason)"
            case .connectionError(let reason):
                return "连接错误: \(reason)"
            case .packetProcessError(let reason):
                return "数据包处理错误: \(reason)"
            case .interfaceError(let reason):
                return "接口错误: \(reason)"
            case .memoryError:
                return "内存错误"
            }
        }
    }
    
    // 数据包统计
    private struct PacketStatistics {
        var inboundPacketsCount: Int = 0
        var outboundPacketsCount: Int = 0
        var inboundBytesCount: Int = 0
        var outboundBytesCount: Int = 0
        var packetProcessErrors: Int = 0
        
        mutating func reset() {
            inboundPacketsCount = 0
            outboundPacketsCount = 0
            inboundBytesCount = 0
            outboundBytesCount = 0
            packetProcessErrors = 0
        }
        
        func toDictionary() -> [String: Any] {
            return [
                "inboundPackets": inboundPacketsCount,
                "outboundPackets": outboundPacketsCount,
                "inboundBytes": inboundBytesCount,
                "outboundBytes": outboundBytesCount,
                "processErrors": packetProcessErrors
            ]
        }
    }
    
    // VPN状态枚举
    private enum VpnState: String {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case starting
        case stopping
        case reasserting
    }
    
    // 当前VPN状态
    private var currentState: VpnState = .disconnected
    
    // 路由验证相关
    private var routeValidationTimer: Timer?
    private var routeValidationHistory: [(timestamp: TimeInterval, isValid: Bool)] = []
    private var validationFailedCount = 0
    private let maxValidationHistory = 10
    private let routeValidationInterval = 30.0 // 验证间隔，单位：秒
    
    // 全局Provider实例，用于C回调访问
    private static var currentProvider: PacketTunnelProvider?
    
    // FFI函数声明
    @_silgen_name("vnt_create")
    private func vnt_create(_ config: UnsafePointer<VntConfig>, _ callbacks: UnsafePointer<VntCallbacks>) -> UnsafeMutableRawPointer?
    
    @_silgen_name("vnt_destroy")
    private func vnt_destroy(_ vnt: UnsafeMutableRawPointer?)
    
    @_silgen_name("vnt_send_ip")
    private func vnt_send_ip(_ vnt: UnsafeMutableRawPointer?, _ data: UnsafePointer<UInt8>, _ len: Int32) -> Bool
    
    @_silgen_name("vnt_wait")
    private func vnt_wait(_ vnt: UnsafeMutableRawPointer?)
    
    @_silgen_name("vnt_set_packet_send_callback")
    private func vnt_set_packet_send_callback(_ callback: @convention(c) (UnsafeRawPointer, CInt) -> Void)
    
    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        logger.info("Starting tunnel with options: \(options?.debugDescription ?? "nil")")
        
        // 重置状态和统计信息
        resetAllState()
        
        // 设置全局引用，供回调使用
        currentPacketTunnelProvider = self
        PacketTunnelProvider.currentProvider = self
        
        // 保存启动状态
        saveVpnState(state: .starting)
        
        // 从App Group加载配置
        loadConfigFromAppGroup()
        
        // 检查是否处于测试模式
        if let testMode = options?["testMode"] as? Bool {
            testModeEnabled = testMode
            logger.info("Test mode: \(testMode ? "enabled" : "disabled")")
        }
        
        // 记录加载的配置摘要
        if let config = vpnConfig {
            logger.info("Loaded VPN config with \(config.count) settings")
        } else {
            logger.warning("No VPN config loaded from App Group")
        }
        
        // 配置VPN网络设置
        guard let networkSettings = createNetworkSettings() else {
            let error = NSError(domain: "com.vntapp.VpnProvider", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Failed to create network settings"])
            logger.error("Failed to create network settings")
            completionHandler(error)
            return
        }
        
        // 设置网络配置
        setTunnelNetworkSettings(networkSettings) { error in
            if let error = error {
                self.logger.error("Failed to set tunnel network settings: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            
            self.isRunning = true
            self.logger.info("Tunnel started successfully")
            
            // 初始化VNT库
            if self.initializeVNT() {
                // 开始处理数据包
                self.startHandlingPackets()
                completionHandler(nil)
            } else {
                let error = NSError(domain: "com.vntapp.VpnProvider", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize VNT library"])
                self.logger.error("Failed to initialize VNT library")
                completionHandler(error)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("Stopping tunnel with reason: \(reason.rawValue)")
        
        // 保存停止状态
        saveVpnState(state: .stopping)
        
        isRunning = false
        
        // 停止路由验证
        stopRouteValidation()
        
        // 取消等待任务
        vntWaitTask?.cancel()
        
        // 清理VNT资源
        if vntManager != nil {
            vnt_destroy(vntManager)
            vntManager = nil
            logger.info("VNT library destroyed")
        }
        
        // 清理资源
        packetFlow = nil
        vpnConfig = nil
        
        // 清除全局引用
        if currentPacketTunnelProvider === self {
            currentPacketTunnelProvider = nil
        }
        
        logger.info("Tunnel stopped")
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        // 处理来自主应用的消息
        logger.info("Received app message of length: \(messageData.count)")
        
        do {
            if let message = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
                logger.info("Successfully parsed message object")
                
                // 处理消息
                if let type = message["type"] as? String {
                    logger.info("Message type: \(type)")
                    
                    switch type {
                    case "config":
                        if let config = message["config"] as? [String: Any] {
                            self.vpnConfig = config
                            logger.info("Updated VPN config with \(config.count) settings")
                            
                            // 保存到App Group以便重启后可用
                            if let userDefaults = UserDefaults(suiteName: appGroupName) {
                                userDefaults.set(config, forKey: "vntConfig")
                                logger.info("Saved updated config to App Group")
                            }
                            
                            // 如果VPN正在运行，尝试重新初始化VNT
                            if isRunning && vntManager != nil {
                                restartVntIfNeeded()
                            }
                            
                            // 返回确认消息
                            let response = ["status": "success", "configSize": config.count]
                            let responseData = try JSONSerialization.data(withJSONObject: response)
                            logger.info("Sending success response to app")
                            completionHandler?(responseData)
                            return
                        } else {
                            logger.error("Invalid config format in message")
                            let errorResponse = ["status": "error", "message": "Invalid config format"]
                            let responseData = try JSONSerialization.data(withJSONObject: errorResponse)
                            completionHandler?(responseData)
                            return
                        }
                    case "ping":
                        // 返回pong消息确认连接，包含当前状态
                        logger.info("Processing ping message")
                        let response = ["status": "pong", "timestamp": Date().timeIntervalSince1970, "state": currentState.rawValue]
                        let responseData = try JSONSerialization.data(withJSONObject: response)
                        logger.info("Sending pong response to app")
                        completionHandler?(responseData)
                        return
                    case "state_query":
                        // 查询当前状态
                        logger.info("Processing state query")
                        let response = ["status": "success", "type": "state_response", "state": currentState.rawValue, "config": vpnConfig ?? [:]]
                        let responseData = try JSONSerialization.data(withJSONObject: response)
                        logger.info("Sending state response to app")
                        completionHandler?(responseData)
                        return
                    // 测试模式相关命令
                    case "test_mode":
                        // 启用或禁用测试模式
                        if let enabled = message["enabled"] as? Bool {
                            testModeEnabled = enabled
                            logger.info("测试模式已\(enabled ? "启用" : "禁用")")
                            
                            let response = [
                                "status": "success", 
                                "message": "测试模式已\(enabled ? "启用" : "禁用")",
                                "testModeEnabled": testModeEnabled
                            ]
                            let responseData = try JSONSerialization.data(withJSONObject: response)
                            completionHandler?(responseData)
                            return
                        } else {
                            // 仅查询测试模式状态
                            let response = [
                                "status": "success",
                                "testModeEnabled": testModeEnabled
                            ]
                            let responseData = try JSONSerialization.data(withJSONObject: response)
                            completionHandler?(responseData)
                            return
                        }
                    case "detailed_state":
                        // 获取详细状态信息
                        logger.info("获取详细状态信息")
                        let stateInfo = getDetailedStateInfo()
                        let response = ["status": "success", "data": stateInfo]
                        let responseData = try JSONSerialization.data(withJSONObject: response)
                        completionHandler?(responseData)
                        return
                    case "test_error":
                        // 注入测试错误
                        guard testModeEnabled else {
                            logger.warning("尝试在非测试模式下注入测试错误")
                            let errorResponse = [
                                "status": "error", 
                                "message": "测试模式未启用"
                            ]
                            let responseData = try JSONSerialization.data(withJSONObject: errorResponse)
                            completionHandler?(responseData)
                            return
                        }
                        
                        if let errorTypeStr = message["error_type"] as? String {
                            // 解析错误类型
                            var errorType: VpnError
                            switch errorTypeStr {
                            case "configNotFound":
                                errorType = .configNotFound
                            case "initializationFailed":
                                errorType = .initializationFailed(reason: "测试初始化失败")
                            case "connectionError":
                                errorType = .connectionError(reason: "测试连接错误")
                            case "packetProcessError":
                                errorType = .packetProcessError(reason: "测试数据包处理错误")
                            case "interfaceError":
                                errorType = .interfaceError(reason: "测试接口错误")
                            case "memoryError":
                                errorType = .memoryError
                            default:
                                errorType = .connectionError(reason: "未知测试错误类型")
                            }
                            
                            // 注入错误
                            injectTestError(errorType)
                            
                            let response = [
                                "status": "success", 
                                "message": "已注入测试错误: \(errorType.description)"
                            ]
                            let responseData = try JSONSerialization.data(withJSONObject: response)
                            completionHandler?(responseData)
                            return
                        }
                    case "memory_check":
                        // 检查内存使用情况
                        checkMemoryUsage()
                        let freeMemory = getFreeMemory()
                        let memoryInfo = [
                            "status": "success",
                            "freeMemory": freeMemory,
                            "freeMemoryMB": Double(freeMemory) / (1024 * 1024)
                        ]
                        
                        let responseData = try JSONSerialization.data(withJSONObject: memoryInfo)
                        completionHandler?(responseData)
                        return
                    case "get_stats":
                        // 获取统计信息
                        logger.info("获取统计信息")
                        let statsResponse = [
                            "status": "success",
                            "statistics": packetStats.toDictionary(),
                            "uptime": Date().timeIntervalSince1970 - lastStatsResetTime
                        ]
                        let responseData = try JSONSerialization.data(withJSONObject: statsResponse)
                        completionHandler?(responseData)
                        return
                    case "reset_stats":
                        // 重置统计信息
                        logger.info("重置统计信息")
                        packetStats.reset()
                        lastStatsResetTime = Date().timeIntervalSince1970
                        
                        let response = ["status": "success", "message": "统计信息已重置"]
                        let responseData = try JSONSerialization.data(withJSONObject: response)
                        completionHandler?(responseData)
                        return
                    default:
                        logger.warning("Unknown message type: \(type)")
                        let errorResponse = ["status": "error", "message": "Unknown message type"]
                        let responseData = try JSONSerialization.data(withJSONObject: errorResponse)
                        completionHandler?(responseData)
                        return
                    }
                } else {
                    logger.error("Message missing 'type' field")
                    let errorResponse = ["status": "error", "message": "Missing type field"]
                    let responseData = try JSONSerialization.data(withJSONObject: errorResponse)
                    completionHandler?(responseData)
                    return
                }
            } else {
                logger.error("Failed to parse message as dictionary")
                let errorResponse = ["status": "error", "message": "Invalid message format"]
                let responseData = try JSONSerialization.data(withJSONObject: errorResponse)
                completionHandler?(responseData)
                return
            }
        } catch {
            logger.error("Error handling app message: \(error.localizedDescription)")
            // 返回错误响应
            do {
                let errorResponse = ["status": "error", "message": "Error processing message: \(error.localizedDescription)"]
                let responseData = try JSONSerialization.data(withJSONObject: errorResponse)
                completionHandler?(responseData)
            } catch {
                completionHandler?(nil)
            }
        }
    }
    
    private func loadConfigFromAppGroup() {
        logger.info("Attempting to load config from App Group: \(appGroupName)")
        
        do {
            if let userDefaults = UserDefaults(suiteName: appGroupName) {
                logger.info("Successfully accessed UserDefaults for App Group")
                
                // 尝试加载主要配置
                if userDefaults.object(forKey: "vntConfig") != nil {
                    if let config = userDefaults.dictionary(forKey: "vntConfig") {
                        // 验证必要配置项
                        try validateConfig(config)
                        vpnConfig = config
                        logger.info("Successfully loaded config from App Group with \(config.count) settings")
                        
                        // 记录配置的关键信息（不记录敏感数据）
                        if let serverAddress = config["serverAddress"] as? String {
                            logger.info("Server address from config: \(serverAddress)")
                        }
                        if let virtualIp = config["virtualIp"] as? String {
                            logger.info("Virtual IP from config: \(virtualIp)")
                        }
                        
                        // 测试模式下记录详细配置
                        if testModeEnabled {
                            logDetailedConfig(config)
                        }
                    } else {
                        throw VpnError.initializationFailed(reason: "Failed to cast config to dictionary")
                    }
                } else {
                    logger.warning("No config found in App Group UserDefaults")
                    
                    // 尝试读取旧的配置键名
                    if let legacyConfig = userDefaults.dictionary(forKey: "vpn_config") {
                        // 验证旧配置
                        try validateConfig(legacyConfig)
                        vpnConfig = legacyConfig
                        logger.info("Found legacy config with key 'vpn_config'")
                    } else {
                        throw VpnError.configNotFound
                    }
                }
                
                // 尝试恢复之前的VPN状态
                if let savedState = userDefaults.string(forKey: "vpnState") {
                    logger.info("Found saved VPN state: \(savedState)")
                    // 注意：我们只读取但不直接恢复状态，因为新的连接应该从starting状态开始
                }
            } else {
                throw VpnError.initializationFailed(reason: "Failed to access UserDefaults for App Group: \(appGroupName)")
            }
        } catch let error as VpnError {
            recordError(error.description)
            logger.error("Failed to load valid VPN config: \(error.description)")
        } catch {
            recordError("未知错误: \(error.localizedDescription)")
            logger.error("Unexpected error loading VPN config: \(error)")
        }
    }
    
    // 验证配置完整性
    private func validateConfig(_ config: [String: Any]) throws {
        let requiredKeys = ["token", "serverAddress", "virtualIp"]
        
        for key in requiredKeys {
            guard let value = config[key], !(value is NSNull) else {
                throw VpnError.initializationFailed(reason: "缺少必要配置项: \(key)")
            }
            
            // 验证字符串类型和长度
            if let stringValue = value as? String {
                if stringValue.isEmpty {
                    throw VpnError.initializationFailed(reason: "配置项为空: \(key)")
                }
                // 安全性检查
                if key == "token" && stringValue.count < 10 {
                    throw VpnError.initializationFailed(reason: "Token格式无效: \(key)")
                }
            }
        }
        
        // 验证MTU范围
        if let mtu = config["mtu"] as? Int {
            if mtu < 68 || mtu > 9216 {
                throw VpnError.initializationFailed(reason: "MTU值超出有效范围: \(mtu)")
            }
        }
    }
    
    // 测试模式下记录详细配置
    private func logDetailedConfig(_ config: [String: Any]) {
        var safeConfig = config
        // 隐藏敏感信息
        if safeConfig["token"] != nil {
            safeConfig["token"] = "****"
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: safeConfig, options: .prettyPrinted)
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.info("Detailed VPN config (test mode): \n\(jsonString)")
            }
        } catch {
            logger.error("Failed to log detailed config: \(error)")
        }
    }
    
    // 记录错误到历史记录
    private func recordError(_ errorMessage: String) {
        let now = Date().timeIntervalSince1970
        errorHistory.append((timestamp: now, error: errorMessage))
        
        // 限制历史记录大小
        if errorHistory.count > maxErrorHistory {
            errorHistory.removeFirst()
        }
        
        // 测试模式下立即发送错误报告
        if testModeEnabled {
            sendErrorReport(errorMessage)
        }
    }
    
    // 发送错误报告到主应用
    private func sendErrorReport(_ error: String) {
        let report: [String: Any] = [
            "type": "error_report",
            "timestamp": Date().timeIntervalSince1970,
            "error": error
        ]
        
        sendMessageToApp(report)
    }
    
    // 保存VPN状态
    private func saveVpnState(state: VpnState) {
        currentState = state
        logger.info("VPN state changed to: \(state.rawValue)")
        
        // 保存状态到App Group
        if let defaults = UserDefaults(suiteName: appGroupName) {
            defaults.set(state.rawValue, forKey: "vpnState")
            defaults.synchronize()
            logger.debug("Saved VPN state to App Group")
        }
        
        // 发送状态更新到主应用
        sendStateUpdate()
    }
    
    // 发送状态更新到主应用
    private func sendStateUpdate() {
        let stateInfo: [String: Any] = [
            "type": "state_update",
            "state": currentState.rawValue,
            "timestamp": Date().timeIntervalSince1970
        ]
        sendMessageToApp(stateInfo)
    }
    
    // 重启VNT实例（配置变更时）
    private func restartVntIfNeeded() {
        logger.info("Restarting VNT due to config change")
        
        // 保存状态为重新连接中
        saveVpnState(state: .reasserting)
        
        // 取消等待任务
        vntWaitTask?.cancel()
        vntWaitTask = nil
        
        // 清理旧实例
        if let manager = vntManager {
            vnt_destroy(manager)
            vntManager = nil
            logger.info("Destroyed old VNT instance")
        }
        
        // 延迟一段时间后重新初始化，避免立即重连导致的问题
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            if self.isRunning {
                logger.info("Re-initializing VNT with new config")
                if self.initializeVNT() {
                    logger.info("Successfully re-initialized VNT, restarting packet processing")
                    self.startHandlingPackets()
                } else {
                    logger.error("Failed to re-initialize VNT after config change")
                    self.saveVpnState(state: .disconnected)
                }
            }
        }
    }
    
    // 重置所有状态和统计信息
    private func resetAllState() {
        logger.debug("Resetting all VPN states and statistics")
        isRunning = false
        packetStats.reset()
        errorHistory.removeAll()
        stats.removeAll()
        lastStatsResetTime = Date().timeIntervalSince1970
        resetRouteValidationState()
    }
    
    // 重置路由验证状态
    private func resetRouteValidationState() {
        routeValidationHistory.removeAll()
        validationFailedCount = 0
        logger.info("Reset route validation state")
    }
    
    // 启动路由验证
    private func startRouteValidation() {
        guard isRunning, routeValidationTimer == nil else {
            logger.warning("Route validation already running or VPN not active")
            return
        }
        
        logger.info("Starting route validation with interval: \(routeValidationInterval) seconds")
        
        // 立即执行一次验证
        validateNetworkRoutes()
        
        // 设置定时器定期验证
        routeValidationTimer = Timer.scheduledTimer(withTimeInterval: routeValidationInterval, repeats: true) {
            [weak self] _ in
            guard let self = self, self.isRunning else {
                self?.stopRouteValidation()
                return
            }
            self.validateNetworkRoutes()
        }
    }
    
    // 停止路由验证
    private func stopRouteValidation() {
        routeValidationTimer?.invalidate()
        routeValidationTimer = nil
        resetRouteValidationState()
        logger.info("Stopped route validation")
    }
    
    // 验证网络路由
    private func validateNetworkRoutes() {
        logger.info("Performing network route validation")
        
        // 获取当前网络接口信息
        getCurrentNetworkInterfaceInfo { [weak self] interfaces in
            guard let self = self, self.isRunning else {
                return
            }
            
            // 检查是否有VPN接口
            let hasVpnInterface = self.checkForVpnInterface(interfaces)
            
            // 记录验证结果
            self.recordValidationResult(isValid: hasVpnInterface)
            
            if hasVpnInterface {
                self.logger.info("Route validation: VPN interface is properly configured")
                self.validationFailedCount = 0 // 重置失败计数
            } else {
                self.logger.warning("Route validation: VPN interface not properly configured")
                self.validationFailedCount += 1
                
                // 如果连续失败多次，触发恢复
                if self.validationFailedCount >= 3 {
                    self.logger.warning("Multiple route validation failures detected, triggering connection recovery")
                    self.attemptConnectionRecovery()
                }
            }
            
            // 发送路由验证状态到主应用
            self.sendRouteValidationStatus(isValid: hasVpnInterface, interfaceCount: interfaces.count)
        }
    }
    
    // 获取当前网络接口信息
    private func getCurrentNetworkInterfaceInfo(completion: @escaping ([String]) -> Void) {
        let task = Process()
        let pipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = ["-l"] // 列出所有接口名称
        task.standardOutput = pipe
        
        do {
            try task.run()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            
            if let output = String(data: data, encoding: .utf8) {
                let interfaces = output.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                logger.debug("Detected network interfaces: \(interfaces)")
                completion(interfaces)
            } else {
                logger.error("Failed to parse network interfaces output")
                completion([])
            }
        } catch {
            logger.error("Error getting network interfaces: \(error.localizedDescription)")
            completion([])
        }
    }
    
    // 检查是否有VPN接口
    private func checkForVpnInterface(_ interfaces: [String]) -> Bool {
        // 检查是否有tun/tap或其他VPN相关接口
        let vpnInterfacePatterns = ["tun", "tap", "utun"]
        
        for interface in interfaces {
            for pattern in vpnInterfacePatterns {
                if interface.contains(pattern) {
                    logger.debug("Found VPN interface: \(interface)")
                    return true
                }
            }
        }
        
        return false
    }
    
    // 记录验证结果
    private func recordValidationResult(isValid: Bool) {
        let now = Date().timeIntervalSince1970
        routeValidationHistory.append((timestamp: now, isValid: isValid))
        
        // 保持历史记录不超过最大数量
        if routeValidationHistory.count > maxValidationHistory {
            routeValidationHistory.removeFirst()
        }
    }
    
    // 发送路由验证状态
    private func sendRouteValidationStatus(isValid: Bool, interfaceCount: Int) {
        let statusInfo: [String: Any] = [
            "type": "route_validation",
            "isValid": isValid,
            "timestamp": Date().timeIntervalSince1970,
            "interfaceCount": interfaceCount,
            "validationFailedCount": validationFailedCount
        ]
        sendMessageToApp(statusInfo)
    }
    
    // 尝试恢复连接
    private func attemptConnectionRecovery() {
        guard isRunning else {
            logger.warning("Skipping connection recovery: VPN not running")
            return
        }
        
        // 检查当前状态是否适合恢复
        guard currentState != .disconnected && currentState != .disconnecting && currentState != .stopping else {
            logger.warning("Skipping connection recovery: Current state not suitable")
            return
        }
        
        logger.info("Attempting connection recovery")
        
        // 保存状态为重新连接中
        saveVpnState(state: .reasserting)
        
        // 延迟一段时间后尝试恢复，避免立即重连
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            logger.info("Starting connection recovery process")
            self.restartVntIfNeeded()
        }
    }
    
    private func createNetworkSettings() -> NEPacketTunnelNetworkSettings? {
        logger.info("Creating network settings")
        
        guard let config = vpnConfig else {
            logger.warning("No VPN config available, using default settings")
            // 使用默认设置
            return createDefaultNetworkSettings()
        }
        
        // 创建VPN网络设置
        let remoteAddress = config["serverAddress"] as? String ?? "10.0.0.1"
        logger.info("Creating tunnel with remote address: \(remoteAddress)")
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        
        // 配置IPv4设置
        if let virtualIp = config["virtualIp"] as? String,
           let virtualNetmask = config["virtualNetmask"] as? String {
            
            logger.info("Configuring IPv4 with address: \(virtualIp), netmask: \(virtualNetmask)")
            let ipv4Settings = NEIPv4Settings(addresses: [virtualIp], subnetMasks: [virtualNetmask])
            
            // 配置路由
            ipv4Settings.includedRoutes = [NEIPv4Route.default()]
            logger.info("Configured default route for inclusion")
            
            // 如果有排除路由，添加它们
            if let excludedRoutes = config["excludedRoutes"] as? [[String: String]] {
                var neExcludedRoutes: [NEIPv4Route] = []
                for route in excludedRoutes {
                    if let destination = route["destination"],
                       let subnetMask = route["subnetMask"] {
                        let neRoute = NEIPv4Route(destinationAddress: destination, subnetMask: subnetMask)
                        neExcludedRoutes.append(neRoute)
                        logger.info("Added excluded route: \(destination)/\(subnetMask)")
                    }
                }
                ipv4Settings.excludedRoutes = neExcludedRoutes
                logger.info("Configured \(neExcludedRoutes.count) excluded routes")
            }
            
            settings.ipv4Settings = ipv4Settings
        } else {
            // 使用默认IPv4设置
            logger.info("Using default IPv4 settings")
            let ipv4Settings = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
            ipv4Settings.includedRoutes = [NEIPv4Route.default()]
            settings.ipv4Settings = ipv4Settings
        }
        
        // 配置DNS设置
        if let dnsServers = config["dnsServers"] as? [String], !dnsServers.isEmpty {
            logger.info("Configuring custom DNS servers: \(dnsServers.joined(separator: ", "))")
            settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        } else {
            // 使用默认DNS
            logger.info("Using default DNS servers: 8.8.8.8, 8.8.4.4")
            settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        }
        
        // 配置MTU
        if let mtu = config["mtu"] as? NSNumber {
            logger.info("Configuring custom MTU: \(mtu)")
            settings.mtu = mtu
        } else {
            logger.info("Using default MTU: 1280")
            settings.mtu = NSNumber(value: 1280)
        }
        
        logger.info("Network settings creation completed")
        return settings
    }
    
    private func createDefaultNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        
        let ipv4Settings = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings
        
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        settings.mtu = NSNumber(value: 1500)
        
        return settings
    }
    
    private func startHandlingPackets() {
        guard let packetFlow = packetFlow else {
            logger.error("Packet flow is nil")
            return
        }
        
        // 启动入站数据包处理线程
        Task {
            await processInboundPackets(packetFlow: self.packetFlow)
        }
        
        // 启动出站数据包处理线程
        Task {
            await processOutboundPackets()
        }
    }
    
    private func processInboundPackets(packetFlow: NEPacketTunnelFlow) async {
        logger.info("Starting inbound packet processing loop")
        
        // 启动路由验证
        startRouteValidation()
        
        while isRunning {
            do {
                // 读取入站数据包
                logger.debug("Waiting for inbound packets...")
                let (packets, protocols) = try await packetFlow.readPackets()
                
                // 检查内存使用情况
                checkMemoryUsage()
                
                // 记录接收到的数据包信息
                let totalBytes = packets.reduce(0) { $0 + $1.count }
                logger.info("Received \(packets.count) packets, total size: \(totalBytes) bytes")
                
                // 更新数据包统计
                packetStats.inboundPacketsCount += packets.count
                packetStats.inboundBytesCount += totalBytes
                
                // 处理每个数据包
                var processFailed = false
                for (index, packet) in packets.enumerated() {
                    do {
                        // 检查数据包大小是否有效
                        if packet.count == 0 {
                            logger.warning("Received empty packet, skipping")
                            continue
                        }
                        
                        // 检查是否超过最大数据包大小（通常MTU+一些头信息）
                        let maxPacketSize = (vpnConfig?["mtu"] as? NSNumber)?.intValue ?? 1500
                        if packet.count > maxPacketSize + 100 {
                            throw VpnError.packetProcessError(reason: "Packet too large: \(packet.count) bytes")
                        }
                        
                        // 检查最小数据包大小（IP头至少20字节）
                        if packet.count < 20 {
                            throw VpnError.packetProcessError(reason: "Packet too small: \(packet.count) bytes")
                        }
                        
                        // 检查VNT管理器是否有效
                        guard let vntManager = self.vntManager else {
                            throw VpnError.initializationFailed(reason: "VNT manager is nil")
                        }
                        
                        // 确保有足够内存
                        if !checkMemoryAvailability(size: packet.count) {
                            throw VpnError.memoryError
                        }
                        
                        // 发送数据包到vnt核心进行处理
                        let success = packet.withUnsafeBytes { rawBufferPointer in
                            if let baseAddress = rawBufferPointer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                                return vnt_send_ip(vntManager, baseAddress, Int32(packet.count))
                            }
                            return false
                        }
                        
                        if !success {
                            throw VpnError.packetProcessError(reason: "Failed to send packet to VNT library")
                        }
                        
                        logger.debug("Successfully sent packet to VNT library, size: \(packet.count) bytes")
                    } catch let error as VpnError {
                        recordError(error.description)
                        packetStats.packetProcessErrors += 1
                        
                        // 记录详细错误信息
                        if testModeEnabled {
                            logger.debug("Error processing packet at index \(index): \(error.description)")
                        }
                        
                        processFailed = true
                    } catch {
                        recordError("未知错误处理数据包: \(error.localizedDescription)")
                        packetStats.packetProcessErrors += 1
                        processFailed = true
                    }
                }
                
                // 如果处理失败，尝试恢复连接
                if processFailed {
                    logger.warning("Packet processing failures detected, triggering connection recovery")
                    attemptConnectionRecovery()
                    // 暂停一段时间避免频繁恢复
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                }
                
                // 定期发送统计报告（每100个数据包或测试模式下）
                if packetStats.inboundPacketsCount % 100 == 0 || testModeEnabled {
                    sendStatisticsReport()
                }
                
            } catch {
                logger.error("Error reading packets: \(error.localizedDescription)")
                
                // 网络错误时尝试恢复连接
                if isRunning {
                    logger.warning("Network read error detected, triggering connection recovery")
                    attemptConnectionRecovery()
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
        }
        
        logger.info("Inbound packet processing loop stopped")
    }
    
    // 发送统计报告到主应用
    private func sendStatisticsReport() {
        let report: [String: Any] = [
            "type": "statistics_report",
            "timestamp": Date().timeIntervalSince1970,
            "duration": Date().timeIntervalSince1970 - self.lastStatsResetTime,
            "packetStats": self.packetStats.toDictionary(),
            "errorCount": self.errorHistory.count
        ]
        
        sendMessageToApp(report)
        
        // 测试模式下记录统计信息
        if testModeEnabled {
            logger.info("Statistics report sent")
        }
    }
    }
    
    private func processOutboundPackets() async {
        logger.info("Starting outbound packet processing")
        
        // 创建VNT等待任务
        vntWaitTask = Task {
            logger.info("Starting VNT wait loop")
            while isRunning && !Task.isCancelled {
                // 调用vnt_wait来等待处理完成
                vnt_wait(vntManager)
                
                // 短暂暂停避免CPU占用过高
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            logger.info("VNT wait loop stopped")
        }
    }
    
    // 初始化VNT库
    private func initializeVNT() -> Bool {
        logger.info("Initializing VNT library")
        
        // 检查内存使用情况
        checkMemoryUsage()
        
        guard let config = vpnConfig else {
            logger.error("No VPN config available for VNT initialization")
            return false
        }
        
        // 重置路由验证状态
        resetRouteValidationState()
        
        // 创建VNT配置
        var vntConfig = VntConfig()
        
        // 添加defer块，确保函数退出时(无论成功失败)都释放C字符串内存
        defer {
            freeVntConfigMemory(&vntConfig)
        }
        
        do {
            // 安全地分配和复制字符串
            vntConfig.token = try allocateAndCopyString(config["token"] as? String ?? "")
            vntConfig.device_id = try allocateAndCopyString(config["deviceId"] as? String)
            vntConfig.name = try allocateAndCopyString(config["name"] as? String ?? "iOS Device")
            vntConfig.server_address = try allocateAndCopyString(config["serverAddress"] as? String ?? "")
            vntConfig.dns = try allocateAndCopyString(config["dnsServers"] as? [String]?.flatMap { $0.joined(separator: ",") })
            vntConfig.password = try allocateAndCopyString(config["password"] as? String)
            vntConfig.virtual_ip = try allocateAndCopyString(config["virtualIp"] as? String)
            
            // 设置其他配置参数
            vntConfig.stun_server = nil
            vntConfig.in_ip = nil
            vntConfig.out_ip = nil
            vntConfig.mtu = Int32((config["mtu"] as? NSNumber)?.intValue ?? 1500)
            vntConfig.server_encrypt = (config["serverEncrypt"] as? Bool) ?? true
            vntConfig.allow_wire_guard = (config["allowWireGuard"] as? Bool) ?? false
            
            // 创建回调
            var callbacks = VntCallbacks()
            callbacks.success = vntSuccessCallback
            callbacks.connect = vntConnectCallback
            callbacks.handshake = vntHandshakeCallback
            callbacks.register_ = vntRegisterCallback
            callbacks.error = vntErrorCallback
            callbacks.stop = vntStopCallback
            callbacks.peer_client_list = vntPeerClientListCallback
            
            // 初始化VNT
            vntManager = vnt_create(&vntConfig, &callbacks)
            if vntManager == nil {
                throw VpnError.initializationFailed(reason: "Failed to create VNT manager")
            }
            
            // 注册数据包发送回调
            vnt_set_packet_send_callback(vntPacketSendCallback)
            logger.info("VNT packet send callback registered")
            
            // 测试模式下验证初始化
            if testModeEnabled {
                validateVntInitialization()
            }
            
            logger.info("VNT library initialized successfully")
            return true
        } catch {
            // 记录错误
            let errorMessage = "VNT initialization error: \(error.localizedDescription)"
            recordError(errorMessage)
            logger.error(errorMessage)
            
            // 不再需要在这里手动释放内存，defer会处理
            
            return false
        }
    }
    
    // 安全地分配和复制字符串
    private func allocateAndCopyString(_ str: String?) throws -> UnsafePointer<CChar>? {
        guard let str = str else {
            return nil
        }
        
        // 检查内存可用性
        if !checkMemoryAvailability(size: str.count + 1) {
            throw VpnError.memoryError
        }
        
        guard let cString = strdup(str) else {
            throw VpnError.memoryError
        }
        
        return cString
    }
    
    // 检查内存可用性
    private func checkMemoryAvailability(size: Int) -> Bool {
        // 简单的内存可用性检查
        let freeMemory = getFreeMemory()
        // 确保有至少10倍于请求大小的可用内存
        return freeMemory > UInt64(size * 10)
    }
    
    // 获取可用内存
    private func getFreeMemory() -> UInt64 {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size)/4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return UInt64(taskInfo.free_count)
        } else {
            logger.error("Failed to get memory info")
            return 0
        }
    }
    
    // 检查内存使用情况
    private func checkMemoryUsage() {
        let freeMemory = getFreeMemory()
        logger.info("Current free memory: \(freeMemory) bytes")
        
        // 如果可用内存低于警告阈值，记录警告
        let warningThreshold: UInt64 = 50 * 1024 * 1024 // 50MB
        if freeMemory < warningThreshold {
            logger.warning("Low memory warning: Only \(freeMemory/1024/1024) MB free")
            recordError("Low memory warning")
        }
    }
    
    // 清理VNT配置内存
    private func freeVntConfigMemory(_ config: inout VntConfig) {
        // 释放所有已分配的C字符串
        free(UnsafeMutablePointer(mutating: config.token))
        free(UnsafeMutablePointer(mutating: config.device_id))
        free(UnsafeMutablePointer(mutating: config.name))
        free(UnsafeMutablePointer(mutating: config.server_address))
        free(UnsafeMutablePointer(mutating: config.dns))
        free(UnsafeMutablePointer(mutating: config.stun_server))
        free(UnsafeMutablePointer(mutating: config.in_ip))
        free(UnsafeMutablePointer(mutating: config.out_ip))
        free(UnsafeMutablePointer(mutating: config.password))
        free(UnsafeMutablePointer(mutating: config.virtual_ip))
        
        // 重置指针为nil
        config.token = nil
        config.device_id = nil
        config.name = nil
        config.server_address = nil
        config.dns = nil
        config.stun_server = nil
        config.in_ip = nil
        config.out_ip = nil
        config.password = nil
        config.virtual_ip = nil
    }
    
    // 验证VNT初始化
    private func validateVntInitialization() {
        guard let manager = vntManager else {
            logger.error("Cannot validate VNT initialization: manager is nil")
            return
        }
        
        logger.info("Validating VNT initialization in test mode")
        // 这里可以添加额外的验证逻辑
        // 例如检查必要的回调是否已注册，或执行其他测试
    }
    
    // 测试辅助方法：注入模拟错误
    private func injectTestError(_ errorType: VpnError) {
        guard testModeEnabled else {
            logger.warning("尝试在非测试模式下注入测试错误")
            return
        }
        
        recordError("[测试模式] 注入模拟错误: \(errorType.description)")
        sendErrorReport("[测试模式] \(errorType.description)")
        
        // 根据错误类型执行不同的恢复操作
        switch errorType {
        case .memoryError:
            // 模拟内存错误处理
            checkMemoryUsage()
        case .connectionError:
            // 模拟连接错误恢复
            attemptConnectionRecovery()
        case .packetProcessError:
            // 模拟数据包处理错误
            packetStats.packetProcessErrors += 1
        default:
            break
        }
    }
    
    // 测试辅助方法：获取当前VPN状态的详细信息
    private func getDetailedStateInfo() -> [String: Any] {
        var stateInfo: [String: Any] = [
            "currentState": currentState.rawValue,
            "isRunning": isRunning,
            "hasVntManager": vntManager != nil,
            "testModeEnabled": testModeEnabled,
            "uptime": Date().timeIntervalSince1970 - lastStatsResetTime,
            "errorCount": errorHistory.count
        ]
        
        // 添加统计信息
        stateInfo["statistics"] = packetStats.toDictionary()
        
        // 测试模式下添加更多详细信息
        if testModeEnabled {
            stateInfo["memoryInfo"] = ["freeMemory": getFreeMemory()]
            stateInfo["lastErrors"] = errorHistory.suffix(5).map { ["timestamp": $0.timestamp, "error": $0.error] }
        }
        
        return stateInfo
    }
    
    // 发送数据包到网络
    private func sendPacketsToNetwork(_ packets: [Data]) {
        guard !packets.isEmpty else {
            return
        }
        
        // 创建协议数组（假设都是IPv4）
        let protocols: [NSNumber] = Array(repeating: NSNumber(value: AF_INET), count: packets.count)
        
        // 发送数据包
        writePackets(packets, withProtocols: protocols)
    }
    
    // 发送数据包到网络
    private func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) {
        guard let packetFlow = packetFlow else {
            logger.error("Packet flow is nil when writing packets")
            return
        }
        
        packetFlow.writePackets(packets, withProtocols: protocols)
    }
    
    // 向主应用发送消息
    private func sendMessageToApp(_ message: [String: Any]) {
        do {
            let messageData = try JSONSerialization.data(withJSONObject: message)
            sendProviderMessage(messageData) { responseData in
                // 处理响应
                if let responseData = responseData {
                    do {
                        if let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
                            self.logger.debug("Received response from app: \(response)")
                        }
                    } catch {
                        self.logger.error("Error parsing response: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            logger.error("Error sending message to app: \(error.localizedDescription)")
        }
    }
    
    // 发送数据包到TUN接口的C回调函数
    private static let vntPacketSendCallback: @convention(c) (UnsafeRawPointer, CInt) -> Void = { data, length in
        // 获取全局PacketTunnelProvider实例
        if let provider = PacketTunnelProvider.currentProvider {
            provider.sendPacketsFromRust(data: data, length: length)
        }
    }
    
    // 接收Rust发来的数据包并发送到网络
    func sendPacketsFromRust(data: UnsafeRawPointer, length: CInt) {
        do {
            // 参数安全检查
            guard data != nil else {
                throw VpnError.packetProcessError(reason: "无效的数据包指针")
            }
            
            let dataSize = Int(length)
            
            // 数据包大小验证
            guard dataSize > 0 else {
                throw VpnError.packetProcessError(reason: "数据包大小为0")
            }
            
            // 最大数据包大小限制（MTU + 100字节缓冲）
            let maxPacketSize = 16384 + 100 // 保守估计的最大MTU + 缓冲
            guard dataSize <= maxPacketSize else {
                throw VpnError.packetProcessError(reason: "数据包过大: \(dataSize) bytes")
            }
            
            // 最小数据包大小检查（至少包含IP头）
            guard dataSize >= 20 else {
                throw VpnError.packetProcessError(reason: "数据包过小: \(dataSize) bytes")
            }
            
            // 内存使用检查
            checkMemoryUsage()
            
            // 安全创建数据包
            let packetData = Data(bytes: data, count: dataSize)
            
            if testModeEnabled {
                logger.debug("[测试模式] 接收Rust数据包, 大小: \(dataSize) bytes")
            }
            
            // 更新统计信息
            packetStats.outboundPacketsCount += 1
            packetStats.outboundBytesCount += dataSize
            
            // 发送数据包到网络
            sendPacketsToNetwork([packetData])
            
            // 定期发送统计报告
            if packetStats.outboundPacketsCount % 100 == 0 {
                sendStatisticsReport()
            }
            
        } catch let error as VpnError {
            // 错误处理
            packetStats.packetProcessErrors += 1
            recordError("发送Rust数据包失败: \(error.description)")
            
            if testModeEnabled {
                sendErrorReport("\(error.description)")
            }
            
            // 错误率过高时尝试恢复连接
            if packetStats.packetProcessErrors > 100 {
                logger.warning("数据包处理错误率过高，尝试恢复连接")
                attemptConnectionRecovery()
                packetStats.reset()
            }
        } catch {
            // 捕获其他未知错误
            recordError("发送Rust数据包时发生未知错误: \(error.localizedDescription)")
        }
    }
}

// VNT回调函数
func vntSuccessCallback() {
    print("VNT connected successfully")
    if let provider = currentPacketTunnelProvider {
        provider.logger.info("VNT connection successful")
        // 更新VPN状态为已连接
        provider.saveVpnState(state: .connected)
        provider.sendMessageToApp(["type": "success", "message": "VPN connected successfully"])
    }
}

func vntConnectCallback(_ info: UnsafePointer<CChar>) {
    let infoStr = String(cString: info)
    print("VNT connecting: \(infoStr)")
    if let provider = currentPacketTunnelProvider {
        provider.logger.info("VNT connecting: \(infoStr)")
        // 更新VPN状态为连接中
        provider.saveVpnState(state: .connecting)
        provider.sendMessageToApp(["type": "connect", "info": infoStr])
    }
}

func vntHandshakeCallback(_ info: UnsafePointer<CChar>) -> Bool {
    let infoStr = String(cString: info)
    print("VNT handshake: \(infoStr)")
    if let provider = currentPacketTunnelProvider {
        provider.logger.info("VNT handshake: \(infoStr)")
    }
    // 默认接受所有握手
    return true
}

func vntRegisterCallback(_ info: UnsafePointer<CChar>) -> Bool {
    let infoStr = String(cString: info)
    print("VNT register: \(infoStr)")
    if let provider = currentPacketTunnelProvider {
        provider.logger.info("VNT register: \(infoStr)")
    }
    // 默认接受所有注册
    return true
}

func vntErrorCallback(_ info: UnsafePointer<CChar>) {
    let infoStr = String(cString: info)
    print("VNT error: \(infoStr)")
    if let provider = currentPacketTunnelProvider {
        provider.logger.error("VNT error: \(infoStr)")
        // 更新VPN状态为断开连接
        provider.saveVpnState(state: .disconnected)
        provider.sendMessageToApp(["type": "error", "info": infoStr])
        
        // 对于可恢复的错误，尝试重新连接
        if provider.isRunning {
            provider.logger.info("Attempting to reconnect after VNT error")
            provider.attemptConnectionRecovery()
        }
    }
}

func vntStopCallback() {
    print("VNT stopped")
    if let provider = currentPacketTunnelProvider {
        provider.logger.info("VNT stopped")
        // 更新VPN状态为断开连接
        provider.saveVpnState(state: .disconnected)
        provider.sendMessageToApp(["type": "stop"])
    }
}

func vntPeerClientListCallback(_ info: UnsafePointer<CChar>) {
    let infoStr = String(cString: info)
    print("VNT peer list: \(infoStr)")
    if let provider = currentPacketTunnelProvider {
        provider.logger.info("VNT peer list received: \(infoStr)")
        provider.sendMessageToApp(["type": "peer_list", "info": infoStr])
    }
}

// VNT库的C接口已通过私有方法声明