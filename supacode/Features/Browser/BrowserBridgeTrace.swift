import Foundation
import SupacodeSettingsShared

/// Step-by-step record of the Chrome sign-in bridge, so a failed hand-off can
/// be diagnosed after the fact. Debug builds send `SupaLogger` to stdout, which
/// is lost for an app launched from Finder, so each step is also appended to
/// `~/Library/Logs/Supacode/browser-bridge.log`. Never records cookie values.
nonisolated enum BrowserBridgeTrace {
  static let fileURL = URL.homeDirectory.appending(path: "Library/Logs/Supacode/browser-bridge.log")
  private static let logger = SupaLogger("BrowserBridge")
  private static let queue = DispatchQueue(label: "app.supabit.supacode.browser-bridge-trace")
  private static let maxBytes = 1_000_000

  /// Unit tests drive the bridge in the test host; keep them out of the file
  /// that diagnoses real attempts.
  private static let isTestHost =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  static func record(_ message: String) {
    logger.info(message)
    guard !isTestHost else { return }
    let line = "\(Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
    queue.async { append(line) }
  }

  private static func append(_ line: String) {
    let manager = FileManager.default
    let path = fileURL.path(percentEncoded: false)
    try? manager.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
      try? manager.removeItem(atPath: path)
    }
    guard manager.fileExists(atPath: path) || manager.createFile(atPath: path, contents: nil),
      let handle = try? FileHandle(forWritingTo: fileURL)
    else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  }
}
