import Flutter
import UIKit

enum PakPerkLocalDataProtection {
  static func apply(
    fileManager: FileManager = .default,
    roots: [URL]? = nil
  ) throws {
    let protectedRoots: [URL]
    if let roots {
      protectedRoots = roots
    } else {
      protectedRoots = try defaultRoots(fileManager: fileManager)
      for root in protectedRoots where !fileManager.fileExists(atPath: root.path) {
        try fileManager.createDirectory(
          at: root,
          withIntermediateDirectories: true
        )
      }
    }
    for root in protectedRoots {
      guard fileManager.fileExists(atPath: root.path) else {
        throw CocoaError(.fileNoSuchFile)
      }
      try protect(root, fileManager: fileManager)
      guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsPackageDescendants]
      ) else {
        throw CocoaError(.fileReadUnknown)
      }
      for case let child as URL in enumerator {
        try protect(child, fileManager: fileManager)
      }
    }
  }

  private static func defaultRoots(fileManager: FileManager) throws -> [URL] {
    guard
      let documents = fileManager.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first,
      let library = fileManager.urls(
        for: .libraryDirectory,
        in: .userDomainMask
      ).first
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return [
      documents,
      library.appendingPathComponent("Preferences", isDirectory: true),
      library.appendingPathComponent("Application Support", isDirectory: true),
    ]
  }

  private static func protect(_ url: URL, fileManager: FileManager) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
    try fileManager.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    do {
      // Drift account rows, guest comment snapshots, outbox records, and
      // SharedPreferences restoration state must never return from an iCloud
      // or device backup after deletion. Protect their parent directories so
      // atomic rewrites and newly-created SQLite sidecars inherit the policy.
      try PakPerkLocalDataProtection.apply()
    } catch {
      // Continuing would make deletion semantics depend on backup timing.
      return false
    }
    // AppAuth documents that the default on-disk URL cache may retain an
    // authorization response access token. Pakperk keeps response caching in
    // memory only; public paper persistence is handled by Drift separately.
    URLCache.shared = URLCache(
      memoryCapacity: 8 * 1024 * 1024,
      diskCapacity: 0,
      diskPath: nil
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
