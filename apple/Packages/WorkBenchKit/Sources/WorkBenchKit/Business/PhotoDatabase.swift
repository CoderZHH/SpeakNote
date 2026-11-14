import Foundation

public actor PhotoDatabase {
  private let engine: PhotoEngine
  public let url: URL
  public init(url: URL) throws {
    self.url = url
    engine = try PhotoEngine(url: url)
  }
  public func snapshot() throws -> PhotoSnapshot { try engine.snapshot() }
  @discardableResult public func perform(_ command: PhotoCommand, now: Date = .now) throws
    -> CommandResult
  { try engine.perform(command, now: now) }
  public func bind(_ workspace: JSONValue) throws { try engine.bind(workspace) }
  public func setting(_ key: String) throws -> JSONValue { try engine.setting(key) }
  public func setSetting(_ key: String, value: JSONValue) throws {
    try engine.setSetting(key, value)
  }
  public func pendingDocuments() throws -> [SyncDocument] { try engine.pendingDocuments() }
  public func acknowledge(_ document: SyncDocument, serverFields: String) throws {
    try engine.acknowledge(document, serverFields: serverFields)
  }
  public func receive(_ documents: [SyncDocument]) throws { try engine.receive(documents) }
  public func importImage(data: Data, name: String, orderID: String) throws -> MediaAttachment {
    try engine.importImage(data: data, name: name, orderID: orderID)
  }
  public func discardUnpublishedImages(orderID: String) throws {
    try engine.discardUnpublishedImages(orderID: orderID)
  }
  public func backup(to destination: URL) throws { try engine.db.backup(to: destination) }
  public var assets: URL { engine.assets }
}
final class PhotoEngine {
  let db: SQLite
  let assets: URL
  init(url: URL) throws {
    db = try SQLite(url)
    assets = url.deletingLastPathComponent().appendingPathComponent(
      "photo-attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try db.script(
      "CREATE TABLE IF NOT EXISTS photo_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS photo_records(id TEXT PRIMARY KEY,kind TEXT NOT NULL,order_id TEXT NOT NULL,payload TEXT NOT NULL,base TEXT NOT NULL DEFAULT 'null',server TEXT,revision INTEGER NOT NULL DEFAULT 1,dirty INTEGER NOT NULL DEFAULT 1,published INTEGER NOT NULL DEFAULT 0,conflict TEXT); CREATE TABLE IF NOT EXISTS photo_drafts(id TEXT PRIMARY KEY,payload TEXT NOT NULL,base_revision INTEGER NOT NULL DEFAULT 0,base_stage TEXT,workflow_revision INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS photo_garbage(file_key TEXT PRIMARY KEY); CREATE TABLE IF NOT EXISTS photo_generation(value INTEGER NOT NULL); INSERT INTO photo_generation SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM photo_generation); CREATE INDEX IF NOT EXISTS photo_order_records ON photo_records(order_id,kind);"
    )
    try reconcileConflicts()
  }
  func setting(_ key: String) throws -> JSONValue {
    let row = try db.one("SELECT value FROM photo_settings WHERE key=?", [.string(key)])
    return try row.isEmpty ? .null : JSONValue(json: row.text("value"))
  }
  func setSetting(_ key: String, _ value: JSONValue) throws {
    try db.execute(
      "INSERT INTO photo_settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      [.string(key), .string(try value.json())])
    try bump()
  }
  func bump() throws { try db.execute("UPDATE photo_generation SET value=value+1") }
  func bind(_ space: JSONValue) throws {
    for field in ["zone", "owner", "account", "container", "environment", "scope"] {
      _ = try Validation.text(space[field], "共享空间", max: 200, required: true)
    }
    try require(
      space["zone"].string.hasPrefix("PhotoWorkspace_")
        && UUID(uuidString: String(space["zone"].string.dropFirst(15))) != nil
        && ["private", "shared"].contains(space["scope"].string), "这不是拍照共享空间")
    let old = try setting("workspace")
    try require(
      old.isNull
        || ["zone", "owner", "account", "container", "environment", "scope"].allSatisfy {
          old[$0] == space[$0]
        }, "已有共享空间，不能混合其他账号或空间")
    try setSetting("workspace", space)
    try setSetting("locked", .bool(false))
  }
  func row(_ id: String) throws -> Record { try db.record("photo_records", id: id) }
  func payload(_ row: Record) throws -> JSONValue {
    try row.isEmpty ? .null : JSONValue(json: row.text("payload"))
  }
  func put(_ id: String, kind: String, orderID: String, payload: JSONValue, published: Bool) throws
  {
    try db.execute(
      "INSERT INTO photo_records(id,kind,order_id,payload,published) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revision=photo_records.revision+1,dirty=1,published=MAX(photo_records.published,excluded.published)",
      [
        .string(id), .string(kind), .string(orderID), .string(try payload.json()),
        .integer(published ? 1 : 0),
      ])
  }
  func snapshot() throws -> PhotoSnapshot {
    var result = PhotoSnapshot()
    result.workspace = try setting("workspace")
    result.locked = try setting("locked").bool
    result.lastSync = try setting("last_sync").isNull ? nil : setting("last_sync").string
    result.pending = Int(
      try db.one("SELECT COUNT(*) AS n FROM photo_records WHERE dirty=1 AND published=1").integer(
        "n"))
    result.generation = try db.one("SELECT value FROM photo_generation").integer("value")
    if result.locked { return result }
    for row in try db.rows("SELECT * FROM photo_records ORDER BY order_id,kind,id") {
      var value = try payload(row)
      if value.isNull { continue }
      value["revision"] = row[value: "revision"]
      value["pending"] = .bool(row.integer("dirty") == 1)
      value["published"] = .bool(row.integer("published") == 1)
      if row.text("kind") == "order" && row.integer("published") == 1 && value["deleted_at"].isNull
      {
        let workflow = try self.row("workflow:" + value["id"].string)
        value["workflow"] = try payload(workflow)
        value["workflow_revision"] = workflow[value: "revision"]
        result.orders.append(PhotoOrder(fields: value.object))
      }
      if row.text("kind") == "attachment" && value["deleted_at"].isNull {
        result.attachments.append(MediaAttachment(fields: value.object))
      }
      if !row[value: "conflict"].isNull {
        let remote = try JSONValue(json: row.text("conflict"))
        result.conflicts.append(
          SyncConflict(
            id: row.identifier, entity: row.text("kind"), recordID: row.text("order_id"),
            local: value, remote: remote["payload"], revision: row.integer("revision"),
            base: (try? JSONValue(json: row.text("base"))) ?? .null))
      }
    }
    return result
  }
  func validateOrder(_ p: JSONValue) throws {
    for (field, max) in [("brand", 200), ("requirements", 20000), ("notes", 20000)] {
      _ = try Validation.text(p[field], field, max: max, required: field == "brand")
    }
    if p["deadline"] != .string("") {
      try require(try !Validation.day(p["deadline"]).isNull, "请选择截止日期")
    }
    for field in ["postage", "commission"] where !p[field].isNull {
      _ = try Validation.integer(p[field], 0...1_000_000_000)
    }
    guard case .array(let images) = p["images"] else { throw WorkBenchError("图片列表不正确") }
    try require(images.count <= 10 && Set(images).count == images.count, "每单最多 10 张不同的截图")
    for image in images {
      let row = try self.row("attachment:" + image.string)
      let data = try payload(row)
      try require(
        UUID(uuidString: image.string) != nil && row.text("order_id") == p["id"].string
          && !data.isNull && data["deleted_at"].isNull, "图片不属于这张订单")
    }
  }
  func perform(_ command: PhotoCommand, now: Date) throws -> CommandResult {
    try require(try !setting("locked").bool, "共享权限已失效，请重新加入后操作")
    let result = try db.transaction {
      let stamp = JSONValue.string(Clock.stamp(now))
      let space = try setting("workspace")
      switch command {
      case .create(let input):
        try require(UUID(uuidString: input.id) != nil, "订单 ID 不正确")
        let existing = try payload(row("order:" + input.id))
        if !existing.isNull {
          try require(
            existing["creation_token"] == .string(input.creationToken)
              && existing["deleted_at"].isNull, "订单已存在或已删除")
          return CommandResult(id: input.id)
        }
        try require(!space.isNull, "请先连接拍照共享空间")
        var fields = input.fields
        fields["currency"] = .string("CNY")
        fields["created_at"] = stamp
        fields["updated_at"] = stamp
        fields["updated_by"] = space["account"]
        fields["workspace_id"] = space["zone"]
        fields["deleted_at"] = .null
        fields["brand"] = try Validation.text(
          fields[value: "brand"], "品牌", max: 200, required: true)
        let p = JSONValue.object(fields)
        try validateOrder(p)
        try put("order:" + input.id, kind: "order", orderID: input.id, payload: p, published: true)
        try publishImages(p)
        try transition(id: input.id, stage: input.stage, expected: 0, now: now)
        return CommandResult(id: input.id)
      case .patch(let id, let field, let before, let value):
        let row = try row("order:" + id)
        var p = try payload(row)
        try require(!p.isNull && p["deleted_at"].isNull, "订单已删除或不存在")
        try require(p[field.rawValue] == before, "这个字段已被修改，请刷新后重试")
        if before == value { return CommandResult(id: id) }
        if !row[value: "conflict"].isNull {
          let remote = try JSONValue(json: row.text("conflict"))["payload"]
          let base = (try? JSONValue(json: row.text("base"))) ?? .null
          try require(!remote.isNull && !RecordMerge.photoConflictFields(
            base: base, local: p, remote: remote).contains(field.rawValue),
            "这个字段有两份修改，请点订单中的“核对修改”；当前输入已保留。")
        }
        p[field.rawValue] = value
        if field == .brand {
          p["brand"] = try Validation.text(value, "品牌", max: 200, required: true)
        }
        try validateOrder(p)
        p["updated_at"] = stamp
        p["updated_by"] = space["account"]
        try put("order:" + id, kind: "order", orderID: id, payload: p, published: true)
        try publishImages(p)
        if field == .images {
          for image in before.array where !value.array.contains(image) {
            try tombstone("attachment:" + image.string, now: now)
          }
        }
        return CommandResult(id: id)
      case .transition(let id, let stage, let expected):
        try transition(id: id, stage: stage, expected: expected, now: now)
        return CommandResult(id: id)
      case .delete(let id, let expected):
        let row = try row("order:" + id)
        let p = try payload(row)
        try require(
          !p.isNull && !p["purged"].bool && row.integer("revision") == expected
            && row[value: "conflict"].isNull, "订单已变化，请刷新后操作")
        try purge(id, now: now)
        return CommandResult(id: id)
      case .resolveConflict(let id, let keepLocal, let expected):
        let row = try row(id)
        if row.isEmpty || row[value: "conflict"].isNull { return CommandResult(id: id) }
        try require(
          row.integer("revision") == expected, "版本已更新，请查看刷新后的比较内容再选择。")
        let remote = try JSONValue(json: row.text("conflict"))
        let local = try payload(row)
        let base = (try? JSONValue(json: row.text("base"))) ?? .null
        let resolved = row.text("kind") == "order"
          ? RecordMerge.resolvePhotoOrder(base: base, local: local, remote: remote["payload"], preferLocal: keepLocal)
          : (keepLocal ? local : remote["payload"])
        if row.text("kind") == "order" { try validateOrder(resolved) }
        try db.execute(
          "UPDATE photo_records SET payload=?,base=?,server=?,dirty=?,conflict=NULL,revision=revision+1 WHERE id=?",
          [
            .string(try resolved.json()),
            .string(try remote["payload"].json()), remote["serverFields"],
            .integer(resolved == remote["payload"] ? 0 : 1), .string(id),
          ])
        return CommandResult(id: id)
      }
    }
    try bump()
    try? cleanAssets()
    return result
  }
  func publishImages(_ p: JSONValue) throws {
    for image in p["images"].array {
      try db.execute(
        "UPDATE photo_records SET published=1 WHERE id=?", [.string("attachment:" + image.string)])
    }
  }
  func transition(id: String, stage: PhotoStage, expected: Int64, now: Date) throws {
    let order = try payload(row("order:" + id))
    try require(!order.isNull && order["deleted_at"].isNull, "订单已不存在")
    let row = try row("workflow:" + id)
    var p = try payload(row)
    let currentStage = p["completed_at"].isNull
      ? PhotoStage(rawValue: p["stage"].string) : .completed
    if !p.isNull && currentStage == stage { return }
    try require(
      row.integer("revision") == expected && row[value: "conflict"].isNull, "进度已变化，请刷新后操作")
    let before = p
    let complete = stage == .completed
    let underlying = complete ? PhotoStage.refund : stage
    if complete { try require(p["stage"] == .string("refund"), "请先进入待返款，再标记已返款") }
    if p.isNull {
      p = .object([
        "id": .string(id), "stage": .string(underlying.rawValue), "completed_at": .null,
        "output_at": .null, "review_at": .null, "return_at": .null, "submit_at": .null,
      ])
    }
    let index = PhotoStage.allCases.firstIndex(of: underlying)!
    for (i, field) in ["output_at", "review_at", "return_at", "submit_at"].enumerated() {
      p[field] = index > i ? (p[field].isNull ? .string(Clock.stamp(now)) : p[field]) : .null
    }
    p["stage"] = .string(underlying.rawValue)
    p["completed_at"] = complete ? .string(Clock.stamp(now)) : .null
    p["updated_at"] = .string(Clock.stamp(now))
    p["updated_by"] = try setting("workspace")["account"]
    try put("workflow:" + id, kind: "workflow", orderID: id, payload: p, published: true)
    let event = UUID().uuidString.lowercased()
    try put(
      "activity:" + event, kind: "activity", orderID: id,
      payload: .object([
        "id": .string(event), "order_id": .string(id), "before": before, "after": p,
        "at": .string(Clock.stamp(now)), "actor": p["updated_by"],
      ]), published: true)
  }
  func tombstone(_ id: String, now: Date) throws {
    let row = try row(id)
    let p = try payload(row)
    if row.isEmpty || p["purged"].bool { return }
    if row.text("kind") == "attachment", !p["file_key"].string.isEmpty {
      try db.execute("INSERT OR IGNORE INTO photo_garbage VALUES(?)", [p["file_key"]])
    }
    try put(
      id, kind: row.text("kind"), orderID: row.text("order_id"),
      payload: .object([
        "id": .string(String(id.split(separator: ":", maxSplits: 1).last!)),
        "order_id": row[value: "order_id"], "deleted_at": .string(Clock.stamp(now)),
        "purged": .bool(true),
      ]), published: true)
    try db.execute("UPDATE photo_records SET base='null',conflict=NULL WHERE id=?", [.string(id)])
  }
  func purge(_ orderID: String, now: Date) throws {
    for row in try db.rows("SELECT id FROM photo_records WHERE order_id=?", [.string(orderID)]) {
      try tombstone(row.identifier, now: now)
    }
  }
  func cleanAssets() throws {
    for row in try db.rows("SELECT file_key FROM photo_garbage") {
      let key = row.text("file_key")
      let live = try db.rows("SELECT payload FROM photo_records WHERE kind='attachment'").contains {
        row in
        let p = try payload(row)
        return p["file_key"] == .string(key) && p["deleted_at"].isNull
      }
      if !live { try MediaFiles.remove(key, in: assets) }
      try db.execute("DELETE FROM photo_garbage WHERE file_key=?", [.string(key)])
    }
  }
  func discardUnpublishedImages(orderID: String) throws {
    for row in try db.rows(
      "SELECT * FROM photo_records WHERE order_id=? AND kind='attachment' AND published=0",
      [.string(orderID)])
    {
      let p = try payload(row)
      try MediaFiles.remove(p["file_key"].string, in: assets)
      try db.execute("DELETE FROM photo_records WHERE id=?", [row[value: "id"]])
    }
    try bump()
  }
}
