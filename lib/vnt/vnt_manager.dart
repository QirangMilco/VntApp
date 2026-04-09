import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/src/rust/api/vnt_api.dart';
import 'package:vnt_app/utils/ip_utils.dart';

final VntManager vntManager = VntManager();

class VntBox {
  final VntApi vntApi;
  final VntConfig vntConfig;
  final NetworkConfig networkConfig;
  VntBox({
    required this.vntApi,
    required this.vntConfig,
    required this.networkConfig,
  });
  static Future<VntBox> create(NetworkConfig config, SendPort uiCall) async {
    var vntConfig = VntConfig(
        tap: false,
        token: config.token,
        deviceId: config.deviceID,
        name: config.deviceName,
        serverAddressStr: config.serverAddress,
        nameServers: config.dns,
        stunServer: config.stunServers,
        inIps: config.inIps.map((v) => IpUtils.parseInIpString(v)).toList(),
        outIps: config.outIps.map((v) => IpUtils.parseOutIpString(v)).toList(),
        password: config.groupPassword.isEmpty ? null : config.groupPassword,
        mtu: config.mtu == 0 ? null : config.mtu,
        ip: config.virtualIPv4.isEmpty ? null : config.virtualIPv4,
        noProxy: config.noInIpProxy,
        serverEncrypt: config.isServerEncrypted,
        cipherModel: config.encryptionAlgorithm,
        finger: config.dataFingerprintVerification,
        punchModel: config.punchModel,
        ports: config.ports.isEmpty ? null : Uint16List.fromList(config.ports),
        firstLatency: config.firstLatency,
        deviceName: config.virtualNetworkCardName.isEmpty
            ? null
            : config.virtualNetworkCardName,
        useChannelType: config.useChannelType,
        packetLossRate: config.simulatedPacketLossRate == 0
            ? null
            : config.simulatedPacketLossRate,
        packetDelay: config.simulatedLatency,
        portMappingList: config.portMappings,
        compressor: config.compressor.isEmpty ? 'none' : config.compressor,
        allowWireGuard: config.allowWg,
        localIpv4: config.localIpv4.isEmpty ? null : config.localIpv4);
    var vntCall = VntApiCallback(successFn: () {
      uiCall.send('success');
    }, createTunFn: (info) {
      // uiCall.send(info);
    }, connectFn: (info) {
      uiCall.send(info);
    }, handshakeFn: (info) {
      // uiCall.send(info);
      return true;
    }, registerFn: (info) {
      // uiCall.send(info);
      return true;
    },     generateTunFn: (info) async {
      //创建vpn
      try {
        if (Platform.isAndroid) {
          int fd = await VntAppCall.startVpn(info, vntConfig.mtu ?? 1400);
          return fd;
        } else if (Platform.isIOS) {
          // iOS: Start VPN via Network Extension (NEPacketTunnelProvider)
          // The Extension creates the TUN interface and returns fd via shared UserDefaults
          debugPrint('iOS TUN: Starting VPN via Network Extension...');
          debugPrint('iOS TUN: virtualIp=${info.virtualIp}, netmask=${info.virtualNetmask}, gateway=${info.virtualGateway}');
          int fd = await VntAppCall.startVpn(info, vntConfig.mtu ?? 1400, tunnelServerAddress: config.serverAddress);
          if (fd > 0) {
            debugPrint('iOS TUN: Got TUN fd=$fd from Network Extension');
          } else {
            debugPrint('iOS TUN: Failed to get TUN fd, got fd=$fd');
          }
          return fd;
        }
        return 0;
      } catch (e) {
        debugPrint('创建vpn异常 $e');
        return 0;
      }
    }, peerClientListFn: (info) {
      // uiCall.send(info);
    }, errorFn: (info) {
      debugPrint('服务异常 类型 ${info.code.name} ${info.msg ?? ''}');
      uiCall.send(info);
    }, stopFn: () {
      uiCall.send('stop');
    });
    var vntApi = await vntInit(vntConfig: vntConfig, call: vntCall);

    return VntBox(vntApi: vntApi, vntConfig: vntConfig, networkConfig: config);
  }

  Future<void> close() async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await VntAppCall.stopVpn();
      } catch (e) {
        debugPrint('stopVpn error: $e');
      }
    }
    vntApi.stop();
  }

  bool isClosed() {
    return vntApi.isStopped();
  }

  NetworkConfig? getNetConfig() {
    return networkConfig;
  }

  Map<String, dynamic> currentDevice() {
    var currentDevice = vntApi.currentDevice();

    var natInfo = vntApi.natInfo();
    return {
      'virtualIp': currentDevice.virtualIp,
      'virtualNetmask': currentDevice.virtualNetmask,
      'virtualGateway': currentDevice.virtualGateway,
      'virtualNetwork': currentDevice.virtualNetwork,
      'broadcastIp': currentDevice.broadcastIp,
      'connectServer': currentDevice.connectServer,
      'status': currentDevice.status,
      'publicIps': natInfo.publicIps,
      'natType': natInfo.natType,
      'localIpv4': natInfo.localIpv4,
      'ipv6': natInfo.ipv6,
    };
  }

  List<RustPeerClientInfo> peerDeviceList() {
    return vntApi.deviceList();
  }

  List<(String, List<RustRoute>)> routeList() {
    return vntApi.routeList();
  }

  RustRoute? route(String ip) {
    return vntApi.route(ip: ip);
  }

  RustNatInfo? peerNatInfo(String ip) {
    return vntApi.peerNatInfo(ip: ip);
  }

  String downStream() {
    return vntApi.downStream();
  }

  String upStream() {
    return vntApi.upStream();
  }
}

class VntManager {
  HashMap<String, VntBox> map = HashMap();
  bool connecting = false;
  Future<VntBox> create(NetworkConfig config, SendPort uiCall) async {
    var key = config.itemKey;
    if (map.containsKey(key)) {
      return map[key]!;
    }
    try {
      connecting = true;
      var vntBox = await VntBox.create(config, uiCall);
      map[key] = vntBox;
      return vntBox;
    } finally {
      connecting = false;
    }
  }

  VntBox? get(String key) {
    var vntBox = map[key];
    if (vntBox != null && !vntBox.isClosed()) {
      return vntBox;
    }
    return null;
  }

  Future<void> remove(String key) async {
    var vnt = map.remove(key);
    if (vnt != null) {
      await vnt.close();
    }
  }

  Future<void> removeAll() async {
    for (var element in map.entries) {
      await element.value.close();
    }
    map.clear();
  }

  bool hasConnectionItem(String key) {
    var vntBox = map[key];
    return vntBox != null && !vntBox.isClosed();
  }

  bool isConnecting() {
    return connecting;
  }

  bool hasConnection() {
    if (map.isEmpty) {
      return false;
    }
    map.removeWhere((key, val) => val.isClosed());
    return map.isNotEmpty;
  }

  int size() {
    map.removeWhere((key, val) => val.isClosed());
    return map.length;
  }

  bool supportMultiple() {
    return !Platform.isAndroid;
  }

  VntBox? getOne() {
    if (map.isEmpty) {
      return null;
    }
    return map.entries.first.value;
  }
}

typedef StartCallback = Future<void> Function();

class VntAppCall {
  static MethodChannel channel = const MethodChannel('top.wherewego.vnt/vpn');
  static StartCallback startCall = () async {};
  static void setStartCall(StartCallback startCall) {
    VntAppCall.startCall = startCall;
  }

  static void init() {
    channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'stopVnt':
          await vntManager.removeAll();
          break;
        case 'startVnt':
          await startCall();
          return vntManager.hasConnection();
        case 'isRunning':
          debugPrint("isRunning ${vntManager.hasConnection()}");
          return vntManager.hasConnection();
        default:
          throw PlatformException(
            code: 'Unimplemented',
            details: 'methodName is not implemented',
          );
      }
    });
  }

  static Future<int> startVpn(RustDeviceConfig info, int mtu, {String tunnelServerAddress = ''}) async {
    final map = rustDeviceConfigToMap(info, mtu);
    if (tunnelServerAddress.isNotEmpty) {
      map['tunnelServerAddress'] = tunnelServerAddress;
    }
    return await VntAppCall.channel.invokeMethod('startVpn', map);
  }

  static Future<void> moveTaskToBack() async {
    return await VntAppCall.channel.invokeMethod('moveTaskToBack');
  }

  static Future<bool> isTileStart() async {
    return await VntAppCall.channel.invokeMethod('isTileStart');
  }

  static Future<void> stopVpn() async {
    return await VntAppCall.channel.invokeMethod('stopVpn');
  }

  /// Check if NEVPNConnection is still connected at the system level
  /// Returns status string: "connected", "disconnected", "connecting", etc.
  static Future<String> checkVpnStatus() async {
    try {
      final result = await VntAppCall.channel.invokeMethod('checkVpnStatus');
      return result?.toString() ?? 'unknown';
    } catch (e) {
      debugPrint('checkVpnStatus error: $e');
      return 'unknown';
    }
  }

  /// Stop VPN at the system level if it's connected (used to clean up stale connections)
  static Future<bool> stopVpnIfConnected() async {
    try {
      final result = await VntAppCall.channel.invokeMethod('stopVpnIfConnected');
      return result as bool? ?? false;
    } catch (e) {
      debugPrint('stopVpnIfConnected error: $e');
      return false;
    }
  }

  /// Read the Extension log file from App Group shared container
  static Future<String> readExtensionLog() async {
    try {
      final result = await VntAppCall.channel.invokeMethod('readExtensionLog');
      return result?.toString() ?? '(no log)';
    } catch (e) {
      return 'Failed to read extension log: $e';
    }
  }

  /// Read the App-side startup log (survives crashes)
  static Future<String> readAppLog() async {
    try {
      final result = await VntAppCall.channel.invokeMethod('readAppLog');
      return result?.toString() ?? '(no app log)';
    } catch (e) {
      return 'Failed to read app log: $e';
    }
  }

  /// Check if previous session crashed (crash flag file exists)
  static Future<bool> checkCrashFlag() async {
    try {
      final result = await VntAppCall.channel.invokeMethod('checkCrashFlag');
      return result as bool? ?? false;
    } catch (e) {
      debugPrint('checkCrashFlag error: $e');
      return false;
    }
  }

  /// Clear the crash flag after reading it
  static Future<void> clearCrashFlag() async {
    try {
      await VntAppCall.channel.invokeMethod('clearCrashFlag');
    } catch (e) {
      debugPrint('clearCrashFlag error: $e');
    }
  }

  static Map<String, dynamic> rustDeviceConfigToMap(
      RustDeviceConfig deviceConfig, int mtu) {
    return {
      'virtualIp': deviceConfig.virtualIp,
      'virtualNetmask': deviceConfig.virtualNetmask,
      'virtualGateway': deviceConfig.virtualGateway,
      'virtualNetwork': deviceConfig.virtualNetwork,
      'mtu': mtu,
      'externalRoute': deviceConfig.externalRoute.map((v) {
        return {
          'destination': v.$1,
          'netmask': v.$2,
        };
      }).toList(),
      'dnsServers': [], // DNS is configured by the Extension via NEPacketTunnelNetworkSettings
    };
  }
}
