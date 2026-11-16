import Foundation
import Observation

struct LocalReminder: Equatable, Sendable {
  let id: String
  let title: String
  let body: String
  let date: Date
}

func taskReminderRows(snapshot: WorkspaceSnapshot, now: Date) -> [LocalReminder] {
  snapshot[.tasks].compactMap { task in
    guard task.status == "todo", task[.reminderEnabled] == .integer(1) else { return nil }
    let fixed = try? Clock.parse(task[.reminderAt].string)
    let start = try? Clock.parse(task[.plannedDate].string + "T" + task[.startTime].string + ":00+08:00")
    guard let date = fixed ?? start, date > now else { return nil }
    let association = snapshot.association(task)?.title
    return LocalReminder(
      id: "workbench-task:" + task.id, title: task.title,
      body: (fixed == nil ? "开始时间 " + task[.startTime].string : "任务提醒")
        + (association.map { " · " + $0 } ?? ""), date: date)
  }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
}

func workspaceReminderPlan(snapshot: WorkspaceSnapshot, now: Date, courseMinutes: Int)
  -> [LocalReminder]
{
  let courses = courseReminderRows(snapshot: snapshot, now: now, minutes: courseMinutes).compactMap
  { row -> LocalReminder? in
    guard let date = try? Clock.parse(row["at"].string) else { return nil }
    return LocalReminder(
      id: row["id"].string, title: row["title"].string, body: row["body"].string, date: date)
  }
  // Tasks and courses share one system queue, so neither category can consume
  // the whole pending-notification budget independently.
  return Array(
    (taskReminderRows(snapshot: snapshot, now: now) + courses)
      .sorted { ($0.date, $0.id) < ($1.date, $1.id) }.prefix(60))
}

@MainActor protocol ReminderNotificationClient {
  func authorized(requestPermission: Bool) async throws -> Bool
  func pending() async -> [LocalReminder]
  func add(_ reminder: LocalReminder) async throws
  func remove(_ identifiers: [String])
}

@MainActor @Observable final class WorkspaceReminders {
  private(set) var issue: String?
  @ObservationIgnored private let client: any ReminderNotificationClient
  @ObservationIgnored private var desired: [LocalReminder] = []
  @ObservationIgnored private var applied: [LocalReminder]?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var processing = false
  @ObservationIgnored private var forcePending = false
  @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
  init(client: any ReminderNotificationClient = SystemReminderNotifications()) {
    self.client = client
  }

  func requestAuthorization() async throws {
    guard try await client.authorized(requestPermission: true) else {
      throw WorkBenchError("请在系统设置的「通知」里允许 SpeakNote（随口记）发送通知，再开启提醒。")
    }
    applied = nil
  }
  func checkAuthorization() async throws {
    guard try await client.authorized(requestPermission: false) else {
      throw WorkBenchError("请在 Mac 上打开 SpeakNote（随口记），进入应用内的「设置 → 通知」并开启通知，然后再请我设置提醒。")
    }
  }
  func reconcile(_ plan: [LocalReminder], force: Bool = false) async {
    desired = plan
    generation += 1
    forcePending = forcePending || force
    if processing {
      await withCheckedContinuation { waiters.append($0) }
      return
    }
    processing = true
    defer {
      processing = false
      let waiting = waiters
      waiters = []
      waiting.forEach { $0.resume() }
    }
    while true {
      let version = generation
      let next = desired
      let shouldApply = forcePending || applied != next
      forcePending = false
      if shouldApply {
        do {
          let existing = await client.pending()
          let desiredIDs = Set(next.map(\.id))
          // Cancel outdated plans before adding replacements, freeing system slots.
          client.remove(existing.filter { !desiredIDs.contains($0.id) }.map(\.id))
          if next.isEmpty {
            applied = next
            issue = nil
          } else if try await client.authorized(requestPermission: false) {
            for reminder in next where !existing.contains(reminder) {
              try await client.add(reminder)
            }
            applied = next
            issue = nil
          } else {
            issue = "系统通知未开启，提醒暂时无法发送。"
          }
        } catch { issue = "提醒未能设置：" + error.localizedDescription }
      }
      if version == generation { break }
    }
  }
}

extension AppSession {
  func requestTaskReminderAuthorization() async throws {
    guard workspace != nil else { throw WorkBenchError("拍照助手不能访问个人提醒") }
    try await reminders.requestAuthorization()
  }
  func refreshWorkspaceReminders(force: Bool = false, courseMinutes: Int? = nil) async {
    guard let store = workspace else { return }
    let minutes: Int
    if let courseMinutes {
      minutes = courseMinutes
    } else {
      minutes =
        Int((try? await store.database.syncSetting("course.reminder_minutes"))?.string ?? "0") ?? 0
    }
    let plan = workspaceReminderPlan(snapshot: store.snapshot, now: .now, courseMinutes: minutes)
    await reminders.reconcile(plan, force: force)
  }
}
