import Foundation

enum RecordMerge {
  static func workspaceContent(_ value: JSONValue) -> JSONValue {
    guard case .object(var fields) = value else { return value }
    for key in ["updated_at", "profile", "repo_path"] { fields.removeValue(forKey: key) }
    let timestamp = fields["status"] == .string("done") ? "completed_at"
      : fields["status"] == .string("abandoned") ? "abandoned_at" : ""
    if !timestamp.isEmpty, fields[value: timestamp].isNull
      || (try? Clock.parse(fields.text(timestamp))) != nil
    { fields.removeValue(forKey: timestamp) }
    return .object(fields)
  }

  static func equivalentWorkspace(_ a: JSONValue, _ b: JSONValue) -> Bool {
    workspaceContent(a) == workspaceContent(b)
  }

  static func timestamp(_ values: [JSONValue], earliest: Bool) -> JSONValue {
    let dates = values.compactMap { value -> Date? in try? Clock.parse(value.string) }
    guard let date = earliest ? dates.min() : dates.max() else { return .null }
    return .string(Clock.stamp(date))
  }

  static func workspace(base: JSONValue, local: JSONValue, remote: JSONValue,
    preferLocalConflicts: Bool = false) -> (JSONValue, Bool) {
    if equivalentWorkspace(local, remote) {
      guard !remote.isNull else { return (remote, false) }
      var merged = remote
      mergeStateDates(local: local, remote: remote, into: &merged)
      if !local["updated_at"].isNull || !remote["updated_at"].isNull {
        merged["updated_at"] = timestamp([local["updated_at"], remote["updated_at"]], earliest: false)
      }
      return (merged, false)
    }
    guard case .object = base, case .object(let fields) = local, case .object = remote else {
      return (preferLocalConflicts ? local : remote, local != remote)
    }
    var merged = remote
    var conflict = false
    var keptLocal = false
    var handled = Set<String>()
    let focus = fields["elapsed_seconds"] != nil
    let groups = [
      ["project_id", "learning_id", "course_id"],
      ["planned_date", "start_time", "end_time", "reminder_enabled", "reminder_at"],
      focus ? ["status", "active_since", "untracked_seconds"] : ["status", "completed_at", "abandoned_at"],
      fields["weekday"] != nil ? ["weekday", "weeks", "period_start", "period_end", "room"] : [],
      fields["first_monday"] != nil ? ["first_monday", "weeks", "periods"] : [],
      fields["focus_id"] != nil ? ["started_at", "ended_at"] : [],
      ["importance", "priority", "important"],
    ]
    for group in groups {
      let l = group.contains { local[$0] != base[$0] }
      let r = group.contains { remote[$0] != base[$0] }
      let same = group.allSatisfy { local[$0] == remote[$0] }
      if l && !r {
        keptLocal = true
        for key in group where fields[key] != nil { merged[key] = local[key] }
      } else if l && r && !same {
        let localState = JSONValue.object(local.object.filter { group.contains($0.key) })
        let remoteState = JSONValue.object(remote.object.filter { group.contains($0.key) })
        if !focus && group.contains("completed_at") && equivalentWorkspace(localState, remoteState) {
          mergeStateDates(local: local, remote: remote, into: &merged)
          keptLocal = keptLocal || group.contains { merged[$0] != remote[$0] }
        } else {
          conflict = true
          if preferLocalConflicts {
            for key in group where fields[key] != nil { merged[key] = local[key] }
            keptLocal = true
          }
        }
      }
      handled.formUnion(group)
    }
    for (key, value) in fields
    where !handled.contains(key) && !["id", "updated_at", "profile", "repo_path"].contains(key)
      && !(focus && ["elapsed_seconds", "started_at", "ended_at"].contains(key))
    {
      if value != base[key] {
        if remote[key] == base[key] { merged[key] = value; keptLocal = true }
        else if remote[key] != value {
          conflict = true
          if preferLocalConflicts { merged[key] = value; keptLocal = true }
        }
      }
    }
    if keptLocal && local["updated_at"].string > remote["updated_at"].string {
      merged["updated_at"] = local["updated_at"]
    }
    return (merged, conflict)
  }

  private static func mergeStateDates(local: JSONValue, remote: JSONValue, into merged: inout JSONValue) {
    let key = remote["status"] == .string("done") ? "completed_at"
      : remote["status"] == .string("abandoned") ? "abandoned_at" : ""
    if !key.isEmpty, local.object[key] != nil || remote.object[key] != nil {
      let value = timestamp([local[key], remote[key]], earliest: true)
      if !value.isNull || (local[key].isNull && remote[key].isNull) { merged[key] = value }
    }
  }

  static func photo(kind: String, base: JSONValue, local: JSONValue, remote: JSONValue) -> JSONValue? {
    if local == remote { return remote }
    if remote == base { return local }
    if local == base { return remote }
    if kind == "workflow" { return photoWorkflow(base: base, local: local, remote: remote) }
    guard case .object = local, case .object = remote else { return nil }
    // Metadata-only changes, including legacy records without a baseline, are harmless.
    if photoContent(local) == photoContent(remote) { return photoMetadata(local, remote, payload: remote) }
    guard kind == "order", case .object = base,
      photoConflictFields(base: base, local: local, remote: remote).isEmpty else { return nil }
    return resolvePhotoOrder(base: base, local: local, remote: remote, preferLocal: true)
  }

  private static func photoContent(_ value: JSONValue) -> JSONValue {
    guard case .object(var fields) = value else { return value }
    for key in ["updated_at", "updated_by", "revision", "pending", "published"] {
      fields.removeValue(forKey: key)
    }
    return .object(fields)
  }

  private static func photoMetadata(_ local: JSONValue, _ remote: JSONValue, payload: JSONValue) -> JSONValue {
    var result = payload
    let newest = [local, remote].sorted {
      ($0["updated_at"].string, $0["updated_by"].string) < ($1["updated_at"].string, $1["updated_by"].string)
    }.last!
    result["updated_at"] = newest["updated_at"]
    result["updated_by"] = newest["updated_by"]
    return result
  }

  private static func workflowRank(_ value: JSONValue) -> Int? {
    guard let stage = PhotoStage(rawValue: value["stage"].string), stage != .completed,
      let rank = PhotoStage.allCases.firstIndex(of: stage) else { return nil }
    if !value["completed_at"].isNull {
      guard stage == .refund, (try? Clock.parse(value["completed_at"].string)) != nil else { return nil }
      return 5
    }
    return rank
  }

  private static func photoWorkflow(base: JSONValue, local: JSONValue, remote: JSONValue) -> JSONValue? {
    guard case .object = local, case .object = remote, local["id"] == remote["id"],
      let l = workflowRank(local), let r = workflowRank(remote) else { return nil }
    let dates = ["output_at", "review_at", "return_at", "submit_at", "completed_at"]
    guard [local, remote].allSatisfy({ value in
      dates.allSatisfy { value[$0].isNull || (try? Clock.parse(value[$0].string)) != nil }
    }) else { return nil }
    let ignored = Set(dates + ["stage", "updated_at", "updated_by"])
    guard local.object.filter({ !ignored.contains($0.key) })
      == remote.object.filter({ !ignored.contains($0.key) }) else { return nil }
    let winner: JSONValue
    if l == r { winner = remote }
    else if let b = workflowRank(base) {
      if l == b { winner = remote }
      else if r == b { winner = local }
      else if l >= b && r >= b { winner = l > r ? local : remote }
      else { return nil } // Concurrent rollback/advance needs an explicit decision.
    } else { return nil }
    var result = winner
    let rank = max(0, workflowRank(winner) ?? 0)
    for (i, key) in dates.prefix(4).enumerated() {
      result[key] = rank > i ? timestamp([local[key], remote[key]], earliest: true) : .null
    }
    result["completed_at"] = rank == 5
      ? timestamp([local["completed_at"], remote["completed_at"]], earliest: true) : .null
    return photoMetadata(local, remote, payload: result)
  }

  static func photoConflictFields(base: JSONValue, local: JSONValue, remote: JSONValue) -> Set<String> {
    Set(local.object.keys).union(remote.object.keys).filter {
      !["updated_at", "updated_by", "revision", "pending", "published"].contains($0)
        && local[$0] != remote[$0]
        && (base.isNull || (local[$0] != base[$0] && remote[$0] != base[$0]))
    }
  }

  static func resolvePhotoOrder(base: JSONValue, local: JSONValue, remote: JSONValue, preferLocal: Bool) -> JSONValue {
    guard case .object = base, case .object = local, case .object = remote else {
      return preferLocal ? local : remote
    }
    var merged = remote
    let conflicts = photoConflictFields(base: base, local: local, remote: remote)
    for (key, value) in local.object where value != base[key] {
      if !conflicts.contains(key) || preferLocal { merged[key] = value }
    }
    return photoMetadata(local, remote, payload: merged)
  }
}
