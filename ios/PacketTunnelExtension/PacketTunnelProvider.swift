import NetworkExtension
import os.log
import Foundation
import Darwin

/// VNT Packet Tunnel Extension Provider
///
/// Architecture: This Extension is the SOLE reader/writer of packetFlow.
/// It reads IP packets from the tunnel via `readPackets`, forwards them to the
/// main app's Rust code via a pipe. Conversely, it reads packets from another
/// pipe (written by Rust) and injects them into the tunnel via `writePackets`.
///
/// Data Flow (receiving from tunnel):
///   packetFlow.readPackets → [Data] → write to extToApp pipe → Rust read(fd) → process
///
/// Data Flow (sending to tunnel):
///   Rust write(fd) → write to appToExt pipe → read from appToExt pipe → packetFlow.writePackets
///
/// FD Transfer:
///   Extension creates 2 pipe pairs, sends app-read + app-write ends via SCM_RIGHTS.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private static let log = OSLog(subsystem: "top.wherewego.vntApp.PacketTunnel", category: "PacketTunnel")
    
    private static let appGroupIdentifier = "group.io.mt64.v4"
    
    /// Shared UserDefaults via App Group
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupIdentifier)
    }
    
    /// Log file URL in App Group shared container (readable by Flutter)
    private var logFileURL: URL {
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        return (containerURL?.appendingPathComponent("extension.log")) ?? URL(fileURLWithPath: "/tmp/extension.log")
    }
    
    /// Write a log line to the shared log file (timestamped, Flutter-readable)
    private func logToFile(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    // Keep log file under 100KB
                    if handle.offsetInFile > 100_000 {
                        handle.truncateFile(atOffset: 0)
                        handle.write(data)
                    }
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
        os_log("%{public}@", log: Self.log, type: .info, message)
    }
    
    /// Whether the tunnel is running
    private var isRunning = false
    
    /// Pipe file descriptors:
    /// extToApp[0] = Extension writes to, App reads from
    /// extToApp[1] = (App's read end — sent via SCM_RIGHTS)
    /// appToExt[0] = (App's write end — sent via SCM_RIGHTS)
    /// appToExt[1] = Extension reads from, App writes to
    private var extToAppWriteFd: Int32 = -1   // Extension writes received packets here
    private var appToExtReadFd: Int32 = -1    // Extension reads packets to send from here
    
    /// Unix Domain Socket server for fd transfer
    private var socketPath: String {
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        return (containerURL?.appendingPathComponent("vnt_fd.sock").path) ?? "/tmp/vnt_fd.sock"
    }
    
    private var listenSocket: Int32 = -1
    
    // MARK: - NEPacketTunnelProvider Lifecycle
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logToFile("=== startTunnel called ===")
        logToFile("Previous state: isRunning=\(isRunning), extToAppWriteFd=\(extToAppWriteFd), appToExtReadFd=\(appToExtReadFd), listenSocket=\(listenSocket), fdsToTransfer.count=\(fdsToTransfer.count)")
        
        guard let sharedDefaults = sharedDefaults else {
            logToFile("ERROR: Failed to access shared UserDefaults")
            let error = NSError(domain: "VNTTunnelError", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to access shared UserDefaults"])
            completionHandler(error)
            return
        }
        
        // Read configuration from shared defaults
        guard let configData = sharedDefaults.data(forKey: "tunnelConfig"),
              let config = try? JSONDecoder().decode(TunnelConfig.self, from: configData) else {
            logToFile("ERROR: Invalid tunnel configuration")
            let error = NSError(domain: "VNTTunnelError", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel configuration"])
            completionHandler(error)
            return
        }
        
        logToFile("Tunnel config: virtualIp=\(config.virtualIp), netmask=\(config.virtualNetmask), gateway=\(config.virtualGateway), mtu=\(config.mtu), dns=\(config.dnsServers), remote=\(config.tunnelRemoteAddress), routes=\(config.externalRoutes.map { "\($0.destination)/\($0.netmask)" }))")
        
        // Create pipe pairs for communication with Rust
        var extToAppPipe: [Int32] = [-1, -1]
        var appToExtPipe: [Int32] = [-1, -1]
        
        guard pipe(&extToAppPipe) == 0 else {
            logToFile("ERROR: Failed to create extToApp pipe: errno=\(errno)")
            let error = NSError(domain: "VNTTunnelError", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to create extToApp pipe: errno=\(errno)"])
            completionHandler(error)
            return
        }
        guard pipe(&appToExtPipe) == 0 else {
            logToFile("ERROR: Failed to create appToExt pipe: errno=\(errno)")
            close(extToAppPipe[0])
            close(extToAppPipe[1])
            let error = NSError(domain: "VNTTunnelError", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to create appToExt pipe: errno=\(errno)"])
            completionHandler(error)
            return
        }
        
        // extToAppPipe: [0]=read end (App reads), [1]=write end (Extension writes)
        // appToExtPipe: [0]=read end (Extension reads), [1]=write end (App writes)
        extToAppWriteFd = extToAppPipe[1]  // Extension keeps the write end
        appToExtReadFd = appToExtPipe[0]   // Extension keeps the read end
        let appReadFd = extToAppPipe[0]    // App gets this via SCM_RIGHTS
        let appWriteFd = appToExtPipe[1]   // App gets this via SCM_RIGHTS
        
        logToFile("Pipes created: extToAppWriteFd=\(extToAppWriteFd), appToExtReadFd=\(appToExtReadFd), appReadFd=\(appReadFd), appWriteFd=\(appWriteFd)")
        
        // Store fds for SCM_RIGHTS transfer
        self.fdsToTransfer = [appReadFd, appWriteFd]
        
        // CRITICAL: Mark as running and start ALL loops BEFORE configuring network settings.
        // This ensures the Extension stays alive (packetFlow is being read) while
        // setTunnelNetworkSettings completes asynchronously.
        isRunning = true
        
        // Start reading packets from the tunnel FIRST — this keeps Extension alive
        startPacketReading()
        
        // Start reading from appToExt pipe and writing to tunnel
        startPipeToTunnelForwarding()
        
        // Start Unix Domain Socket server for fd transfer
        startFdTransferServer()
        
        logToFile("All loops started, configuring network settings before completing startTunnel")
        
        // Configure routes/DNS first. iOS-generated traffic will not reliably enter the
        // packet tunnel until these settings are applied.
        configureNetworkSettings(config: config) { [weak self] error in
            guard let self = self else {
                completionHandler(NSError(domain: "VNTTunnelError", code: 99,
                                          userInfo: [NSLocalizedDescriptionKey: "PacketTunnelProvider released during startup"]))
                return
            }
            if let error = error {
                self.logToFile("ERROR: Failed to configure network settings: \(error.localizedDescription)")
                self.isRunning = false
                if self.extToAppWriteFd >= 0 { close(self.extToAppWriteFd); self.extToAppWriteFd = -1 }
                if self.appToExtReadFd >= 0 { close(self.appToExtReadFd); self.appToExtReadFd = -1 }
                for fd in self.fdsToTransfer {
                    if fd >= 0 { close(fd) }
                }
                self.fdsToTransfer.removeAll()
                if self.listenSocket >= 0 {
                    close(self.listenSocket)
                    self.listenSocket = -1
                }
                try? FileManager.default.removeItem(atPath: self.socketPath)
                sharedDefaults.set(false, forKey: "tunnelReady")
                sharedDefaults.removeObject(forKey: "tunnelReadyTime")
                completionHandler(error)
                return
            }

            self.logToFile("Network settings configured successfully")
            sharedDefaults.set(true, forKey: "tunnelReady")
            sharedDefaults.set(Date().timeIntervalSince1970, forKey: "tunnelReadyTime")
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logToFile("=== stopTunnel called, reason=\(reason.rawValue) ===")
        // Flush remaining log data
        logToFile("readPacketsLoop forwarded \(packetCount) total packets before stop")
        
        // Mark as not running FIRST so that all loops stop
        isRunning = false
        
        // Close ALL pipe fds (including the App-side ends in fdsToTransfer)
        if extToAppWriteFd >= 0 { close(extToAppWriteFd); extToAppWriteFd = -1 }
        if appToExtReadFd >= 0 { close(appToExtReadFd); appToExtReadFd = -1 }
        for fd in fdsToTransfer {
            if fd >= 0 { close(fd) }
        }
        fdsToTransfer.removeAll()
        
        // Notify main app immediately
        sharedDefaults?.set(false, forKey: "tunnelReady")
        sharedDefaults?.removeObject(forKey: "tunnelReadyTime")
        
        // Close socket server
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
        
        // Remove socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Reset packet counter
        packetCount = 0
        
        // Stop the tunnel
        super.stopTunnel(with: reason) { [weak self] in
            self?.logToFile("Packet tunnel stopped")
            completionHandler()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let message = String(data: messageData, encoding: .utf8) {
            os_log("Received app message: %{public}@", log: Self.log, type: .info, message)
            
            switch message {
            case "getStatus":
                let response = isRunning ? "running" : "stopped"
                completionHandler?(response.data(using: .utf8))
            default:
                completionHandler?(nil)
            }
        } else {
            completionHandler?(nil)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        os_log("Tunnel going to sleep", log: Self.log, type: .info)
        completionHandler()
    }
    
    override func wake() {
        os_log("Tunnel waking up", log: Self.log, type: .info)
    }
    
    // MARK: - Packet Flow I/O
    
    /// Continuously read packets from the tunnel and forward them to the app via pipe.
    /// This keeps the Extension alive because iOS requires active packetFlow usage.
    private func startPacketReading() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.readPacketsLoop()
        }
    }
    
    /// Write all bytes to a file descriptor, handling partial writes
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var remaining = data.count
        var offset = 0
        while remaining > 0 {
            let written = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!.advanced(by: offset), remaining)
            }
            guard written > 0 else {
                logToFile("writeAll FAILED: write() returned error, errno=\(errno)")
                return false
            }
            offset += written
            remaining -= written
        }
        return true
    }

    private var packetCount = 0
    private var lastHeartbeatLog = Date()
    private var outboundPacketDetailCount = 0

    private func ipv4AddressString(from packet: Data, start: Int) -> String? {
        guard packet.count >= start + 4 else { return nil }
        return [
            String(packet[start]),
            String(packet[start + 1]),
            String(packet[start + 2]),
            String(packet[start + 3])
        ].joined(separator: ".")
    }

    private func protocolName(_ proto: UInt8) -> String {
        switch proto {
        case 1:
            return "ICMP"
        case 6:
            return "TCP"
        case 17:
            return "UDP"
        default:
            return "PROTO_\(proto)"
        }
    }

    private func logOutboundPacketDetail(packet: Data, protocolFamily: NSNumber, index: Int) {
        guard outboundPacketDetailCount < 20 else { return }
        outboundPacketDetailCount += 1

        let family = protocolFamily.int32Value
        guard family == AF_INET else {
            logToFile("readPacketsLoop: packet#\(outboundPacketDetailCount) family=\(family) size=\(packet.count) index=\(index)")
            return
        }

        guard packet.count >= 20 else {
            logToFile("readPacketsLoop: packet#\(outboundPacketDetailCount) family=AF_INET size=\(packet.count) index=\(index) invalid=short-ipv4")
            return
        }

        let version = packet[0] >> 4
        let ihl = Int(packet[0] & 0x0F) * 4
        guard version == 4, ihl >= 20, packet.count >= ihl else {
            logToFile("readPacketsLoop: packet#\(outboundPacketDetailCount) family=AF_INET size=\(packet.count) index=\(index) invalid=bad-ipv4-header")
            return
        }

        let proto = packet[9]
        let src = ipv4AddressString(from: packet, start: 12) ?? "?"
        let dst = ipv4AddressString(from: packet, start: 16) ?? "?"
        logToFile("readPacketsLoop: packet#\(outboundPacketDetailCount) family=AF_INET proto=\(protocolName(proto)) src=\(src) dst=\(dst) size=\(packet.count) index=\(index)")
    }

    private func readPacketsLoop() {
        guard isRunning else { return }

        // Read packets from packetFlow (asynchronous)
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }

            if !packets.isEmpty {
                // Forward each packet to the app via the extToApp pipe.
                // Wire format: [4-byte BE total_length][4-byte BE protocol_family][IP packet data]
                // total_length = 4 (protocol_family) + IP_packet_length
                for (index, packet) in packets.enumerated() {
                    let proto = protocols[index].int32Value
                    self.logOutboundPacketDetail(packet: packet, protocolFamily: protocols[index], index: index)

                    var totalLen = UInt32(4 + packet.count).bigEndian
                    var protoVal = UInt32(proto).bigEndian

                    // Build complete message in one contiguous buffer to avoid partial write issues
                    var message = Data(capacity: 8 + packet.count)
                    message.append(Data(bytes: &totalLen, count: 4))
                    message.append(Data(bytes: &protoVal, count: 4))
                    message.append(packet)

                    if !self.writeAll(self.extToAppWriteFd, message) {
                        logToFile("readPacketsLoop: failed to write packet #\(index) to pipe, fd=\(self.extToAppWriteFd)")
                        // Don't break — try remaining packets
                    }
                }
                
                self.packetCount += packets.count
                
                // Heartbeat log every 100 packets or every 10 seconds
                let now = Date()
                if self.packetCount % 100 == 0 || now.timeIntervalSince(self.lastHeartbeatLog) > 10 {
                    self.logToFile("readPacketsLoop: forwarded \(self.packetCount) packets total (this batch: \(packets.count))")
                    self.lastHeartbeatLog = now
                }
            }

            // Continue reading
            self.readPacketsLoop()
        }
    }
    
    /// Continuously read packets from the appToExt pipe and write them to the tunnel.
    private func startPipeToTunnelForwarding() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.pipeToTunnelLoop()
        }
    }
    
    private var pipeToTunnelPacketCount = 0
    private var lastPipeToTunnelLog = Date()

    private func readExact(from fd: Int32, into buffer: UnsafeMutableRawPointer, byteCount: Int) -> Bool {
        var offset = 0
        while offset < byteCount {
            let n = read(fd, buffer.advanced(by: offset), byteCount - offset)
            if n > 0 {
                offset += n
                continue
            }
            if n == 0 {
                logToFile("pipeToTunnel: pipe closed while reading, got \(offset)/\(byteCount)")
                return false
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(1_000)
                continue
            }
            logToFile("pipeToTunnel: readExact failed, got \(offset)/\(byteCount), errno=\(errno)")
            return false
        }
        return true
    }

    private func pipeToTunnelLoop() {
        guard isRunning, appToExtReadFd >= 0 else { return }

        // Wire format from Rust: [4-byte BE total_length][4-byte BE protocol_family][IP packet data]
        // total_length = 4 (proto) + IP_packet_length

        // Read total_length prefix (4 bytes)
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        guard lengthBytes.withUnsafeMutableBytes({ raw in
            readExact(from: appToExtReadFd, into: raw.baseAddress!, byteCount: 4)
        }) else {
            return
        }

        let totalLength = UInt32(bigEndian: lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) })

        guard totalLength >= 4 && totalLength <= 65535 + 4 else {
            logToFile("pipeToTunnel: INVALID total length \(totalLength)")
            return
        }

        let packetLength = Int(totalLength - 4) // subtract protocol_family bytes

        // Read protocol_family (4 bytes)
        var protoBytes = [UInt8](repeating: 0, count: 4)
        guard protoBytes.withUnsafeMutableBytes({ raw in
            readExact(from: appToExtReadFd, into: raw.baseAddress!, byteCount: 4)
        }) else {
            return
        }

        let protocolFamily = Int32(bitPattern: UInt32(bigEndian: protoBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))

        // Read packet data
        var packetData = [UInt8](repeating: 0, count: packetLength)
        guard packetData.withUnsafeMutableBytes({ raw in
            readExact(from: appToExtReadFd, into: raw.baseAddress!, byteCount: packetLength)
        }) else {
            return
        }

        // Write to tunnel via packetFlow.writePackets with the correct protocol family
        let packet = Data(packetData)
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: protocolFamily)])

        pipeToTunnelPacketCount += 1
        let now = Date()
        if pipeToTunnelPacketCount <= 10 || pipeToTunnelPacketCount % 100 == 0 || now.timeIntervalSince(lastPipeToTunnelLog) > 10 {
            logToFile("pipeToTunnel: injected \(pipeToTunnelPacketCount) packets total, lastSize=\(packet.count), proto=\(protocolFamily)")
            lastPipeToTunnelLog = now
        }

        // Continue reading
        pipeToTunnelLoop()
    }
    
    // MARK: - File Descriptor Transfer
    
    /// FDs to transfer to the main app via SCM_RIGHTS
    private var fdsToTransfer: [Int32] = []
    
    /// Start a Unix Domain Socket server to transfer pipe fds to the main app
    private func startFdTransferServer() {
        // Remove existing socket file if present
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Create Unix Domain Socket
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            os_log("Failed to create Unix Domain Socket: %d", log: Self.log, type: .error, errno)
            return
        }
        listenSocket = sock
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = socketPath.cString(using: .utf8)!
        // Copy path into sun_path using raw bytes
        let pathCount = min(pathData.count - 1, 103) // exclude null, leave room
        withUnsafeMutableBytes(of: &addr) { rawPtr in
            let sunPathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 2
            let dest = rawPtr.baseAddress!.advanced(by: sunPathOffset)
            memcpy(dest, pathData, pathCount)
            dest.advanced(by: pathCount).initializeMemory(as: UInt8.self, to: 0)
        }
        
        // Bind
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPtr in
                bind(sock, reboundPtr, addrLen)
            }
        }
        
        guard bindResult == 0 else {
            os_log("Failed to bind Unix Domain Socket: %d", log: Self.log, type: .error, errno)
            close(sock)
            listenSocket = -1
            return
        }
        
        // Listen
        guard listen(sock, 5) == 0 else {
            os_log("Failed to listen on Unix Domain Socket: %d", log: Self.log, type: .error, errno)
            close(sock)
            listenSocket = -1
            return
        }
        
        os_log("FD transfer server started at: %{public}@", log: Self.log, type: .info, socketPath)
        
        // Accept connections in a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptAndSendFd()
        }
    }
    
    /// Accept connection from main app and send the pipe fds via SCM_RIGHTS
    /// fd[0] = app's read end (Extension → App)
    /// fd[1] = app's write end (App → Extension)
    private func acceptAndSendFd() {
        guard isRunning else { return }
        
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        
        let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPtr in
                accept(listenSocket, reboundPtr, &clientAddrLen)
            }
        }
        
        guard clientSock >= 0 else {
            if isRunning && listenSocket >= 0 {
                os_log("Accept failed: %d", log: Self.log, type: .error, errno)
                // Retry after a short delay
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.acceptAndSendFd()
                }
            }
            return
        }
        
        os_log("Main app connected for fd transfer", log: Self.log, type: .info)
        
        // Send the pipe fds using sendmsg with SCM_RIGHTS
        let result = sendFileDescriptors(sock: clientSock, fdsToSend: fdsToTransfer)
        
        if result {
            os_log("Successfully sent fds %@ to main app", log: Self.log, type: .info, fdsToTransfer)
        } else {
            os_log("Failed to send fds: %d", log: Self.log, type: .error, errno)
        }
        
        close(clientSock)
    }
    
    /// Send multiple file descriptors to a connected Unix Domain Socket using SCM_RIGHTS
    private func sendFileDescriptors(sock: Int32, fdsToSend: [Int32]) -> Bool {
        guard !fdsToSend.isEmpty else { return false }
        
        var buf = [UInt8](repeating: 0, count: 1) // Dummy data
        
        // Control message buffer: cmsghdr + N fds
        let cmsgDataSize = MemoryLayout<Int32>.size * fdsToSend.count
        let cmsgBufferSize = MemoryLayout<cmsghdr>.size + cmsgDataSize
        var cmsgBuffer = [UInt8](repeating: 0, count: cmsgBufferSize)
        
        // Set up the control message header
        cmsgBuffer.withUnsafeMutableBytes { cmsgRaw in
            guard let cmsg = cmsgRaw.baseAddress?.assumingMemoryBound(to: cmsghdr.self) else { return }
            cmsg.pointee.cmsg_len = socklen_t(MemoryLayout<cmsghdr>.size + cmsgDataSize)
            cmsg.pointee.cmsg_level = SOL_SOCKET
            cmsg.pointee.cmsg_type = SCM_RIGHTS
            
            // Copy the fds into the control message data
            for (index, fd) in fdsToSend.enumerated() {
                let fdPtr = cmsgRaw.baseAddress!.advanced(by: MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size * index)
                    .assumingMemoryBound(to: Int32.self)
                fdPtr.pointee = fd
            }
        }
        
        var msg = msghdr()
        msg.msg_name = nil
        msg.msg_namelen = 0
        msg.msg_iovlen = 1
        msg.msg_controllen = socklen_t(cmsgBufferSize)
        
        let sendResult = buf.withUnsafeMutableBufferPointer { bufPtr in
            var iov = iovec(iov_base: bufPtr.baseAddress, iov_len: 1)
            return withUnsafeMutablePointer(to: &iov) { iovPtr in
                cmsgBuffer.withUnsafeMutableBufferPointer { cmsgPtr in
                    msg.msg_iov = iovPtr
                    msg.msg_control = cmsgPtr.baseAddress.map { UnsafeMutableRawPointer($0) }
                    return withUnsafeBytes(of: &msg) { msgBytes in
                        sendmsg(sock, msgBytes.baseAddress!.assumingMemoryBound(to: msghdr.self), 0)
                    }
                }
            }
        }
        
        return sendResult >= 0
    }
    
    // MARK: - Network Configuration
    
    private func configureNetworkSettings(config: TunnelConfig, completion: @escaping (Error?) -> Void) {
        let settings = createTunnelNetworkSettings(config: config)
        setTunnelNetworkSettings(settings) { error in
            completion(error)
        }
    }
    
    private func createTunnelNetworkSettings(config: TunnelConfig) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: config.tunnelRemoteAddress)
        
        // Set IPv4 address and subnet
        let ipv4Settings = NEIPv4Settings(addresses: [config.virtualIp], subnetMasks: [config.virtualNetmask])
        
        // Route VPN subnet through the tunnel
        let vpnRoute = NEIPv4Route(destinationAddress: config.virtualNetwork, subnetMask: config.virtualNetmask)
        ipv4Settings.includedRoutes = [vpnRoute]
        
        // Add external routes
        var includedRoutes: [NEIPv4Route] = [vpnRoute]
        for route in config.externalRoutes {
            let externalRoute = NEIPv4Route(destinationAddress: route.destination, subnetMask: route.netmask)
            includedRoutes.append(externalRoute)
        }
        ipv4Settings.includedRoutes = includedRoutes
        
        // Exclude the tunnel server to avoid routing loop
        if let serverAddress = config.tunnelServerAddress,
           let serverIPv4 = parseServerIPv4(serverAddress) {
            let serverRoute = NEIPv4Route(destinationAddress: serverIPv4, subnetMask: "255.255.255.255")
            ipv4Settings.excludedRoutes = [serverRoute]
            logToFile("Added excluded route for tunnel server: \(serverIPv4)/32")
        } else if let serverAddress = config.tunnelServerAddress, !serverAddress.isEmpty {
            logToFile("Skip excluded route: invalid tunnelServerAddress=\(serverAddress)")
        }
        
        settings.ipv4Settings = ipv4Settings
        settings.mtu = NSNumber(value: config.mtu)
        
        // DNS settings — use system default DNS to avoid breaking the host's DNS resolution
        // Only override DNS if the config explicitly provides servers AND is not empty
        if !config.dnsServers.isEmpty {
            let dnsSettings = NEDNSSettings(servers: config.dnsServers)
            dnsSettings.matchDomains = []
            settings.dnsSettings = dnsSettings
        } else {
            // Explicitly tell iOS NOT to override DNS — pass nil so system DNS is used
            settings.dnsSettings = nil
        }
        
        return settings
    }

    /// Parse tunnel server address to IPv4 string.
    /// Accepts forms like:
    /// - 1.2.3.4
    /// - 1.2.3.4:39872
    /// - tcp://1.2.3.4:39872
    private func parseServerIPv4(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

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
        guard let host = parts.first, !host.isEmpty else { return nil }

        var addr = in_addr()
        return host.withCString { cStr -> String? in
            if inet_pton(AF_INET, cStr, &addr) == 1 {
                return String(host)
            }
            return nil
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let vntTunnelDidBecomeReady = Notification.Name("vntTunnelDidBecomeReady")
    static let vntTunnelDidStop = Notification.Name("vntTunnelDidStop")
}

// Note: TunnelConfig and ExternalRoute are defined in SharedTunnelConfig.swift
