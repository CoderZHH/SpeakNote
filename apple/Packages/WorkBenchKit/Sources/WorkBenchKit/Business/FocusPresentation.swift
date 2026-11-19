import Foundation
import WorkBenchActivity

public struct FocusPresentation: Equatable, Sendable {
  public let id: String
  public let taskID: String?
  public let timer: FocusTimerState
  static func current(in snapshot: WorkspaceSnapshot) -> FocusPresentation? {
    var lastInterval: [String: Date] = [:]
    for interval in snapshot[.focusIntervals] {
      let id = interval.fields.text("focus_id")
      for key in ["started_at", "ended_at"] {
        if let date = try? Clock.parse(interval.fields.text(key)) {
          lastInterval[id] = max(lastInterval[id] ?? .distantPast, date)
        }
      }
    }
    func lastAction(_ item: WorkspaceItem) -> Date {
      (["started_at", "ended_at", "active_since"].compactMap {
        try? Clock.parse(item.fields.text($0))
      }
        + [lastInterval[item.id] ?? .distantPast]).max() ?? .distantPast
    }
    let candidates = snapshot[.focusSessions].filter {
      ["running", "paused", "ended"].contains($0.status)
    }
    .sorted {
      if ($0.status == "running") != ($1.status == "running") { return $0.status == "running" }
      let first = lastAction($0)
      let second = lastAction($1)
      if first != second { return first > second }
      if ($0.status == "ended") != ($1.status == "ended") { return $0.status == "ended" }
      return $0.id > $1.id
    }
    // Ending the latest focus must not resurrect an older paused task on the
    // menu bar or Dynamic Island. A resumed task has a newer interval instead.
    guard let focus = candidates.first, focus.status != "ended" else { return nil }
    let taskID = focus.fields[value: "task_id"].isNull ? nil : focus.fields.text("task_id")
    let title = taskID.flatMap { snapshot.item(.tasks, $0)?.title } ?? "自由专注"
    return FocusPresentation(
      id: focus.id, taskID: taskID,
      timer: .init(
        title: title, accumulatedSeconds: focus.fields.integer("elapsed_seconds"),
        activeSince: try? Clock.parse(focus.fields.text("active_since")),
        isRunning: focus.status == "running",
        goalSeconds: focus.fields.integer("goal_seconds")))
  }
}
