import CloudKit
import XCTest

@testable import WorkBenchKit

final class ZoneInitializationTests: XCTestCase {
  @MainActor func testExistingZoneIsUsedWithoutResaving() async throws {
    var saved = false
    try await ensureRecordZone(fetch: {}, create: { saved = true })
    XCTAssertFalse(saved)
  }
  @MainActor func testMissingZoneIsCreated() async throws {
    for code in [CKError.Code.zoneNotFound, .unknownItem] {
      var saved = false
      try await ensureRecordZone(fetch: { throw CKError(code) }, create: { saved = true })
      XCTAssertTrue(saved)
    }
  }
  @MainActor func testOtherFetchErrorsDoNotTriggerCreation() async {
    var saved = false
    do {
      try await ensureRecordZone(
        fetch: { throw CKError(.serverRejectedRequest) }, create: { saved = true })
      XCTFail("Fetch failure must remain visible")
    } catch { XCTAssertEqual((error as? CKError)?.code, .serverRejectedRequest) }
    XCTAssertFalse(saved)
  }
  @MainActor func testFailedCreationDoesNotReportSuccess() async {
    do {
      try await ensureRecordZone(
        fetch: { throw CKError(.zoneNotFound) }, create: { throw CKError(.networkFailure) })
      XCTFail("Failed creation must remain visible")
    } catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
  }
}
