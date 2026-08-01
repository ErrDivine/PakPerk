import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testLocalDataIsExcludedFromBackup() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let nested = root.appendingPathComponent("pakperk_content.sqlite")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    XCTAssertTrue(FileManager.default.createFile(atPath: nested.path, contents: Data()))
    defer { try? FileManager.default.removeItem(at: root) }

    try PakPerkLocalDataProtection.apply(roots: [root])

    XCTAssertEqual(
      try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
      true
    )
    XCTAssertEqual(
      try nested.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
      true
    )
    // The simulator filesystem applies the backup resource value but does not
    // expose iOS data-protection classes. Keep the device assertion strict.
    #if !targetEnvironment(simulator)
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: nested.path)[.protectionKey]
          as? FileProtectionType,
        .completeUntilFirstUserAuthentication
      )
    #endif
  }

}
