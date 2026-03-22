import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let storageChannel = "pocket_llm/storage_info"
  private let runtimePathsChannel = "pocket_llm/runtime_paths"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    UNUserNotificationCenter.current().delegate = self

    if let controller = window?.rootViewController as? FlutterViewController {
      let storageInfo = FlutterMethodChannel(
        name: storageChannel,
        binaryMessenger: controller.binaryMessenger
      )
      storageInfo.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "getStorageInfo":
          self?.getStorageInfo(result: result)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let runtimePaths = FlutterMethodChannel(
        name: runtimePathsChannel,
        binaryMessenger: controller.binaryMessenger
      )
      runtimePaths.setMethodCallHandler { call, result in
        switch call.method {
        case "getAppleFrameworksDir":
          result(Bundle.main.privateFrameworksPath)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func getStorageInfo(result: FlutterResult) {
    do {
      let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
      guard
        let free = attributes[.systemFreeSize] as? NSNumber,
        let total = attributes[.systemSize] as? NSNumber
      else {
        result(
          FlutterError(
            code: "storage_error",
            message: "Unable to read storage attributes",
            details: nil
          )
        )
        return
      }

      result([
        "freeBytes": free.int64Value,
        "totalBytes": total.int64Value,
      ])
    } catch {
      result(
        FlutterError(
          code: "storage_error",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }
}
