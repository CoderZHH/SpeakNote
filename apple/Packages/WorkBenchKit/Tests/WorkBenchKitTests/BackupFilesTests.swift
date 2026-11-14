import XCTest

@testable import WorkBenchKit

final class BackupFilesTests: XCTestCase {
  func testRetryKeepsIdenticalSnapshotAndDifferentContentNeverOverwrites() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = Data("{\"version\":1,\"state\":{\"tasks\":[1]}}".utf8)
    let after = Data("{\"version\":1,\"state\":{\"tasks\":[2]}}".utf8)
    let url = try writeImmutableBackup(before, folder: folder, name: "snapshot.json")
    _ = try writeImmutableBackup(before, folder: folder, name: "snapshot.json")
    XCTAssertThrowsError(try writeImmutableBackup(after, folder: folder, name: "snapshot.json"))
    XCTAssertEqual(try Data(contentsOf: url), before)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
        .intValue, 0o600)
  }
  func testDistinctSnapshotFilesRetainHistory() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = Data("{\"version\":1,\"state\":{}}".utf8)
    _ = try writeImmutableBackup(data, folder: folder, name: "mac-day1.json")
    _ = try writeImmutableBackup(data, folder: folder, name: "ios-day1.json")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
  }
  func testInvalidDocumentsAndUnsafeNamesAreRejectedBeforeCreatingFiles() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let good = Data("{\"version\":1,\"state\":{}}".utf8)
    for name in ["../outside.json", ".hidden.json", "file.txt", "sub/file.json"] {
      XCTAssertThrowsError(try writeImmutableBackup(good, folder: folder, name: name))
    }
    XCTAssertThrowsError(
      try writeImmutableBackup(Data("{}".utf8), folder: folder, name: "bad.json"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
  }
}
