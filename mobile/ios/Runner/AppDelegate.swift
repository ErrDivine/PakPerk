import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
