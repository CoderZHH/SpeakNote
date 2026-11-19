import Foundation

enum WorkspaceMigration {
  static func run(_ db: SQLite) throws {
    let version = try db.one("PRAGMA user_version").values.first?.int ?? 0
    try require(version <= 22, "数据库由更新版本创建，请先更新 WorkBench")
    let tables = try Set(
      db.rows("SELECT name FROM sqlite_master WHERE type='table'").map { $0.text("name") })
    try require(tables.isEmpty || tables.contains("tasks"), "选择的文件不是 WorkBench 数据库")
    if !tables.isEmpty && version < 22 {
      let directory = db.url.deletingLastPathComponent().appendingPathComponent(
        "schema-backups", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let backup = directory.appendingPathComponent(
        "before-v22-" + UUID().uuidString.lowercased() + ".sqlite")
      try db.backup(to: backup)
    }
    try db.script("PRAGMA foreign_keys=OFF")
    defer { try? db.script("PRAGMA foreign_keys=ON") }
    try db.transaction {
      let url = Bundle.module.url(forResource: "schema", withExtension: "sql")!
      try db.script(String(contentsOf: url, encoding: .utf8))
      let additions: [(String, String, String)] = [
        (
          "tasks", "reminder_enabled",
          "INTEGER NOT NULL DEFAULT 0 CHECK(typeof(reminder_enabled)='integer' AND reminder_enabled IN (0,1))"
        ),
        ("tasks", "reminder_at", "TEXT"),
        ("tasks", "course_id", "TEXT REFERENCES courses(id) ON DELETE SET NULL"),
        ("tasks", "collection_id", "TEXT REFERENCES collections(id) ON DELETE SET NULL"),
        ("notes", "course_id", "TEXT REFERENCES courses(id) ON DELETE SET NULL"),
        ("notes", "collection_id", "TEXT REFERENCES collections(id) ON DELETE SET NULL"),
        ("attachments", "course_id", "TEXT REFERENCES courses(id) ON DELETE CASCADE"),
        ("attachments", "collection_id", "TEXT REFERENCES collections(id) ON DELETE CASCADE"),
        ("reflections", "tags", "TEXT NOT NULL DEFAULT '[]'"),
        ("notes", "remark", "TEXT NOT NULL DEFAULT ''"),
        (
          "focus_sessions", "untracked_seconds",
          "INTEGER CHECK(untracked_seconds IS NULL OR (typeof(untracked_seconds)='integer' AND untracked_seconds>=0))"
        ),
        ("projects", "repo_path", "TEXT"), ("projects", "completed_at", "TEXT"),
        ("projects", "position", "INTEGER NOT NULL DEFAULT 0"),
        ("accounts", "tags", "TEXT NOT NULL DEFAULT '[]'"),
        ("notes", "project_id", "TEXT REFERENCES projects(id) ON DELETE SET NULL"),
        ("notes", "learning_id", "TEXT REFERENCES learning(id) ON DELETE SET NULL"),
        ("learning", "parent_id", "TEXT REFERENCES learning(id) ON DELETE CASCADE"),
        ("learning", "position", "INTEGER NOT NULL DEFAULT 0"),
        (
          "learning", "status",
          "TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','done'))"
        ), ("learning", "completed_at", "TEXT"),
        ("lessons", "parent_id", "TEXT REFERENCES lessons(id) ON DELETE CASCADE"),
        ("lessons", "collection_id", "TEXT REFERENCES collections(id) ON DELETE CASCADE"),
        ("tasks", "start_time", "TEXT"), ("tasks", "end_time", "TEXT"),
        ("tasks", "abandoned_at", "TEXT"),
        (
          "tasks", "importance",
          "INTEGER NOT NULL DEFAULT 1 CHECK(typeof(importance)='integer' AND importance BETWEEN 1 AND 5)"
        ),
      ]
      for (table, column, definition) in additions where try !db.columns(table).contains(column) {
        try db.script("ALTER TABLE \(quote(table)) ADD COLUMN \(quote(column)) \(definition)")
      }
      // Rebuild only the CHECK/default definition; keep every column and custom index/trigger.
      try rebuild(
        db, "accounts", pattern: "CHECK\\s*\\(\\s*platform\\s+IN\\s*\\([^)]*\\)\\s*\\)",
        replacement:
          "CHECK(platform IN ('douyin','bilibili','xiaohongshu','x','tiktok','instagram','youtube'))"
      )
      try rebuild(
        db, "tasks", pattern: "CHECK\\s*\\(\\s*status\\s+IN\\s*\\([^)]*\\)\\s*\\)",
        replacement: "CHECK(status IN ('todo','done','abandoned'))")
      try rebuild(
        db, "tasks", pattern: "importance INTEGER NOT NULL DEFAULT 3",
        replacement: "importance INTEGER NOT NULL DEFAULT 1")
      try rebuild(
        db, "focus_sessions", pattern: "CHECK\\s*\\(\\s*status\\s+IN\\s*\\([^)]*\\)\\s*\\)",
        replacement: "CHECK(status IN ('running','paused','ended'))")
      try rebuild(
        db, "attachments", pattern: "CHECK\\s*\\(\\s*\\(task_id IS NOT NULL\\)[^;]*?=1\\)",
        replacement:
          "CHECK((task_id IS NOT NULL)+(note_id IS NOT NULL)+(project_id IS NOT NULL)+(learning_id IS NOT NULL)+(course_id IS NOT NULL)+(collection_id IS NOT NULL)=1)"
      )
      try rebuild(
        db, "lessons",
        pattern: "(learning_id\\s+TEXT)\\s+NOT\\s+NULL",
        replacement: "$1"
      )
      let lessonsSQL = try db.one(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='lessons'"
      ).text("sql")
      if !lessonsSQL.localizedCaseInsensitiveContains("collection_id IS NOT NULL") {
        try rebuild(
          db, "lessons",
          pattern: "\\)\\s*$",
          replacement: ", CHECK((learning_id IS NOT NULL)+(collection_id IS NOT NULL)=1))"
        )
      }
      if version < 7 {
        for lesson in try db.rows("SELECT * FROM lessons WHERE task_id IS NULL") {
          let key = JSONValue.id()
          let now = JSONValue.string(Clock.stamp())
          try db.insert(
            "tasks",
            [
              "id": key, "title": lesson[value: "title"],
              "status": .string(lesson.integer("done") == 1 ? "done" : "todo"),
              "learning_id": lesson[value: "learning_id"], "planned_date": .null, "created_at": now,
              "updated_at": now, "completed_at": lesson.integer("done") == 1 ? now : .null,
            ])
          try db.execute("UPDATE lessons SET task_id=? WHERE id=?", [key, lesson[value: "id"]])
        }
        try db.execute("UPDATE learning SET parent_id=NULL")
      }
      if version < 11 {
        for focus in try db.rows(
          "SELECT * FROM focus_sessions WHERE status='running' AND active_since IS NOT NULL AND NOT EXISTS(SELECT 1 FROM focus_intervals WHERE focus_id=focus_sessions.id AND ended_at IS NULL)"
        ) {
          try db.insert(
            "focus_intervals",
            [
              "id": .id(), "focus_id": focus[value: "id"],
              "started_at": focus[value: "active_since"],
            ])
        }
      }
      if version < 13 {
        try db.execute("UPDATE tasks SET importance=4 WHERE priority='high' OR important=1")
      }
      if version < 14 {
        try db.execute(
          "UPDATE tasks SET importance=1 WHERE importance=3 AND priority='normal' AND important=0")
      }
      if version < 16 {
        try db.execute(
          "UPDATE focus_sessions SET untracked_seconds=MAX(0,elapsed_seconds-COALESCE((SELECT SUM(MAX(0,CAST((julianday(ended_at)-julianday(started_at))*86400 AS INTEGER))) FROM focus_intervals WHERE focus_id=focus_sessions.id AND ended_at IS NOT NULL),0)) WHERE untracked_seconds IS NULL"
        )
      }
      if !tables.isEmpty && version < 22 {
        let now = JSONValue.string(Clock.stamp())
        if try db.one("SELECT count(*) AS n FROM projects").integer("n") > 0,
          try db.one("SELECT count(*) AS n FROM spaces WHERE legacy_entity='projects'").integer("n") == 0
        {
          try db.insert(
            "spaces",
            [
              "id": .string("space-legacy-projects"), "title": .string("项目"),
              "symbol": .string("folder"), "color": .string("blue"),
              "allows_lessons": .integer(0), "legacy_entity": .string("projects"),
              "position": .integer(0), "status": .string("active"),
              "created_at": now, "updated_at": now,
            ])
        }
        if try db.one("SELECT count(*) AS n FROM learning").integer("n") > 0,
          try db.one("SELECT count(*) AS n FROM spaces WHERE legacy_entity='learning'").integer("n") == 0
        {
          let pos = try db.one("SELECT COALESCE(MAX(position),-1)+1 AS n FROM spaces").integer("n")
          try db.insert(
            "spaces",
            [
              "id": .string("space-legacy-learning"), "title": .string("学习"),
              "symbol": .string("book"), "color": .string("teal"),
              "allows_lessons": .integer(1), "legacy_entity": .string("learning"),
              "position": .integer(pos), "status": .string("active"),
              "created_at": now, "updated_at": now,
            ])
        }
      }
      try require(try db.rows("PRAGMA foreign_key_check").isEmpty, "数据库关联校验失败")
      try db.script("PRAGMA user_version=22")
    }
  }
  private static func rebuild(_ db: SQLite, _ table: String, pattern: String, replacement: String)
    throws
  {
    let original = try db.one(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", [.string(table)]
    ).text("sql")
    let updated = original.replacingOccurrences(
      of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    if original == updated { return }
    let objects = try db.rows(
      "SELECT sql FROM sqlite_master WHERE tbl_name=? AND type IN ('index','trigger') AND sql IS NOT NULL",
      [.string(table)])
    let columns = try db.columns(table).sorted().map(quote).joined(separator: ",")
    let create = updated.replacingOccurrences(
      of: "(?i)^CREATE TABLE(?: IF NOT EXISTS)? \\S+",
      with: "CREATE TABLE \(quote(table + "_native_upgrade"))", options: .regularExpression)
    try db.script(create)
    try db.execute(
      "INSERT INTO \(quote(table + "_native_upgrade"))(\(columns)) SELECT \(columns) FROM \(quote(table))"
    )
    try db.script(
      "DROP TABLE \(quote(table)); ALTER TABLE \(quote(table + "_native_upgrade")) RENAME TO \(quote(table));"
    )
    for object in objects { try db.script(object.text("sql")) }
  }
}
