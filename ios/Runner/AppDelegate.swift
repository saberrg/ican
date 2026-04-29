import Flutter
import os.log
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let appLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.icannavigation.app",
    category: "AppLog"
  )

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    registerAppLogChannel(with: messenger)
    OnDeviceVisionChannel.register(with: messenger)
    AudioPlaybackChannel.register(with: messenger)
  }

  override func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
    super.applicationDidReceiveMemoryWarning(application)
    // Free the VLM to reclaim ~800MB under memory pressure
    LlamaService.shared.noteMemoryWarning()
    LlamaService.shared.unloadModel()
  }

  private func registerAppLogChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.ican/app_log",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "log" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let message = args["message"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "Missing log message.", details: nil))
        return
      }

      self?.writeAppLog(message)
      result(nil)
    }
  }

  private func writeAppLog(_ message: String) {
    let redacted = redactSecrets(message)
    os_log("%{public}@", log: appLog, type: .info, redacted)
  }

  private func redactSecrets(_ message: String) -> String {
    var redacted = message
    let patterns = [
      #"(?i)(API_KEY\s*[=:]\s*)[^\s,;]+"#,
      #"(?i)(x-goog-api-key\s*[=:]\s*)[^\s,;]+"#,
      #"(?i)(Authorization\s*:\s*Bearer\s+)[^\s,;]+"#,
      #"(?i)(key=)[A-Za-z0-9_\-]{20,}"#,
      #"(AIza)[0-9A-Za-z_\-]{20,}"#,
    ]

    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
      redacted = regex.stringByReplacingMatches(
        in: redacted,
        options: [],
        range: range,
        withTemplate: "$1<redacted>"
      )
    }

    if redacted.count > 1200 {
      return String(redacted.prefix(1200)) + "..."
    }
    return redacted
  }
}
