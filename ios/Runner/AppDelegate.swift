import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let vpnChannelName = "vnt.app/vpn"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "VntVpnChannel") {
      let channel = FlutterMethodChannel(name: vpnChannelName, binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleVpnMethod(call: call, result: result)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleVpnMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startVpn":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "startVpn 参数无效", details: nil))
        return
      }

      VPNManager.shared.startVpn(with: args) { fd, error in
        if let error {
          result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
        } else {
          result(fd)
        }
      }

    case "stopVpn":
      VPNManager.shared.stopVpn()
      result(nil)

    case "isRunning":
      result(VPNManager.shared.isVpnRunning())

    case "startVnt":
      // iOS 场景由 Flutter 侧自行驱动配置选择与连接
      result(VPNManager.shared.isVpnRunning())

    case "stopVnt":
      VPNManager.shared.stopVpn()
      result(nil)

    case "getVpnStatus":
      VPNManager.shared.runtimeStatusAsync { status in
        result(status)
      }

    case "getDeviceInfo":
      VPNManager.shared.runtimeStatusAsync { status in
        result([
          "isConnected": status["isRunning"] as? Bool ?? false,
          "configName": "",
          "onlineCount": 0,
          "offlineCount": 0,
          "vpnStatus": status["vpnStatus"] as? String ?? "unknown",
          "runtimeState": status["runtimeState"] as? String ?? "unknown",
          "extensionState": status["extensionState"] as? String ?? "unknown",
          "extensionUptimeSec": status["extensionUptimeSec"] as? Int ?? 0,
        ])
      }

    case "moveTaskToBack", "isTileStart", "getTileConfigKey", "updateWidgetAndTile":
      // Android 专有接口：iOS 侧返回空值或默认值，保持 Flutter 通道兼容
      if call.method == "isTileStart" {
        result(false)
      } else {
        result(nil)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
