import Foundation

/// Shared configuration models for PacketTunnelExtension and Runner
/// Both targets compile this file, so definitions are shared without duplication.

struct TunnelConfig: Codable {
    let virtualIp: String
    let virtualNetmask: String
    let virtualGateway: String
    let virtualNetwork: String
    let mtu: Int
    let tunnelRemoteAddress: String
    let tunnelServerAddress: String?
    let externalRoutes: [ExternalRoute]
    let dnsServers: [String]
}

struct ExternalRoute: Codable {
    let destination: String
    let netmask: String
}
