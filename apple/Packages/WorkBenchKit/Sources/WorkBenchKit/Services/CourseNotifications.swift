import Foundation
import UserNotifications

private final class WorkspaceNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
@MainActor private let workspaceNotificationDelegate = WorkspaceNotificationDelegate()

func courseNotificationDateComponents(_ date: Date) -> DateComponents {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  var components = calendar.dateComponents(
    [.year, .month, .day, .hour, .minute, .second], from: date)
  components.timeZone = calendar.timeZone
  components.calendar = calendar
  return components
}

@MainActor final class SystemReminderNotifications: ReminderNotificationClient {
  private var testing: Bool { ProcessInfo.processInfo.environment["WORKBENCH_QA"] == "1" }
  private var center: UNUserNotificationCenter {
    let value = UNUserNotificationCenter.current()
    value.delegate = workspaceNotificationDelegate
    return value
  }
  private func owns(_ id: String) -> Bool {
    id.hasPrefix("workbench-task:") || id.hasPrefix("workbench-course:")
  }
  func authorizationStatus() async -> UNAuthorizationStatus {
    guard !testing else { return .denied }
    return await center.notificationSettings().authorizationStatus
  }
  func authorized(requestPermission: Bool) async throws -> Bool {
    let status = await authorizationStatus()
    if requestPermission && status == .notDetermined {
      return try await center.requestAuthorization(options: [.alert, .sound])
    }
    return status == .authorized || status == .provisional
  }
  func pending() async -> [LocalReminder] {
    guard !testing else { return [] }
    return await center.pendingNotificationRequests().compactMap { request in
      guard owns(request.identifier),
        let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
      else { return nil }
      return LocalReminder(
        id: request.identifier, title: request.content.title, body: request.content.body, date: date
      )
    }
  }
  func add(_ reminder: LocalReminder) async throws {
    guard !testing else { return }
    let content = UNMutableNotificationContent()
    content.title = reminder.title
    content.body = reminder.body
    content.sound = .default
    content.threadIdentifier =
      reminder.id.hasPrefix("workbench-task:") ? "workbench-tasks" : "workbench-courses"
    let trigger = UNCalendarNotificationTrigger(
      dateMatching: courseNotificationDateComponents(reminder.date), repeats: false)
    try await center.add(
      UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
  }
  func remove(_ identifiers: [String]) {
    guard !testing, !identifiers.isEmpty else { return }
    center.removePendingNotificationRequests(withIdentifiers: identifiers.filter(owns))
  }
}
