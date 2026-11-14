import UserNotifications
import XCTest

@testable import WorkBenchKit

final class CourseNotificationTests: XCTestCase {
  func testAbsoluteTriggerKeepsUTCZoneInsteadOfShiftingShanghaiClassTime() throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = try XCTUnwrap(formatter.date(from: "2026-10-14T23:50:00.000Z"))
    let components = courseNotificationDateComponents(date)
    XCTAssertEqual(components.timeZone?.secondsFromGMT(), 0)
    XCTAssertEqual(components.day, 14)
    XCTAssertEqual(components.hour, 23)
    XCTAssertEqual(components.minute, 50)
    XCTAssertEqual(components.calendar?.date(from: components), date)
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    XCTAssertEqual(trigger.dateComponents.timeZone?.secondsFromGMT(), 0)
    XCTAssertFalse(trigger.repeats)
  }
}
