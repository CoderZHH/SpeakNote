import Foundation

extension WorkspaceEngine {
  func startFocus(taskID: String?, goalSeconds: Int? = nil, now: Date) throws -> CommandResult {
    if let taskID {
      try require(try exists(.tasks, taskID).text("status") == "todo", "请先恢复任务，再开始专注")
    }
    if let goalSeconds {
      try require((0...43200).contains(goalSeconds), "目标时长需在 0–12 小时之间")
    }
    let task = taskID.map(JSONValue.string) ?? .null
    let running = try db.one("SELECT * FROM focus_sessions WHERE status='running'")
    if !running.isEmpty && running[value: "task_id"] == task {
      if let goalSeconds {
        try db.update(
          "focus_sessions", id: running.identifier,
          ["goal_seconds": .integer(Int64(goalSeconds))])
      }
      return CommandResult(id: running.identifier, alreadyRunning: true)
    }
    try pauseFocus(now: now)
    let old = try db.one(
      "SELECT * FROM focus_sessions WHERE task_id IS ? AND status='paused' ORDER BY started_at DESC LIMIT 1",
      [task])
    let id: String
    if !old.isEmpty {
      id = old.identifier
      var patch: Record = ["status": .string("running"), "active_since": .string(Clock.stamp(now))]
      if let goalSeconds { patch["goal_seconds"] = .integer(Int64(goalSeconds)) }
      try db.update("focus_sessions", id: id, patch)
    } else {
      id = UUID().uuidString.lowercased()
      try db.insert(
        "focus_sessions",
        [
          "id": .string(id), "task_id": task, "started_at": .string(Clock.stamp(now)),
          "active_since": .string(Clock.stamp(now)),
          "goal_seconds": .integer(Int64(max(0, goalSeconds ?? 0))),
          "status": .string("running"), "untracked_seconds": .integer(0),
        ])
    }
    try db.insert(
      "focus_intervals",
      ["id": .id(), "focus_id": .string(id), "started_at": .string(Clock.stamp(now))])
    return CommandResult(id: id)
  }
  func updateFocusGoal(id: String, goalSeconds: Int) throws -> CommandResult {
    _ = try exists(.focusSessions, id)
    try require((0...43200).contains(goalSeconds), "目标时长需在 0–12 小时之间")
    try db.update("focus_sessions", id: id, ["goal_seconds": .integer(Int64(goalSeconds))])
    return CommandResult(id: id)
  }
  func pauseFocus(now: Date) throws {
    for focus in try db.rows("SELECT * FROM focus_sessions WHERE status='running'") {
      try closeOpenInterval(focus, now: now, status: "paused")
    }
  }
  func closeOpenInterval(_ focus: Record, now: Date, status: String) throws {
    let active =
      try focus[value: "active_since"].isNull ? now : Clock.parse(focus.text("active_since"))
    let elapsed = focus.integer("elapsed_seconds") + Int64(max(0, now.timeIntervalSince(active)))
    try db.execute(
      "UPDATE focus_intervals SET ended_at=? WHERE focus_id=? AND ended_at IS NULL",
      [.string(Clock.stamp(max(now, active))), focus[value: "id"]])
    try db.update(
      "focus_sessions", id: focus.identifier,
      [
        "elapsed_seconds": .integer(elapsed), "active_since": .null, "status": .string(status),
        "ended_at": status == "ended" ? .string(Clock.stamp(now)) : .null,
      ])
  }
  func finishFocus(_ focus: Record, now: Date) throws {
    if focus.text("status") == "ended" { return }
    if focus.text("status") == "running" {
      try closeOpenInterval(focus, now: now, status: "ended")
    } else {
      try db.update(
        "focus_sessions", id: focus.identifier,
        ["status": .string("ended"), "active_since": .null, "ended_at": .string(Clock.stamp(now))])
    }
  }
  func intervalSeconds(_ row: Record) throws -> Int64 {
    if row[value: "ended_at"].isNull { return 0 }
    return Int64(
      max(
        0,
        try Clock.parse(row.text("ended_at")).timeIntervalSince(Clock.parse(row.text("started_at")))
      ))
  }
  func correctFocus(id: String, intervalID: String?, start: Date, end: Date, now: Date) throws
    -> CommandResult
  {
    let focus = try exists(.focusSessions, id)
    try require(end > start && end <= now, "结束时间需晚于开始，且不能晚于现在")
    let rows = try db.rows("SELECT * FROM focus_intervals WHERE focus_id=?", [.string(id)])
    var before: Record = [:]
    if let intervalID {
      before = try exists(.focusIntervals, intervalID)
      try require(before.text("focus_id") == id, "专注时段归属不正确")
    } else {
      try require(rows.isEmpty, "请选择要修正的专注时段")
    }
    for other in rows where other.identifier != before.identifier {
      let from = try Clock.parse(other.text("started_at"))
      let until = try other[value: "ended_at"].isNull ? now : Clock.parse(other.text("ended_at"))
      try require(!(start < until && end > from), "不能覆盖暂停间隔或其他专注时段")
    }
    let known = try rows.reduce(Int64(0)) { try $0 + intervalSeconds($1) }
    let extra =
      before.isEmpty
      ? 0
      : (focus[value: "untracked_seconds"].isNull
        ? max(0, focus.integer("elapsed_seconds") - known) : focus.integer("untracked_seconds"))
    let changes: Record = [
      "started_at": .string(Clock.stamp(start)), "ended_at": .string(Clock.stamp(end)),
    ]
    if let intervalID {
      try db.update("focus_intervals", id: intervalID, changes)
    } else {
      try db.insert(
        "focus_intervals", changes.merging(["id": .id(), "focus_id": .string(id)]) { _, v in v })
    }
    let updated = try db.rows("SELECT * FROM focus_intervals WHERE focus_id=?", [.string(id)])
    let elapsed = try updated.reduce(extra) { try $0 + intervalSeconds($1) }
    let starts = try updated.map { try Clock.parse($0.text("started_at")) }
    let ends = try updated.filter { !$0[value: "ended_at"].isNull }.map {
      try Clock.parse($0.text("ended_at"))
    }
    let ended =
      before.isEmpty || before[value: "ended_at"].isNull || focus.text("status") == "ended"
    let first = min(
      starts.min()!, extra > 0 ? try Clock.parse(focus.text("started_at")) : starts.min()!)
    try db.update(
      "focus_sessions", id: id,
      [
        "started_at": .string(Clock.stamp(first)), "elapsed_seconds": .integer(elapsed),
        "untracked_seconds": .integer(extra),
        "status": .string(ended ? "ended" : focus.text("status")),
        "ended_at": ended ? .string(Clock.stamp(ends.max()!)) : .null,
        "active_since": ended ? .null : focus[value: "active_since"],
      ])
    return CommandResult(id: id)
  }
  func reconcileFocus(inferLegacy: Bool) throws {
    for focus in try db.rows("SELECT * FROM focus_sessions WHERE status='ended'") {
      if focus[value: "untracked_seconds"].isNull && !inferLegacy { continue }
      let rows = try db.rows("SELECT * FROM focus_intervals WHERE focus_id=?", [focus[value: "id"]])
      if rows.contains(where: { $0[value: "ended_at"].isNull }) { continue }
      let known = try rows.reduce(Int64(0)) { try $0 + intervalSeconds($1) }
      let extra =
        focus[value: "untracked_seconds"].isNull
        ? max(0, focus.integer("elapsed_seconds") - known) : focus.integer("untracked_seconds")
      var changes: Record = [:]
      if focus[value: "untracked_seconds"] != .integer(extra) {
        changes["untracked_seconds"] = .integer(extra)
      }
      if !rows.isEmpty {
        let first = try rows.map { try Clock.parse($0.text("started_at")) }.min()!
        let last = try rows.map { try Clock.parse($0.text("ended_at")) }.max()!
        let start = min(first, extra > 0 ? try Clock.parse(focus.text("started_at")) : first)
        if focus.integer("elapsed_seconds") != known + extra {
          changes["elapsed_seconds"] = .integer(known + extra)
        }
        if try Clock.parse(focus.text("started_at")) != start {
          changes["started_at"] = .string(Clock.stamp(start))
        }
        if try focus[value: "ended_at"].isNull || Clock.parse(focus.text("ended_at")) != last {
          changes["ended_at"] = .string(Clock.stamp(last))
        }
      }
      try db.update("focus_sessions", id: focus.identifier, changes)
    }
  }
}
