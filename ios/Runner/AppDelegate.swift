import Flutter
import UIKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // 注册MethodChannel以处理VPN相关操作
    setupVPNMethodChannel()
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private func setupVPNMethodChannel() {
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let vpnChannel = FlutterMethodChannel(name: "com.vntapp/vpn", binaryMessenger: controller.binaryMessenger)
    
    vpnChannel.setMethodCallHandler {\ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      switch call.method {
      case "startVpn":
        self?.startVPN(result: result)
      case "stopVpn":
        self?.stopVPN(result: result)
      case "getVpnStatus":
        self?.getVpnStatus(result: result)
      case "requestVpnPermission":
        self?.requestVpnPermission(result: result)
      case "saveVpnConfig":
        self?.saveVpnConfig(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
  
  private func startVPN(result: @escaping FlutterResult) {
    VPNManager.shared.startVPN { success, error in
      if success {
        result(true)
      } else {
        result(FlutterError(code: "VPN_ERROR", message: error?.localizedDescription, details: nil))
      }
    }
  }
  
  private func stopVPN(result: @escaping FlutterResult) {
    VPNManager.shared.stopVPN()
    result(true)
  }
  
  private func getVpnStatus(result: @escaping FlutterResult) {
    let status = VPNManager.shared.getVPNStatus()
    result(status)
  }
  
  private func requestVpnPermission(result: @escaping FlutterResult) {
    VPNManager.shared.requestVPNAuthorization { success, error in
      if success {
        result(true)
      } else if let error = error {
        result(FlutterError(code: "VPN_PERMISSION_ERROR", message: error.localizedDescription, details: nil))
      } else {
        result(false)
      }
    }
  }
  
  private func saveVpnConfig(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
      return
    }
    
    let success = VPNManager.shared.saveVPNConfigToAppGroup(config: args)
    result(success)
  }
}
