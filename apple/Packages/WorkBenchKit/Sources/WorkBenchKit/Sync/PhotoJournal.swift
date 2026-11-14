import Foundation

extension PhotoEngine {
  func pendingDocuments() throws -> [SyncDocument] {
    var counts: [String: Int] = [:]
    return try db.rows(
      "SELECT * FROM photo_records WHERE dirty=1 AND published=1 AND conflict IS NULL ORDER BY order_id,CASE kind WHEN 'attachment' THEN 0 WHEN 'workflow' THEN 1 WHEN 'order' THEN 2 ELSE 3 END"
    ).compactMap { row in
      let order = row.text("order_id")
      counts[order, default: 0] += 1
      if counts[order]! > 180 { return nil }
      return SyncDocument(
        id: row.identifier, kind: row.text("kind"), orderID: order, payload: try payload(row),
        revision: row.integer("revision"),
        serverFields: row[value: "server"].isNull ? nil : row.text("server"))
    }
  }
  func acknowledge(_ doc: SyncDocument, serverFields: String) throws {
    let p = try payload(row(doc.id))
    try db.execute(
      "UPDATE photo_records SET base=?,server=?,dirty=CASE WHEN revision=? THEN 0 ELSE dirty END WHERE id=?",
      [
        .string(try (p["purged"].bool ? JSONValue.null : doc.payload).json()),
        .string(serverFields), .integer(doc.revision ?? -1), .string(doc.id),
      ])
  }
  func receive(_ documents: [SyncDocument]) throws {
    // Files must be present and verified before committing records or advancing a cursor.
    let deletedOrders = Set(
      try db.rows("SELECT order_id,payload FROM photo_records WHERE kind='order'").filter {
        try payload($0)["purged"].bool
      }.map { $0.text("order_id") }
    )
    .union(
      documents.filter { $0.kind == "order" && $0.payload["purged"].bool }.compactMap(\.order_id))
    for doc in documents
    where doc.kind == "attachment" && !doc.payload.isNull && !doc.payload["purged"].bool
      && !deletedOrders.contains(doc.order_id ?? "")
    { try MediaFiles.validate(doc.payload, directory: assets, maximum: 20 * 1024 * 1024) }
    try db.transaction {
      for doc in documents.sorted(by: {
        ($0.kind == "attachment" ? 0 : 1) < ($1.kind == "attachment" ? 0 : 1)
      }) {
        guard let kind = doc.kind, let orderID = doc.order_id,
          ["order", "workflow", "attachment", "activity"].contains(kind),
          doc.id.hasPrefix(kind + ":"),
          UUID(uuidString: String(doc.id.dropFirst(kind.count + 1))) != nil,
          UUID(uuidString: orderID) != nil
        else { throw WorkBenchError("共享订单格式不正确") }
        let remote = doc.payload
        let old = try row(doc.id)
        let local = try payload(old)
        let owner = try payload(row("order:" + orderID))
        try require(
          old.isEmpty || (old.text("kind") == kind && old.text("order_id") == orderID), "共享记录归属不正确")
        if remote["purged"].bool {
          try require(
            remote["id"].string == String(doc.id.dropFirst(kind.count + 1))
              && remote["order_id"] == .string(orderID) && !remote["deleted_at"].string.isEmpty,
            "删除标记格式不正确")
        }
        let tomb = remote["purged"].bool || local["purged"].bool || owner["purged"].bool
        if tomb {
          let payload: JSONValue =
            remote["purged"].bool
            ? remote
            : local["purged"].bool
              ? local
              : .object([
                "id": .string(String(doc.id.dropFirst(kind.count + 1))),
                "order_id": .string(orderID), "deleted_at": owner["deleted_at"],
                "purged": .bool(true),
              ])
          if kind == "attachment" {
            for p in [local, remote] where !p["file_key"].string.isEmpty {
              try db.execute("INSERT OR IGNORE INTO photo_garbage VALUES(?)", [p["file_key"]])
            }
          }
          try db.execute(
            "INSERT INTO photo_records(id,kind,order_id,payload,base,server,dirty,published) VALUES(?,?,?,?,'null',?,?,1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,base='null',server=excluded.server,dirty=excluded.dirty,published=1,revision=photo_records.revision+1,conflict=NULL",
            [
              .string(doc.id), .string(kind), .string(orderID), .string(try payload.json()),
              doc.serverFields.map(JSONValue.string) ?? .null, .integer(payload == remote ? 0 : 1),
            ])
          if kind == "order" { try purge(orderID, now: Clock.parse(payload["deleted_at"].string)) }
          continue
        }
        if !remote.isNull {
          try require(
            remote["id"].string == String(doc.id.dropFirst(kind.count + 1))
              && (!["order", "workflow"].contains(kind) || remote["id"] == .string(orderID)),
            "共享记录标识不匹配")
          if kind == "order" { try validateOrder(remote) }
          if kind == "workflow" {
            try require(
              PhotoStage.allCases.filter { $0 != .completed }.contains {
                $0.rawValue == remote["stage"].string
              }, "共享进度不正确")
          }
          if kind == "attachment" {
            try require(remote["order_id"] == .string(orderID), "共享图片归属不正确")
          }
        }
        let base = (try? JSONValue(json: old.text("base"))) ?? .null
        if !old[value: "conflict"].isNull, remote == base,
          try JSONValue(json: old.text("conflict"))["payload"] != base
        { continue }
        if old.integer("dirty") == 1 && local != remote {
          if let merged = RecordMerge.photo(kind: kind, base: base, local: local, remote: remote) {
            try db.execute(
              "UPDATE photo_records SET payload=?,base=?,server=?,dirty=?,revision=revision+1,conflict=NULL WHERE id=?",
              [
                .string(try merged.json()), .string(try remote.json()),
                doc.serverFields.map(JSONValue.string) ?? .null, .integer(merged == remote ? 0 : 1),
                .string(doc.id),
              ])
          } else {
            let conflict = JSONValue.string(try doc.value().json())
            try db.execute(
              "UPDATE photo_records SET conflict=?,revision=revision+CASE WHEN conflict=? THEN 0 ELSE 1 END WHERE id=?",
              [conflict, conflict, .string(doc.id)])
          }
        } else {
          try db.execute(
            "INSERT INTO photo_records(id,kind,order_id,payload,base,server,dirty,published) VALUES(?,?,?,?,?,?,0,1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,base=excluded.base,server=excluded.server,dirty=0,published=1,revision=photo_records.revision+CASE WHEN photo_records.payload=excluded.payload THEN 0 ELSE 1 END,conflict=NULL",
            [
              .string(doc.id), .string(kind), .string(orderID), .string(try remote.json()),
              .string(try remote.json()), doc.serverFields.map(JSONValue.string) ?? .null,
            ])
        }
      }
      try reconcileConflicts()
      try bump()
    }
    try? cleanAssets()
  }

  // Revisit persisted conflicts on upgrade as well as after receiving changes.
  func reconcileConflicts() throws {
    try db.transaction {
      var changed = false
      for row in try db.rows("SELECT * FROM photo_records WHERE conflict IS NOT NULL") {
        let remote = try JSONValue(json: row.text("conflict"))
        let base = try JSONValue(json: row.text("base"))
        guard let merged = RecordMerge.photo(kind: row.text("kind"), base: base,
          local: try payload(row), remote: remote["payload"]) else { continue }
        if row.text("kind") == "order" {
          do { try validateOrder(merged) } catch { continue }
        }
        try db.execute(
          "UPDATE photo_records SET payload=?,base=?,server=?,dirty=?,conflict=NULL,revision=revision+1 WHERE id=?",
          [.string(try merged.json()), .string(try remote["payload"].json()), remote["serverFields"],
           .integer(merged == remote["payload"] ? 0 : 1), row[value: "id"]])
        changed = true
      }
      if changed { try bump() }
    }
  }
}
