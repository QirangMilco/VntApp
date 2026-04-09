import Flutter
import UIKit
import NetworkExtension

/// App-side file logger that writes to App Group shared container.
/// This survives app crashes because the log is flushed immediately.
private let appGroupIdentifier = "group.top.wherewego.vntApp"

private func appLogURL() -> URL {
    let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    return (containerURL?.appendingPathComponent("app.log")) ?? URL(fileURLWithPath: "/tmp/app.log")
}

/// Write a log line to the shared app log file (timestamped, persists across crashes)
private func logToFile(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: appLogURL().path) {
            if let handle = try? FileHandle(forWritingTo: appLogURL()) {
                handle.seekToEndOfFile()
                handle.write(data)
                // Keep log under 50KB
                if handle.offsetInFile > 50_000 {
                    handle.truncateFile(atOffset: 0)
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            try? data.write(to: appLogURL())
        }
    }
    NSLog(message)
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var flutterMethodChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    logToFile("[AppDelegate] ========== didFinishLaunchingWithOptions START ==========")
    
    // Set APP_GROUP_PATH environment variable so Rust panic hook can write crash logs there
    if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
        setenv("APP_GROUP_PATH", containerURL.path, 1)
        logToFile("[AppDelegate] Set APP_GROUP_PATH=\(containerURL.path)")
    }
    
    // Write a marker to a separate "crash detect" file
    // If this file exists on next launch, it means the previous launch crashed
    let crashDetectURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
        .appendingPathComponent("alive.flag") ?? URL(fileURLWithPath: "/tmp/alive.flag")
    
    if FileManager.default.fileExists(atPath: crashDetectURL.path) {
        logToFile("[AppDelegate] ⚠️ CRASH DETECTED! Previous session did not exit cleanly")
        // Don't delete — let the Flutter side read and display it
    }
    // Write "alive" marker
    try? "alive".write(to: crashDetectURL, atomically: true, encoding: .utf8)
    
    GeneratedPluginRegistrant.register(with: self)
    logToFile("[AppDelegate] Plugins registered")
    
    // Register VPN Method Channel handler
    guard let controller = window?.rootViewController as? FlutterViewController else {
      logToFile("[AppDelegate] ❌ ERROR: rootViewController is nil or not FlutterViewController!")
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    logToFile("[AppDelegate] Got FlutterViewController, setting up channel")
    setupVPNChannel(controller: controller)
    
    // Load and prepare VPN manager
    VPNManager.shared.startMonitoringStatus()
    logToFile("[AppDelegate] VPN monitoring started")
    
    logToFile("[AppDelegate] didFinishLaunchingWithOptions END")
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    logToFile("[AppDelegate] super.application returned: \(result)")
    return result
  }
  
  private func setupVPNChannel(controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "top.wherewego.vnt/vpn",
      binaryMessenger: controller.binaryMessenger
    )
    self.flutterMethodChannel = channel
    
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "startVpn":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterMethodNotImplemented)
          return
        }
        logToFile("[AppDelegate] startVpn called")
        VPNManager.shared.startVpn(config: args) { fd, error in
          if let error = error {
            logToFile("[AppDelegate] startVpn failed: \(error)")
            result(FlutterError(code: "VPN_START_FAILED",
                               message: error.localizedDescription,
                               details: nil))
          } else {
            logToFile("[AppDelegate] startVpn success, fd=\(fd)")
            result(fd)
          }
        }
      case "stopVpn":
        logToFile("[AppDelegate] stopVpn called")
        VPNManager.shared.stopVpn()
        result(nil)
      case "checkVpnStatus":
        let status = VPNManager.shared.getVpnStatusString()
        logToFile("[AppDelegate] checkVpnStatus: \(status)")
        result(status)
      case "stopVpnIfConnected":
        logToFile("[AppDelegate] stopVpnIfConnected called")
        let didStop = VPNManager.shared.stopVpnIfConnected()
        logToFile("[AppDelegate] stopVpnIfConnected returned: \(didStop)")
        result(didStop)
      case "readExtensionLog":
        do {
          let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
          let logURL = containerURL?.appendingPathComponent("extension.log")
          if let logURL = logURL, FileManager.default.fileExists(atPath: logURL.path) {
            let logContent = try String(contentsOf: logURL, encoding: .utf8)
            result(logContent)
          } else {
            result("(no extension log found)")
          }
        } catch {
          result("Error reading log: \(error.localizedDescription)")
        }
      case "readAppLog":
        do {
          if FileManager.default.fileExists(atPath: appLogURL().path) {
            let logContent = try String(contentsOf: appLogURL(), encoding: .utf8)
            result(logContent)
          } else {
            result("(no app log found)")
          }
        } catch {
          result("Error reading app log: \(error.localizedDescription)")
        }
      case "checkCrashFlag":
        let crashDetectURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("alive.flag") ?? URL(fileURLWithPath: "/tmp/alive.flag")
        result(FileManager.default.fileExists(atPath: crashDetectURL.path))
      case "clearCrashFlag":
        let crashDetectURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("alive.flag") ?? URL(fileURLWithPath: "/tmp/alive.flag")
        try? FileManager.default.removeItem(atPath: crashDetectURL.path)
        result(nil)
      case "moveTaskToBack":
        // No-op on iOS
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
  
  override func applicationDidEnterBackground(_ application: UIApplication) {
    logToFile("[AppDelegate] applicationDidEnterBackground")
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    logToFile("[AppDelegate] applicationWillTerminate — clearing crash flag")
    // Clear the crash flag — this is a clean exit
    let crashDetectURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
        .appendingPathComponent("alive.flag") ?? URL(fileURLWithPath: "/tmp/alive.flag")
    try? FileManager.default.removeItem(atPath: crashDetectURL.path)
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    logToFile("[AppDelegate] applicationWillEnterForeground")
  }
}
