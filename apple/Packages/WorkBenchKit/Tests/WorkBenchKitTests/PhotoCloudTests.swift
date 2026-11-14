import CloudKit
import XCTest

@testable import WorkBenchKit

final class PhotoCloudTests: XCTestCase {
  func testDiscoveryOnlyIncludesPhotoZonesAndRetainsAccountAndOwner() {
    let name = "PhotoWorkspace_00000000-0000-4000-8000-000000000001"
    let zones = [
      CKRecordZone.ID(zoneName: "Workbench", ownerName: "owner"),
      CKRecordZone.ID(zoneName: "PhotoWorkspace_invalid", ownerName: "owner"),
      CKRecordZone.ID(zoneName: name, ownerName: "original-owner"),
    ]
    let own = photoDiscoveredSpaces(
      zones, own: true, account: "me", container: "test", environment: "Development")
    XCTAssertEqual(own.count, 1)
    XCTAssertEqual(own[0]["owner"] as? String, "me")
    XCTAssertEqual(own[0]["scope"] as? String, "private")
    let joined = photoDiscoveredSpaces(
      zones, own: false, account: "her", container: "test", environment: "Development")
    XCTAssertEqual(joined.count, 1)
    XCTAssertEqual(joined[0]["owner"] as? String, "original-owner")
    XCTAssertEqual(joined[0]["account"] as? String, "her")
    XCTAssertEqual(joined[0]["scope"] as? String, "shared")
  }
  func testPersonalZoneAndMismatchedOwnerAreNeverShared() throws {
    let zone = "PhotoWorkspace_00000000-0000-4000-8000-000000000001"
    func input(_ zone: String, _ scope: String, _ owner: String) -> [String: Any] {
      ["workspace": ["zone": zone, "scope": scope, "owner": owner]]
    }
    XCTAssertThrowsError(try photoZone(input("Workbench", "private", "me"), account: "me"))
    XCTAssertThrowsError(
      try photoZone(input("PhotoWorkspace_invalid", "private", "me"), account: "me"))
    XCTAssertThrowsError(try photoZone(input(zone, "private", "other"), account: "me"))
    let own = try photoZone(input(zone, "private", "me"), account: "me")
    XCTAssertTrue(own.1)
    XCTAssertEqual(own.0.ownerName, CKCurrentUserDefaultName)
    let shared = try photoZone(input(zone, "shared", "owner"), account: "me")
    XCTAssertFalse(shared.1)
    XCTAssertEqual(shared.0.ownerName, "owner")
  }
  func testOnlyAppleShareLinksAreAccepted() throws {
    XCTAssertEqual(try photoInviteURL(" https://www.icloud.com/share/test ").host, "www.icloud.com")
    for host in ["icloud.com.cn", "www.icloud.com.cn"] {
      let raw = "https://\(host)/share/example-token#拍照订单"
      let parsed = try photoInviteURL(raw)
      XCTAssertEqual(parsed.host, host)
      XCTAssertEqual(parsed.path, "/share/example-token")
      XCTAssertEqual(parsed.fragment, "%E6%8B%8D%E7%85%A7%E8%AE%A2%E5%8D%95")
    }
    for raw in [
      "http://www.icloud.com/share/a", "https://icloud.com.evil.example/share/a",
      "https://icloud.com.cn.evil.example/share/a", "https://icloud.com.cn/other",
      "https://user@icloud.com.cn/share/a", "https://icloud.com/other",
      "https://user@icloud.com/share/a", "file:///share/a",
    ] {
      XCTAssertThrowsError(try photoInviteURL(raw))
    }
  }
}
