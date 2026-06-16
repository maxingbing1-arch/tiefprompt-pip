import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pipManager: PipManager?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "tiefprompt/pip",
      binaryMessenger: engineBridge.engine.binaryMessenger
    )

    guard #available(iOS 15.0, *) else {
      channel.setMethodCallHandler { _, result in
        result(FlutterMethodNotImplemented)
      }
      return
    }

    let manager = PipManager()
    pipManager = manager
    manager.setup()

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        result(manager.isAvailable)

      case "isActive":
        result(manager.isActive)

      case "startPip":
        let args = call.arguments as? [String: Any] ?? [:]
        manager.start(
          text: args["text"] as? String ?? "",
          speed: args["speed"] as? Double ?? 0.33,
          fontSize: args["fontSize"] as? CGFloat ?? 56,
          isMirrored: args["isMirrored"] as? Bool ?? false,
          scrollOffset: args["scrollOffset"] as? Double ?? 0
        )
        result(nil)

      case "stopPip":
        manager.stop()
        result(nil)

      case "updateSpeed":
        let args = call.arguments as? [String: Any] ?? [:]
        if let speed = args["speed"] as? Double {
          manager.updateSpeed(speed)
        }
        result(nil)

      case "updateSettings":
        let args = call.arguments as? [String: Any] ?? [:]
        manager.updateSettings(
          fontSize: args["fontSize"] as? CGFloat,
          mirrored: args["isMirrored"] as? Bool
        )
        result(nil)

      case "seekTo":
        let args = call.arguments as? [String: Any] ?? [:]
        if let offset = args["scrollOffset"] as? Double {
          manager.seekTo(scrollOffset: offset)
        }
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

