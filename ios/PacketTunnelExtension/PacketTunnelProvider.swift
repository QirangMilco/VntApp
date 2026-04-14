import Foundation
import NetworkExtension

private extension Array {
  func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return [self] }
    var result: [[Element]] = []
    result.reserveCapacity((count + size - 1) / size)
    var index = 0
    while index < count {
      let end = Swift.min(index + size, count)
      result.append(Array(self[index..<end]))
      index += size
    }
    return result
  }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let ioQueue = DispatchQueue(label: "vnt.app.packet-tunnel.io")

  private static func networkAddress(ip: String, netmask: String) -> String {
    let ipParts = ip.split(separator: ".").compactMap { UInt8($0) }
    let maskParts = netmask.split(separator: ".").compactMap { UInt8($0) }
    guard ipParts.count == 4, maskParts.count == 4 else {
      return "10.26.0.0"
    }
    let result = zip(ipParts, maskParts).map { String($0 & $1) }
    return result.joined(separator: ".")
  }

  private static func ipv4Host(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let host = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? raw
    let seg = host.split(separator: ".")
    guard seg.count == 4 else { return nil }
    for item in seg {
      guard let n = Int(item), n >= 0, n <= 255 else { return nil }
    }
    return host
  }

  private func normalizeTunnelRemoteAddress(_ raw: String?) -> String {
    let input = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if input.isEmpty {
      return "127.0.0.1"
    }

    if let url = URL(string: input), let host = url.host, !host.isEmpty {
      return host
    }

    if let schemeRange = input.range(of: "://") {
      let withoutScheme = String(input[schemeRange.upperBound...])
      let hostAndMaybePort = withoutScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? withoutScheme
      if !hostAndMaybePort.isEmpty {
        return hostAndMaybePort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? hostAndMaybePort
      }
    }

    if input.contains(":") {
      return input.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? input
    }

    return input
  }
  private var running = false
  private var startedAt: Date?
  private var packetsFromSystem: UInt64 = 0
  private var bytesFromSystem: UInt64 = 0
  private var activeConfig: SharedTunnelConfig?
  private var activeRemoteAddress: String?
  private var appliedVirtualIp: String = ""
  private var appliedVirtualNetmask: String = ""
  private var appliedVirtualGateway: String = ""
  private var packetsToSystem: UInt64 = 0
  private var bytesToSystem: UInt64 = 0
  private var outputTimer: DispatchSourceTimer?
  private var ipv6MapRefreshTick: Int = 0
  private var lastInputErrorCode: Int32 = 0
  private var lastInputErrorAt: Date = .distantPast
  private var lastOutputErrorCode: Int32 = 0
  private var lastOutputErrorAt: Date = .distantPast
  private var lastReapplySkipReason: String = ""
  private var lastReapplySkipAt: Date = .distantPast
  private var lastInputBatchLogAt: Date = .distantPast
  private var lastOutputBatchLogAt: Date = .distantPast
  private var lastSnapshotDiagLogAt: Date = .distantPast
  private var appliedPeerRouteSignature: String = ""
  private var debugEvents: [String] = []

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    NSLog("[PacketTunnel] startTunnel called")

    if
      let proto = protocolConfiguration as? NETunnelProviderProtocol,
      let appGroup = proto.providerConfiguration?["appGroup"] as? String,
      !appGroup.isEmpty
    {
      SharedTunnelConfig.appGroupOverride = appGroup
      NSLog("[PacketTunnel] appGroup override from providerConfiguration: \(appGroup)")
    }

    SharedTunnelRuntimeState.save(state: "starting")

    let config: SharedTunnelConfig
    if let loaded = SharedTunnelConfig.loadFromAppGroup() {
      config = loaded
    } else if let fallback = fallbackConfigFromProviderConfiguration() {
      NSLog("[PacketTunnel] load shared config failed, fallback from providerConfiguration, appGroup=\(SharedTunnelConfig.appGroup)")
      config = fallback
    } else {
      NSLog("[PacketTunnel] load shared config failed, appGroup=\(SharedTunnelConfig.appGroup)")
      SharedTunnelRuntimeState.save(state: "error", message: "未读取到共享隧道配置")
      completionHandler(NSError(domain: "PacketTunnelProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "未读取到共享隧道配置"]))
      return
    }
    NSLog("[PacketTunnel] config loaded: ip=\(config.virtualIp), netmask=\(config.virtualNetmask), gateway=\(config.virtualGateway), routeCount=\(config.externalRoute.count), mtu=\(config.mtu)")

    let remoteAddress = normalizeTunnelRemoteAddress(config.tunnelServerAddress)
    NSLog("[PacketTunnel] tunnelRemoteAddress normalized: raw=\(config.tunnelServerAddress ?? "nil"), normalized=\(remoteAddress)")

    let configuredIp = config.virtualIp.trimmingCharacters(in: .whitespacesAndNewlines)
    let configuredMask = config.virtualNetmask.trimmingCharacters(in: .whitespacesAndNewlines)
    let configuredGateway = config.virtualGateway.trimmingCharacters(in: .whitespacesAndNewlines)

    if !configuredIp.isEmpty, configuredIp != "0.0.0.0", !configuredMask.isEmpty, configuredMask != "0.0.0.0", !configuredGateway.isEmpty, configuredGateway != "0.0.0.0" {
      activateTunnel(
        config: config,
        remoteAddress: remoteAddress,
        virtualIp: configuredIp,
        virtualNetmask: configuredMask,
        virtualGateway: configuredGateway,
        rustAlreadyStarted: false,
        completionHandler: completionHandler
      )
      return
    }

    SharedTunnelRuntimeState.save(state: "starting", message: "等待服务端分配虚拟 IP")
    NSLog("[PacketTunnel] virtual IP 未配置，等待服务端分配")

    do {
      try bootstrapRustDataPlane(config: config)
      NSLog("[PacketTunnel] rust dataplane started (waiting assigned virtual ip)")
    } catch {
      NSLog("[PacketTunnel] rust dataplane start failed: \(error.localizedDescription)")
      SharedTunnelRuntimeState.save(state: "error", message: error.localizedDescription)
      completionHandler(error)
      return
    }

    waitForAssignedVirtualTuple(config: config) { [weak self] tuple in
      guard let self else {
        completionHandler(NSError(domain: "PacketTunnelProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "provider 已释放"]))
        return
      }

      guard let tuple else {
        self.teardownRustDataPlane()
        let err = NSError(domain: "PacketTunnelProvider", code: -12, userInfo: [NSLocalizedDescriptionKey: "等待服务端分配虚拟 IP 超时"])
        NSLog("[PacketTunnel] \(err.localizedDescription)")
        SharedTunnelRuntimeState.save(state: "error", message: err.localizedDescription)
        completionHandler(err)
        return
      }

      self.activateTunnel(
        config: config,
        remoteAddress: remoteAddress,
        virtualIp: tuple.ip,
        virtualNetmask: tuple.netmask,
        virtualGateway: tuple.gateway,
        initialPeerHosts: tuple.peerHosts,
        rustAlreadyStarted: true,
        completionHandler: completionHandler
      )
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    running = false
    stopRustOutputLoop()
    teardownRustDataPlane()
    startedAt = nil
    packetsFromSystem = 0
    packetsToSystem = 0
    bytesFromSystem = 0
    bytesToSystem = 0
    activeConfig = nil
    activeRemoteAddress = nil
    appliedVirtualIp = ""
    appliedVirtualNetmask = ""
    appliedVirtualGateway = ""
    appliedPeerRouteSignature = ""
    ipv6MapRefreshTick = 0
    lastInputErrorCode = 0
    lastInputErrorAt = .distantPast
    lastOutputErrorCode = 0
    lastOutputErrorAt = .distantPast
    SharedTunnelRuntimeState.save(state: "stopped")
    completionHandler()
  }

  private func beginReadingPackets() {
    guard running else { return }

    packetFlow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      guard self.running else { return }

      if packets.isEmpty {
        self.beginReadingPackets()
        return
      }

      self.ioQueue.async { [weak self] in
        guard let self else { return }
        guard self.running else { return }

        self.packetsFromSystem += UInt64(packets.count)
        self.bytesFromSystem += UInt64(packets.reduce(0) { $0 + $1.count })
        self.handlePacketsFromSystem(packets, protocols: protocols)
        self.beginReadingPackets()
      }
    }
  }

  private func appendDebugEvent(_ message: String) {
    let line = "\(Int(Date().timeIntervalSince1970 * 1000)) \(message)"
    debugEvents.append(line)
    if debugEvents.count > 60 {
      debugEvents.removeFirst(debugEvents.count - 60)
    }
  }

  private func packetSummary(_ packet: Data, protocolNumber: Int32) -> String {
    if protocolNumber == 2, packet.count >= 20 {
      let src = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
      let dst = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
      let ttl = packet[8]
      let proto = packet[9]
      return "ipv4 src=\(src) dst=\(dst) ttl=\(ttl) proto=\(proto) len=\(packet.count)"
    }

    if protocolNumber == 30, packet.count >= 40 {
      let src = packet[8..<24].map { String(format: "%02x", $0) }.chunked(into: 2).map { $0.joined() }.joined(separator: ":")
      let dst = packet[24..<40].map { String(format: "%02x", $0) }.chunked(into: 2).map { $0.joined() }.joined(separator: ":")
      let nextHeader = packet[6]
      return "ipv6 src=\(src) dst=\(dst) next=\(nextHeader) len=\(packet.count)"
    }

    return "proto=\(protocolNumber) len=\(packet.count)"
  }

  private func logInputBatch(_ packets: [Data], protocols: [NSNumber]) {
#if DEBUG
    let now = Date()
    guard now.timeIntervalSince(lastInputBatchLogAt) >= 1.0 else { return }
    lastInputBatchLogAt = now
    let samples = packets.prefix(3).enumerated().map { index, packet in
      let proto = index < protocols.count ? protocols[index].int32Value : 0
      return packetSummary(packet, protocolNumber: proto)
    }
    let message = "input batch: count=\(packets.count), samples=\(samples)"
    appendDebugEvent(message)
    NSLog("[PacketTunnel] \(message)")
#endif
  }

  private func logOutputBatch(_ packets: [Data], protocols: [NSNumber]) {
#if DEBUG
    let now = Date()
    guard now.timeIntervalSince(lastOutputBatchLogAt) >= 1.0 else { return }
    lastOutputBatchLogAt = now
    let samples = packets.prefix(3).enumerated().map { index, packet in
      let proto = index < protocols.count ? protocols[index].int32Value : 0
      return packetSummary(packet, protocolNumber: proto)
    }
    let message = "output batch: count=\(packets.count), samples=\(samples)"
    appendDebugEvent(message)
    NSLog("[PacketTunnel] \(message)")
#endif
  }

  private func logSnapshotDiagnostics(_ snapshot: RustDataplaneSnapshot, config: SharedTunnelConfig) {
#if DEBUG
    let now = Date()
    guard now.timeIntervalSince(lastSnapshotDiagLogAt) >= 1.0 else { return }
    lastSnapshotDiagLogAt = now
    let message = "snapshot diag: currentVip=\(snapshot.currentVirtualIp ?? "nil"), currentMask=\(snapshot.currentVirtualNetmask ?? "nil"), currentGw=\(snapshot.currentVirtualGateway ?? "nil"), appliedVip=\(appliedVirtualIp), appliedMask=\(appliedVirtualNetmask), appliedGw=\(appliedVirtualGateway), configVip=\(config.virtualIp), configMask=\(config.virtualNetmask), configGw=\(config.virtualGateway), peerVirtualIps=\(snapshot.peerVirtualIps?.count ?? 0), peers=\(snapshot.peerDevices.count), status=\(snapshot.currentStatus ?? "nil"), lastError=\(snapshot.lastError ?? "nil"), lastErrorCode=\(snapshot.lastErrorCode)"
    appendDebugEvent(message)
    NSLog("[PacketTunnel] \(message)")
#endif
  }

  private func reportInputError(code: Int32) {
    let now = Date()
    if code == lastInputErrorCode, now.timeIntervalSince(lastInputErrorAt) < 1.0 {
      return
    }
    lastInputErrorCode = code
    lastInputErrorAt = now

    if code == -5 {
      SharedTunnelRuntimeState.save(state: "running", message: "Rust 入包告警: \(code)")
      return
    }

    SharedTunnelRuntimeState.save(state: "error", message: "Rust 入包失败: \(code)")
  }

  private func reportOutputError(code: Int32) {
    let now = Date()
    if code == lastOutputErrorCode, now.timeIntervalSince(lastOutputErrorAt) < 1.0 {
      return
    }
    lastOutputErrorCode = code
    lastOutputErrorAt = now
    SharedTunnelRuntimeState.save(state: "error", message: "Rust 出包失败: \(code)")
  }

  private func handlePacketsFromSystem(_ packets: [Data], protocols: [NSNumber]) {
    logInputBatch(packets, protocols: protocols)
    for (index, packet) in packets.enumerated() {
      let proto = index < protocols.count ? protocols[index].int32Value : 0
      let code = RustDataPlaneBridge.shared.input(packet: packet, protocolNumber: proto)
      if code != 0 {
        let message = "input packet failed: code=\(code), summary=\(packetSummary(packet, protocolNumber: proto))"
        appendDebugEvent(message)
        NSLog("[PacketTunnel] \(message)")
        reportInputError(code: code)
      }
    }
  }

  private func writePacketsToSystem(_ packets: [Data], protocols: [NSNumber]) {
    guard running else { return }
    guard !packets.isEmpty, packets.count == protocols.count else { return }
    logOutputBatch(packets, protocols: protocols)
    packetsToSystem += UInt64(packets.count)
    bytesToSystem += UInt64(packets.reduce(0) { $0 + $1.count })
    _ = RustDataPlaneBridge.shared.reportOutput(count: UInt64(packets.count))
    packetFlow.writePackets(packets, withProtocols: protocols)
  }

  private func activateTunnel(
    config: SharedTunnelConfig,
    remoteAddress: String,
    virtualIp: String,
    virtualNetmask: String,
    virtualGateway: String,
    initialPeerHosts: [String] = [],
    rustAlreadyStarted: Bool,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let settings = buildNetworkSettings(
      config: config,
      remoteAddress: remoteAddress,
      virtualIp: virtualIp,
      virtualNetmask: virtualNetmask,
      virtualGateway: virtualGateway,
      peerHosts: initialPeerHosts
    )

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else {
        completionHandler(NSError(domain: "PacketTunnelProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "provider 已释放"]))
        return
      }

      if let error {
        NSLog("[PacketTunnel] setTunnelNetworkSettings failed: \(error.localizedDescription)")
        if rustAlreadyStarted {
          self.teardownRustDataPlane()
        }
        SharedTunnelRuntimeState.save(state: "error", message: error.localizedDescription)
        completionHandler(error)
        return
      }

      self.running = true
      self.startedAt = Date()
      self.packetsFromSystem = 0
      self.packetsToSystem = 0
      self.bytesFromSystem = 0
      self.bytesToSystem = 0
      self.activeConfig = config
      self.activeRemoteAddress = remoteAddress
      self.appliedVirtualIp = virtualIp
      self.appliedVirtualNetmask = virtualNetmask
      self.appliedVirtualGateway = virtualGateway
      self.ipv6MapRefreshTick = 0
      self.lastInputErrorCode = 0
      self.lastInputErrorAt = .distantPast
      self.lastOutputErrorCode = 0
      self.lastOutputErrorAt = .distantPast
      self.appliedPeerRouteSignature = self.peerRouteSignature(initialPeerHosts)

      if !rustAlreadyStarted {
        do {
          try self.bootstrapRustDataPlane(config: config)
          NSLog("[PacketTunnel] rust dataplane started")
        } catch {
          NSLog("[PacketTunnel] rust dataplane start failed: \(error.localizedDescription)")
          self.running = false
          SharedTunnelRuntimeState.save(state: "error", message: error.localizedDescription)
          completionHandler(error)
          return
        }
      }

      SharedTunnelRuntimeState.save(state: "running")
      self.beginReadingPackets()
      self.beginRustOutputLoop()
      NSLog("[PacketTunnel] tunnel running, appliedVip=\(virtualIp), peerRoutes=\(self.appliedPeerRouteSignature)")
      completionHandler(nil)
    }
  }

  private func waitForAssignedVirtualTuple(
    config: SharedTunnelConfig,
    timeout: TimeInterval = 10,
    completion: @escaping ((ip: String, netmask: String, gateway: String, peerHosts: [String])?) -> Void
  ) {
    let deadline = Date().addingTimeInterval(timeout)

    func resolveGateway(raw: String, current: String, fallback: String) -> String {
      let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedRaw.isEmpty, trimmedRaw != "0.0.0.0" {
        return trimmedRaw
      }
      let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedCurrent.isEmpty, trimmedCurrent != "0.0.0.0" {
        return trimmedCurrent
      }
      let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedFallback.isEmpty, trimmedFallback != "0.0.0.0" {
        return trimmedFallback
      }
      return ""
    }

    func poll() {
      guard Date() <= deadline else {
        completion(nil)
        return
      }

      if let snapshot = RustDataPlaneBridge.shared.snapshot() {
        let vip = (snapshot.currentVirtualIp ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let mask = (snapshot.currentVirtualNetmask ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let gw = resolveGateway(
          raw: snapshot.currentVirtualGateway ?? "",
          current: self.appliedVirtualGateway,
          fallback: config.virtualGateway
        )
        let peerHosts = self.peerHosts(from: snapshot, localVirtualIp: vip)

        if !vip.isEmpty, vip != "0.0.0.0", !mask.isEmpty, mask != "0.0.0.0", !gw.isEmpty {
          completion((vip, mask, gw, peerHosts))
          return
        }
      }

      self.ioQueue.asyncAfter(deadline: .now() + .milliseconds(200)) {
        poll()
      }
    }

    ioQueue.async {
      poll()
    }
  }

  private func buildNetworkSettings(
    config: SharedTunnelConfig,
    remoteAddress: String,
    virtualIp: String,
    virtualNetmask: String,
    virtualGateway: String,
    peerHosts: [String] = []
  ) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

    let ipv4 = NEIPv4Settings(addresses: [virtualIp], subnetMasks: [virtualNetmask])
    var includedRoutes = config.externalRoute.map { route in
      NEIPv4Route(destinationAddress: route.destination, subnetMask: route.netmask)
    }
    if includedRoutes.isEmpty {
      let network = config.virtualNetwork ?? Self.networkAddress(ip: virtualIp, netmask: virtualNetmask)
      includedRoutes = [NEIPv4Route(destinationAddress: network, subnetMask: virtualNetmask)]
      NSLog("[PacketTunnel] no externalRoute, fallback to virtual network route: \(network)/\(virtualNetmask)")
    }

    var routeKeys = Set(includedRoutes.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" })
    for host in peerHosts {
      let key = "\(host)/255.255.255.255"
      guard routeKeys.insert(key).inserted else { continue }
      includedRoutes.append(NEIPv4Route(destinationAddress: host, subnetMask: "255.255.255.255"))
    }

    ipv4.includedRoutes = includedRoutes
    settings.ipv4Settings = ipv4

    let dnsServers = config.dnsServers.isEmpty ? ["223.5.5.5", "8.8.8.8"] : config.dnsServers
    settings.dnsSettings = NEDNSSettings(servers: dnsServers)
    settings.mtu = NSNumber(value: max(1200, config.mtu))
    return settings
  }

  private func peerHosts(from snapshot: RustDataplaneSnapshot, localVirtualIp: String) -> [String] {
    var seen = Set<String>()
    var hosts: [String] = []

    if let peerVirtualIps = snapshot.peerVirtualIps {
      for raw in peerVirtualIps {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host != localVirtualIp else { continue }
        guard Self.ipv4Host(host) != nil else { continue }
        guard seen.insert(host).inserted else { continue }
        hosts.append(host)
      }
    }

    if hosts.isEmpty {
      for peer in snapshot.peerDevices {
        let host = peer.virtualIp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host != localVirtualIp else { continue }
        guard Self.ipv4Host(host) != nil else { continue }
        guard seen.insert(host).inserted else { continue }
        hosts.append(host)
      }
    }

    return hosts.sorted()
  }

  private func peerRouteSignature(_ hosts: [String]) -> String {
    hosts.joined(separator: ",")
  }

  private func tryApplyAssignedVirtualIp() {
    guard running, let config = activeConfig, let remoteAddress = activeRemoteAddress else { return }
    guard let snapshot = RustDataPlaneBridge.shared.snapshot() else {
      logReapplySkip(reason: "snapshot=nil")
      return
    }

    logSnapshotDiagnostics(snapshot, config: config)

    let vip = (snapshot.currentVirtualIp ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let mask = (snapshot.currentVirtualNetmask ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let gw = (snapshot.currentVirtualGateway ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    guard !vip.isEmpty, !mask.isEmpty else {
      logReapplySkip(reason: "incomplete assigned tuple: ip=\(vip), mask=\(mask), gw=\(gw)")
      return
    }
    guard vip != "0.0.0.0", mask != "0.0.0.0" else {
      logReapplySkip(reason: "invalid assigned tuple: ip=\(vip), mask=\(mask), gw=\(gw)")
      return
    }

    let effectiveGateway: String
    if !gw.isEmpty, gw != "0.0.0.0" {
      effectiveGateway = gw
    } else if !appliedVirtualGateway.isEmpty, appliedVirtualGateway != "0.0.0.0" {
      effectiveGateway = appliedVirtualGateway
    } else {
      effectiveGateway = config.virtualGateway
    }

    guard !effectiveGateway.isEmpty, effectiveGateway != "0.0.0.0" else {
      logReapplySkip(reason: "gateway unavailable: raw=\(gw), applied=\(appliedVirtualGateway), config=\(config.virtualGateway)")
      return
    }

    let peerHosts = peerHosts(from: snapshot, localVirtualIp: vip)
    let peerSignature = peerRouteSignature(peerHosts)

    guard vip != appliedVirtualIp || mask != appliedVirtualNetmask || effectiveGateway != appliedVirtualGateway || peerSignature != appliedPeerRouteSignature else {
      logReapplySkip(reason: "assigned tuple unchanged: ip=\(vip), mask=\(mask), gw=\(effectiveGateway), peerRoutes=\(peerSignature)")
      return
    }

    let settings = buildNetworkSettings(
      config: config,
      remoteAddress: remoteAddress,
      virtualIp: vip,
      virtualNetmask: mask,
      virtualGateway: effectiveGateway,
      peerHosts: peerHosts
    )

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else { return }
      if let error {
        NSLog("[PacketTunnel] reapply assigned virtual ip failed: \(error.localizedDescription)")
        return
      }
      self.appliedVirtualIp = vip
      self.appliedVirtualNetmask = mask
      self.appliedVirtualGateway = effectiveGateway
      self.appliedPeerRouteSignature = peerSignature
      self.lastReapplySkipReason = ""
      let message = "reapply assigned virtual ip success: ip=\(vip), netmask=\(mask), gateway=\(effectiveGateway), rawGateway=\(gw), peerRoutes=\(peerSignature)"
      self.appendDebugEvent(message)
      NSLog("[PacketTunnel] \(message)")
    }
  }

  private func logReapplySkip(reason: String) {
    let now = Date()
    if reason == lastReapplySkipReason && now.timeIntervalSince(lastReapplySkipAt) < 3 {
      return
    }
    lastReapplySkipReason = reason
    lastReapplySkipAt = now
    appendDebugEvent("reapply assigned virtual ip skipped: \(reason)")
    NSLog("[PacketTunnel] reapply assigned virtual ip skipped: \(reason)")
  }

  private func beginRustOutputLoop() {
    stopRustOutputLoop()
    let timer = DispatchSource.makeTimerSource(queue: ioQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
    timer.setEventHandler { [weak self] in
      self?.drainRustOutput()
    }
    outputTimer = timer
    timer.resume()
  }

  private func stopRustOutputLoop() {
    outputTimer?.setEventHandler {}
    outputTimer?.cancel()
    outputTimer = nil
  }

  private func drainRustOutput() {
    guard running else { return }

    tryApplyAssignedVirtualIp()

    ipv6MapRefreshTick += 1
    if ipv6MapRefreshTick >= 250 {
      _ = RustDataPlaneBridge.shared.refreshIpv6Map()
      ipv6MapRefreshTick = 0
    }

    var packets: [Data] = []
    var protos: [NSNumber] = []
    packets.reserveCapacity(16)
    protos.reserveCapacity(16)

    var maxPacketSize = 4096
    var consecutiveErrors = 0

    for _ in 0..<16 {
      var result = RustDataPlaneBridge.shared.pullOutput(maxPacketSize: maxPacketSize)

      if result.code == -4, maxPacketSize < 65535 {
        maxPacketSize = min(maxPacketSize * 2, 65535)
        result = RustDataPlaneBridge.shared.pullOutput(maxPacketSize: maxPacketSize)
      }

      if result.code == 1 {
        break
      }
      if result.code != 0 {
        consecutiveErrors += 1
        if consecutiveErrors >= 3 {
          reportOutputError(code: result.code)
          break
        }
        continue
      }

      consecutiveErrors = 0
      guard let packet = result.packet, let proto = result.protocolNumber else {
        continue
      }
      packets.append(packet)
      protos.append(proto)
    }

    if !packets.isEmpty {
      writePacketsToSystem(packets, protocols: protos)
    }
  }

  private func fallbackConfigFromProviderConfiguration() -> SharedTunnelConfig? {
    guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
      return nil
    }
    guard let dict = proto.providerConfiguration?["tunnelConfig"] as? [String: Any] else {
      return nil
    }
    NSLog("[PacketTunnel] using fallback tunnelConfig from providerConfiguration")
    return SharedTunnelConfig(dict: dict)
  }

  private func bootstrapRustDataPlane(config: SharedTunnelConfig) throws {
    guard RustDataPlaneBridge.shared.isAvailable else {
      throw NSError(domain: "PacketTunnelProvider", code: -10, userInfo: [NSLocalizedDescriptionKey: "Rust 数据面符号未找到"])
    }

    let encoder = JSONEncoder()
    let data = try encoder.encode(config)
    guard let json = String(data: data, encoding: .utf8) else {
      throw NSError(domain: "PacketTunnelProvider", code: -11, userInfo: [NSLocalizedDescriptionKey: "配置序列化失败"])
    }

    let code = RustDataPlaneBridge.shared.start(configJson: json)
    guard code == 0 else {
      throw NSError(domain: "PacketTunnelProvider", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Rust 数据面启动失败: \(code)"])
    }
  }

  private func teardownRustDataPlane() {
    _ = RustDataPlaneBridge.shared.stop()
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    guard
      let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
      let action = obj["action"] as? String
    else {
      completionHandler?(nil)
      return
    }

    switch action {
    case "status":
      tryApplyAssignedVirtualIp()
      let shared = SharedTunnelRuntimeState.load()
      let uptime: TimeInterval = startedAt.map { Date().timeIntervalSince($0) } ?? 0
      let rustStats = RustDataPlaneBridge.shared.stats()
      let rustSnapshot = RustDataPlaneBridge.shared.snapshot()
      let config = SharedTunnelConfig.loadFromAppGroup()
      let payload: [String: Any] = [
        "running": rustStats?.running ?? running,
        "state": shared?.state ?? "unknown",
        "message": shared?.message as Any,
        "updatedAt": shared?.updatedAt as Any,
        "uptimeSec": Int(uptime),
        "packetsFromSystem": rustStats?.packetsFromSystem ?? packetsFromSystem,
        "packetsToSystem": rustStats?.packetsToSystem ?? packetsToSystem,
        "bytesFromSystem": bytesFromSystem,
        "bytesToSystem": bytesToSystem,
        "outputQueueLen": rustStats?.outputQueueLen ?? 0,
        "outputDropped": rustStats?.outputDropped ?? 0,
        "pollErrorCount": rustStats?.pollErrorCount ?? 0,
        "lastErrorCode": rustStats?.lastErrorCode ?? 0,
        "ipv6Enabled": rustStats?.ipv6Enabled ?? true,
        "ipv6MapSize": rustStats?.ipv6MapSize ?? 0,
        "ipv6MapMissCount": rustStats?.ipv6MapMissCount ?? 0,
        "ipv6CompatDowngradeCount": rustStats?.ipv6CompatDowngradeCount ?? 0,
        "virtualIp": rustSnapshot?.currentVirtualIp ?? config?.virtualIp as Any,
        "virtualNetmask": rustSnapshot?.currentVirtualNetmask ?? config?.virtualNetmask as Any,
        "virtualGateway": rustSnapshot?.currentVirtualGateway ?? config?.virtualGateway as Any,
        "virtualNetwork": rustSnapshot?.currentVirtualNetwork ?? config?.virtualNetwork as Any,
        "tunnelServerAddress": rustSnapshot?.currentConnectServer ?? config?.tunnelServerAddress as Any,
        "routeCount": config?.externalRoute.count ?? 0,
        "configUpdatedAt": config?.updatedAt as Any,
        "peerVirtualIps": rustSnapshot?.peerVirtualIps as Any,
        "peerDevices": rustSnapshot?.peerDevices.map { $0.toDictionary() } ?? [],
        "currentStatus": rustSnapshot?.currentStatus as Any,
        "broadcastIp": rustSnapshot?.currentBroadcastIp as Any,
        "natType": rustSnapshot?.natType as Any,
        "publicIps": rustSnapshot?.publicIps as Any,
        "localIpv4": rustSnapshot?.localIpv4 as Any,
        "ipv6": rustSnapshot?.ipv6 as Any,
        "rustLastError": rustSnapshot?.lastError as Any,
        "rustLastErrorCode": rustSnapshot?.lastErrorCode as Any,
        "appliedVirtualIp": appliedVirtualIp,
        "appliedVirtualNetmask": appliedVirtualNetmask,
        "appliedVirtualGateway": appliedVirtualGateway,
        "appliedPeerRouteSignature": appliedPeerRouteSignature,
        "debugEvents": debugEvents,
      ]

      if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
        completionHandler?(data)
      } else {
        completionHandler?(nil)
      }

    default:
      completionHandler?(nil)
    }
  }
}
