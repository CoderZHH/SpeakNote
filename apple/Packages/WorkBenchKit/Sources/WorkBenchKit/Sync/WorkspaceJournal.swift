import Foundation

extension WorkspaceEngine {
  func installJournal() throws {
    try db.script(
      "CREATE TABLE IF NOT EXISTS wb_sync_control(id INTEGER PRIMARY KEY CHECK(id=1),suppress INTEGER NOT NULL DEFAULT 0); INSERT OR IGNORE INTO wb_sync_control VALUES(1,0); CREATE TABLE IF NOT EXISTS wb_sync_meta(entity TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 1,dirty INTEGER NOT NULL DEFAULT 1,deleted INTEGER NOT NULL DEFAULT 0,server_fields TEXT,base_payload TEXT,PRIMARY KEY(entity,id)); CREATE TABLE IF NOT EXISTS wb_sync_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS wb_sync_conflicts(id TEXT PRIMARY KEY,entity TEXT NOT NULL,record_id TEXT NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS wb_sync_inbox(entity TEXT NOT NULL,id TEXT NOT NULL,document TEXT NOT NULL,PRIMARY KEY(entity,id));"
    )
    if try !db.columns("wb_sync_conflicts").contains("base_payload") {
      try db.script("ALTER TABLE wb_sync_conflicts ADD COLUMN base_payload TEXT")
    }
    for entity in WorkspaceEntity.allCases {
      let table = entity.rawValue
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        let deleted = operation == "DELETE" ? 1 : 0
        let reference = operation == "DELETE" ? "OLD" : "NEW"
        try db.script(
          "CREATE TRIGGER IF NOT EXISTS wb_sync_\(table)_\(operation.lowercased()) AFTER \(operation) ON \(quote(table)) WHEN (SELECT suppress FROM wb_sync_control WHERE id=1)=0 BEGIN INSERT INTO wb_sync_meta(entity,id,dirty,deleted) VALUES('\(table)',\(reference).id,1,\(deleted)) ON CONFLICT(entity,id) DO UPDATE SET revision=revision+1,dirty=1,deleted=\(deleted); END; INSERT OR IGNORE INTO wb_sync_meta(entity,id) SELECT '\(table)',id FROM \(quote(table));"
        )
      }
    }
    try reconcileConflicts()
  }
  func syncSetting(_ key: String) throws -> JSONValue {
    try db.one("SELECT value FROM wb_sync_settings WHERE key=?", [.string(key)])[value: "value"]
  }
  func setSyncSetting(_ key: String, _ value: JSONValue) throws {
    try db.execute(
      "INSERT INTO wb_sync_settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      [.string(key), value])
  }
  func bindCloud(container: String, account: String) throws {
    let current = try syncSetting("cloud.container")
    let previous = try syncSetting("cloud.account." + container)
    try require(current.isNull || current == .string(container), "iCloud 容器已改变，同步已暂停")
    try require(previous.isNull || previous == .string(account), "iCloud 账号已改变，请备份并另选工作区")
    try setSyncSetting("cloud.account." + container, .string(account))
    try setSyncSetting("cloud.container", .string(container))
  }
  func pendingDocuments() throws -> [SyncDocument] {
    try reconcileFocus(inferLegacy: true)
    return try db.rows("SELECT * FROM wb_sync_meta WHERE dirty=1 ORDER BY entity,id").compactMap {
      meta in
      let entity = meta.text("entity")
      let id = meta.identifier
      var payload = try db.record(entity, id: id)
      if entity == "focus_sessions" && !payload.isEmpty && payload.text("status") != "ended" {
        return nil
      }
      if entity == "focus_intervals" && !payload.isEmpty {
        if try payload[value: "ended_at"].isNull
          || db.record("focus_sessions", id: payload.text("focus_id")).text("status") != "ended"
        {
          return nil
        }
      }
      if entity == "attachments" && !payload.isEmpty && meta.integer("deleted") != 1 {
        try MediaFiles.validate(
          .object(payload),
          directory: db.url.deletingLastPathComponent().appendingPathComponent("attachments"),
          maximum: 100 * 1024 * 1024)
      }
      payload.removeValue(forKey: "profile")
      payload.removeValue(forKey: "repo_path")
      return SyncDocument(
        entity: entity, id: id,
        payload: meta.integer("deleted") == 1 || payload.isEmpty ? .null : .object(payload),
        revision: meta.integer("revision"),
        serverFields: meta["server_fields"]?.isNull == false ? meta.text("server_fields") : nil)
    }
  }
  func acknowledge(_ doc: SyncDocument, serverFields: String) throws {
    guard let entity = doc.entity, let revision = doc.revision else {
      throw WorkBenchError("同步确认格式不正确")
    }
    try db.execute(
      "UPDATE wb_sync_meta SET server_fields=?,base_payload=?,dirty=CASE WHEN revision=? THEN 0 ELSE dirty END WHERE entity=? AND id=?",
      [
        .string(serverFields), doc.payload.isNull ? .null : .string(try doc.payload.json()),
        .integer(revision), .string(entity), .string(doc.id),
      ])
  }
  func receive(_ documents: [SyncDocument]) throws {
    try db.transaction {
      for doc in documents {
        try require(
          WorkspaceEntity(rawValue: doc.entity ?? "") != nil && !doc.id.isEmpty
            && doc.id.utf16.count <= 100, "同步数据类型不正确")
        try db.execute(
          "INSERT INTO wb_sync_inbox VALUES(?,?,?) ON CONFLICT(entity,id) DO UPDATE SET document=excluded.document",
          [.string(doc.entity!), .string(doc.id), .string(try doc.value().json())])
      }
      try db.execute("UPDATE wb_sync_control SET suppress=1 WHERE id=1")
      while true {
        var progress = false
        let rows = try db.rows("SELECT * FROM wb_sync_inbox").sorted {
          (WorkspaceEntity.allCases.firstIndex(of: WorkspaceEntity(rawValue: $0.text("entity"))!)!)
            < (WorkspaceEntity.allCases.firstIndex(
              of: WorkspaceEntity(rawValue: $1.text("entity"))!)!)
        }
        for row in rows {
          let doc = try JSONDecoder().decode(
            SyncDocument.self, from: Data(row.text("document").utf8))
          try db.script("SAVEPOINT incoming_record")
          do {
            try mergeDocument(doc)
            try db.execute(
              "DELETE FROM wb_sync_inbox WHERE entity=? AND id=?",
              [row[value: "entity"], row[value: "id"]])
            try db.script("RELEASE incoming_record")
            progress = true
          } catch {
            try db.script("ROLLBACK TO incoming_record; RELEASE incoming_record")
            if !error.localizedDescription.contains("FOREIGN KEY")
              && !error.localizedDescription.contains("记录已不存在")
            {
              throw error
            }
          }
        }
        if !progress { break }
      }
      try db.execute("UPDATE wb_sync_control SET suppress=0 WHERE id=1")
      try reconcileFocus(inferLegacy: false)
      try reconcileConflicts()
    }
  }
  func mergeDocument(_ doc: SyncDocument) throws {
    guard let entity = WorkspaceEntity(rawValue: doc.entity ?? "") else {
      throw WorkBenchError("同步类型不正确")
    }
    let table = entity.rawValue
    let before = try db.record(table, id: doc.id)
    let meta = try db.one(
      "SELECT * FROM wb_sync_meta WHERE entity=? AND id=?", [.string(table), .string(doc.id)])
    var localFields = before
    localFields.removeValue(forKey: "repo_path")
    localFields.removeValue(forKey: "profile")
    let local = localFields.isEmpty ? JSONValue.null : .object(localFields)
    let base = (try? JSONValue(json: meta.text("base_payload"))) ?? .null
    var remote = doc.payload
    if !remote.isNull {
      var f = remote.object
      f.removeValue(forKey: "repo_path")
      f.removeValue(forKey: "profile")
      if entity == .tasks && f["importance"] == nil {
        f["importance"] =
          before["importance"]
          ?? .integer(f[value: "important"].bool || f["priority"] == .string("high") ? 4 : 1)
      }
      remote = .object(f)
    }
    let deleted = meta.integer("dirty") == 1 && meta.integer("deleted") == 1
    if local == remote && base == remote && meta.integer("dirty") == 0 {
      try db.execute("UPDATE wb_sync_meta SET server_fields=? WHERE entity=? AND id=?",
        [doc.serverFields.map(JSONValue.string) ?? .null, .string(table), .string(doc.id)])
      return
    }
    var merged: JSONValue
    var conflict = false
    if deleted {
      merged = .null
      conflict = !RecordMerge.equivalentWorkspace(remote, base) && !remote.isNull
    } else if meta.integer("dirty") == 1 && remote == base {
      merged = local
    } else if meta.integer("dirty") == 1 && local != remote && local != base {
      (merged, conflict) = RecordMerge.workspace(base: base, local: local, remote: remote)
    } else {
      merged = remote
    }
    if conflict {
      try preserveConflict(entity: table, recordID: doc.id, payload: deleted ? remote : local, base: base)
    }
    if !merged.isNull {
      try require(merged["id"] == .string(doc.id), "同步记录 ID 不一致")
      if entity == .focusSessions {
        try require(merged["status"] == .string("ended"), "不能同步运行中的计时器")
      }
      var fields = merged.object
      for (field, parent) in [
        ("space_id", "spaces"), ("collection_id", "collections"),
        ("project_id", "projects"), ("learning_id", "learning"), ("course_id", "courses"),
        ("source_note_id", "notes"), ("semester_id", "semesters"), ("focus_id", "focus_sessions"),
      ] where !fields[value: field].isNull {
        let tomb = try db.one(
          "SELECT deleted FROM wb_sync_meta WHERE entity=? AND id=?",
          [.string(parent), fields[value: field]])
        if tomb.integer("deleted") == 1 {
          if [.attachments, .courses, .courseMeetings, .focusIntervals, .collections].contains(entity)
            || (entity == .lessons && (field == "learning_id" || field == "collection_id"))
          {
            merged = .null
            break
          }
          fields[field] = .null
        }
      }
      if !merged.isNull {
        if [
          .spaces, .collections, .tasks, .notes, .projects, .learning, .reflections, .accounts,
          .courses, .semesters, .courseMeetings,
        ].contains(entity) {
          fields = try validate(entity, fields, creating: before.isEmpty)
        }
        if entity == .attachments {
          try MediaFiles.validate(
            .object(fields),
            directory: db.url.deletingLastPathComponent().appendingPathComponent("attachments"),
            maximum: 100 * 1024 * 1024)
        }
        if entity == .focusIntervals {
          let start = try Clock.parse(fields.text("started_at"))
          let end = try Clock.parse(fields.text("ended_at"))
          try require(end >= start, "同步专注时段不正确")
          for other in try db.rows(
            "SELECT * FROM focus_intervals WHERE focus_id=? AND id!=? AND ended_at IS NOT NULL",
            [fields[value: "focus_id"], .string(doc.id)])
          {
            if try start < Clock.parse(other.text("ended_at"))
              && end > Clock.parse(other.text("started_at"))
            {
              try preserveConflict(entity: table, recordID: doc.id, payload: remote)
              fields = before
              break
            }
          }
        }
        try require(Set(fields.keys).isSubset(of: try db.columns(table)), "同步字段不正确")
        if fields.isEmpty {
          merged = .null
        } else {
          if before.isEmpty {
            try db.insert(table, fields)
          } else {
            try db.update(table, id: doc.id, fields)
          }
          merged = .object(fields)
        }
      }
    }
    if merged.isNull { try db.execute("DELETE FROM \(quote(table)) WHERE id=?", [.string(doc.id)]) }
    try db.execute(
      "INSERT INTO wb_sync_meta(entity,id,dirty,deleted,server_fields,base_payload) VALUES(?,?,?,?,?,?) ON CONFLICT(entity,id) DO UPDATE SET revision=revision+1,dirty=excluded.dirty,deleted=excluded.deleted,server_fields=excluded.server_fields,base_payload=excluded.base_payload",
      [
        .string(table), .string(doc.id), .integer(merged != remote ? 1 : 0),
        .integer(merged.isNull ? 1 : 0), doc.serverFields.map(JSONValue.string) ?? .null,
        remote.isNull ? .null : .string(try remote.json()),
      ])
  }
  func restoreConflict(_ id: String) throws -> CommandResult {
    let conflict = try db.record("wb_sync_conflicts", id: id)
    if conflict.isEmpty { return CommandResult() }
    let revision = try conflictRevision(entity: conflict.text("entity"), recordID: conflict.text("record_id"))
    return try resolveConflict(id, choice: .keepBoth, expectedRevision: revision)
  }
}
