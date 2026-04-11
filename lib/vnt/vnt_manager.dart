import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/src/rust/api/vnt_api.dart';
import 'package:vnt_app/utils/ip_utils.dart';

/// macOS 权限管理器
class MacOSPrivilegeManager {
  /// 检查当前进程是否有 root 权限
  static Future<bool> hasRootPrivilege() async {
    if (!Platform.isMacOS) return true;

    try {
      // 尝试执行一个需要 root 权限���命令来检测
      final result = await Process.run('id', ['-u']);
      final uid = int.tryParse(result.stdout.toString().trim()) ?? -1;
      return uid == 0; // uid 0 表示 root
    } catch (e) {
      return false;
    }
  }

  /// 使用 osascript 以管理员权限重新启动 app
  /// [showPrompt] 是否显示友好的提示信息
  static Future<bool> restartWithPrivilege({bool showPrompt = false}) async {
    if (!Platform.isMacOS) return false;

    try {
      // 获取当前 app 的路径
      final executablePath = Platform.resolvedExecutable;
      // 获取 .app bundle 的路径
      // 例如：/Applications/vnt_app.app/Contents/MacOS/vnt_app
      // 需要提取到：/Applications/vnt_app.app
      final appBundlePath = _getAppBundlePath(executablePath);

      if (appBundlePath == null) {
        return false;
      }

      // 构建 AppleScript 脚本
      // 如果需要显示提示，添加友好的提示信息
      String script;
      if (showPrompt) {
        script = '''
tell application "System Events"
    display dialog "VNT 需要管理员权限来创建虚拟网络设备。\\n\\n授权后将自动重启应用。" buttons {"取消", "授权"} default button "授权" with icon caution
    if button returned of result is "授权" then
        do shell script "\\"$executablePath\\" > /dev/null 2>&1 &" with administrator privileges
    end if
end tell
''';
      } else {
        // 直接请求权限，不显示额外提示
        script =
            'do shell script "\\"$executablePath\\" > /dev/null 2>&1 &" with administrator privileges';
      }

      final result = await Process.run('osascript', ['-e', script]);

      if (result.exitCode == 0) {
        // 延迟退出当前 app，给新 app 启动的时间
        Future.delayed(const Duration(milliseconds: 500), () {
          exit(0);
        });
        return true;
      } else {
        return false;
      }
    } catch (e) {
      return false;
    }
  }

  /// 从可执行文件路径提取 .app bundle 路径
  static String? _getAppBundlePath(String executablePath) {
    // 例如：/Applications/vnt_app.app/Contents/MacOS/vnt_app
    // 需要提取：/Applications/vnt_app.app

    final contentsIndex = executablePath.indexOf('/Contents/MacOS/');
    if (contentsIndex == -1) {
      return null;
    }

    return executablePath.substring(0, contentsIndex) + '.app';
  }

  /// 启动时检查并请求权限（用于 app 启动时调用）
  /// 返回 true 表示需要重启（已经开始重启流程）
  /// 返回 false 表示不需要重启（已有权限或不是 macOS）
  static Future<bool> checkAndRequestPrivilegeOnStartup() async {
    if (!Platform.isMacOS) return false;

    final hasPrivilege = await hasRootPrivilege();
    if (hasPrivilege) {
      return false;
    }

    // 启动时直接请求权限，不显示额外提示（系统会显示标准的密码框）
    return await restartWithPrivilege(showPrompt: false);
  }

  /// 连接时检查权限（用于连接 VPN 时调用，作为兜底检查）
  /// 返回 true 表示需要重启（已经开始重启流程）
  /// 返回 false 表示不需要重启（已有权限或不是 macOS）
  static Future<bool> checkAndRequestPrivilege() async {
    if (!Platform.isMacOS) return false;

    final hasPrivilege = await hasRootPrivilege();
    if (hasPrivilege) {
      print('✓ 已有管理员权限');
      return false;
    }

    return await restartWithPrivilege(showPrompt: false);
  }
}

final VntManager vntManager = VntManager();

class VntBox {
  final VntApi? vntApi;
  final VntConfig vntConfig;
  final NetworkConfig networkConfig;
  bool _closed = false;
  Map<String, dynamic>? _iosStatusCache;
  bool _iosStatusRefreshing = false;
  Timer? _iosDebugPollTimer;
  String _lastIosDebugEvents = '';

  VntBox({
    required this.vntApi,
    required this.vntConfig,
    required this.networkConfig,
    Map<String, dynamic>? iosStatus,
  }) : _iosStatusCache = iosStatus {
    if (Platform.isIOS && vntApi == null) {
      _lastIosDebugEvents =
          (iosStatus?['extensionDebugEvents'] as List?)?.join(' || ') ?? '';
      _startIosDebugPolling();
    }
  }

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

    if (Platform.isIOS) {
      return _createForIos(
          config: config, vntConfig: vntConfig, uiCall: uiCall);
    }

    var vntCall = VntApiCallback(successFn: () {
      uiCall.send('success');
    }, createTunFn: (info) {
      // uiCall.send(info);
    }, connectFn: (info) {
      uiCall.send(info);
    }, handshakeFn: (info) {
      return true;
    }, registerFn: (info) {
      return true;
    }, generateTunFn: (info) async {
      try {
        int fd =
            await VntAppCall.startVpn(info, vntConfig.mtu ?? 1400, vntConfig);
        return fd;
      } catch (e) {
        debugPrint('创建vpn异常 $e');
        uiCall.send('stop');
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

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static Future<VntBox> _createForIos({
    required NetworkConfig config,
    required VntConfig vntConfig,
    required SendPort uiCall,
  }) async {
    final deviceConfig = VntAppCall.buildIosDeviceConfig(config);
    final fd = await VntAppCall.startVpn(
        deviceConfig, vntConfig.mtu ?? 1400, vntConfig);
    if (fd <= 0) {
      throw Exception('iOS VPN 启动失败: fd=$fd');
    }

    const maxChecks = 40; // 40 * 250ms = 10s
    var sentProbe = false;
    for (var i = 0; i < maxChecks; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      final status = await VntAppCall.getVpnStatus();
      if (status == null) {
        continue;
      }

      final vpnStatus = (status['vpnStatus'] ?? '').toString();
      final vpnStatusRaw = _toInt(status['vpnStatusRaw']);
      final runtimeState = (status['runtimeState'] ?? '').toString();
      final extensionState = (status['extensionState'] ?? '').toString();
      final extensionMessage = status['extensionMessage'];
      final packetsFromSystem = _toInt(status['extensionPacketsFromSystem']);
      final packetsToSystem = _toInt(status['extensionPacketsToSystem']);
      final lastErrorCode = _toInt(status['extensionLastErrorCode']);
      final extensionVirtualIp = status['extensionVirtualIp'];
      final routeCount = _toInt(status['extensionRouteCount']);
      final extensionRustLastError = status['extensionRustLastError'];
      final extensionRustLastErrorCode =
          _toInt(status['extensionRustLastErrorCode']);
      final extensionAppliedVirtualIp = status['extensionAppliedVirtualIp'];
      final extensionAppliedVirtualNetmask =
          status['extensionAppliedVirtualNetmask'];
      final extensionAppliedVirtualGateway =
          status['extensionAppliedVirtualGateway'];
      final extensionDebugEvents =
          (status['extensionDebugEvents'] as List?)?.join(' || ');
      final lastDisconnectError = status['lastDisconnectError'];
      final lastDisconnectErrorDomain = status['lastDisconnectErrorDomain'];
      final lastDisconnectErrorCode = _toInt(status['lastDisconnectErrorCode']);

      if (!sentProbe &&
          vpnStatus == 'disconnected' &&
          runtimeState == 'starting') {
        sentProbe = true;
        try {
          await VntAppCall.getVpnStatus();
          debugPrint('[iOS VPN] sent warmup probe while disconnected/starting');
        } catch (_) {}
      }

      debugPrint(
        '[iOS VPN] status[$i/$maxChecks]: vpnStatus=$vpnStatus(raw=$vpnStatusRaw), runtimeState=$runtimeState, extensionState=$extensionState, msg=$extensionMessage, inPkts=$packetsFromSystem, outPkts=$packetsToSystem, lastErr=$lastErrorCode, extVip=$extensionVirtualIp, routeCount=$routeCount, rustErr=$extensionRustLastError, rustErrCode=$extensionRustLastErrorCode, appliedVip=$extensionAppliedVirtualIp, appliedMask=$extensionAppliedVirtualNetmask, appliedGw=$extensionAppliedVirtualGateway, debugEvents=$extensionDebugEvents, lastDisconnect=$lastDisconnectError, lastDisconnectDomain=$lastDisconnectErrorDomain, lastDisconnectCode=$lastDisconnectErrorCode',
      );

      if (runtimeState == 'error' || extensionState == 'error') {
        throw Exception(
            'iOS VPN 扩展启动失败: vpnStatus=$vpnStatus runtime=$runtimeState ext=$extensionState msg=$extensionMessage code=$lastErrorCode');
      }

      // iOS 上 runtimeState 来自共享状态，可能因写入时序滞后；
      // 连接成功以系统 VPN 状态 + 扩展运行态为准。
      if ((vpnStatus == 'connected' || vpnStatus == 'reasserting') &&
          extensionState == 'running') {
        uiCall.send('success');
        return VntBox(
            vntApi: null,
            vntConfig: vntConfig,
            networkConfig: config,
            iosStatus: status);
      }
    }

    final latest = await VntAppCall.getVpnStatus();
    throw Exception('iOS VPN 等待扩展就绪超时: ${latest ?? {}}');
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _iosDebugPollTimer?.cancel();
    _iosDebugPollTimer = null;

    if (Platform.isIOS) {
      await VntAppCall.stopVpn();
      return;
    }

    vntApi?.stop();
    if (Platform.isAndroid) {
      await VntAppCall.stopVpn();
    }
  }

  bool isClosed() {
    if (_closed) {
      return true;
    }
    return vntApi?.isStopped() ?? false;
  }

  NetworkConfig? getNetConfig() {
    return networkConfig;
  }

  void _refreshIosStatusAsync() {
    if (!Platform.isIOS || vntApi != null || _closed || _iosStatusRefreshing) {
      return;
    }
    _iosStatusRefreshing = true;
    unawaited(VntAppCall.getVpnStatus().then((status) {
      if (status != null) {
        _iosStatusCache = status;
        final debugEvents =
            (status['extensionDebugEvents'] as List?)?.join(' || ') ?? '';
        if (debugEvents.isNotEmpty && debugEvents != _lastIosDebugEvents) {
          _lastIosDebugEvents = debugEvents;
          debugPrint('[iOS VPN] extension debug: $debugEvents');
        }
      }
    }).whenComplete(() {
      _iosStatusRefreshing = false;
    }));
  }

  void _startIosDebugPolling() {
    if (!Platform.isIOS || vntApi != null || _closed) {
      return;
    }
    _iosDebugPollTimer?.cancel();
    _iosDebugPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed) {
        _iosDebugPollTimer?.cancel();
        _iosDebugPollTimer = null;
        return;
      }
      _refreshIosStatusAsync();
    });
  }

  Map<String, dynamic> currentDevice() {
    if (vntApi == null) {
      _refreshIosStatusAsync();
      final status = _iosStatusCache;

      final virtualIp = (status?['extensionVirtualIp'] as String?)?.trim();
      final virtualNetmask =
          (status?['extensionVirtualNetmask'] as String?)?.trim();
      final virtualGateway =
          (status?['extensionVirtualGateway'] as String?)?.trim();
      final virtualNetwork =
          (status?['extensionVirtualNetwork'] as String?)?.trim();
      final connectServer =
          (status?['extensionTunnelServerAddress'] as String?)?.trim();
      final currentStatus =
          (status?['extensionCurrentStatus'] as String?)?.trim();

      return {
        'virtualIp':
            (virtualIp == null || virtualIp.isEmpty) ? 'N/A' : virtualIp,
        'virtualNetmask': (virtualNetmask == null || virtualNetmask.isEmpty)
            ? 'N/A'
            : virtualNetmask,
        'virtualGateway': (virtualGateway == null || virtualGateway.isEmpty)
            ? 'N/A'
            : virtualGateway,
        'virtualNetwork': (virtualNetwork == null || virtualNetwork.isEmpty)
            ? 'N/A'
            : virtualNetwork,
        'broadcastIp': '',
        'connectServer': (connectServer == null || connectServer.isEmpty)
            ? vntConfig.serverAddressStr
            : connectServer,
        'status': _closed
            ? 'Stopped'
            : ((currentStatus == null || currentStatus.isEmpty)
                ? 'Connected'
                : currentStatus),
        'publicIps': <String>[],
        'natType': 'Unknown',
        'localIpv4':
            networkConfig.localIpv4.isEmpty ? null : networkConfig.localIpv4,
        'ipv6': null,
      };
    }

    var currentDevice = vntApi!.currentDevice();
    var natInfo = vntApi!.natInfo();
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
    if (vntApi != null) {
      return vntApi!.deviceList();
    }

    if (!Platform.isIOS) {
      return const [];
    }

    _refreshIosStatusAsync();
    final raw = _iosStatusCache?['extensionPeerDevices'];
    if (raw is! List) {
      return const [];
    }

    final result = <RustPeerClientInfo>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item as Map);
      final vip = (map['virtualIp'] ?? '').toString();
      if (vip.isEmpty) continue;
      result.add(RustPeerClientInfo(
        virtualIp: vip,
        name: (map['name'] ?? '').toString(),
        status: (map['status'] ?? '').toString(),
        clientSecret: map['clientSecret'] == true,
      ));
    }
    return result;
  }

  List<(String, List<RustRoute>)> routeList() {
    return vntApi?.routeList() ?? const [];
  }

  RustRoute? route(String ip) {
    if (vntApi != null) {
      return vntApi!.route(ip: ip);
    }

    if (!Platform.isIOS) {
      return null;
    }

    _refreshIosStatusAsync();
    final raw = _iosStatusCache?['extensionPeerDevices'];
    if (raw is! List) {
      return null;
    }

    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item as Map);
      final vip = (map['virtualIp'] ?? '').toString();
      if (vip != ip) continue;
      final route = map['route'];
      if (route is! Map) return null;
      final routeMap = Map<String, dynamic>.from(route as Map);
      return RustRoute(
        protocol: (routeMap['protocol'] ?? 'Unknown').toString(),
        addr: (routeMap['addr'] ?? '').toString(),
        metric: _toInt(routeMap['metric']),
        rt: _toInt(routeMap['rt']),
      );
    }

    return null;
  }

  RustNatInfo? peerNatInfo(String ip) {
    return vntApi?.peerNatInfo(ip: ip);
  }

  String downStream() {
    return vntApi?.downStream() ?? '0 bytes';
  }

  String upStream() {
    return vntApi?.upStream() ?? '0 bytes';
  }
}

class VntManager {
  HashMap<String, VntBox> map = HashMap();
  bool connecting = false;
  // 记录主动断开连接的配置key，避免显示"服务已停止"提示
  final Set<String> _manualDisconnecting = {};

  // 判断设备是否在线 - 不区分大小写，去掉空格和换行
  bool _isDeviceOnline(String status) {
    return status.trim().toLowerCase() == 'online';
  }

  /// 标记为主动断开连接
  void markManualDisconnect(String key) {
    _manualDisconnecting.add(key);
  }

  /// 检查是否为主动断开连接
  bool isManualDisconnect(String key) {
    return _manualDisconnecting.contains(key);
  }

  /// 清除主动断开标记
  void clearManualDisconnect(String key) {
    _manualDisconnecting.remove(key);
  }

  Future<VntBox> create(NetworkConfig config, SendPort uiCall) async {
    var key = config.itemKey;
    if (map.containsKey(key)) {
      return map[key]!;
    }
    try {
      connecting = true;

      // macOS 权限检查：如果没有权限，请求重新启动
      if (Platform.isMacOS) {
        final needsRestart =
            await MacOSPrivilegeManager.checkAndRequestPrivilege();
        if (needsRestart) {
          // 已经开始重启流程，抛出异常通知 UI
          throw Exception('需要管理员权限，app 正在重新启动...');
        }
      }

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
    // 更新磁贴和小组件状态
    if (Platform.isAndroid) {
      VntAppCall.updateWidgetAndTile(hasConnection());
    }
  }

  Future<void> removeAll() async {
    for (var element in map.entries) {
      await element.value.close();
    }
    map.clear();
    // 更新磁贴和小组件状态
    if (Platform.isAndroid) {
      VntAppCall.updateWidgetAndTile(false);
    }
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
    return !Platform.isAndroid && !Platform.isIOS;
  }

  VntBox? getOne() {
    if (map.isEmpty) {
      return null;
    }
    return map.entries.first.value;
  }
}

typedef StartCallback = Future<void> Function(String? configKey);

class VntAppCall {
  static MethodChannel channel = const MethodChannel('vnt.app/vpn');
  static StartCallback startCall = (String? configKey) async {};
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
          // 获取可选的配置key参数
          String? configKey = call.arguments as String?;
          await startCall(configKey);
          return vntManager.hasConnection();
        case 'isRunning':
          debugPrint("isRunning ${vntManager.hasConnection()}");
          return vntManager.hasConnection();
        case 'getDeviceInfo':
          // 获取设备信息：在线数量、离线数量、配置名称
          return _getDeviceInfo();
        default:
          throw PlatformException(
            code: 'Unimplemented',
            details: 'methodName is not implemented',
          );
      }
    });
  }

  /// 获取设备信息
  static Map<String, dynamic> _getDeviceInfo() {
    var vntBox = vntManager.getOne();
    if (vntBox == null) {
      return {
        'isConnected': false,
        'configName': '',
        'onlineCount': 0,
        'offlineCount': 0,
      };
    }

    var deviceList = vntBox.peerDeviceList();
    int onlineCount = 0;
    int offlineCount = 0;

    for (var device in deviceList) {
      if (vntManager._isDeviceOnline(device.status)) {
        onlineCount++;
      } else {
        offlineCount++;
      }
    }

    var networkConfig = vntBox.getNetConfig();
    String configName = networkConfig?.configName ?? '未知配置';

    return {
      'isConnected': true,
      'configName': configName,
      'onlineCount': onlineCount,
      'offlineCount': offlineCount,
    };
  }

  static Future<int> startVpn(
      RustDeviceConfig info, int mtu, VntConfig vntConfig) async {
    final payload = rustDeviceConfigToMap(info, mtu, vntConfig);
    final vntMap = vntConfigToMap(vntConfig);
    debugPrint(
      '[iOS VPN] startVpn: ip=${info.virtualIp}, netmask=${info.virtualNetmask}, gateway=${info.virtualGateway}, routeCount=${info.externalRoute.length}, server=${vntConfig.serverAddressStr}, enableIpv6OverVnt=${vntMap['enableIpv6OverVnt']}, vntConfigJsonLen=${(payload['vntConfigJson'] as String?)?.length ?? 0}',
    );
    return await VntAppCall.channel.invokeMethod('startVpn', payload);
  }

  static RustDeviceConfig buildIosDeviceConfig(NetworkConfig config) {
    final ip = config.virtualIPv4.isEmpty ? '10.26.0.2' : config.virtualIPv4;
    final netmask = _defaultNetmask(config.virtualIPv4);
    final gateway = _deriveGateway(ip);
    final network = _deriveNetwork(ip, netmask);
    final routes = _buildExternalRoutes(config.outIps);

    if (config.virtualIPv4.isEmpty) {
      debugPrint(
          '[iOS VPN] 警告: 配置未填写 virtualIPv4，当前使用回退地址 $ip。若服务端分配地址与此不一致，可能导致互联失败。');
    }
    debugPrint(
      '[iOS VPN] 组装设备配置: config=${config.configName}, rawVirtualIp=${config.virtualIPv4}, ip=$ip, netmask=$netmask, gateway=$gateway, network=$network, routeCount=${routes.length}, rawOutIps=${config.outIps.length}',
    );

    return RustDeviceConfig(
      virtualIp: ip,
      virtualNetmask: netmask,
      virtualGateway: gateway,
      virtualNetwork: network,
      externalRoute: routes,
    );
  }

  static String _defaultNetmask(String virtualIp) {
    if (virtualIp.isEmpty) {
      return '255.255.255.0';
    }
    final parts = virtualIp.split('.');
    if (parts.length != 4) {
      return '255.255.255.0';
    }
    return '255.255.255.0';
  }

  static String _deriveGateway(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) {
      return '10.26.0.1';
    }
    return '${parts[0]}.${parts[1]}.${parts[2]}.1';
  }

  static String _deriveNetwork(String ip, String netmask) {
    final ipSeg = ip.split('.');
    final maskSeg = netmask.split('.');
    if (ipSeg.length != 4 || maskSeg.length != 4) {
      return '10.26.0.0';
    }

    final network = List<int>.generate(4, (index) {
      final ipPart = int.tryParse(ipSeg[index]) ?? 0;
      final maskPart = int.tryParse(maskSeg[index]) ?? 0;
      return ipPart & maskPart;
    });
    return '${network[0]}.${network[1]}.${network[2]}.${network[3]}';
  }

  static List<(String, String)> _buildExternalRoutes(List<String> outIps) {
    // iOS 下当 outIps 为空时，不应默认下发 0.0.0.0/0。
    // 否则会把控制面（server/stun）流量也导入隧道，形成回环，表现为连接后互不可见。
    if (outIps.isEmpty) {
      return const [];
    }

    final routes = <(String, String)>[];
    for (final item in outIps) {
      final pair = item.split('/');
      if (pair.length != 2) {
        continue;
      }
      final destination = pair[0];
      final prefix = int.tryParse(pair[1]);
      if (prefix == null || prefix < 0 || prefix > 32) {
        continue;
      }
      final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
      final netmask =
          '${(mask >> 24) & 0xFF}.${(mask >> 16) & 0xFF}.${(mask >> 8) & 0xFF}.${mask & 0xFF}';
      routes.add((destination, netmask));
    }

    return routes;
  }

  static Future<void> moveTaskToBack() async {
    return await VntAppCall.channel.invokeMethod('moveTaskToBack');
  }

  static Future<bool> isTileStart() async {
    return await VntAppCall.channel.invokeMethod('isTileStart');
  }

  static Future<String?> getTileConfigKey() async {
    return await VntAppCall.channel.invokeMethod('getTileConfigKey');
  }

  static Future<void> stopVpn() async {
    return await VntAppCall.channel.invokeMethod('stopVpn');
  }

  static Future<Map<String, dynamic>?> getVpnStatus() async {
    try {
      final status = await VntAppCall.channel.invokeMethod('getVpnStatus');
      if (status is Map) {
        return Map<String, dynamic>.from(status);
      }
      return null;
    } catch (e) {
      debugPrint('[iOS VPN] getVpnStatus 调用失败: $e');
      return null;
    }
  }

  /// 更新磁贴和小组件状态
  /// @param isConnected 是否已连接
  static Future<void> updateWidgetAndTile(bool isConnected) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await VntAppCall.channel.invokeMethod('updateWidgetAndTile', {
        'isConnected': isConnected,
      });
      debugPrint('已通知更新磁贴和小组件状态: isConnected=$isConnected');
    } catch (e) {
      debugPrint('更新磁贴和小组件状态失败: $e');
    }
  }

  static Map<String, dynamic> rustDeviceConfigToMap(
      RustDeviceConfig deviceConfig, int mtu, VntConfig vntConfig) {
    return {
      'virtualIp': deviceConfig.virtualIp,
      'virtualNetmask': deviceConfig.virtualNetmask,
      'virtualGateway': deviceConfig.virtualGateway,
      'virtualNetwork': deviceConfig.virtualNetwork,
      'virtualIpAutoAssigned': vntConfig.ip == null,
      'mtu': mtu,
      'dnsServers': vntConfig.nameServers,
      'tunnelServerAddress': vntConfig.serverAddressStr,
      'externalRoute': deviceConfig.externalRoute.map((v) {
        return {
          'destination': v.$1,
          'netmask': v.$2,
        };
      }).toList(),
      'vntConfigJson': jsonEncode(vntConfigToMap(vntConfig)),
    };
  }

  static Map<String, dynamic> vntConfigToMap(VntConfig config) {
    return {
      'token': config.token,
      'deviceId': config.deviceId,
      'name': config.name,
      'serverAddressStr': config.serverAddressStr,
      'nameServers': config.nameServers,
      'stunServer': config.stunServer,
      'inIps': config.inIps.map((v) => [v.$1, v.$2, v.$3]).toList(),
      'outIps': config.outIps.map((v) => [v.$1, v.$2]).toList(),
      'password': config.password,
      'mtu': config.mtu,
      'ip': config.ip,
      'noProxy': config.noProxy,
      'serverEncrypt': config.serverEncrypt,
      'cipherModel': config.cipherModel,
      'finger': config.finger,
      'punchModel': config.punchModel,
      'ports': config.ports?.toList(),
      'firstLatency': config.firstLatency,
      'useChannelType': config.useChannelType,
      'packetLossRate': config.packetLossRate,
      'packetDelay': config.packetDelay,
      'portMappingList': config.portMappingList,
      'compressor': config.compressor,
      'allowWireGuard': config.allowWireGuard,
      'localIpv4': config.localIpv4,
      'enableIpv6OverVnt': false,
    };
  }
}
