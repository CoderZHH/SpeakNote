import CloudKit
import CryptoKit
import Foundation

// Only the dedicated zone is ever accepted. The personal Workbench zone is never shared.
func photoZone(_ input: [String: Any], account: String) throws -> (CKRecordZone.ID, Bool) {
  guard let space = input["workspace"] as? [String: Any], let name = space["zone"] as? String,
    name.hasPrefix("PhotoWorkspace_"),
    UUID(uuidString: String(name.dropFirst("PhotoWorkspace_".count))) != nil,
    let owner = space["owner"] as? String, let scope = space["scope"] as? String,
    ["private", "shared"].contains(scope)
  else { throw cloudError("这不是拍照共享空间") }
  let own = scope == "private"
  guard !own || owner == account else { throw cloudError("共享空间的所有者不匹配") }
  return (CKRecordZone.ID(zoneName: name, ownerName: own ? CKCurrentUserDefaultName : owner), own)
}
func photoInviteURL(_ value: String) throws -> URL {
  guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
    url.scheme == "https",
    ["icloud.com", "www.icloud.com", "icloud.com.cn", "www.icloud.com.cn"].contains(
      url.host?.lowercased() ?? ""), url.path.hasPrefix("/share/"),
    url.user == nil, url.password == nil
  else { throw cloudError("请粘贴有效的 iCloud 拍照邀请链接") }
  return url
}
func photoDiscoveredSpaces(
  _ zones: [CKRecordZone.ID], own: Bool, account: String, container: String, environment: String
) -> [[String: Any]] {
  zones.filter {
    $0.zoneName.hasPrefix("PhotoWorkspace_")
      && UUID(uuidString: String($0.zoneName.dropFirst(15))) != nil
  }
  .sorted { ($0.zoneName, $0.ownerName) < ($1.zoneName, $1.ownerName) }
  .map {
    [
      "id": $0.zoneName, "zone": $0.zoneName, "owner": own ? account : $0.ownerName,
      "scope": own ? "private" : "shared", "account": account, "container": container,
      "environment": environment,
    ]
  }
}
@MainActor func photoCloudExchange(
  _ input: [String: Any], container: CKContainer, account: String, environment: String
) async throws -> [String: Any] {
  let op = input["operation"] as? String ?? ""
  let identity: [String: Any] = [
    "account": account, "container": container.containerIdentifier ?? "",
    "environment": environment,
  ]
  if op == "photo.discover" {
    let owned = try await container.privateCloudDatabase.allRecordZones()
    let joined = try await container.sharedCloudDatabase.allRecordZones()
    let spaces =
      photoDiscoveredSpaces(
        owned.map(\.zoneID), own: true, account: account,
        container: container.containerIdentifier ?? "", environment: environment)
      + photoDiscoveredSpaces(
        joined.map(\.zoneID), own: false, account: account,
        container: container.containerIdentifier ?? "", environment: environment)
    return ["workspaces": spaces]
  }
  if op == "photo.create" {
    guard let name = input["zone"] as? String, name.hasPrefix("PhotoWorkspace_"),
      UUID(uuidString: String(name.dropFirst(15))) != nil
    else { throw cloudError("共享空间标识不正确") }
    let zone = CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
    try await ensureRecordZone(
      fetch: { _ = try await container.privateCloudDatabase.recordZone(for: zone) },
      create: { _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zone)) })
    var space = identity
    space["zone"] = name
    space["owner"] = account
    space["scope"] = "private"
    space["id"] = name
    return ["workspace": space]
  }
  if op == "photo.join" {
    let url = try photoInviteURL(input["url"] as? String ?? "")
    let results = try await container.shareMetadatas(for: [url])
    guard let result = results[url] else { throw cloudError("未找到共享邀请") }
    let metadata = try result.get()
    guard metadata.containerIdentifier == container.containerIdentifier,
      metadata.share.recordID.zoneID.zoneName.hasPrefix("PhotoWorkspace_"),
      UUID(uuidString: String(metadata.share.recordID.zoneID.zoneName.dropFirst(15))) != nil
    else { throw cloudError("这条邀请不属于拍照空间") }
    if let expected = input["expectedWorkspace"] as? [String: Any] {
      let expectedZone = try photoZone(["workspace": expected], account: account).0
      guard expectedZone == metadata.share.recordID.zoneID else {
        throw cloudError("请使用原拍照空间的新邀请，不能混合两个空间")
      }
    }
    let accepted = try await container.accept([metadata])
    guard let result = accepted[metadata] else { throw cloudError("没有接受共享邀请") }
    _ = try result.get()
    var space = identity
    let zone = metadata.share.recordID.zoneID
    space["zone"] = zone.zoneName
    space["owner"] = zone.ownerName
    space["scope"] = "shared"
    space["id"] = zone.zoneName
    return ["workspace": space]
  }
  let (zone, own) = try photoZone(input, account: account)
  let database = own ? container.privateCloudDatabase : container.sharedCloudDatabase
  if op == "photo.invite" {
    guard own else { throw cloudError("只有空间创建者可以邀请") }
    let email = (input["email"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard email.contains("@"), email.count <= 254 else { throw cloudError("请输入她使用 iCloud 的邮箱") }
    let recordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
    let share: CKShare
    do {
      guard let existing = try await database.record(for: recordID) as? CKShare else {
        throw cloudError("共享信息不正确")
      }
      share = existing
    } catch let error as CKError where error.code == .unknownItem {
      share = CKShare(recordZoneID: zone)
    }
    let people = try await container.shareParticipants(forEmailAddresses: [email])
    guard let person = people[email] else { throw cloudError("未找到这个 iCloud 用户，请检查邮箱") }
    let participant = try person.get()
    participant.permission = .readWrite
    share.publicPermission = .none
    share[CKShare.SystemFieldKey.title] = "我们的拍照订单" as CKRecordValue
    share.addParticipant(participant)
    let result = try await database.modifyRecords(
      saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
    guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare, let url = saved.url
    else { throw cloudError("没有生成邀请链接") }
    return ["url": url.absoluteString]
  }
  guard let path = input["assetDirectory"] as? String else { throw cloudError("拍照附件目录不可用") }
  let folder = URL(fileURLWithPath: path, isDirectory: true)
  if op == "photo.pull" {
    var token: CKServerChangeToken?
    if let raw = input["token"] as? String, let data = Data(base64Encoded: raw) {
      token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
    do {
      let changes = try await database.recordZoneChanges(inZoneWith: zone, since: token)
      var docs: [[String: Any]] = []
      for change in changes.modificationResultsByID.values {
        let record = try change.get().record
        if record is CKShare { continue }
        docs.append(try photoDocument(record, folder: folder))
      }
      for deletion in changes.deletions {
        let parts = deletion.recordID.recordName.split(separator: ":")
        if parts.count == 3, parts[0] == "photo" { throw cloudError("拍照记录被外部删除，请重新同步完整空间") }
      }
      let encoded = try NSKeyedArchiver.archivedData(
        withRootObject: changes.changeToken, requiringSecureCoding: true
      ).base64EncodedString()
      return ["documents": docs, "token": encoded, "more": changes.moreComing]
    } catch let error as CKError where error.code == .changeTokenExpired {
      return ["expired": true]
    } catch let error as CKError
      where error.code == .zoneNotFound || error.code == .permissionFailure
      || error.code == .unknownItem
    { return ["revoked": true, "error": "拍照共享权限已失效，请检查邀请或重新加入"] }
  }
  if op == "photo.push" {
    let pending = input["documents"] as? [[String: Any]] ?? []
    let groups = Dictionary(grouping: pending, by: { $0["order_id"] as? String ?? "" })
    var acks: [[String: Any]] = []
    var conflicts: [[String: Any]] = []
    for group in groups.values {
      let conflictStart = conflicts.count
      guard group.count <= 200 else { throw cloudError("待同步记录较多，请分批保存") }
      var records: [CKRecord] = []
      for d in group {
        guard let id = d["id"] as? String, let kind = d["kind"] as? String,
          let order = d["order_id"] as? String,
          UUID(uuidString: order) != nil,
          ["order", "workflow", "attachment", "activity"].contains(kind),
          id.hasPrefix(kind + ":"), UUID(uuidString: String(id.dropFirst(kind.count + 1))) != nil
        else { throw cloudError("拍照同步格式不正确") }
        let recordID = CKRecord.ID(recordName: "photo:" + id, zoneID: zone)
        let record: CKRecord
        if let raw = d["serverFields"] as? String, let data = Data(base64Encoded: raw) {
          let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
          decoder.requiresSecureCoding = true
          defer { decoder.finishDecoding() }
          guard let decoded = CKRecord(coder: decoder), decoded.recordID == recordID else {
            throw cloudError("拍照同步区域不匹配")
          }
          record = decoded
        } else {
          record = CKRecord(recordType: "PhotoRecord", recordID: recordID)
        }
        record["kind"] = kind as CKRecordValue
        record["orderID"] = order as CKRecordValue
        record["payload"] =
          String(
            data: try JSONSerialization.data(withJSONObject: d["payload"] ?? NSNull()),
            encoding: .utf8)! as CKRecordValue
        record["media"] = nil
        if kind == "attachment", let metadata = d["payload"] as? [String: Any],
          metadata["purged"] as? Bool != true
        {
          let file = try photoAssetURL(metadata, folder: folder)
          guard FileManager.default.fileExists(atPath: file.path) else {
            throw cloudError("订单截图尚未下载完成")
          }
          record["media"] = CKAsset(fileURL: file)
        }
        records.append(record)
      }
      do {
        let result = try await database.modifyRecords(
          saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        var failure: String?
        for (record, d) in zip(records, group) {
          do {
            guard let save = result.saveResults[record.recordID] else {
              throw cloudError("拍照保存结果缺失")
            }
            acks.append(["pending": d, "serverFields": try archive(save.get())])
          } catch let error as CKError where error.code == .serverRecordChanged {
            conflicts.append(
              try photoDocument(try await database.record(for: record.recordID), folder: folder))
          } catch { failure = describeCloudError(error) }
        }
        if let failure, conflicts.count == conflictStart {
          return ["acks": acks, "conflicts": conflicts, "error": failure]
        }
      } catch { return ["acks": acks, "conflicts": conflicts, "error": describeCloudError(error)] }
    }
    return ["acks": acks, "conflicts": conflicts]
  }
  throw cloudError("拍照云端操作不正确")
}
private func photoAssetURL(_ p: [String: Any], folder: URL) throws -> URL {
  guard let key = p["file_key"] as? String,
    key.range(of: "^[0-9a-fA-F-]{36}\\.(png|jpg|webp|gif|heic|avif)$", options: .regularExpression)
      != nil
  else { throw cloudError("订单截图标识不正确") }
  guard key.split(separator: ".").first.map(String.init) == p["id"] as? String else {
    throw cloudError("图片文件与记录不匹配")
  }
  return folder.appendingPathComponent(key)
}
private func photoDocument(_ record: CKRecord, folder: URL) throws -> [String: Any] {
  guard let kind = record["kind"] as? String, let order = record["orderID"] as? String,
    let raw = record["payload"] as? String,
    let payload = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
    record.recordID.recordName.hasPrefix("photo:\(kind):")
  else { throw cloudError("拍照云端记录不正确") }
  if kind == "attachment", payload["purged"] as? Bool != true {
    let target = try photoAssetURL(payload, folder: folder)
    guard let source = (record["media"] as? CKAsset)?.fileURL else { throw cloudError("共享截图缺少文件") }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let bytes = try Data(contentsOf: source)
    guard bytes.count <= 20 * 1024 * 1024, bytes.count == (payload["size"] as? NSNumber)?.intValue,
      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == payload["sha256"]
        as? String
    else { throw cloudError("共享图片完整性校验失败") }
    let staging = folder.appendingPathComponent(".download-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.copyItem(at: source, to: staging)
    if FileManager.default.fileExists(atPath: target.path) {
      _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
    } else {
      try FileManager.default.moveItem(at: staging, to: target)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
  }
  return [
    "id": String(record.recordID.recordName.dropFirst(6)), "kind": kind, "order_id": order,
    "payload": payload, "serverFields": try archive(record),
  ]
}
