import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    
    let storageChannel = FlutterMethodChannel(name: "pocket_llm/storage_info", binaryMessenger: flutterViewController.engine.binaryMessenger)
    storageChannel.setMethodCallHandler { (call, result) in
      if call.method == "getStorageInfo" {
        do {
          let fileURL = URL(fileURLWithPath: NSHomeDirectory())
          let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
          
          let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
          let total = values.volumeTotalCapacity ?? 0
          
          result([
            "freeBytes": free,
            "totalBytes": total
          ])
        } catch {
          result(FlutterError(code: "UNAVAILABLE", message: "Could not get storage info", details: nil))
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
