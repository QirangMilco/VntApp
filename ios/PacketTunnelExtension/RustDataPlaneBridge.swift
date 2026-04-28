import Foundation
import Darwin

struct RustPeerRouteSnapshot: Decodable {
  let `protocol`: String
  let addr: String
  let metric: Int
  let rt: Int

  func toDictionary() -> [String: Any] {
    [
      "protocol": `protocol`,
      "addr": addr,
      "metric": metric,
      "rt": rt,
    ]
  }
}

struct RustPeerSnapshot: Decodable {
  let virtualIp: String
  let name: String
  let status: String
  let clientSecret: Bool
  let route: RustPeerRouteSnapshot?

  func toDictionary() -> [String: Any] {
    [
      "virtualIp": virtualIp,
      "name": name,
      "status": status,
      "clientSecret": clientSecret,
      "route": route?.toDictionary() as Any,
    ]
  }
}

struct RustDataplaneSnapshot: Decodable {
  let running: Bool
  let currentVirtualIp: String?
  let currentVirtualNetmask: String?
  let currentVirtualGateway: String?
  let currentVirtualNetwork: String?
  let currentConnectServer: String?
  let currentStatus: String?
  let currentBroadcastIp: String?
  let natType: String?
  let publicIps: [String]?
  let localIpv4: String?
  let ipv6: String?
  let peerVirtualIps: [String]?
  let peerDevices: [RustPeerSnapshot]
  let lastError: String?
  let lastErrorCode: Int32
}

struct RustDataPlaneStats {
  let running: Bool
  let packetsFromSystem: UInt64
  let packetsToSystem: UInt64
  let outputQueueLen: UInt64
  let outputDropped: UInt64
  let pollErrorCount: UInt64
  let lastErrorCode: Int32
  let ipv6Enabled: Bool
  let ipv6MapSize: UInt64
  let ipv6MapMissCount: UInt64
  let ipv6CompatDowngradeCount: UInt64
}

struct RustDataPlaneCStats {
  var running: Int32 = 0
  var packets_from_system: UInt64 = 0
  var packets_to_system: UInt64 = 0
  var output_queue_len: UInt64 = 0
  var output_dropped: UInt64 = 0
  var poll_error_count: UInt64 = 0
  var last_error_code: Int32 = 0
  var ipv6_enabled: Int32 = 0
  var ipv6_map_size: UInt64 = 0
  var ipv6_map_miss_count: UInt64 = 0
  var ipv6_compat_downgrade_count: UInt64 = 0
}

final class RustDataPlaneBridge {
  static let shared = RustDataPlaneBridge()

  private typealias InitLogFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
  private typealias StartFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
  private typealias StopFn = @convention(c) () -> Int32
  private typealias InputFn = @convention(c) (UnsafePointer<UInt8>?, Int, Int32) -> Int32
  private typealias PollOutputFn = @convention(c) (
    UnsafeMutablePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<Int>?,
    UnsafeMutablePointer<Int32>?
  ) -> Int32
  private typealias OutputCountFn = @convention(c) (UInt64) -> Int32
  private typealias GetStatsFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
  private typealias RefreshIpv6MapFn = @convention(c) () -> Int32
  private typealias SnapshotJsonFn = @convention(c) (
    UnsafeMutablePointer<UnsafePointer<CChar>?>?,
    UnsafeMutablePointer<Int>?
  ) -> Int32
  private typealias SnapshotJsonFreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

  private let initLogFn: InitLogFn?
  private let startFn: StartFn?
  private let stopFn: StopFn?
  private let inputIpv4Fn: InputFn?
  private let inputIpv6Fn: InputFn?
  private let pollOutputFn: PollOutputFn?
  private let outputCountFn: OutputCountFn?
  private let getStatsFn: GetStatsFn?
  private let refreshIpv6MapFn: RefreshIpv6MapFn?
  private let snapshotJsonFn: SnapshotJsonFn?
  private let snapshotJsonFreeFn: SnapshotJsonFreeFn?

  private init() {
    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_init_log") {
      initLogFn = unsafeBitCast(ptr, to: InitLogFn.self)
    } else {
      initLogFn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_start") {
      startFn = unsafeBitCast(ptr, to: StartFn.self)
    } else {
      startFn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_stop") {
      stopFn = unsafeBitCast(ptr, to: StopFn.self)
    } else {
      stopFn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_input_ipv4") {
      inputIpv4Fn = unsafeBitCast(ptr, to: InputFn.self)
    } else {
      inputIpv4Fn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_input_ipv6") {
      inputIpv6Fn = unsafeBitCast(ptr, to: InputFn.self)
    } else {
      inputIpv6Fn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_poll_output") {
      pollOutputFn = unsafeBitCast(ptr, to: PollOutputFn.self)
    } else {
      pollOutputFn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_output_count") {
      outputCountFn = unsafeBitCast(ptr, to: OutputCountFn.self)
    } else {
      outputCountFn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_get_stats") {
      getStatsFn = unsafeBitCast(ptr, to: GetStatsFn.self)
    } else {
      getStatsFn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_refresh_ipv6_map") {
      refreshIpv6MapFn = unsafeBitCast(ptr, to: RefreshIpv6MapFn.self)
    } else {
      refreshIpv6MapFn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_snapshot_json") {
      snapshotJsonFn = unsafeBitCast(ptr, to: SnapshotJsonFn.self)
    } else {
      snapshotJsonFn = nil
    }

    if let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vnt_ios_dataplane_snapshot_json_free") {
      snapshotJsonFreeFn = unsafeBitCast(ptr, to: SnapshotJsonFreeFn.self)
    } else {
      snapshotJsonFreeFn = nil
    }
  }

  var isAvailable: Bool {
    startFn != nil && stopFn != nil && inputIpv4Fn != nil && inputIpv6Fn != nil && pollOutputFn != nil && outputCountFn != nil && getStatsFn != nil
  }

  func initLog(logDir: String) -> Int32 {
    guard let initLogFn else { return -1001 }
    return logDir.withCString { ptr in
      initLogFn(ptr)
    }
  }

  func start(configJson: String) -> Int32 {
    guard let startFn else { return -1001 }
    return configJson.withCString { ptr in
      startFn(ptr)
    }
  }

  func stop() -> Int32 {
    guard let stopFn else { return -1001 }
    return stopFn()
  }

  func input(packet: Data, protocolNumber: Int32) -> Int32 {
    let inputFn: InputFn?
    if protocolNumber == 2 {
      inputFn = inputIpv4Fn
    } else if protocolNumber == 30 {
      inputFn = inputIpv6Fn
    } else {
      return 0
    }

    guard let inputFn else { return -1001 }
    return packet.withUnsafeBytes { rawBuf in
      let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress
      return inputFn(ptr, packet.count, protocolNumber)
    }
  }

  func pullOutput(maxPacketSize: Int = 65535) -> (code: Int32, packet: Data?, protocolNumber: NSNumber?) {
    guard let pollOutputFn else { return (-1001, nil, nil) }
    var buffer = [UInt8](repeating: 0, count: maxPacketSize)
    var outLen: Int = 0
    var outProto: Int32 = 0
    let code = pollOutputFn(&buffer, maxPacketSize, &outLen, &outProto)
    guard code == 0 else { return (code, nil, nil) }
    guard outLen > 0, outLen <= maxPacketSize else { return (-1002, nil, nil) }
    let data = Data(buffer.prefix(outLen))
    return (0, data, NSNumber(value: outProto))
  }

  func reportOutput(count: UInt64) -> Int32 {
    guard let outputCountFn else { return -1001 }
    return outputCountFn(count)
  }

  func refreshIpv6Map() -> Int32 {
    guard let refreshIpv6MapFn else { return -1001 }
    return refreshIpv6MapFn()
  }

  func snapshot() -> RustDataplaneSnapshot? {
    guard let snapshotJsonFn, let snapshotJsonFreeFn else { return nil }

    var ptr: UnsafePointer<CChar>?
    var len: Int = 0
    let code = snapshotJsonFn(&ptr, &len)
    guard code == 0, let ptr, len > 0 else { return nil }

    let data = Data(bytes: ptr, count: len)
    snapshotJsonFreeFn(UnsafeMutablePointer(mutating: ptr))
    return try? JSONDecoder().decode(RustDataplaneSnapshot.self, from: data)
  }

  func stats() -> RustDataPlaneStats? {
    guard let getStatsFn else { return nil }
    var stats = RustDataPlaneCStats()
    let code = withUnsafeMutablePointer(to: &stats) { ptr in
      getStatsFn(UnsafeMutableRawPointer(ptr))
    }
    guard code == 0 else { return nil }
    return RustDataPlaneStats(
      running: stats.running != 0,
      packetsFromSystem: stats.packets_from_system,
      packetsToSystem: stats.packets_to_system,
      outputQueueLen: stats.output_queue_len,
      outputDropped: stats.output_dropped,
      pollErrorCount: stats.poll_error_count,
      lastErrorCode: stats.last_error_code,
      ipv6Enabled: stats.ipv6_enabled != 0,
      ipv6MapSize: stats.ipv6_map_size,
      ipv6MapMissCount: stats.ipv6_map_miss_count,
      ipv6CompatDowngradeCount: stats.ipv6_compat_downgrade_count
    )
  }

}
